# Reproducible release preparation

Current state: local direct-distribution engineering preview, version 0.2.0 (build 2). Installed Git remains mandatory; a bundled/store runtime is not authorized. No Apple Developer team or code-signing identity is configured. No Apple submission has been made. App Store gates are tracked separately in [STORE_READINESS.md](STORE_READINESS.md).

## Local preview

```sh
./scripts/test.sh
UNIVERSAL=1 ./scripts/build-app.sh
./scripts/release.sh preview --app 'build/GitFlow Studio.app' --output build/releases/local-preview
```

The new output folder contains the `.app`, an ad hoc signed ZIP, `SHA256SUMS`, `manifest.json`, and `preflight.json`. It is suitable for local engineering review, not a Gatekeeper-approved customer release. Existing output folders are never overwritten. Preview packaging reports that it did not run tests itself; keep the test report alongside the artifact.

Recreate the original icon with `swift scripts/generate-icon.swift Resources` and `iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`. AppKit generates all icon sizes; the app has no graphics dependency. The privacy manifest and icon are copied by SPM packaging and included by the Xcode resources phase.

## Developer ID

Enroll the publisher in the Apple Developer Program, configure their signing identity with its private key locally, and create a notarization Keychain profile using Apple's supported tools. Never commit certificates, private keys, passwords, tokens, or Keychain exports. No secret values belong in project documentation or command history.

```sh
security find-identity -v -p codesigning
./scripts/release-preflight.sh --identity PUBLIC_CERTIFICATE_SHA1
./scripts/release.sh prepare --identity PUBLIC_CERTIFICATE_SHA1 --output build/releases/developer-id
```

`prepare` checks the selected Developer ID Application fingerprint, runs tests, builds universal by default, signs with hardened runtime and a secure timestamp, and produces a checksum-verified `submission.zip`. It fails before building when signing prerequisites are missing. It rejects unexpected nested code until an explicit inside-out signing plan is implemented. `--arm64-only` is available for a deliberately scoped release.

Only the next explicit command uploads the prepared app to Apple. User authorization to prepare artifacts does not imply that this command has already run:

```sh
./scripts/release.sh submit --release-dir build/releases/developer-id --keychain-profile PROFILE_NAME
```

The pipeline accepts credentials only through an existing Keychain profile. It records submission attempts, checks the Accepted response, staples and validates the ticket, verifies the Developer ID signature and hardened runtime, runs Gatekeeper assessment, then packages the final ZIP. Nothing is published to a download site automatically.

For an interrupted wait with a recorded submission ID, use `resume` with the same directory/profile. Do not remove its attempt marker or create a duplicate submission. If no receipt ID was returned, recover that exact submission in Apple's tools first.

```sh
./scripts/release.sh resume --release-dir build/releases/developer-id --keychain-profile PROFILE_NAME
./scripts/release.sh verify --release-dir build/releases/developer-id
```

Only the verified `final/` archive is a direct-distribution candidate. Validate a downloaded/quarantined copy on a clean Mac, including installed Git availability, hooks/authentication, supported conflict workflows and minimum OS before publishing. Retain the matching source revision, test logs, dSYM files and profiling traces privately with each release.

## Native UI checks

With full Xcode and an unlocked desktop:

```sh
xcodebuild -project GitFlowStudio.xcodeproj -scheme GitFlowStudio \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath build/UITests.xcresult test
```

The UI test target creates isolated temporary repositories for staging/committing, merge/rebase/cherry-pick/revert resolution, repeated launch and a 100-conflict editor exercise. It never targets a user repository. XCTest screenshots are retained as attachments. Seven tests have passed on hosted Xcode 16.4; that evidence does not replace validation of the final signed binary.

## Instruments

```sh
./scripts/profile-instruments.sh PID 'Time Profiler' 30
./scripts/profile-instruments.sh PID Allocations 30
./scripts/profile-instruments.sh PID 'Points of Interest' 30
```

The script records `.trace`, its table of contents, host/tool details and the packaged executable's SHA-256 under `build/profiles`. Interact with a disposable repository during each trace. The app emits local intervals named Git Subprocess, Repository Open, Repository Status, History Page and Repository Presentation. No paths, arguments or source text are recorded in those intervals. Review the traces in Instruments; the script does not turn a recording into a performance claim. See [PERFORMANCE.md](../PERFORMANCE.md) for protocols and unmeasured targets.

Hosted evidence is linked from [RELEASE_STATUS.md](RELEASE_STATUS.md). `macos.yml` runs core/Xcode/universal/UI validation; `instruments.yml` captures and exports service CPU samples; `app-profile.yml` captures the native conflict workspace and supports exporting a saved trace independently. `interaction-profile.yml` attaches Time Profiler to a Release app before measured native edits, retaining CPU/memory/clock metrics. `platform-verification.yml` executes Intel coverage; macOS 14 core evidence is retained, but that runner is retiring and minimum-OS GUI acceptance needs another host. The initial Allocations recorder returned 54 after its time limit and forced target stop, although the trace exported successfully. Preserve that exit/termination qualification rather than interpreting a readable trace as a clean app shutdown.
