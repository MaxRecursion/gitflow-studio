# Repository-opening responsiveness

## Report and diagnostic limits

The reported freeze occurs after clicking **Open Repository**, before the folder picker appears. Two local samples of the original application and a later sample of the first fixed build caught an idle AppKit event loop rather than the freeze; the system log query contained no picker-service errors. The exact reported freeze was not reproduced locally. The original running executable's UUID differed from the newer executable on disk, so rebuilding that bundle had not updated the running process.

## Version 0.2.1 changes

- Defer creation of `NSOpenPanel` until the SwiftUI action returns. Use `beginSheetModal` with the owning window, or nonblocking `begin` when no suitable window is available. Retain one picker per window and release it on completion. Initialize Repository uses the same path.
- Replace awaiting an unstructured shared status task with independently cancellable waiters. A cancelled caller returns promptly, another caller can keep the shared read alive, and a mutation resumes every invalidated waiter. Obsolete completions cannot clear a replacement request.
- Register and tear down FSEvents on utility workers. Show the initial repository state before monitoring registration completes, then refresh once the watcher is installed. Check cancellation before replacing the current repository.
- Allow the build script to output to a separate app path so a running application need not be overwritten.
- Read the restore preference through `bool(forKey:)`, preserving the default of restoring when unset. A launch argument such as `-restoreRepository NO` is stored as a string; the previous optional Bool cast ignored it. That allowed an error alert from a deleted recent fixture to interfere with the initial picker test.
- Replace symbol-specific animations with opacity/state feedback. Staging on the hosted Intel VM triggered Metal's `Target device architecture is nil` assertion during the previous symbol effects. Native drawing and ordinary transitions remain.

## Verification

Three real-Git status regression tests use a disposable repository and a wrapper that gates status execution. Before the status fix, two tests failed after their five-second watchdog released Git. Afterward all three passed without waiting for that watchdog. All 82 core tests pass locally in Debug and Release on Apple M4, macOS 27.0.1, Swift 6.4 CLT, Git 2.54.0. The universal arm64/x86_64 Release bundle builds and its local ad hoc signature verifies.

`testOpenRepositoryThroughNativePicker` launches without the `--repo` shortcut, clicks the actual Open button, cancels three successive pickers, chooses a temporary repository through the native Go to Folder dialog, and verifies that an external edit appears. Final-source hosted ARM [run 41420267665](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41420267665) passes **82 core tests and all eight native UI tests**, plus native Xcode/universal builds and preview packaging. The picker workflow took 28.739 seconds including all XCTest actions and waits; that is not a measurement of panel display latency. Hosted Intel [run 41420320112](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41420320112) passes **82 core tests and all six critical GUI workflows**, including the picker and staging. Performance tests are excluded on Intel. Platform results are recorded in [release status](RELEASE_STATUS.md).

The [initial ARM run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41417940184) passed the other seven UI tests but stopped before clicking Open: AppKit exposes both the toolbar item and its nested button with the same accessibility identifier. Test-only revision `d6b15e1` selects the first match explicitly. Its [ARM run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41418883528) then encountered the restore-preference alert described above. The [first Intel run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41417969889) exposed both the selector and symbol-animation problems; [diagnostics export](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41419772314) retains the Metal assertion. The [next Intel run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41418894783) exposed an overly short five-second test watchdog. Revision `6018e26` addresses those findings; the watchdog is now a 60-second failure backstop, not a performance assertion.

## Try the fixed build

```sh
UNIVERSAL=1 ./scripts/build-app.sh --output 'build/fixes/repository-open-verified/GitFlow Studio.app'
```

Save any drafts and quit the old instances normally. Then open `build/fixes/repository-open-verified/GitFlow Studio.app` and confirm **0.2.1 (4)** in About. The build does not terminate an existing instance or modify any repository. It is a local engineering preview, signed ad hoc, without a notarization ticket.
