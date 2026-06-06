# Task: Tolerate zero-length handshake records in REALITY server

**Repo:** `truvvor/Xray-core`
**Current branch:** `claude/optimize-encryption-dpi-w8aSj` (same SHA as `feat/distro-minimal-build88`, HEAD `3c526ef`)
**Deployment target:** production server at `us.overheat.cn:2222` (VPS `67.217.246.160`), via existing `deploy-xray-nfs.yml` workflow

---

## Background

Client-side commit `3c526ef` ("anti-DPI: SNI-targeted ClientHello micro-fragmentation + dummy record injection") changed `transport/internet/finalmask/fragment/conn.go` so the fragmenter now writes a **zero-length TLS handshake record** as the first bytes on the wire, before the fragmented ClientHello:

```go
dummy := []byte{p[0], p[1], p[2], 0x00, 0x00}   // type=0x16, version, length=0
c.Conn.Write(dummy)
time.Sleep(...)
// then the real ClientHello, micro-fragmented around SNI
```

This breaks any unmodified TLS server. `go.mod` in this repo pins `github.com/xtls/reality v0.0.0-20260322125925-9234c772ba8f`, whose record-reader follows **RFC 8446 §5.1 verbatim**:

> Zero-length fragments of Handshake types are not permitted.

Result on server: `failed to read client hello` on every connection from clients built after `3c526ef`. One iOS user's device (ISP IP `62.231.1.66`) has been 100% failing since build was re-vendored. Another client on an older LibXray (IP `46.138.2.245`) connects fine because its build predates `3c526ef`.

The change was client-only. The server binary (built 11 April, `pid 2904537`) has no corresponding update and correctly refuses these malformed records.

## Decision

Do **not** revert the client — anti-DPI fragmentation is the current shipping strategy. Make the server **tolerant** of the zero-length handshake prefix.

## Task

Add a transparent connection wrapper on the server side that silently consumes zero-length handshake records before the REALITY/TLS stack sees them. This is 30–40 lines of Go in a new file; no dependency changes, no rebuild of `xtls/reality`.

## Step 1 — Add `transport/internet/reality/tolerant_conn.go`

New file, same package as `reality.go`:

```go
package reality

import (
	"bytes"
	"errors"
	"io"
	"net"
)

// tolerantReadConn wraps a net.Conn and transparently skips any
// zero-length TLS handshake records that appear at the very start
// of the stream.
//
// Commit 3c526ef ("anti-DPI: SNI-targeted ClientHello
// micro-fragmentation + dummy record injection") in this repo makes
// the client fragmenter prefix its ClientHello with an empty
// handshake record as a DPI-parser-poisoning measure. Per RFC 8446
// §5.1 zero-length Handshake fragments are not permitted, and the
// pinned xtls/reality reader correctly rejects them — which kills
// every session before REALITY handshake can start.
//
// Because the prefix is *only* emitted before the real ClientHello,
// this wrapper peeks at record headers on the first Read() and
// discards any 0x16/any-version/0x0000 record. After the first
// non-empty record is observed, the wrapper falls through to the
// underlying Read() with zero overhead for the rest of the session.
type tolerantReadConn struct {
	net.Conn
	prefixScanned bool
	// buf holds bytes already read from the underlying conn that
	// belong to the first non-empty record and must be returned to
	// the next Read() call.
	buf bytes.Buffer
}

func newTolerantReadConn(c net.Conn) *tolerantReadConn {
	return &tolerantReadConn{Conn: c}
}

func (t *tolerantReadConn) Read(p []byte) (int, error) {
	if t.prefixScanned {
		if t.buf.Len() > 0 {
			return t.buf.Read(p)
		}
		return t.Conn.Read(p)
	}

	// Scan and drop leading zero-length handshake records.
	// Budget: at most 4 leading empty records, 5 bytes each, to avoid
	// a malicious client keeping the server reading forever.
	var header [5]byte
	for i := 0; i < 4; i++ {
		if _, err := io.ReadFull(t.Conn, header[:]); err != nil {
			return 0, err
		}
		contentType := header[0]
		length := int(header[3])<<8 | int(header[4])
		isHandshake := contentType == 0x16 // TLS ContentType.Handshake
		if isHandshake && length == 0 {
			continue // drop this empty record, loop to next
		}
		// This is the first real record. Put its header into buf and
		// read its body so Read() caller gets a coherent record start.
		t.buf.Write(header[:])
		if length > 0 {
			body := make([]byte, length)
			if _, err := io.ReadFull(t.Conn, body); err != nil {
				return 0, err
			}
			t.buf.Write(body)
		}
		t.prefixScanned = true
		return t.buf.Read(p)
	}

	return 0, errors.New("reality: too many leading empty handshake records")
}
```

## Step 2 — Use the wrapper in `transport/internet/reality/reality.go`

Current `Server()` function (around line 52):

```go
func Server(c net.Conn, config *reality.Config) (net.Conn, error) {
	realityConn, err := reality.Server(context.Background(), c, config)
	return &Conn{Conn: realityConn}, err
}
```

Change to:

```go
func Server(c net.Conn, config *reality.Config) (net.Conn, error) {
	realityConn, err := reality.Server(context.Background(), newTolerantReadConn(c), config)
	return &Conn{Conn: realityConn}, err
}
```

One-line change.

## Step 3 — Build and deploy

Commit the two-file change on `claude/optimize-encryption-dpi-w8aSj`:

```
git checkout claude/optimize-encryption-dpi-w8aSj
git pull
git add transport/internet/reality/tolerant_conn.go transport/internet/reality/reality.go
git commit -m "reality: tolerate zero-length handshake prefix from anti-DPI fragmenter

Commit 3c526ef made the client fragmenter prefix ClientHello with a
zero-length handshake record to poison DPI parser state. Per RFC 8446
§5.1 this is invalid TLS, and the pinned xtls/reality reader correctly
rejects it — breaking all sessions from upgraded clients.

Wrap server-side net.Conn with tolerantReadConn which silently drops
up to 4 leading empty handshake records before passing the stream to
reality.Server(). Once the first real record is observed, further
Read() calls pass through unchanged.

Fixes 'failed to read client hello' on clients built from 3c526ef or
later."
git push origin claude/optimize-encryption-dpi-w8aSj
```

Then trigger the `deploy-xray-nfs.yml` workflow (GitHub Actions UI → run workflow) to build and SSH-deploy the new binary to `67.217.246.160:2222`. Workflow restarts the `xray` service automatically.

## Step 4 — Verification

After deploy, check server logs:

```
ssh -p 2222 root@67.217.246.160
journalctl -u xray --since "5 minutes ago" | grep -iE "failed to read client hello|accepted tcp"
```

Expect: no new `failed to read client hello` from `62.231.1.66`; successful `accepted tcp` entries follow REALITY handshake.

Separately, have the iOS user reconnect. tunnel.log should show non-zero `packetsRecv` and xray-core.log should show `[proxy]` accepts without closing.

## Risks and fallbacks

**Budget of 4 leading empty records.** A malicious client could try to exhaust the server by keeping the read loop busy. 4 × 5 bytes = 20 bytes max read before the server rejects — negligible. Concurrent-connection DoS is already bounded by normal socket accept limits.

**False positives.** A legitimate TLS client could theoretically begin a session with an empty record (though RFC 8446 forbids it). The wrapper would silently accept this; standard TLS implementations never emit such records, so this is a no-op in practice.

**Buffer growth.** The first real record is fully buffered in memory before being returned. Typical ClientHello is < 2 KB; MAX_RECORD size per TLS 1.3 is 16 KB + header. One-shot allocation, freed after `prefixScanned` flips. Acceptable.

**Rollback.** If the deploy breaks existing clients for any reason, revert the two-file commit and redeploy from the previous commit (`3c526ef`). The wrapper is additive and self-contained, so revert is safe.

## Definition of done

1. `truvvor/Xray-core` branch `claude/optimize-encryption-dpi-w8aSj` HEAD contains the new `tolerant_conn.go` and the one-line wrapper in `reality.go`.
2. `deploy-xray-nfs.yml` run completes successfully; new binary is running on `67.217.246.160:2222`.
3. Fresh `journalctl -u xray` shows no `failed to read client hello` from client IPs known to be on post-`3c526ef` builds.
4. iOS user (IP `62.231.1.66`) connects successfully.

## Report back

- Commit SHA of the two-file change
- Deploy workflow run URL
- Grep result from Step 4 verification (5–10 lines of xray log before/after, redacting IPs if needed)
- `xray version` output on the server
