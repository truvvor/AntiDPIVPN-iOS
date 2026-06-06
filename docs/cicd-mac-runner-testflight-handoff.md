# Setup CI/CD: GitHub Actions self-hosted Mac runner → TestFlight

A working pattern, distilled from `truvvor/AntiDPIVPN-iOS`, for any iOS app to build + sign + upload to TestFlight on every push, using a shared Mac Mini self-hosted runner.

This document assumes:
- You have an iOS app source repo on GitHub
- A Mac Mini runner is already registered with GitHub Actions (label `self-hosted, macOS, ARM64`). It hosts an Apple ID logged in to Xcode, has signing certificates in `login.keychain-db`, and Xcode 26.4 (or compatible) installed
- You have an App Store Connect record for your app (Bundle ID + SKU registered in Apple Developer portal + ASC)
- You have an App Store Connect API key with "Developer" or higher role

If any of those are missing, this doc has pointers but assumes the runner-side infra exists (it does, on `rentamacs-Mac-mini-5.local`, IP `192.168.1.210`, user `rentamac`).

---

## What you need before starting

### From Apple Developer / App Store Connect

1. **Team ID** — 10-char alphanumeric, in Apple Developer Account → Membership. Example: `WJWU38ALPB`.
2. **Bundle Identifier** — must match what's registered in your App Store Connect record. Example: `com.example.myapp`.
3. **App Store Connect API key**:
   - Users and Access → Keys (in App Store Connect)
   - Create a new key with role "Developer" (or higher; "App Manager" works for upload)
   - Download the `.p8` file
   - Note the **Key ID** (10-char alphanumeric, e.g. `4RA5988Z6S`)
   - Note the **Issuer ID** (UUID, e.g. `e51df9f1-5d4a-4eb9-83e1-a8d49966cdfc`)
   - **The .p8 file must be installed on the runner** at `~/Library/Keys/AuthKey_<KEYID>.p8` (or `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8` — `xcrun altool` looks in both). For shared runner: SCP the .p8 to `rentamac@192.168.1.210:~/.appstoreconnect/private_keys/`.

### From the runner

The Mac Mini already has:
- **Keychain password**: `rentamac` (matches local user). The CI uses this in `security unlock-keychain -p 'rentamac'`. Since it's hardcoded, you have to use the same password — or change the runner setup, which is shared infrastructure (don't).
- **Xcode 26.4** at `/Applications/Xcode.app`. Newer versions may work; older ones may not have iOS 18 SDK.
- **xcodegen** at `/usr/local/bin/xcodegen` (installed via `brew install xcodegen`).
- **Signing certificates** for both Apple Development and Apple Distribution under your team. If yours aren't there yet, log in to Xcode Cloud / Account preferences once on the Mac Mini with your Apple ID and let Xcode auto-fetch them — this is a one-time interactive step.

### Add your repo to the runner

GitHub self-hosted runners are scoped per-repo (or per-org). The Mac Mini runner needs to be **added as a runner** to your repo:

- Go to `https://github.com/<your-org>/<your-repo>/settings/actions/runners`
- Click "New self-hosted runner" → macOS / ARM64
- Copy the registration token shown
- SSH `rentamac@192.168.1.210`, navigate to `~/actions-runner-<your-repo>` (each repo gets its own runner directory; if not exists, follow the GitHub-provided shell snippet to set up). The runner registers as `rentamacs-Mac-mini-5` against your repo.
- Make sure runner labels include `self-hosted, macOS, ARM64`.

Alternatively, if your runner is already set up org-wide and your repo is in the allowed list, you can use the existing runner without re-registering.

---

## Project file layout

Use [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate `*.xcodeproj` from `project.yml`. This avoids merge conflicts in `.pbxproj` and lets new source files be picked up automatically (`type: group` in sources).

Minimum `project.yml`:

```yaml
name: MyApp
options:
  bundleIdPrefix: com.example
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "26.4"

targets:
  MyApp:
    type: application
    platform: iOS
    sources:
      - path: MyApp
        type: group   # Auto-include all files under MyApp/
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.myapp
        INFOPLIST_FILE: MyApp/Info.plist
        SWIFT_VERSION: "5.9"
        TARGETED_DEVICE_FAMILY: "1,2"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: <YOUR_TEAM_ID>
        CODE_SIGN_ENTITLEMENTS: "MyApp/MyApp.entitlements"
```

**Don't commit the generated `.xcodeproj` to git.** Add it to `.gitignore`. CI regenerates it every build.

`Info.plist` must have:
- `CFBundleShortVersionString` (user-visible version, e.g. `1.0`)
- `CFBundleVersion` (build number, monotonically increasing — TestFlight rejects duplicates)
- `CFBundleIdentifier`: `$(PRODUCT_BUNDLE_IDENTIFIER)`

---

## The workflow file

Create `.github/workflows/build.yml`:

```yaml
name: Build & Upload to TestFlight

on:
  push:
    branches: [main]   # add other branches you want to auto-build
  workflow_dispatch:    # manual trigger from Actions UI

jobs:
  build:
    runs-on: self-hosted

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build and Upload
        env:
          RUNNER_TEMP: ${{ runner.temp }}
        run: |
          set -e

          # ---------- Keychain unlock ----------
          # Required so codesign can read the signing identities. The
          # password 'rentamac' is the runner-machine's local account
          # password; do not change unless you also reconfigure the runner.
          security list-keychains -d user -s ~/Library/Keychains/login.keychain-db /Library/Keychains/System.keychain
          security unlock-keychain -p 'rentamac' ~/Library/Keychains/login.keychain-db
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k 'rentamac' ~/Library/Keychains/login.keychain-db >/dev/null 2>&1
          security set-keychain-settings -lut 21600 ~/Library/Keychains/login.keychain-db
          echo "=== Signing identities ==="
          security find-identity -v -p codesigning

          # ---------- Regenerate Xcode project ----------
          # XcodeGen with `type: group` source means new files dropped
          # into the source directory get included automatically; we
          # don't store .pbxproj in git.
          if ! command -v xcodegen >/dev/null 2>&1; then
            echo "xcodegen not found; install via 'brew install xcodegen'"
            exit 1
          fi
          xcodegen generate --spec project.yml

          # ---------- Archive ----------
          xcodebuild -scheme MyApp \
            -sdk iphoneos \
            -configuration Release \
            -archivePath $RUNNER_TEMP/MyApp.xcarchive \
            archive \
            -allowProvisioningUpdates \
            CODE_SIGN_STYLE=Automatic \
            DEVELOPMENT_TEAM=<YOUR_TEAM_ID>

          # ---------- ExportOptions plist ----------
          printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n  <key>method</key>\n  <string>app-store-connect</string>\n  <key>uploadSymbols</key>\n  <false/>\n  <key>signingStyle</key>\n  <string>automatic</string>\n  <key>teamID</key>\n  <string><YOUR_TEAM_ID></string>\n</dict>\n</plist>\n' > $RUNNER_TEMP/ExportOptions.plist

          # ---------- Export IPA ----------
          xcodebuild -exportArchive \
            -archivePath $RUNNER_TEMP/MyApp.xcarchive \
            -exportPath $RUNNER_TEMP/export \
            -exportOptionsPlist $RUNNER_TEMP/ExportOptions.plist \
            -allowProvisioningUpdates

          # ---------- Upload to TestFlight ----------
          # The .p8 key file must already be at
          # ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 on runner.
          xcrun altool --upload-app \
            -f $RUNNER_TEMP/export/MyApp.ipa \
            -t ios \
            --apiKey <YOUR_API_KEY_ID> \
            --apiIssuer <YOUR_ISSUER_ID>

          # ---------- Stage dSYMs for artifact upload ----------
          mkdir -p "$RUNNER_TEMP/debug_symbols"
          cp -R "$RUNNER_TEMP/MyApp.xcarchive/dSYMs" "$RUNNER_TEMP/debug_symbols/" 2>/dev/null || true
          cp "$RUNNER_TEMP/MyApp.xcarchive/Products/Applications/MyApp.app/MyApp" \
             "$RUNNER_TEMP/debug_symbols/MyApp.bin" 2>/dev/null || true
          ls -la "$RUNNER_TEMP/debug_symbols/"

      - name: Upload dSYMs + binary
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: dsyms-and-binary
          path: ${{ runner.temp }}/debug_symbols
          retention-days: 7
          if-no-files-found: warn

      - name: Cleanup
        if: always()
        run: |
          rm -rf ${{ runner.temp }}/MyApp.xcarchive
          rm -rf ${{ runner.temp }}/export
          rm -f ${{ runner.temp }}/ExportOptions.plist
```

Substitute everywhere:
- `MyApp` → your scheme name (matches `project.yml` target)
- `<YOUR_TEAM_ID>` → your Apple Developer Team ID
- `<YOUR_API_KEY_ID>` → from App Store Connect API key
- `<YOUR_ISSUER_ID>` → from App Store Connect API key

---

## First-time validation

Before pushing real code, do a dry run:

1. Manual trigger: GitHub → Actions → "Build & Upload to TestFlight" → "Run workflow" on `main`. This catches workflow YAML syntax errors before they block real commits.
2. Watch the run logs. Expected output milestones:
   - `=== Signing identities ===` showing both `Apple Development` and `Apple Distribution` lines for your team
   - `Created project at .../MyApp.xcodeproj` from xcodegen
   - `BUILD SUCCEEDED` or `ARCHIVE SUCCEEDED` from xcodebuild
   - altool's `No errors uploading` or similar

If the keychain step fails with `errSecInternalComponent`, the keychain wasn't fully unlocked — check that `set-key-partition-list` and `set-keychain-settings -lut 21600` both ran. The combined unlock + xcodebuild in a single `run:` block is intentional — splitting them re-locks the keychain between steps.

---

## Pitfalls and known issues

These caused real failures in the parent project — pre-empt them:

### `xcodegen not found`
Install via `brew install xcodegen` on the runner. The CI guard catches this with a clear error message.

### `errSecAuthFailed (-25308)` from `git push`
Cosmetic warning from macOS Keychain trying to cache git credentials. Doesn't block the actual push if the underlying SSH/HTTPS auth succeeds. Verify with `git ls-remote origin` after the push.

### `unable to find a fulfilled provisioning profile`
Automatic signing needs an active Apple Developer membership and the Mac Mini's Xcode logged in to that account. Open Xcode → Settings → Accounts on the Mac Mini, ensure the account is logged in and "Manage Certificates…" shows valid certs. Do this once per Apple ID, interactively.

### `App Store Connect API key not found`
`altool` looks for the .p8 in `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8` (preferred) or `~/Library/Keys/AuthKey_<KEYID>.p8`. SCP the file there with `chmod 600`. Once present, all repos using the same API key share it.

### TestFlight rejects upload: "The bundle version must be higher than..."
`CFBundleVersion` (build number) must monotonically increase per TestFlight session. Bump it in `Info.plist` on every release-worthy commit, OR auto-increment in CI by reading from a counter file / git rev-list count.

### Job stuck "Waiting for runner to pick up"
The runner process on Mac Mini is offline (LaunchAgent died, machine slept, network dropped). SSH in:
```
ps aux | grep Runner.Listener
launchctl list | grep actions.runner
```
Restart with `launchctl kickstart -k gui/$(id -u)/actions.runner.<...>` or run `cd ~/actions-runner-<repo> && ./run.sh` interactively to debug.

### "Profile required for embedded.mobileprovision" or similar
For app-extensions (e.g. NetworkExtension, NotificationServiceExtension), each appex needs its own bundle ID + provisioning profile. Add the extension as a separate target in `project.yml` and ensure each has `PRODUCT_BUNDLE_IDENTIFIER` set. Automatic signing handles the rest, but the App ID must exist in the Apple Developer portal.

### Two repos sharing the same runner
The runner can serve multiple repos sequentially (one job at a time). If you'd run high-volume CI, register a second runner instance on the same machine with a different name (`./config.sh --name second-runner-...`).

### Pipeline output is huge in GitHub UI
xcodebuild is verbose. To trim, pipe through `xcbeautify` or `xcpretty`:
```
brew install xcbeautify   # one-time on runner
xcodebuild ... | xcbeautify
```
Then capture the exit code with `${PIPESTATUS[0]}` because `pipefail` doesn't apply to single commands without `set -o pipefail`.

---

## Going further

- **dSYM upload to crash service**: the workflow already saves dSYMs as a 7-day GitHub artifact. To auto-upload to e.g. Sentry, add a step after archive: `sentry-cli upload-dif <path-to-dsyms>`.
- **Slack/Discord notification**: add `slackapi/slack-github-action` or Discord webhook step on `if: failure()` and `if: success()`.
- **Multi-environment**: parameterize `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` via GitHub Environments + secrets if you have Dev/Staging/Prod.
- **Caching DerivedData**: skip if you ship infrequently, but `actions/cache` keyed on `Package.resolved` + Swift hash can cut 30-40% off build time for incremental commits.

---

## Definition of done

- A push to your default branch triggers a workflow run within seconds.
- The run completes in 5–15 minutes (depends on app size).
- A new build appears in App Store Connect → TestFlight → Builds within ~15 minutes after the workflow finishes (Apple processing time).
- The build is selectable in TestFlight on a registered tester device.
- dSYMs are downloadable from the Actions run page for symbolication.
