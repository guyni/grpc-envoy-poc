// Package client implements one simulated node agent: a long-lived,
// independently authenticated bidirectional stream with reconnect and
// application heartbeats.
package client

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"math/rand"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"

	pb "github.com/guyni/grpc-envoy-poc/gen/msgbroker/v1"
	"github.com/guyni/grpc-envoy-poc/internal/auth"
)

// Config is shared by every simulated agent.
type Config struct {
	Target    string
	TLS       *tls.Config // nil => plaintext h2c (P1 baseline)
	Secret    []byte
	Issuer    string
	Audience  string
	Cluster   string
	TokenMode string // normal|expired|forged|wrongaud|wrongiss|noidentity|missing
	TokenTTL  time.Duration

	Heartbeat        time.Duration
	HeartbeatTimeout time.Duration
	EchoInterval     time.Duration
	EchoSize         int
	// HelloNode overrides the node id sent in Hello, to exercise the
	// identity-binding check. Empty means "use the token's node".
	HelloNode string

	Log *slog.Logger
}

// Agent is one simulated node.
type Agent struct {
	cfg  Config
	Node string
	id   int
	rnd  *rand.Rand

	mu         sync.Mutex
	connects   int64
	reconnects int64
	commands   int64
	acks       int64
	mismatches int64
	generation uint64
	lastErr    string
	latencies  []float64 // ms
	echoRTTs   []float64 // ms
	sessions   int64
}

// New builds agent number id with node name "<prefix>-%04d".
func New(cfg Config, prefix string, id int) *Agent {
	return &Agent{
		cfg:  cfg,
		Node: fmt.Sprintf("%s-%04d", prefix, id),
		id:   id,
		rnd:  rand.New(rand.NewSource(time.Now().UnixNano() + int64(id)*7919)),
	}
}

func (a *Agent) log() *slog.Logger {
	if a.cfg.Log == nil {
		return slog.Default()
	}
	return a.cfg.Log.With("node", a.Node)
}

// Run keeps one logical session alive until ctx is done.
func (a *Agent) Run(ctx context.Context) {
	backoff := time.Second
	for {
		if ctx.Err() != nil {
			return
		}
		start := time.Now()
		err := a.session(ctx)
		if ctx.Err() != nil {
			return
		}

		a.mu.Lock()
		a.sessions++
		if err != nil {
			a.lastErr = err.Error()
		}
		a.mu.Unlock()

		// Reset backoff only after a stable session, not after a brief success.
		if time.Since(start) > 30*time.Second {
			backoff = time.Second
		} else if backoff < 30*time.Second {
			backoff *= 2
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
		}
		a.mu.Lock()
		a.reconnects++
		a.mu.Unlock()

		// Full jitter.
		sleep := time.Duration(a.rnd.Int63n(int64(backoff)) + 1)
		a.log().Debug("session ended, reconnecting", "err", err, "sleep", sleep, "backoff", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(sleep):
		}
	}
}

func (a *Agent) session(parent context.Context) error {
	var tc credentials.TransportCredentials
	if a.cfg.TLS != nil {
		tc = credentials.NewTLS(a.cfg.TLS)
	} else {
		tc = insecure.NewCredentials()
	}

	conn, err := grpc.NewClient(a.cfg.Target,
		grpc.WithTransportCredentials(tc),
		grpc.WithPerRPCCredentials(tokenCreds{a: a, secure: a.cfg.TLS != nil}),
	)
	if err != nil {
		return err
	}
	defer conn.Close()

	ctx, cancel := context.WithCancel(parent)
	defer cancel()

	stream, err := pb.NewMsgBrokerClient(conn).Connect(ctx)
	if err != nil {
		return err
	}

	helloNode := a.cfg.HelloNode
	if helloNode == "" {
		helloNode = a.Node
	}
	if err := stream.Send(&pb.AgentMessage{
		NodeId: a.Node, ClusterId: a.cfg.Cluster,
		Payload: &pb.AgentMessage_Hello{Hello: &pb.Hello{
			NodeId: helloNode, ClusterId: a.cfg.Cluster, AgentVersion: "poc/0.1",
		}},
	}); err != nil {
		return err
	}

	var lastRecv atomic.Int64
	lastRecv.Store(time.Now().UnixNano())
	// A stream can be up without a session: if the application is stalled when
	// Hello arrives it may never send Welcome, and the stream then looks healthy
	// while the agent is invisible to the broker. Require Welcome, or reconnect.
	var welcomed atomic.Bool
	sessionStart := time.Now()

	sendCh := make(chan *pb.AgentMessage, 64)
	done := make(chan struct{})
	errCh := make(chan error, 3)

	// Single writer: every Send goes through this goroutine.
	go func() {
		hb := time.NewTicker(a.cfg.Heartbeat)
		defer hb.Stop()
		var echoC <-chan time.Time
		if a.cfg.EchoInterval > 0 && a.cfg.EchoSize > 0 {
			et := time.NewTicker(a.cfg.EchoInterval)
			defer et.Stop()
			echoC = et.C
		}
		for {
			select {
			case <-ctx.Done():
				return
			case m := <-sendCh:
				if err := stream.Send(m); err != nil {
					errCh <- err
					cancel()
					return
				}
			case <-hb.C:
				if err := stream.Send(&pb.AgentMessage{
					NodeId: a.Node, ClusterId: a.cfg.Cluster,
					Payload: &pb.AgentMessage_Heartbeat{Heartbeat: &pb.Heartbeat{SentUnixNano: time.Now().UnixNano()}},
				}); err != nil {
					errCh <- err
					cancel()
					return
				}
			case <-echoC:
				if err := stream.Send(&pb.AgentMessage{
					NodeId: a.Node, ClusterId: a.cfg.Cluster,
					Payload: &pb.AgentMessage_Echo{Echo: &pb.Echo{
						Payload: make([]byte, a.cfg.EchoSize), SentUnixNano: time.Now().UnixNano(),
					}},
				}); err != nil {
					errCh <- err
					cancel()
					return
				}
			}
		}
	}()

	// Watchdog: a healthy transport with a stuck application is detected here,
	// not by TCP or HTTP/2 keepalive.
	go func() {
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if !welcomed.Load() && time.Since(sessionStart) > a.cfg.HeartbeatTimeout {
					errCh <- fmt.Errorf("no Welcome within %s — reconnecting", a.cfg.HeartbeatTimeout)
					cancel()
					return
				}
				if time.Since(time.Unix(0, lastRecv.Load())) > a.cfg.HeartbeatTimeout {
					errCh <- fmt.Errorf("heartbeat timeout (%s) — reconnecting", a.cfg.HeartbeatTimeout)
					cancel()
					return
				}
			}
		}
	}()

	go func() {
		defer close(done)
		for {
			m, err := stream.Recv()
			if err != nil {
				errCh <- err
				return
			}
			lastRecv.Store(time.Now().UnixNano())
			if _, ok := m.Payload.(*pb.BrokerMessage_Welcome); ok {
				welcomed.Store(true)
			}
			a.handle(m, sendCh, ctx)
		}
	}()

	select {
	case <-ctx.Done():
		_ = stream.CloseSend()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
		return nil
	case err := <-errCh:
		return err
	}
}

func (a *Agent) handle(m *pb.BrokerMessage, sendCh chan<- *pb.AgentMessage, ctx context.Context) {
	switch p := m.Payload.(type) {
	case *pb.BrokerMessage_Welcome:
		a.mu.Lock()
		a.connects++
		a.generation = p.Welcome.Generation
		a.mu.Unlock()
		a.log().Info("session established",
			"generation", p.Welcome.Generation, "session_id", p.Welcome.SessionId)

	case *pb.BrokerMessage_Command:
		a.mu.Lock()
		a.commands++
		if p.Command.NodeId != a.Node {
			a.mismatches++
			a.mu.Unlock()
			a.log().Error("cross-agent command delivery", "command_node", p.Command.NodeId, "command_id", p.Command.CommandId)
			return
		}
		lat := float64(time.Now().UnixNano()-p.Command.IssuedUnixNano) / 1e6
		a.latencies = appendCapped(a.latencies, lat, 4096)
		a.acks++
		a.mu.Unlock()
		a.log().Debug("command acked", "id", p.Command.CommandId, "latency_ms", lat)

		select {
		case sendCh <- &pb.AgentMessage{
			NodeId: a.Node, ClusterId: a.cfg.Cluster,
			Payload: &pb.AgentMessage_CommandAck{CommandAck: &pb.CommandAck{
				CommandId:      p.Command.CommandId,
				IssuedUnixNano: p.Command.IssuedUnixNano,
				AckedUnixNano:  time.Now().UnixNano(),
			}},
		}:
		case <-ctx.Done():
		}

	case *pb.BrokerMessage_Echo:
		rtt := float64(time.Now().UnixNano()-p.Echo.SentUnixNano) / 1e6
		a.mu.Lock()
		a.echoRTTs = appendCapped(a.echoRTTs, rtt, 4096)
		a.mu.Unlock()

	case *pb.BrokerMessage_HeartbeatAck:
		// Liveness is tracked by lastRecv in the session loop.
	}
}

func appendCapped(s []float64, v float64, max int) []float64 {
	if len(s) >= max {
		return s
	}
	return append(s, v)
}

// Row is the per-agent CSV line.
type Row struct {
	Node       string  `json:"node"`
	Connects   int64   `json:"connects"`
	Reconnects int64   `json:"reconnects"`
	Sessions   int64   `json:"sessions"`
	Commands   int64   `json:"commands"`
	Acks       int64   `json:"acks"`
	Mismatches int64   `json:"mismatches"`
	Generation uint64  `json:"generation"`
	LatencyP50 float64 `json:"latency_p50_ms"`
	LatencyP99 float64 `json:"latency_p99_ms"`
	EchoP50    float64 `json:"echo_p50_ms"`
	EchoP99    float64 `json:"echo_p99_ms"`
	LastError  string  `json:"last_error"`
}

// Snapshot returns a consistent copy of this agent's counters.
func (a *Agent) Snapshot() Row {
	a.mu.Lock()
	defer a.mu.Unlock()
	return Row{
		Node: a.Node, Connects: a.connects, Reconnects: a.reconnects, Sessions: a.sessions,
		Commands: a.commands, Acks: a.acks, Mismatches: a.mismatches, Generation: a.generation,
		LatencyP50: quantile(a.latencies, 0.50), LatencyP99: quantile(a.latencies, 0.99),
		EchoP50: quantile(a.echoRTTs, 0.50), EchoP99: quantile(a.echoRTTs, 0.99),
		LastError: a.lastErr,
	}
}

// AllLatencies returns a copy of this agent's command latency samples (ms).
func (a *Agent) AllLatencies() []float64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	cp := make([]float64, len(a.latencies))
	copy(cp, a.latencies)
	return cp
}

// AllEchoRTTs returns a copy of this agent's echo round-trip samples (ms).
func (a *Agent) AllEchoRTTs() []float64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	cp := make([]float64, len(a.echoRTTs))
	copy(cp, a.echoRTTs)
	return cp
}

// Quantile returns the q-quantile of an unsorted sample slice.
func Quantile(s []float64, q float64) float64 { return quantile(s, q) }

func quantile(s []float64, q float64) float64 {
	if len(s) == 0 {
		return 0
	}
	cp := make([]float64, len(s))
	copy(cp, s)
	sort.Float64s(cp)
	i := int(q * float64(len(cp)-1))
	return cp[i]
}

type tokenCreds struct {
	a      *Agent
	secure bool
}

func (t tokenCreds) GetRequestMetadata(ctx context.Context, _ ...string) (map[string]string, error) {
	if t.a.cfg.TokenMode == "missing" {
		return nil, nil
	}
	tok, err := t.a.token()
	if err != nil {
		return nil, err
	}
	return map[string]string{"authorization": "Bearer " + tok}, nil
}

func (t tokenCreds) RequireTransportSecurity() bool { return t.secure }

func (a *Agent) token() (string, error) {
	now := time.Now()
	c := auth.Claims{
		Issuer: a.cfg.Issuer, Audience: a.cfg.Audience, Subject: a.Node,
		IssuedAt: now.Unix(), NotBefore: now.Unix(), Expires: now.Add(a.cfg.TokenTTL).Unix(),
		Cluster: a.cfg.Cluster, Node: a.Node,
	}
	secret := a.cfg.Secret

	switch a.cfg.TokenMode {
	case "", "normal":
	case "expired":
		c.IssuedAt = now.Add(-2 * time.Hour).Unix()
		c.NotBefore = c.IssuedAt
		c.Expires = now.Add(-time.Hour).Unix()
	case "forged":
		secret = []byte("not-the-shared-secret")
	case "wrongaud":
		c.Audience = "another-service"
	case "wrongiss":
		c.Issuer = "unknown-issuer"
	case "noidentity":
		c.Cluster, c.Node = "", ""
	case "missing":
		return "", errors.New("token mode missing has no token")
	default:
		return "", fmt.Errorf("unknown token mode %q", a.cfg.TokenMode)
	}
	return auth.Sign(c, secret)
}
