# Performance

## Reproduction environment

- Apple M4, arm64, 16 GiB RAM.
- macOS 27.0.1 (26A434).
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`).
- Git 2.54.0, selected from `/opt/homebrew/bin/git` by the app's discovery order. The shell's system Git also reports Apple Git 2.54.0 (Apple Git-157).
- Xcode Command Line Tools at `/Library/Developer/CommandLineTools`.
- Full Xcode and `xctrace` are not installed locally. A real hosted Instruments service trace is documented below.

## Benchmark protocol

Run `swift run --build-system native -c release GitBenchmarks`. The executable creates an isolated repository with 1,000 tracked text files and 100 commits, makes one working-tree edit, warms each operation once, then records 30 sequential samples. It reports the median and nearest-rank p95 as JSON. `--quick` uses 100 files and 20 commits. Temporary fixture creation is excluded from the measurements and the fixture is removed afterward. The 0.2 protocol disables auto-maintenance only in that disposable fixture (`maintenance.auto=false`, `gc.auto=0`) and verifies the object graph with `git fsck` before sampling. Application Git still runs automatic maintenance, in the foreground.

The suite measures repository opening, status refresh, the first 100 history entries, a small diff, and Git subprocess overhead. These are service-layer wall-clock measurements. They are not measurements of rendered frame time, application launch, conflict-editor latency, or history scrolling.

## Measured results

The current 0.2 Release run at source `d1922bb` is recorded in [Documentation/benchmark-0.2-preview.json](Documentation/benchmark-0.2-preview.json), timestamped `2026-11-01T19:57:06Z`. It ran from an isolated committed checkout after the universal build and 79 core tests passed in Release configuration. Compilation and fixture setup/teardown are outside the samples. The 0.1 preview remains in `Documentation/benchmark-release-preview.json` and earlier results in `Documentation/benchmark-results.json`.

| Operation | Median | p95 | Samples |
|---|---:|---:|---:|
| Open repository | 3.35 ms | 3.84 ms | 30 |
| Status, 1,000 tracked files | 5.41 ms | 6.94 ms | 30 |
| First 100 history entries | 10.95 ms | 14.91 ms | 30 |
| Small unstaged diff | 4.27 ms | 6.21 ms | 30 |
| Git version subprocess | 3.42 ms | 4.83 ms | 30 |

The measured status operation is below the 100 ms engineering target on this fixture and host. This does not establish the same result for repositories with slow storage, filters, submodules, or many untracked files. The subprocess baseline accounts for a substantial part of each small operation's wall time. CPU load and power state were not controlled; these numbers are a reproducible local baseline rather than a cross-machine guarantee.

## Idle sample

[Documentation/idle-measurement.json](Documentation/idle-measurement.json) records a separate Release app process with a clean two-file repository, five commits, one linked worktree, and the Changes view visible. After 30 seconds of warmup, 31 `ps` samples over 30 seconds measured **137.52 MiB median and peak RSS**. The recorded CPU-time delta was **0.00 seconds**. This means no CPU time was measurable at `ps` precision during that interval; it is not a guarantee of zero CPU use. RSS is resident memory, not Instruments physical footprint, and this small fixture does not establish typical or large-repository memory use. The JSON includes the tested binary's SHA-256.

To reproduce, launch the Release app, open a fixture, leave it idle, obtain its PID with `pgrep -x GitFlowStudio`, then run:

```sh
python3 scripts/measure-idle.py PID --warmup 30 --seconds 30 \
  --executable 'build/GitFlow Studio.app/Contents/MacOS/GitFlowStudio' \
  --fixture 'Describe repository size and visible workspace' > idle-measurement.json
```

Do not change repositories, interact with the window, or run a Git operation during the sample. This standard-library Python script is a developer measurement tool; Python is not part of the application's runtime.

## Targets and verification

| Metric | Engineering target | Verification |
|---|---:|---|
| Warm app startup | <500 ms | First-frame time unmeasured; final Debug/XCTest launch/window interval median 2.137 s includes automation |
| Idle CPU | Near zero | No measurable CPU-time increase over a 30-second `ps` sample; Instruments pending |
| Typical idle memory | <150 MB | 0.1 small fixture: 146.50 MiB RSS (153.62 MB); 0.2 ordinary idle footprint not remeasured |
| Small-repository status | <100 ms where Git permits | 5.41 ms median / 6.94 ms p95 on the 0.2 fixture |
| Ordinary UI interaction | <16 ms | Not measured |
| Large history and editor scrolling | Smooth | Needs frame profiling |

## Implemented controls

Git runs off the main thread, stdout/stderr drain concurrently, and output is bounded. Repository mutations are serialized across linked worktrees; repeated in-flight status requests are coalesced. Filesystem notifications are event driven and debounced. History uses page limits rather than loading the full graph, and lists use native lazy layout. Editor rendering uses TextKit 2, line-number drawing follows visible layout fragments, and basic syntax recoloring is limited to the edited paragraph after initial loading. Source scrolling synchronizes proportionally; it does not compute semantic line alignment. Word comparison is bounded and performed off the main actor. Individual-line selection parses rows once off the main actor and reuses them as checkboxes change.

Conflict versions are limited to 8 MB each. Bounded memory use and paragraph-level recoloring are useful controls, but they do not prove large-file interaction latency. The line-number index still shifts offsets after edits, and decision updates can replace the result text; these need profiling on large documents before stronger responsiveness claims.

## Instruments procedure

On a Mac with full Xcode, build the Release app and profile its process plus child Git processes. Capture Time Profiler and Hangs while opening a repository, switching selected diffs, scrolling history, and editing conflicts. Use Allocations and VM Tracker for baseline, large-file opening, and repeated repository switching. Use the SwiftUI instrument for redundant updates and File Activity for event storms. Keep the repository fixture, commit count, OS/tool versions, power state, and build configuration with each trace.

Measure warm startup from launch to usable window separately from SwiftPM build time. Sample idle CPU and memory after at least 30 seconds without repository changes. Do not infer performance targets from a successful build or a service benchmark. Large-repository stress cases, 100,000-file status, large binary conflicts, and long-session leak checks remain release work.

## Profiling preparation update — November 1, 2026

`GitPerformance` emits local OSSignposter intervals for Git Subprocess, Repository Open, Repository Status, History Page, and Repository Presentation. `scripts/profile-instruments.sh` attaches to an explicit PID for Time Profiler, Allocations or Points of Interest, records environment/build identity and exports the trace table of contents. It does not record command arguments, paths or source text.

The local invocation returned exit 69: xctrace is unavailable under the selected Command Line Tools directory. No Instruments trace was recorded locally. Full Xcode remains necessary for this capture path. The existing service/idle figures above describe earlier recorded binaries, not a claim that the current universal build has identical timings.

The Release universal cross-build succeeded for arm64 and x86_64. Local builds establish compile/link evidence. Hosted platform execution results, including the macOS 14 runner limitation, are tracked in RELEASE_STATUS.md; no Intel performance claim is inferred from compilation.

## Hosted Instruments evidence — November 1, 2026

A real Time Profiler capture completed on a GitHub-hosted Apple Silicon VM: macOS 15.8.2 (24H232), Xcode 16.4 (16F6), Swift 6.1.2, VirtualMac2,1, 3 logical CPUs and 7 GiB RAM. [Capture run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41298382422) retained the trace, table of contents, environment and executable SHA-256. The trace records GitBenchmarks from 10:40:10.169Z through 10:40:26.851Z (16.681659 seconds), ending with the target's normal exit status 0.

Local artifact: `build/profiles/hosted-service/GitServices.trace`. Executable SHA-256: `a577d82e29cb49556390f731bbc8a7ec7213cb8abe4f716850a5501ed2038f8e`. The measured executable creates the 1,000-file / 100-commit fixture and performs the service benchmark suite. This captures the benchmark process, not the SwiftUI app or its child Git processes. It does not establish application startup, editor latency, allocations, idle footprint or scrolling acceptance. Instrumented duration includes fixture construction and profiler overhead. Those UI and resource traces remain required.

The exported profile contains 1,024 running-thread samples with 1,024 ms total sampled weight: 482 ms on the benchmark main thread and 542 ms on other threads. The largest leaf weights are `__unlink` (187 ms), `__posix_spawn` (90 ms), `__open_dprotected_np` (76 ms), `__getattrlist` (43 ms) and `fsync` (37 ms). Only 5 ms has an unsymbolicated leaf. See [the summary](Documentation/instruments-service-summary.json). Reproduce it with `python3 scripts/summarize-time-profile.py time-profile.xml`.

The filesystem-heavy result includes creating and removing the disposable fixture; it does not justify changing repository semantics or diagnosing a SwiftUI bottleneck. The next useful profile separates steady-state service intervals from setup/teardown and includes Git child processes. Main-thread samples here belong to a command-line benchmark, not the app's UI thread. The [export run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41298711377) retains the sampled XML alongside the original trace.

## Final preview idle sample

The final local universal app was sampled after 30 seconds of warmup with a clean one-file/four-commit fixture and Changes visible. [The new record](Documentation/idle-release-preview.json) has 31 samples over 30.01 seconds: median RSS **146.50 MiB**, peak **146.55 MiB**, and no CPU-time increase measurable at `ps` precision. Executable SHA-256: `12534acb803f8b032b23ae0fe2430dad92e262037d8c0c833535472e9c58213e`. The earlier 137.52 MiB observation refers to an older binary and fixture. Neither record establishes typical physical footprint or a large-repository memory guarantee.

## Native conflict workspace Allocations capture

[Export/validation run 41300675288](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41300675288) successfully reads the native app's saved Allocations trace. [Its table of contents](Documentation/instruments-app-allocations-toc.xml) records GitFlowStudio on hosted macOS 15.8.2, a generated conflict fixture, and 30.480923 seconds from 11:07:14.141Z to 11:07:44.622Z. The end reason is Time limit reached; the launched target was stopped with SIGKILL by the recording session.

The [original recording run](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41300364232) saved the trace but returned code 54. That nonzero recorder result is preserved, not treated as a clean application exit. A separate successful export validates the artifact. The trace is retained locally at `build/profiles/native-allocations/App.trace` and in the final QA evidence. Open it in Instruments to inspect heap categories, retained allocations and stacks. Its exported table of contents does not provide heap totals, and no numeric allocation/leak conclusion is claimed. This is a bounded startup/idle conflict-workspace capture; editor interaction, long-session growth, scrolling and large repositories remain unprofiled.

## Release editor interaction profile — November 2, 2026

[Run 41304728335](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41304728335) captured the actual Release SwiftUI/AppKit app at source `a6d20bc971bd8ae1b2c921b98769f54e8ed78629` on the hosted macOS 15.8.2 / Xcode 16.4 ARM VM described above. XCTest waited for Instruments to attach before editing a generated file with 100 separated conflict regions (about 1,000 source lines). Each of five measured sequences chose Current, clicked the native result editor, typed a space and chose Incoming. The trace also contains setup synchronization, autosaving and the explicit discard/quit dialog.

Both test and profiler exited 0. The saved trace spans **15.261761 seconds**, ending when the app exited normally. Raw XCTest [measurements](Documentation/instruments-editor-metrics.json), [derived results](Documentation/editor-performance-result.json), [sample summary](Documentation/instruments-editor-summary.json) and [trace table of contents](Documentation/instruments-editor-toc.xml) are retained. The full `.trace`, sample XML, `.xcresult`, screenshot and logs are in the workflow artifact and local `build/parity-evidence/interaction-final/build/interaction-profile/`.

| App measurement | Median | Observed range | Samples |
|---|---:|---:|---:|
| Automated interaction sequence, wall time | 1.863 s | 1.794–1.991 s | 5 |
| App CPU time per sequence | 0.979 s | 0.928–1.081 s | 5 |
| Peak physical memory reported by XCTest | 52.56 MB | 52.22–52.71 MB | 5 |
| Absolute physical memory reported by XCTest | 52.04 MB | 51.82–52.17 MB | 5 |

Clock time includes accessibility automation and XCTest idle synchronization; it does **not** measure a keystroke or frame. Memory is XCTest's physical-memory metric, not the local RSS measurement, and is specific to this hosted fixture. Per-iteration physical-memory deltas include negative values and cannot establish a leak trend from five samples. Hardware CPU cycle/instruction counters returned zero and are treated as unavailable.

The trace contains **7,211 ms of sampled running-thread weight**, including 6,230 ms on the app main thread and 981 ms on other threads. Leaf samples are dominated by framework/runtime work (`objc_msgSend` 558 ms); this is a sample weight, not exact CPU accounting. Inclusive app stacks include `NativeCodeEditor.updateNSView` at 109 ms and syntax highlighting at 45 ms across the complete capture; those values overlap callers and cannot be added or converted to a frame budget. The capture includes XCTest accessibility activity and the quit confirmation. It does not isolate ordinary editor rendering, Git child processes, history scrolling or long-session retention. No app-algorithm rewrite is justified by the aggregate leaf list alone.

The first launch-only XCTest passed but exported no launch metric on this macOS/Xcode combination. Combining that unavailable signpost metric with a manual interval then triggered an Apple metric-harvesting assertion; the test now uses only a manually bounded clock interval from launch request through a visible window, excluding termination; that interval includes XCTest synchronization and is not equivalent to launch-to-first-frame. The <500 ms startup and <16 ms interaction targets remain unproven.

A separate concurrent-test run exposed a missed subprocess deadline under heavy read load. Deadlines now use a dedicated user-initiated serial queue instead of the default global queue, begin before launch, and preserve their error category before launch. A regression runs 16 commands whose descendants retain pipes and requires every command to time out. This is a reliability correction; the earlier trace and benchmark numbers identify their original binaries and are not presented as remeasurements of this change.

## Intel renderer compatibility correction

Hosted Intel testing on macOS 15.7.9 / Xcode 16.4 caught an app exit on opening History. Exported app stderr identifies Metal loader assertion `Target device architecture is nil`. The earlier four conflict-continuation tests passed, while History failed. `NativeCommitGraph` now draws those short paths with AppKit/Core Graphics rather than SwiftUI Canvas. It keeps lazy row layout and does not require a Metal shader device. This is a compatibility correction supported by diagnostics, not a measured scrolling-speed claim. The final Intel regression result is recorded in RELEASE_STATUS.md.

A follow-up stress run exposed Dispatch's 64-thread soft limit: blocked subprocess waiters occupied every global worker while their pipe-drain blocks waited in the same pool. A one-second local `sample` captured that state. A cancellable FIFO admission actor now limits concurrent commands to eight (at most 32 waiter/pipe workers), while queued requests suspend. The suite adds a queued-admission cancellation test, bringing current coverage to 78 core tests. Both the 16-command timeout regression and the full local suite pass. The current benchmark table above uses this bounded runner; earlier figures remain tied to their recorded source revisions.

## Final launch clock and maintenance checks

At revision `30f759b`, [ARM validation 41343354957](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41343354957) exports three Debug launch intervals: 1.783, 1.930 and 1.944 seconds (median 1.930 s). The manually bounded clock excludes termination and includes XCTest launch/idle/window synchronization. It is an automation baseline, not launch-to-first-frame or proof against the 500 ms target. Final-source measurements are retained with the 0.2 release evidence.

Initial attempts to construct the 1,000-file fixture failed while Git traces showed detached repacks overlapping subsequent commits. An independent Python/CLI control completed 100 commits and `fsck`; no upstream Git defect is inferred. The application now supplies transient `maintenance.autoDetach=false` and `gc.autoDetach=false` settings so automatic work remains within its command lifetime and mutation gate, without changing stored repository configuration. The new 1,000-file / 21-commit regression forces automatic GC, verifies pack creation, final bytes, history, clean status and `fsck`, and passes in Debug and Release. Benchmark fixture maintenance is disabled separately to isolate the measured services. Failed attempts and traces are retained as diagnostics; they are not measurements.

The final-source (`d1922bb`) ARM run exports launch/window clock intervals of **2.549, 2.075 and 2.137 seconds** (median **2.137 s**), retained in [ui-metrics-0.2.json](Documentation/ui-metrics-0.2.json). This Debug/XCTest baseline includes automation and VM synchronization; it replaces neither a Release first-frame capture nor the engineering startup target. The earlier 1.930-second observation is retained with its own source revision, not averaged into the final run.
