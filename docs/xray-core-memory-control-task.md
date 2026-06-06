# Task: Programmatic memory control in LibXray

**Repo:** `truvvor/Xray-core`
**Base branch:** `feat/distro-minimal-build88`
**Downstream repo to update:** `truvvor/AntiDPIVPN-iOS`, branch `claude/review-project-structure-YAZJR`
**Build host:** Mac Mini `rentamacs-Mac-mini-5` (user `rentamac`, LAN `192.168.1.210:22`)

---

## Context

`truvvor/AntiDPIVPN-iOS` is an iOS VPN client (VLESS + REALITY + XTLS-Vision + ML-KEM-768 + mimicry) running xray-core inside a `NEPacketTunnelProvider` extension. The extension has an iOS jetsam budget of ~50 MB RSS.

Under connection bursts (Telegram-style 50+ concurrent TCP connects in a few ms), RSS grows from 42 MB (post-LibXray-init) to 77+ MB within 30 seconds and the extension is killed by iOS. Latest run:

```
[00:22:45] MEM@ready: used=42.8MB avail=39.2MB
[00:22:50] MEM:       used=55.1MB avail=28.8MB pkts=306/200
[00:23:05] MEM:       used=66.6MB avail=17.9MB pkts=2520/1966
[00:23:20] MEM:       used=76.9MB avail=1.9MB  pkts=111108/238145  (killed shortly after)
```

Growth is **not per-packet** (506 packets → +13 MB; 100k packets → +10 MB). Cause: Go runtime allocates new 2 MB spans as goroutines spawn (REALITY + mimicry + finalmask per connection) and **does not return freed pages to the OS** after GC. This is the classic "Go in constrained embedded environment" behavior.

Two things are missing from current LibXray, both present in the reference implementation (Hiddify / sing-box libbox):

1. **Programmatic GC + memory limits set from Go code.** `setenv("GOMEMLIMIT", ...)` from Swift is ineffective — Go runtime reads env vars once at `dlopen` time, before Swift runs. `runtime/debug.SetMemoryLimit` works because it's called after Go runtime is live.
2. **Exported `FreeOSMemory()` hook.** Needed so Swift can force Go to return freed heap to the OS on iOS memory-pressure events. Without this, Go's internal GC frees memory but RSS stays at peak; iOS reads RSS and triggers jetsam.

This is a prerequisite for the iOS-side fix (subscribing to `DispatchSource.makeMemoryPressureSource` and calling into Go). Pure-Swift fixes cannot solve this.

---

## Task

Add two things to the LibXray Go package that is fed to `gomobile bind`:

1. An `init()` that calls `runtime/debug.SetMemoryLimit(45 << 20)` and `SetGCPercent(50)`.
2. An exported function `LibXrayFreeOSMemory()` that calls `runtime/debug.FreeOSMemory()`.

Then rebuild `LibXray.xcframework` on the Mac Mini and commit the new binary into the iOS repo.

---

## Step 1 — Locate the gomobile-bound package

In the `truvvor/Xray-core` fork, find the package whose functions become Swift-callable via `gomobile bind`. Existing `LibXray*` exports are the marker:

```
grep -rn "^func LibXray" --include="*.go"
```

The file(s) with `LibXrayRunXrayFromJSON`, `LibXrayStopXray` identify the target package. The new init() and export must live in **that same package** (or a new file in it). A function added to any other Go package will not reach the iOS framework.

## Step 2 — Add runtime control

Create a new file in the target package (preferred — minimises risk of breaking an existing init() chain). Suggested path: `<target-pkg>/runtime_control.go`:

```go
package libXray  // match the target package's declared name

import "runtime/debug"

func init() {
    // Keep Go runtime inside the NetworkExtension jetsam budget (~50 MB).
    // 45 MiB is a soft cap: Go GC's more aggressively to stay under it;
    // under extreme pressure it may exceed rather than deadlock, which
    // is the correct trade for a user-facing tunnel.
    // GOGC=50 triggers GC at 1.5x live set instead of the default 2x.
    debug.SetMemoryLimit(45 << 20)
    debug.SetGCPercent(50)
}

// LibXrayFreeOSMemory forces Go to return unused heap pages to the OS.
// Called from Swift on DispatchSource memory-pressure events. Without
// this, Go GC frees memory internally but RSS stays at peak; iOS reads
// RSS and kills the extension.
func LibXrayFreeOSMemory() {
    debug.FreeOSMemory()
}
```

If the target package already declares an `init()`, either add the two `debug.*` calls to the existing one, or keep a second `init()` in a new file — Go allows multiple per package. The single-file approach above is cleanest.

## Step 3 — Commit and push to Xray-core

```
git checkout feat/distro-minimal-build88
git pull origin feat/distro-minimal-build88
git add <target-pkg>/runtime_control.go
git commit -m "runtime: programmatic memory limit + FreeOSMemory export

setenv('GOMEMLIMIT',...) at runtime is ineffective because Go reads env
only at dyld load, before Swift runs. SetMemoryLimit() inside init()
works because it runs after Go runtime is up.

LibXrayFreeOSMemory export lets the iOS side force-release heap pages
on memory-pressure events, mirroring hiddify/sing-box libbox behavior.
Without this, Go GC frees memory internally but RSS stays at peak,
triggering iOS jetsam on the NetworkExtension."
git push origin feat/distro-minimal-build88
```

Record the resulting commit SHA — it goes into the iOS commit message.

## Step 4 — Rebuild `LibXray.xcframework` on the Mac Mini

SSH to `rentamac@192.168.1.210`. The build driver is at `~/libxray` and already has a `build_py_patch.py` that does `go mod edit -replace` to point at the local fork at `~/Xray-core`. Before running it, make sure the local Xray-core is on the new commit:

```
cd ~/Xray-core
git fetch origin
git checkout feat/distro-minimal-build88
git pull origin feat/distro-minimal-build88

cd ~/libxray
python3 build_py_patch.py
```

Output: `~/libxray/output/LibXray.xcframework` (path may differ — check the script's output line).

### Step 4a — Verification

**Export symbol must be present:**

```
nm -gU ~/libxray/output/LibXray.xcframework/ios-arm64/LibXray.framework/LibXray \
  | grep -i FreeOSMemory
```

Expect a non-empty line mentioning `LibXrayFreeOSMemory`. If empty, the function didn't make it to the export surface — revisit Step 1 (wrong package) and rebuild.

**Binary size sanity check:**

```
ls -la ~/libxray/output/LibXray.xcframework/ios-arm64/LibXray.framework/LibXray
```

Expect ~30.6 MB (build 88 baseline) ± a few KB. Any growth of > 1 MB is a red flag: either `runtime/debug` pulled in unexpected deps (it shouldn't — it's in stdlib) or `-tags xray_minimal` got dropped somewhere. Do not proceed if the binary is substantially bigger.

## Step 5 — Update the iOS repo

```
cd ~/AntiDPIVPN-iOS   # or clone fresh to a temp dir
git checkout claude/review-project-structure-YAZJR
git pull origin claude/review-project-structure-YAZJR

rm -rf LibXray.xcframework
cp -R ~/libxray/output/LibXray.xcframework ./

git add LibXray.xcframework
git commit -m "vendor: LibXray.xcframework with runtime memory control

Adds:
- init(): debug.SetMemoryLimit(45 MiB) + SetGCPercent(50)
- LibXrayFreeOSMemory() exported for iOS memory-pressure hook

Built from truvvor/Xray-core@<SHA from Step 3>."
git push origin claude/review-project-structure-YAZJR
```

**Do NOT open a pull request.** The iOS agent continues work on the same branch: declaring the new function in the bridging header, wiring `DispatchSource.makeMemoryPressureSource`, adding input-side backpressure on `packetFlow.readPackets`.

---

## Definition of done

1. `truvvor/Xray-core`, branch `feat/distro-minimal-build88`, HEAD contains `debug.SetMemoryLimit(45 << 20)` and exported `LibXrayFreeOSMemory`.
2. `nm -gU` on the rebuilt `LibXray` binary inside the xcframework lists `LibXrayFreeOSMemory`.
3. `LibXray` binary size ≈ 30.6 MB (no unexpected growth).
4. `truvvor/AntiDPIVPN-iOS`, branch `claude/review-project-structure-YAZJR`, HEAD contains the updated `LibXray.xcframework`.
5. The iOS commit message references the Xray-core commit SHA from Step 3.

## Report back

One short note:

- Xray-core commit SHA
- AntiDPIVPN-iOS commit SHA
- `LibXray` binary size in the rebuilt xcframework
- Output of `nm -gU ... | grep FreeOSMemory`

## Risks and fallbacks

**GC deadlock at too-low a limit.** 45 MiB is chosen to match Hiddify's libbox. If live testing shows throughput regression or GC stalls, raise to `55 << 20` in a single follow-up commit. Do not drop below 40 MiB — the extension baseline (Go runtime + hev + Swift) is already ~40 MB.

**Unexpected binary bloat.** If the `.framework` binary grows > 1 MB: confirm `-tags xray_minimal` is still applied in `build_py_patch.py` and nothing in the new file imports outside stdlib. `runtime/debug` is in stdlib and should not add bytes.

**Multiple `init()` in one package.** Go allows this, but if the existing target package already has an `init()` that does nontrivial work, prefer merging the two `debug.*` calls into it rather than creating a second `init()` — easier to reason about init order if things go wrong later.

**Symbol not exported despite compilation success.** gomobile only exports functions from the package passed on its command line. If `nm` doesn't show `LibXrayFreeOSMemory`, the function lives in the wrong package. Check `build_py_patch.py` or any gomobile invocation to see which package path is passed to `gomobile bind`, and place the new file inside that package.
