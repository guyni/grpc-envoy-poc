// Package stats holds the counters the POC reports. Every number in the
// results file comes from here or from Envoy's admin endpoint — never from
// access logs, which undercount long-lived streams.
package stats

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	gstats "google.golang.org/grpc/stats"
)

// Counters is shared by the server and its HTTP exposition.
type Counters struct {
	started time.Time

	AcceptedConns  atomic.Int64
	OpenConns      atomic.Int64
	StreamsTotal   atomic.Int64
	StreamsActive  atomic.Int64
	SessionsActive atomic.Int64
	Fences         atomic.Int64

	CommandsSent   atomic.Int64
	CommandsAcked  atomic.Int64
	EchoesServed   atomic.Int64
	HeartbeatsRecv atomic.Int64

	AuthFailures sync.Map // Reason string -> *atomic.Int64
}

func New() *Counters { return &Counters{started: time.Now()} }

// AuthFailure records a rejected stream by reason.
func (c *Counters) AuthFailure(reason string) {
	v, _ := c.AuthFailures.LoadOrStore(reason, &atomic.Int64{})
	v.(*atomic.Int64).Add(1)
}

// Snapshot is the JSON shape exposed on /stats.
type Snapshot struct {
	UptimeSeconds  float64          `json:"uptime_seconds"`
	AcceptedConns  int64            `json:"accepted_conns"`
	OpenConns      int64            `json:"open_conns"`
	StreamsTotal   int64            `json:"streams_total"`
	StreamsActive  int64            `json:"streams_active"`
	SessionsActive int64            `json:"sessions_active"`
	Fences         int64            `json:"fences"`
	CommandsSent   int64            `json:"commands_sent"`
	CommandsAcked  int64            `json:"commands_acked"`
	EchoesServed   int64            `json:"echoes_served"`
	HeartbeatsRecv int64            `json:"heartbeats_recv"`
	AuthFailures   map[string]int64 `json:"auth_failures"`
}

func (c *Counters) Snapshot() Snapshot {
	af := map[string]int64{}
	c.AuthFailures.Range(func(k, v any) bool {
		af[k.(string)] = v.(*atomic.Int64).Load()
		return true
	})
	return Snapshot{
		UptimeSeconds:  time.Since(c.started).Seconds(),
		AcceptedConns:  c.AcceptedConns.Load(),
		OpenConns:      c.OpenConns.Load(),
		StreamsTotal:   c.StreamsTotal.Load(),
		StreamsActive:  c.StreamsActive.Load(),
		SessionsActive: c.SessionsActive.Load(),
		Fences:         c.Fences.Load(),
		CommandsSent:   c.CommandsSent.Load(),
		CommandsAcked:  c.CommandsAcked.Load(),
		EchoesServed:   c.EchoesServed.Load(),
		HeartbeatsRecv: c.HeartbeatsRecv.Load(),
		AuthFailures:   af,
	}
}

// ServeHTTP exposes /stats, /metrics and /healthz.
func (c *Counters) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/stats":
		w.Header().Set("content-type", "application/json")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		_ = enc.Encode(c.Snapshot())
	case "/metrics":
		w.Header().Set("content-type", "text/plain; version=0.0.4")
		s := c.Snapshot()
		for _, kv := range [][2]any{
			{"poc_accepted_connections_total", s.AcceptedConns},
			{"poc_open_connections", s.OpenConns},
			{"poc_streams_total", s.StreamsTotal},
			{"poc_streams_active", s.StreamsActive},
			{"poc_sessions_active", s.SessionsActive},
			{"poc_session_fences_total", s.Fences},
			{"poc_commands_sent_total", s.CommandsSent},
			{"poc_commands_acked_total", s.CommandsAcked},
			{"poc_echoes_served_total", s.EchoesServed},
			{"poc_heartbeats_received_total", s.HeartbeatsRecv},
		} {
			fmt.Fprintf(w, "%s %v\n", kv[0], kv[1])
		}
		keys := make([]string, 0, len(s.AuthFailures))
		for k := range s.AuthFailures {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			fmt.Fprintf(w, "poc_auth_failures_total{reason=%q} %d\n", k, s.AuthFailures[k])
		}
	case "/healthz":
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	default:
		http.NotFound(w, r)
	}
}

// ConnStats counts accepted TCP connections at the gRPC transport layer.
type ConnStats struct{ C *Counters }

func (h ConnStats) TagRPC(ctx context.Context, _ *gstats.RPCTagInfo) context.Context {
	return ctx
}

func (h ConnStats) HandleRPC(context.Context, gstats.RPCStats) {}

func (h ConnStats) TagConn(ctx context.Context, _ *gstats.ConnTagInfo) context.Context {
	return ctx
}

func (h ConnStats) HandleConn(_ context.Context, s gstats.ConnStats) {
	switch s.(type) {
	case *gstats.ConnBegin:
		h.C.AcceptedConns.Add(1)
		h.C.OpenConns.Add(1)
	case *gstats.ConnEnd:
		h.C.OpenConns.Add(-1)
	}
}
