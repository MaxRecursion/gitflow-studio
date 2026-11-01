# GitFlow Studio release status

November 2, 2026 — direct-distribution engineering preview, **0.2.0 (build 2)**. Installed Git remains mandatory. Full Desktop parity and production release acceptance are unfinished.

## Source and local artifacts

- Source: https://github.com/MaxRecursion/gitflow-studio
- Portfolio: https://maxrecursion.dev (Projects → GitFlow Studio); existing published entry retained.
- Local artifacts: `build/releases/0.2.0-preview/` — universal native app, ad hoc preview ZIP, matching arm64/x86_64 debug symbols, source archive, QA evidence, checksums and readiness manifest.
- App/runtime source: `d1922bb`; the final manifest also records the documentation/source-archive revision. The isolated release checkout excludes the separate, uncommitted UI styling work in the main workspace.

The app is locally signed ad hoc. It has **no Developer ID signature or notarization ticket**, and no customer release or Apple upload has been made. Follow [the direct-distribution handoff](../Distribution/Direct/README.md) and [RELEASING.md](RELEASING.md).

## Verified execution

| Environment | Evidence |
|---|---|
| Apple M4, macOS 27.0.1, Swift 6.4 CLT, Git 2.54.0 | Universal app builds and signature verifies; **79 core tests pass in Debug and Release**. Binary and dSYM UUIDs match for both slices. |
| ARM VM, macOS 15.8.2, Xcode 16.4, Swift 6.1.2 | [Run 41344239348](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41344239348): **79 core tests, seven native UI tests**, native Xcode build and universal packaging pass. |
| Intel VM, macOS 15.7.9, Xcode 16.4, Swift 6.1.2 | [Run 41344239987](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41344239987): **79 core tests and five native UI workflows** pass. No Intel performance claim is made. |
| ARM, macOS 14.8.9, Xcode 16.2 | Earlier source passes **76 core tests**. Initial UI fixture execution hit mismatched Xcode shim libraries; subsequent jobs encountered runner retirement brownout. Final-source minimum-OS GUI acceptance needs another host. |

Native UI coverage includes file staging/commit/history inspection, real merge/rebase/cherry-pick/revert conflict continuation, a 100-region editor exercise and repeated launch. Git verifies final bytes, index/history and operation state. Submodule choices, tag push, remote worktrees, root undo and ancestor reset have service tests and connected controls; their individual GUI paths still need wider regression coverage.

Hardening found and corrected an Intel Metal graph assertion, Dispatch-worker exhaustion and detached auto-maintenance overlap. History now uses native Core Graphics paths. A cancellable eight-command admission queue bounds process/pipe workers. Automatic maintenance runs in the foreground inside command/mutation lifetimes without changing stored configuration. The 1,000-file forced-GC regression verifies pack creation, 21 commits and fsck in Debug and Release.

## Measured scope

The current 1,000-file / 100-commit Release service fixture records status median **5.41 ms**, p95 **6.94 ms** over 30 samples. Fixture auto-maintenance is disabled and its object graph is validated before measurement. The application still performs automatic maintenance, in the foreground.

The [Release editor profile](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41304728335) retains an actual 15.26-second native Time Profiler trace and five measured decision/edit sequences. Median automated sequence time is **1.863 s**; median peak physical memory reported by XCTest is **52.56 MB** for that fixture. These include instrumentation/automation costs and do not establish frame latency or typical memory. Source revisions and environments are recorded in [PERFORMANCE.md](../PERFORMANCE.md).

Earlier service/Allocations/idle evidence remains documented. Launch-to-first-frame, <16 ms interactions, large history scrolling, SwiftUI updates, long-session retention and typical 0.2 idle footprint are unproven. Native launch-clock tests include XCTest synchronization and do not verify the <500 ms target.

## Remaining gates

No Apple Developer team, valid Developer ID Application identity/private key, or notarization Keychain profile is configured. Preflight finds zero signing identities and stops before building/uploading a Developer ID candidate. Actual signing, accepted notarization, stapling, Gatekeeper and downloaded clean-machine validation remain blocked by those prerequisites.

The user selected **mandatory installed Git and direct distribution**. No bundled runtime/store variant is authorized. Mac App Store submission is deferred; this unsandboxed build is not a store candidate. The draft metadata and sandbox/runtime assessment remain in [STORE_READINESS.md](STORE_READINESS.md).

Full parity remains open: complex rename/file-directory and mixed submodule conflicts, richer working diffs, advanced history planning, hosted accounts/PR workflows, live HTTPS/SSH acceptance and a full accessibility audit. See [the source-based ledger](DESKTOP_PARITY.md) and [ROADMAP.md](../ROADMAP.md). Test execution on the stated hosts does not substitute for acceptance of the final signed binary on each supported platform.
