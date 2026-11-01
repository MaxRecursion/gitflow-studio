# GitFlow Studio release status

November 1, 2026 — engineering preview, version 0.1.0 (build 1).

## Published source and portfolio

- Source: https://github.com/MaxRecursion/gitflow-studio
- Portfolio: https://maxrecursion.dev (Projects → GitFlow Studio)
- Portfolio source commit: `8f8e334`; Vercel production deployment succeeded and HTTPS HTML contains the repository and architecture links.

## Prepared locally

- Native SwiftUI/AppKit universal `.app`, ad hoc signed and signature-verified.
- Preview ZIP, SHA-256 checksums, source archive, test/build evidence and original app icon.
- App Store listing draft, privacy policy draft, bundled privacy manifest and readiness assessment.
- Separate Developer ID prepare/submit/resume/verify scripts that fail closed without signing prerequisites.
- Real hosted Instruments Time Profiler trace with sample exports, environment and reproducible summary.

The final artifact location is `build/releases/0.1.0-preview/`. Its manifest records the actual source revision. `QA-evidence.zip` contains the raw local tests, measurements, native screenshot, hosted trace and readiness evidence. The app archive is a local preview, not a notarized customer download.

## Verified scope

67 real-Git integration tests pass locally and on hosted macOS. A full Xcode 16.4 project build and universal cross-build succeeded. GUI smoke tests completed real merge resolution, post-termination draft restoration, staged commit creation, settings, line staging and worktree creation. The separate native UI test target and its exact CI result are recorded in GUI_VERIFICATION.md.

Latest local service fixture: 1,000 files, 100 commits, 30 warm samples; status median 5.62 ms / p95 6.98 ms. Final small-fixture idle sample: 146.50 MiB median RSS with no CPU-time increase detectable by `ps` over 30 seconds. The hosted service trace excludes the SwiftUI app and Git children. These results do not establish startup, frame-time, typical memory or large-repository targets.

## Remaining release gates

No Apple Developer team, Developer ID signing certificate/private key, or notarization Keychain profile is configured. Signing readiness correctly stops before a build/upload; no notarization submission occurred. App Store sandbox/runtime feasibility and account metadata are separate gates, as selected by the user. See [STORE_READINESS.md](STORE_READINESS.md) and [RELEASING.md](RELEASING.md).

Full GitHub Desktop parity is not complete. The source-based [parity ledger](DESKTOP_PARITY.md) and [roadmap](../ROADMAP.md) identify missing/partial workflows, including complex conflict relationships, submodule/image tooling, advanced history operations and hosted GitHub integrations. Minimum macOS and actual Intel runtime verification, broader accessibility and UI/resource profiling remain required.
