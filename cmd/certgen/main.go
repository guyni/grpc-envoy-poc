// Command certgen issues the POC's agent CA, per-agent client certificates,
// negative-test certificates and bearer tokens.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/guyni/grpc-envoy-poc/internal/auth"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "ca":
		doCA(os.Args[2:])
	case "agents":
		doAgents(os.Args[2:])
	case "secret":
		doSecret(os.Args[2:])
	case "token":
		doToken(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  certgen ca     -out DIR [-cn NAME] [-days N]
  certgen agents -ca DIR -out DIR -n N [-prefix agent] [-cluster poc] [-ttl 24h]
                 [-expired] [-foreign]
  certgen secret -out FILE [-bytes N]
  certgen token  -secret-file F -node N [-cluster poc] [-iss poc-issuer] [-aud msgbroker] [-ttl 15m]
`)
	os.Exit(2)
}

func doCA(args []string) {
	fs := flag.NewFlagSet("ca", flag.ExitOnError)
	out := fs.String("out", "certs/agent-ca", "output directory")
	cn := fs.String("cn", "poc-agent-ca", "CA common name")
	days := fs.Int("days", 3650, "validity in days")
	_ = fs.Parse(args)

	cert, key, err := newCA(*cn, *days)
	must(err)
	must(os.MkdirAll(*out, 0o755))
	must(writePEM(filepath.Join(*out, "agent-ca.crt"), "CERTIFICATE", cert.Raw))
	must(writeKey(filepath.Join(*out, "agent-ca.key"), key))
	fmt.Printf("CA written to %s (CN=%s)\n", *out, *cn)
}

func doAgents(args []string) {
	fs := flag.NewFlagSet("agents", flag.ExitOnError)
	caDir := fs.String("ca", "certs/agent-ca", "CA directory")
	out := fs.String("out", "certs/agents", "output directory")
	n := fs.Int("n", 10, "number of certificates")
	prefix := fs.String("prefix", "agent", "node name prefix")
	cluster := fs.String("cluster", "poc", "cluster in the SPIFFE URI SAN")
	ttl := fs.Duration("ttl", 24*time.Hour, "certificate lifetime")
	expired := fs.Bool("expired", false, "issue an already-expired certificate")
	foreign := fs.Bool("foreign", false, "sign with a throwaway CA instead of the agent CA")
	_ = fs.Parse(args)

	var caCert *x509.Certificate
	var caKey *ecdsa.PrivateKey
	var err error
	if *foreign {
		caCert, caKey, err = newCA("foreign-ca", 365)
		must(err)
	} else {
		caCert, caKey, err = loadCA(*caDir)
		must(err)
	}
	must(os.MkdirAll(*out, 0o755))

	for i := 0; i < *n; i++ {
		node := fmt.Sprintf("%s-%04d", *prefix, i)
		cert, key, err := newLeaf(caCert, caKey, *cluster, node, *ttl, *expired)
		must(err)
		must(writePEM(filepath.Join(*out, node+".crt"), "CERTIFICATE", cert.Raw))
		must(writeKey(filepath.Join(*out, node+".key"), key))
	}
	fmt.Printf("%d certificate(s) written to %s (cluster=%s, foreign=%v, expired=%v)\n",
		*n, *out, *cluster, *foreign, *expired)
}

func doSecret(args []string) {
	fs := flag.NewFlagSet("secret", flag.ExitOnError)
	out := fs.String("out", "certs/jwt-secret", "output file")
	size := fs.Int("bytes", 32, "secret size")
	_ = fs.Parse(args)

	b := make([]byte, *size)
	_, err := rand.Read(b)
	must(err)
	must(os.MkdirAll(filepath.Dir(*out), 0o755))
	must(os.WriteFile(*out, []byte(fmt.Sprintf("%x", b)), 0o600))
	fmt.Printf("secret written to %s\n", *out)
}

func doToken(args []string) {
	fs := flag.NewFlagSet("token", flag.ExitOnError)
	secretFile := fs.String("secret-file", "certs/jwt-secret", "HMAC secret file")
	node := fs.String("node", "", "node claim")
	cluster := fs.String("cluster", "poc", "cluster claim")
	iss := fs.String("iss", "poc-issuer", "issuer")
	aud := fs.String("aud", "msgbroker", "audience")
	ttl := fs.Duration("ttl", 15*time.Minute, "lifetime")
	_ = fs.Parse(args)

	if *node == "" {
		fmt.Fprintln(os.Stderr, "-node is required")
		os.Exit(2)
	}
	secret, err := os.ReadFile(*secretFile)
	must(err)
	now := time.Now()
	tok, err := auth.Sign(auth.Claims{
		Issuer: *iss, Audience: *aud, Subject: *node,
		IssuedAt: now.Unix(), NotBefore: now.Unix(), Expires: now.Add(*ttl).Unix(),
		Cluster: *cluster, Node: *node,
	}, []byte(trimSpace(string(secret))))
	must(err)
	fmt.Println(tok)
}

func newCA(cn string, days int) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: cn, Organization: []string{"grpc-envoy-poc"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Duration(days) * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	cert, err := x509.ParseCertificate(der)
	return cert, key, err
}

func loadCA(dir string) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	certPEM, err := os.ReadFile(filepath.Join(dir, "agent-ca.crt"))
	if err != nil {
		return nil, nil, err
	}
	keyPEM, err := os.ReadFile(filepath.Join(dir, "agent-ca.key"))
	if err != nil {
		return nil, nil, err
	}
	cb, _ := pem.Decode(certPEM)
	if cb == nil {
		return nil, nil, fmt.Errorf("no certificate PEM in %s", dir)
	}
	cert, err := x509.ParseCertificate(cb.Bytes)
	if err != nil {
		return nil, nil, err
	}
	kb, _ := pem.Decode(keyPEM)
	if kb == nil {
		return nil, nil, fmt.Errorf("no key PEM in %s", dir)
	}
	key, err := x509.ParseECPrivateKey(kb.Bytes)
	if err != nil {
		return nil, nil, err
	}
	return cert, key, nil
}

func newLeaf(ca *x509.Certificate, caKey *ecdsa.PrivateKey, cluster, node string, ttl time.Duration, expired bool) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	uri, err := url.Parse(fmt.Sprintf("spiffe://example.com/cluster/%s/node/%s", cluster, node))
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	notBefore := time.Now().Add(-time.Hour)
	notAfter := time.Now().Add(ttl)
	if expired {
		notBefore = time.Now().Add(-48 * time.Hour)
		notAfter = time.Now().Add(-24 * time.Hour)
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: node, Organization: []string{"grpc-envoy-poc"}},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
		URIs:         []*url.URL{uri},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca, &key.PublicKey, caKey)
	if err != nil {
		return nil, nil, err
	}
	cert, err := x509.ParseCertificate(der)
	return cert, key, err
}

func writePEM(path, typ string, der []byte) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return pem.Encode(f, &pem.Block{Type: typ, Bytes: der})
}

func writeKey(path string, key *ecdsa.PrivateKey) error {
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	if err := writePEM(path, "EC PRIVATE KEY", der); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[len(s)-1] == '\n' || s[len(s)-1] == '\r' || s[len(s)-1] == ' ') {
		s = s[:len(s)-1]
	}
	return s
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
