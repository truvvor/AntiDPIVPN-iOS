# Task: sync.Pool for mimicry & finalmask hot-path allocations

**Repo:** `truvvor/Xray-core`
**Branch:** `claude/optimize-encryption-dpi-w8aSj` (current HEAD `3c526ef` or its successors)
**Downstream:** `truvvor/AntiDPIVPN-iOS`, branch `claude/review-project-structure-YAZJR` — just needs the new `LibXray.xcframework` vendored in, no Swift changes.
**Build host:** Mac Mini `rentamacs-Mac-mini-5` via existing `~/libxray` + `build_py_patch.py` pipeline (same workflow as the `FreeOSMemory` hand-off we already shipped).

---

## Context

iOS VPN client runs LibXray inside a `NEPacketTunnelProvider` with a hard ~50 MB jetsam budget. After fixing connection-count (mux re-enabled once the server's `account.Flow == XRV + RequestCommandMux → AllowedNetwork=UDP` bug was cleared) and DNS storms (UDP/53 routed to `direct`), the tunnel now holds a stable **52-58 MB RSS floor** through 10+ minutes of browsing + Spotify + speedtest, with sleep/wake cycles handled cleanly. Log excerpt from build 50:

```
[19:48:20] MEM: used=57.6 avail=10.9 pkts=123219/123587
[19:49:50] MEM: used=56.1 avail=12.2 pkts=124969/125541
[19:53:33] MEM: used=54.8 avail=13.2 pkts=127404/130728
[19:56:15] MEM: used=52.2 avail=11.7 pkts=127915/131269
```

Memory breathes up/down with load, `FreeOSMemory()` actually returns pages now (previously always 0). This is a huge improvement.

What still kills it: **moderate** TCP bursts (~20–30 new connects over 5 seconds, observed at `19:56:30`). RSS jumps +8 MB in seconds, `avail` drops from 10 MB to 1.8 MB, iOS triggers 5+ MEMPRESSURE criticals in one second, process is killed.

The 52-58 MB floor is close to the jetsam ceiling. Any spike overshoots. **Reducing the per-session state cost** is the only remaining lever without touching the wire protocol.

## Diagnosis

Under ~300 pkt/sec of real traffic, tunnel.log shows heap grows ~600-800 KB/sec transiently during activity. This is NOT connection state (mux is handling count). This is **per-Write() allocation churn** in the anti-DPI wrapper layers:

1. **`transport/internet/finalmask/fragment/conn.go`** — `fragmentConn.Write()` allocates a fresh `buff := make([]byte, 2048)` (and occasionally larger) on every outgoing write when processing fragmented ClientHello records or general fragmentation. Called once per outgoing packet during active handshakes and fragmented data streams. At 300 pkt/sec, that's 300 × ~2 KB = 600 KB/sec of pure transient allocation.

2. **`transport/internet/reality/mimicry.go`** (or equivalent file) — `mimicry.Write()` similarly allocates per-packet buffers for chunk shaping (phase-based sub-write sizing for the `webrtc_zoom` profile). Additional small allocations per-write for the phase scheduler state.

These allocations are SHORT-LIVED — they're freed after the Write completes. But their aggregate rate is what keeps Go's heap from shrinking: new span allocations happen faster than old spans go idle long enough for `debug.FreeOSMemory()` to reclaim them.

Replacing the per-call `make([]byte, ...)` with a `sync.Pool` lookup eliminates this churn. No bytes on the wire change. Server is oblivious. Protocol is identical. The pool amortizes buffer allocations across hundreds of Write() calls, keeping heap growth linear in concurrent-session count rather than in packet rate.

## Task

Add `sync.Pool`-based buffer pooling to the two hot-path `Write()` functions:

### File 1: `transport/internet/finalmask/fragment/conn.go`

At package scope, add:

```go
// fragmentBufferPool reuses the per-Write() scratch buffer used to
// build fragmented TLS records. Previously fragmentConn.Write() did
// `buff := make([]byte, 2048)` on every call. At 300+ pkt/sec under
// active bursts, that generated multi-hundred-KB/sec of transient
// allocations, which Go couldn't release back to the OS fast enough
// on memory-constrained iOS NetworkExtension (50 MB budget).
var fragmentBufferPool = sync.Pool{
	New: func() interface{} {
		b := make([]byte, 2048)
		return &b
	},
}
```

Ensure `"sync"` is imported.

In `fragmentConn.Write` and `fragmentClientHello` (the helper added in commit `3c526ef`), replace every `buff := make([]byte, 2048)` with:

```go
bufPtr := fragmentBufferPool.Get().(*[]byte)
buff := *bufPtr
defer func() {
	// Reset slice length for next user; keep capacity
	b := buff[:0]
	*bufPtr = b
	fragmentBufferPool.Put(bufPtr)
}()
```

Where the existing code later does `buff = make([]byte, 5+l)` to grow beyond 2048 bytes (rare), leave that path alone — the pool covers the common case. If the grown buffer is returned to the pool, that's fine (it can serve a future larger request).

For simplicity, the pattern `defer func() { ...; Put(...) }()` can be simplified if the function has a single exit path — just put it back explicitly before `return`.

### File 2: `transport/internet/reality/mimicry.go` (or wherever `mimicry.Write()` lives)

First locate the file:

```
grep -rn "func.*Write.*profile.*webrtc_zoom\|MIMICRY.*Write" transport/internet/reality/ --include="*.go"
grep -rn "chunk\|phase\|full-mimicry" transport/internet/reality/ --include="*.go"
```

Find the per-Write chunk allocator. Typical shape:

```go
func (m *mimicryConn) Write(p []byte) (n int, err error) {
    ...
    chunk := make([]byte, chunkSize)   // <-- hot-path allocation
    ...
}
```

Apply the same pattern. Package-level pool:

```go
var mimicryChunkPool = sync.Pool{
	New: func() interface{} {
		b := make([]byte, 4096)
		return &b
	},
}
```

And replace each `make([]byte, N)` in Write() with pool Get/Put. If `chunkSize` varies and sometimes exceeds the pooled buffer, grow as needed and put back — the pool will gradually accept larger buffers.

### Non-goals

- **Do NOT change any protocol bytes.** Output of Write() must be bit-identical.
- **Do NOT change exported APIs.** Only internal buffer reuse.
- **Do NOT add GC hints (`runtime.GC`, `debug.FreeOSMemory`) inside these hot paths.** We already hook `FreeOSMemory` from the iOS side on a heartbeat.

## Verification

After the changes compile and build_py_patch.py produces a new xcframework:

1. **Binary symbols sanity-check** — mimicry and finalmask symbols still present:
   ```
   nm -gU ~/libxray/output/LibXray.xcframework/ios-arm64/LibXray.framework/LibXray \
     | grep -iE "mimicry|fragment" | head -20
   ```

2. **Size check** — should be ~same as previous (≈ 40 MB for ios-arm64 binary). Pool code is ~20 lines total; any size jump > 100 KB is a red flag.

3. **Protocol-level check** — deploy to iOS user, have them connect to an existing session, run speedtest. REALITY handshake should succeed on server (same `xtls/reality` parser as before, no byte changes). Memory floor should drop meaningfully (target: 45-48 MB instead of 52-58 MB).

## Commit & deploy

```
git checkout claude/optimize-encryption-dpi-w8aSj
git pull
git add transport/internet/finalmask/fragment/conn.go transport/internet/reality/mimicry.go
git commit -m "perf: sync.Pool for mimicry + finalmask Write() buffers

Hot-path Write()s in both layers allocated a fresh []byte per call.
At 300+ pkt/sec on iOS NE extension (50MB jetsam budget), this
generated multi-hundred-KB/sec of transient heap churn that Go
couldn't reclaim fast enough — pushing RSS past jetsam under bursts.

Pool per-call scratch buffers. Wire protocol unchanged."
git push origin claude/optimize-encryption-dpi-w8aSj
```

Rebuild LibXray on Mac Mini (SSH to `rentamac@192.168.1.210`):
```
cd ~/Xray-core && git fetch && git checkout claude/optimize-encryption-dpi-w8aSj && git pull
cd ~/libxray && python3 build_py_patch.py
```

Vendor the result into iOS repo:
```
cd ~/AntiDPIVPN-iOS
git checkout claude/review-project-structure-YAZJR
git pull
rm -rf LibXray.xcframework
cp -R ~/libxray/output/LibXray.xcframework ./
git add LibXray.xcframework
git commit -m "vendor: LibXray with sync.Pool for mimicry/finalmask hot-path

Built from truvvor/Xray-core@<SHA from this task>.
Expected effect: memory floor drops from 52-58MB to ~45-48MB under
active traffic, giving enough headroom to absorb moderate TCP bursts
without hitting iOS jetsam."
git push origin claude/review-project-structure-YAZJR
```

Do NOT open a PR.

## Definition of done

- Two files modified with `sync.Pool` for buffer reuse.
- `xray_minimal` tag still applied by build script; no unexpected binary bloat.
- New xcframework vendored into iOS repo on `claude/review-project-structure-YAZJR`.
- iOS user confirms connection still works (protocol unchanged → must be fine).
- New iOS log shows memory floor ≤ 48 MB under sustained traffic (before was 52-58 MB).

## Report back

- Xray-core commit SHA
- iOS commit SHA
- nm output confirming mimicry/fragment symbols present
- Binary size in the new xcframework

## Risks and fallbacks

**Pool contention under extreme concurrency.** sync.Pool is per-P (per goroutine scheduler). Under bursts across many goroutines, contention is negligible (~1 atomic op per Get/Put). No lock contention expected.

**Buffer grow-then-shrink churn.** If Write() sometimes needs >2 KB and returns a 10 KB buffer to the pool, that 10 KB slot can occupy pool memory. sync.Pool is cleared periodically by the runtime between GC cycles, so this is self-bounded. Acceptable.

**Race conditions.** The pool pattern with `defer Put(...)` is safe: buffer is owned by Write() from Get to Put, no cross-goroutine sharing. Simple and race-free.

**Rollback.** Single commit per file, pure additive change with no protocol impact. `git revert` is safe.
