// Package auth implements the POC's bearer-token scheme: a compact HS256 JWT
// carrying issuer, audience, expiry and the agent's cluster and node claims.
//
// It is deliberately small — the POC needs a verifiable token with the same
// claim checks the proposal requires (signature, alg, iss, aud, exp, cluster,
// node), not a production issuer.
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Reason values are stable labels used for metric counters.
type Reason string

const (
	ReasonMissing    Reason = "missing"
	ReasonMalformed  Reason = "malformed"
	ReasonAlg        Reason = "alg"
	ReasonSignature  Reason = "signature"
	ReasonExpired    Reason = "expired"
	ReasonNotYet     Reason = "not_yet_valid"
	ReasonIssuer     Reason = "issuer"
	ReasonAudience   Reason = "audience"
	ReasonNoIdentity Reason = "no_identity"
)

// Error carries a machine-readable reason alongside the human message.
type Error struct {
	Reason Reason
	Err    error
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %v", e.Reason, e.Err) }
func (e *Error) Unwrap() error { return e.Err }

func newErr(r Reason, format string, args ...any) *Error {
	return &Error{Reason: r, Err: fmt.Errorf(format, args...)}
}

// Claims is the token payload.
type Claims struct {
	Issuer    string `json:"iss"`
	Audience  string `json:"aud"`
	Subject   string `json:"sub"`
	IssuedAt  int64  `json:"iat"`
	NotBefore int64  `json:"nbf"`
	Expires   int64  `json:"exp"`
	Cluster   string `json:"cluster"`
	Node      string `json:"node"`
}

var header = base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))

// Sign returns a compact HS256 JWT for the claims.
func Sign(c Claims, secret []byte) (string, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	body := base64.RawURLEncoding.EncodeToString(payload)
	signingInput := header + "." + body
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(signingInput))
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

// Parse verifies and decodes a token.
//
// The algorithm is pinned to HS256: anything else, including "none", is
// rejected before the signature is considered.
func Parse(token string, secret []byte) (Claims, error) {
	var c Claims

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return c, newErr(ReasonMalformed, "expected 3 segments, got %d", len(parts))
	}

	var h struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	hb, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return c, newErr(ReasonMalformed, "header: %v", err)
	}
	if err := json.Unmarshal(hb, &h); err != nil {
		return c, newErr(ReasonMalformed, "header: %v", err)
	}
	if h.Alg != "HS256" {
		return c, newErr(ReasonAlg, "alg %q not accepted", h.Alg)
	}

	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return c, newErr(ReasonMalformed, "signature: %v", err)
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(parts[0] + "." + parts[1]))
	if !hmac.Equal(sig, mac.Sum(nil)) {
		return c, newErr(ReasonSignature, "signature mismatch")
	}

	pb, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return c, newErr(ReasonMalformed, "payload: %v", err)
	}
	if err := json.Unmarshal(pb, &c); err != nil {
		return c, newErr(ReasonMalformed, "payload: %v", err)
	}

	now := time.Now().Unix()
	if c.Expires == 0 {
		return c, newErr(ReasonExpired, "token has no exp")
	}
	if now >= c.Expires {
		return c, newErr(ReasonExpired, "expired %ds ago", now-c.Expires)
	}
	if c.NotBefore != 0 && now < c.NotBefore {
		return c, newErr(ReasonNotYet, "not valid for another %ds", c.NotBefore-now)
	}
	if c.Cluster == "" || c.Node == "" {
		return c, newErr(ReasonNoIdentity, "cluster/node claims required")
	}
	return c, nil
}

// Expired reports whether the claims are past expiry, for mid-stream checks.
func (c Claims) Expired(now time.Time) bool { return now.Unix() >= c.Expires }
