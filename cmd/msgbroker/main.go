// Command msgbroker is the synthetic bidirectional gRPC service under test.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/keepalive"

	pb "github.com/guyni/grpc-envoy-poc/gen/msgbroker/v1"
	"github.com/guyni/grpc-envoy-poc/internal/server"
	"github.com/guyni/grpc-envoy-poc/internal/stats"
)

func main() {
	var (
		addr        = flag.String("addr", ":50051", "gRPC listen address")
		statsAddr   = flag.String("stats-addr", ":9090", "HTTP stats listen address")
		issuer      = flag.String("issuer", "poc-issuer", "required token issuer")
		audience    = flag.String("audience", "msgbroker", "required token audience")
		secretFile  = flag.String("secret-file", "", "file containing the HMAC secret (or set POC_JWT_SECRET)")
		cmdInterval = flag.Duration("command-interval", 5*time.Second, "per-agent command interval")
		cmdPayload  = flag.Int("command-payload", 0, "command payload bytes")
		maxStreams  = flag.Uint("max-streams", 1024, "advertised MaxConcurrentStreams")
		tlsCert     = flag.String("tls-cert", "", "server certificate (empty = plaintext h2c)")
		tlsKey      = flag.String("tls-key", "", "server private key")
		logLevel    = flag.String("log-level", "info", "debug|info|warn|error")
	)
	flag.Parse()

	level := slog.LevelInfo
	switch strings.ToLower(*logLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(log)

	secret, err := loadSecret(*secretFile)
	if err != nil {
		log.Error("secret", "err", err)
		os.Exit(1)
	}

	srv := server.New(server.Config{
		Issuer: *issuer, Audience: *audience, Secret: secret,
		CommandInterval: *cmdInterval, CommandPayload: *cmdPayload,
		MaxStreams: uint32(*maxStreams), Log: log,
	})

	opts := []grpc.ServerOption{
		grpc.MaxConcurrentStreams(uint32(*maxStreams)),
		grpc.StreamInterceptor(srv.StreamAuth),
		grpc.StatsHandler(stats.ConnStats{C: srv.Counters()}),
		// The relay's pooled upstream keeps connections open without active
		// streams and pings every 60s; allow that policy.
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime: 60 * time.Second, PermitWithoutStream: true,
		}),
	}
	if *tlsCert != "" {
		creds, err := credentials.NewServerTLSFromFile(*tlsCert, *tlsKey)
		if err != nil {
			log.Error("tls", "err", err)
			os.Exit(1)
		}
		opts = append(opts, grpc.Creds(creds))
	}

	gs := grpc.NewServer(opts...)
	pb.RegisterMsgBrokerServer(gs, srv)

	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Error("listen", "addr", *addr, "err", err)
		os.Exit(1)
	}

	mux := http.NewServeMux()
	mux.Handle("/", srv.Counters())
	mux.HandleFunc("/debug/hang", func(w http.ResponseWriter, r *http.Request) {
		on := r.URL.Query().Get("on")
		srv.SetHang(on == "1" || on == "true")
		fmt.Fprintf(w, "hang=%v\n", on == "1" || on == "true")
	})
	hs := &http.Server{Addr: *statsAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := hs.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("stats server", "err", err)
		}
	}()

	go func() {
		log.Info("msgbroker listening",
			"addr", *addr, "stats", *statsAddr, "tls", *tlsCert != "",
			"issuer", *issuer, "audience", *audience, "max_streams", *maxStreams)
		if err := gs.Serve(lis); err != nil {
			log.Error("serve", "err", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	log.Info("shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = hs.Shutdown(ctx)
	gs.Stop()
}

func loadSecret(file string) ([]byte, error) {
	if file != "" {
		b, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		return []byte(strings.TrimSpace(string(b))), nil
	}
	if v := os.Getenv("POC_JWT_SECRET"); v != "" {
		return []byte(v), nil
	}
	return nil, errors.New("no secret: set -secret-file or POC_JWT_SECRET")
}
