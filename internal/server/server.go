// Package server implements the synthetic msgbroker gRPC service.
package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	pb "github.com/guyni/grpc-envoy-poc/gen/msgbroker/v1"
	"github.com/guyni/grpc-envoy-poc/internal/auth"
	"github.com/guyni/grpc-envoy-poc/internal/stats"
)

// Config is the service configuration.
type Config struct {
	Issuer          string
	Audience        string
	Secret          []byte
	CommandInterval time.Duration
	CommandPayload  int
	MaxStreams      uint32
	Log             *slog.Logger
}

// Server holds the session registry and counters.
type Server struct {
	pb.UnimplementedMsgBrokerServer

	cfg Config
	st  *stats.Counters

	mu       sync.Mutex
	sessions map[string]*session
	cmdSeq   atomic.Uint64

	// hang simulates an application that stops processing while the transport
	// stays healthy: handlers stop sending acks and commands, the process keeps
	// answering HTTP (stats) and HTTP/2 PINGs.
	hang atomic.Bool
}

// SetHang turns the simulated application stall on or off.
func (s *Server) SetHang(on bool) { s.hang.Store(on) }

type session struct {
	id         string
	key        string
	node       string
	cluster    string
	generation uint64
	cancel     context.CancelFunc
	started    time.Time

	cmdsSent  atomic.Int64
	cmdsAcked atomic.Int64
}

func New(cfg Config) *Server {
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	return &Server{
		cfg:      cfg,
		st:       stats.New(),
		sessions: make(map[string]*session),
	}
}

// Counters exposes the service counters to the HTTP exposition.
func (s *Server) Counters() *stats.Counters { return s.st }

type ctxKey struct{}

func claimsFrom(ctx context.Context) (auth.Claims, bool) {
	c, ok := ctx.Value(ctxKey{}).(auth.Claims)
	return c, ok
}

type authStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (w *authStream) Context() context.Context { return w.ctx }

// StreamAuth validates exactly one bearer token per stream and binds the
// verified principal to the stream context. The token's cluster and node
// claims — never the TLS peer or source IP — are the agent identity.
func (s *Server) StreamAuth(srv any, ss grpc.ServerStream, _ *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
	ctx := ss.Context()
	md, _ := metadata.FromIncomingContext(ctx)
	vals := md.Get("authorization")

	if len(vals) == 0 {
		s.st.AuthFailure(string(auth.ReasonMissing))
		return status.Error(codes.Unauthenticated, "missing authorization metadata")
	}
	if len(vals) > 1 {
		s.st.AuthFailure(string(auth.ReasonMalformed))
		return status.Error(codes.Unauthenticated, "exactly one authorization value required")
	}
	const prefix = "Bearer "
	if len(vals[0]) <= len(prefix) || vals[0][:len(prefix)] != prefix {
		s.st.AuthFailure(string(auth.ReasonMalformed))
		return status.Error(codes.Unauthenticated, "authorization must be a Bearer token")
	}

	claims, err := auth.Parse(vals[0][len(prefix):], s.cfg.Secret)
	if err != nil {
		var ae *auth.Error
		reason := "invalid"
		if errors.As(err, &ae) {
			reason = string(ae.Reason)
		}
		s.st.AuthFailure(reason)
		return status.Error(codes.Unauthenticated, err.Error())
	}
	if claims.Issuer != s.cfg.Issuer {
		s.st.AuthFailure(string(auth.ReasonIssuer))
		return status.Errorf(codes.Unauthenticated, "issuer %q not accepted", claims.Issuer)
	}
	if claims.Audience != s.cfg.Audience {
		s.st.AuthFailure(string(auth.ReasonAudience))
		return status.Errorf(codes.Unauthenticated, "audience %q not accepted", claims.Audience)
	}

	return handler(srv, &authStream{ServerStream: ss, ctx: context.WithValue(ctx, ctxKey{}, claims)})
}

// Connect runs one agent's long-lived bidirectional session.
func (s *Server) Connect(stream pb.MsgBroker_ConnectServer) error {
	claims, ok := claimsFrom(stream.Context())
	if !ok {
		return status.Error(codes.Internal, "missing verified claims")
	}
	log := s.cfg.Log.With("cluster", claims.Cluster, "node", claims.Node)

	s.st.StreamsTotal.Add(1)
	s.st.StreamsActive.Add(1)
	defer s.st.StreamsActive.Add(-1)

	ctx, cancel := context.WithCancel(stream.Context())
	defer cancel()

	out := make(chan *pb.BrokerMessage, 64)
	sendErr := make(chan error, 1)
	var seq atomic.Uint64
	next := func() uint64 { return seq.Add(1) }

	// Single writer owns stream.Send.
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case m := <-out:
				if err := stream.Send(m); err != nil {
					sendErr <- err
					cancel()
					return
				}
			}
		}
	}()

	enqueue := func(m *pb.BrokerMessage) {
		select {
		case out <- m:
		case <-ctx.Done():
		}
	}

	var sess *session
	defer func() {
		if sess != nil {
			s.unregister(sess)
		}
	}()

	for {
		m, err := stream.Recv()
		if err != nil {
			if errors.Is(err, io.EOF) {
				log.Info("agent closed send side")
				return nil
			}
			select {
			case se := <-sendErr:
				return se
			default:
			}
			return err
		}

		// A hung application consumes messages but processes none of them:
		// no heartbeat acks, no commands. The transport is still healthy.
		if s.hang.Load() {
			continue
		}

		// Token expiry is enforced for the whole stream lifetime, not only at
		// startup; the handler must stop, unblock and return.
		if claims.Expired(time.Now()) {
			s.st.AuthFailure(string(auth.ReasonExpired))
			return status.Error(codes.Unauthenticated, "token expired during stream")
		}

		switch p := m.Payload.(type) {
		case *pb.AgentMessage_Hello:
			if p.Hello.NodeId != claims.Node || p.Hello.ClusterId != claims.Cluster {
				return status.Errorf(codes.PermissionDenied,
					"hello identity cluster=%q node=%q does not match token cluster=%q node=%q",
					p.Hello.ClusterId, p.Hello.NodeId, claims.Cluster, claims.Node)
			}
			if sess != nil {
				return status.Error(codes.InvalidArgument, "duplicate hello on stream")
			}
			sess = s.register(claims, cancel)
			log = log.With("generation", sess.generation)
			log.Info("session registered", "agent_version", p.Hello.AgentVersion)
			enqueue(&pb.BrokerMessage{Seq: next(), Payload: &pb.BrokerMessage_Welcome{Welcome: &pb.Welcome{
				SessionId: sess.id, Generation: sess.generation,
				ClusterId: claims.Cluster, NodeId: claims.Node,
			}}})
			go s.pushCommands(ctx, sess, enqueue, next)

		case *pb.AgentMessage_Heartbeat:
			s.st.HeartbeatsRecv.Add(1)
			enqueue(&pb.BrokerMessage{Seq: next(), Payload: &pb.BrokerMessage_HeartbeatAck{HeartbeatAck: &pb.HeartbeatAck{
				SentUnixNano: p.Heartbeat.SentUnixNano, RecvUnixNano: time.Now().UnixNano(),
			}}})

		case *pb.AgentMessage_Echo:
			s.st.EchoesServed.Add(1)
			enqueue(&pb.BrokerMessage{Seq: next(), Payload: &pb.BrokerMessage_Echo{Echo: p.Echo}})

		case *pb.AgentMessage_CommandAck:
			s.st.CommandsAcked.Add(1)
			if sess != nil {
				sess.cmdsAcked.Add(1)
			}
		}
	}
}

// pushCommands sends one unique command per interval for this agent only.
func (s *Server) pushCommands(ctx context.Context, sess *session, enqueue func(*pb.BrokerMessage), next func() uint64) {
	t := time.NewTicker(s.cfg.CommandInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if s.hang.Load() {
				continue
			}
			id := fmt.Sprintf("%s:%d", sess.node, s.cmdSeq.Add(1))
			payload := make([]byte, s.cfg.CommandPayload)
			s.st.CommandsSent.Add(1)
			sess.cmdsSent.Add(1)
			enqueue(&pb.BrokerMessage{Seq: next(), Payload: &pb.BrokerMessage_Command{Command: &pb.Command{
				CommandId: id, NodeId: sess.node, Kind: "poc-command",
				Payload: payload, IssuedUnixNano: time.Now().UnixNano(),
			}}})
		}
	}
}

func (s *Server) register(c auth.Claims, cancel context.CancelFunc) *session {
	key := c.Cluster + "/" + c.Node
	id := make([]byte, 8)
	_, _ = rand.Read(id)

	s.mu.Lock()
	defer s.mu.Unlock()

	var gen uint64 = 1
	if old, ok := s.sessions[key]; ok {
		gen = old.generation + 1
		// Fence the half-open predecessor: its handler returns, its streams end.
		old.cancel()
		s.st.Fences.Add(1)
	}

	sess := &session{
		id: hex.EncodeToString(id), key: key, node: c.Node, cluster: c.Cluster,
		generation: gen, cancel: cancel, started: time.Now(),
	}
	s.sessions[key] = sess
	s.st.SessionsActive.Add(1)
	return sess
}

func (s *Server) unregister(sess *session) {
	s.mu.Lock()
	if cur, ok := s.sessions[sess.key]; ok && cur == sess {
		delete(s.sessions, sess.key)
	}
	s.mu.Unlock()
	s.st.SessionsActive.Add(-1)
}

// Sessions returns a point-in-time copy of registered sessions.
func (s *Server) Sessions() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.sessions)
}
