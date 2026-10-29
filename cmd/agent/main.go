// Command agent runs N simulated node agents against the msgbroker service,
// either directly (P1/P2) or through the Envoy relay (P3).
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/guyni/grpc-envoy-poc/internal/client"
)

func main() {
	var (
		target     = flag.String("target", "", "host:port to dial")
		plaintext  = flag.Bool("plaintext", false, "use h2c instead of TLS")
		insecure   = flag.Bool("insecure", false, "TLS without server verification")
		caFile     = flag.String("ca", "", "trust bundle for server verification")
		certDir    = flag.String("cert-dir", "", "directory of <node>.crt/.key client certs (relay mTLS)")
		cluster    = flag.String("cluster", "poc", "cluster claim")
		nodePrefix = flag.String("node-prefix", "agent", "node name prefix")
		agents     = flag.Int("agents", 1, "number of simulated agents")
		duration   = flag.Duration("duration", 60*time.Second, "run duration")
		heartbeat  = flag.Duration("heartbeat", 30*time.Second, "application heartbeat interval")
		hbTimeout  = flag.Duration("heartbeat-timeout", 90*time.Second, "reconnect if nothing received for this long")
		echoEvery  = flag.Duration("echo-interval", 0, "echo (round-trip) interval, 0 disables")
		echoSize   = flag.Int("echo-size", 0, "echo payload bytes")
		sessionMax = flag.Duration("session-max", 0, "reopen the stream after this long (0 disables)")
		tokenMode  = flag.String("token-mode", "normal", "normal|expired|forged|wrongaud|wrongiss|noidentity|missing")
		helloNode  = flag.String("hello-node", "", "override the node id sent in Hello (identity-binding test)")
		tokenTTL   = flag.Duration("token-ttl", 15*time.Minute, "token lifetime")
		issuer     = flag.String("issuer", "poc-issuer", "token issuer")
		audience   = flag.String("audience", "msgbroker", "token audience")
		secretFile = flag.String("secret-file", "", "file containing the HMAC secret (or set POC_JWT_SECRET)")
		outDir     = flag.String("out", "", "directory for agents.csv and summary.json")
		logLevel   = flag.String("log-level", "warn", "debug|info|warn|error")
		progress   = flag.Duration("progress", 10*time.Second, "progress print interval (0 disables)")
	)
	flag.Parse()

	if *target == "" {
		fmt.Fprintln(os.Stderr, "-target is required")
		os.Exit(2)
	}

	level := slog.LevelWarn
	switch strings.ToLower(*logLevel) {
	case "debug":
		level = slog.LevelDebug
	case "info":
		level = slog.LevelInfo
	case "error":
		level = slog.LevelError
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	secret, err := loadSecret(*secretFile)
	if err != nil {
		log.Error("secret", "err", err)
		os.Exit(1)
	}

	cfg := client.Config{
		Target: *target, Secret: secret, Issuer: *issuer, Audience: *audience,
		Cluster: *cluster, TokenMode: *tokenMode, TokenTTL: *tokenTTL,
		Heartbeat: *heartbeat, HeartbeatTimeout: *hbTimeout,
		EchoInterval: *echoEvery, EchoSize: *echoSize,
		HelloNode: *helloNode,
		Log:       log,
	}

	baseTLS, err := buildTLS(*plaintext, *insecure, *caFile)
	if err != nil {
		log.Error("tls", "err", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	if *duration > 0 {
		var stop context.CancelFunc
		ctx, stop = context.WithTimeout(ctx, *duration)
		defer stop()
	}

	agentsList := make([]*client.Agent, 0, *agents)
	for i := 0; i < *agents; i++ {
		c := cfg
		if baseTLS != nil {
			tlsCfg := baseTLS.Clone()
			if *certDir != "" {
				node := fmt.Sprintf("%s-%04d", *nodePrefix, i)
				crt, key := filepath.Join(*certDir, node+".crt"), filepath.Join(*certDir, node+".key")
				// Read the current certificate at each handshake so a renewed
				// certificate on disk is used without a restart.
				tlsCfg.GetClientCertificate = func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
					loaded, err := tls.LoadX509KeyPair(crt, key)
					if err != nil {
						return nil, err
					}
					return &loaded, nil
				}
			}
			c.TLS = tlsCfg
		}
		agentsList = append(agentsList, client.New(c, *nodePrefix, i))
	}

	log.Info("starting load", "agents", len(agentsList), "target", *target,
		"plaintext", *plaintext, "insecure", *insecure, "token_mode", *tokenMode,
		"heartbeat", *heartbeat, "duration", *duration)

	var wg sync.WaitGroup
	start := time.Now()
	for _, a := range agentsList {
		wg.Add(1)
		go func(a *client.Agent) {
			defer wg.Done()
			if *sessionMax > 0 {
				runWithSessionMax(ctx, a, *sessionMax)
				return
			}
			a.Run(ctx)
		}(a)
	}

	if *progress > 0 {
		go func() {
			t := time.NewTicker(*progress)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					connected, commands, reconnects, mismatches := totals(agentsList)
					log.Warn("progress", "elapsed", time.Since(start).Round(time.Second).String(),
						"connected_now", connected, "commands", commands,
						"reconnects", reconnects, "mismatches", mismatches)
				}
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start)

	rows := make([]client.Row, 0, len(agentsList))
	var allLat, allEcho []float64
	for _, a := range agentsList {
		rows = append(rows, a.Snapshot())
		allLat = append(allLat, a.AllLatencies()...)
		allEcho = append(allEcho, a.AllEchoRTTs()...)
	}
	sort.Float64s(allLat)
	sort.Float64s(allEcho)

	sum := summary{
		Target: *target, StartedAt: start.UTC().Format(time.RFC3339),
		ElapsedSeconds: elapsed.Seconds(), Agents: len(agentsList),
		Plaintext: *plaintext, Insecure: *insecure, TokenMode: *tokenMode,
		CommandLatencyP50Ms: client.Quantile(allLat, 0.50),
		CommandLatencyP99Ms: client.Quantile(allLat, 0.99),
		EchoLatencyP50Ms:    client.Quantile(allEcho, 0.50),
		EchoLatencyP99Ms:    client.Quantile(allEcho, 0.99),
	}
	for _, r := range rows {
		sum.Connects += r.Connects
		sum.Reconnects += r.Reconnects
		sum.Commands += r.Commands
		sum.Acks += r.Acks
		sum.Mismatches += r.Mismatches
		if r.LastError != "" {
			sum.AgentsWithErrors++
		}
	}
	if len(allLat) > 0 {
		sum.CommandSamples = len(allLat)
	}

	if *outDir != "" {
		if err := writeResults(*outDir, rows, sum); err != nil {
			log.Error("write results", "err", err)
			os.Exit(1)
		}
	}

	b, _ := json.MarshalIndent(sum, "", "  ")
	fmt.Println(string(b))
}

// runWithSessionMax reopens the stream before the token or certificate expires,
// with randomized timing across agents.
func runWithSessionMax(ctx context.Context, a *client.Agent, max time.Duration) {
	for ctx.Err() == nil {
		jittered := max/2 + time.Duration(time.Now().UnixNano()%int64(max/2+1))
		sub, cancel := context.WithTimeout(ctx, jittered)
		a.Run(sub)
		cancel()
		if ctx.Err() != nil {
			return
		}
	}
}

func totals(as []*client.Agent) (connected, commands, reconnects, mismatches int64) {
	for _, a := range as {
		r := a.Snapshot()
		connected += r.Connects
		commands += r.Commands
		reconnects += r.Reconnects
		mismatches += r.Mismatches
	}
	return
}

type summary struct {
	Target              string  `json:"target"`
	StartedAt           string  `json:"started_at"`
	ElapsedSeconds      float64 `json:"elapsed_seconds"`
	Agents              int     `json:"agents"`
	Plaintext           bool    `json:"plaintext"`
	Insecure            bool    `json:"insecure"`
	TokenMode           string  `json:"token_mode"`
	Connects            int64   `json:"connects"`
	Reconnects          int64   `json:"reconnects"`
	Commands            int64   `json:"commands"`
	Acks                int64   `json:"acks"`
	Mismatches          int64   `json:"mismatches"`
	AgentsWithErrors    int     `json:"agents_with_errors"`
	CommandSamples      int     `json:"command_samples"`
	CommandLatencyP50Ms float64 `json:"command_latency_p50_ms"`
	CommandLatencyP99Ms float64 `json:"command_latency_p99_ms"`
	EchoLatencyP50Ms    float64 `json:"echo_latency_p50_ms"`
	EchoLatencyP99Ms    float64 `json:"echo_latency_p99_ms"`
}

func writeResults(dir string, rows []client.Row, sum summary) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	f, err := os.Create(filepath.Join(dir, "agents.csv"))
	if err != nil {
		return err
	}
	defer f.Close()
	w := csv.NewWriter(f)
	defer w.Flush()
	_ = w.Write([]string{"node", "connects", "reconnects", "sessions", "commands", "acks",
		"mismatches", "generation", "latency_p50_ms", "latency_p99_ms", "echo_p50_ms", "echo_p99_ms", "last_error"})
	for _, r := range rows {
		_ = w.Write([]string{r.Node, i64(r.Connects), i64(r.Reconnects), i64(r.Sessions),
			i64(r.Commands), i64(r.Acks), i64(r.Mismatches), strconv.FormatUint(r.Generation, 10),
			ff(r.LatencyP50), ff(r.LatencyP99), ff(r.EchoP50), ff(r.EchoP99), r.LastError})
	}
	b, _ := json.MarshalIndent(sum, "", "  ")
	return os.WriteFile(filepath.Join(dir, "summary.json"), b, 0o644)
}

func i64(v int64) string  { return strconv.FormatInt(v, 10) }
func ff(v float64) string { return strconv.FormatFloat(v, 'f', 2, 64) }

func buildTLS(plaintext, insecure bool, caFile string) (*tls.Config, error) {
	if plaintext {
		return nil, nil
	}
	cfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if insecure {
		cfg.InsecureSkipVerify = true
	}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, err
		}
		roots := x509.NewCertPool()
		if !roots.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("no certificates parsed from %s", caFile)
		}
		cfg.RootCAs = roots
	}
	return cfg, nil
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
	return nil, fmt.Errorf("no secret: set -secret-file or POC_JWT_SECRET")
}
