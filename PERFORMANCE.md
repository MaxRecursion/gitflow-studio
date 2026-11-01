# Performance

## Reproduction environment

- Apple M4, arm64, 16 GiB RAM.
- macOS 27.0.1 (26A434).
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`).
- Git 2.54.0, selected from `/opt/homebrew/bin/git` by the app's discovery order. The shell's system Git also reports Apple Git 2.54.0 (Apple Git-157).
- Xcode Command Line Tools at `/Library/Developer/CommandLineTools`.
- Full Xcode and `xctrace` are not installed locally. A real hosted Instruments service trace is documented below.

## Benchmark protocol

Run `swift run --build-system native -c release GitBenchmarks`. The executable creates an isolated repository with 1,000 tracked text files and 100 commits, makes one working-tree edit, warms each operation once, then records 30 sequential samples. It reports the median and nearest-rank p95 as JSON. `--quick` uses 100 files and 20 commits. Temporary fixture creation is excluded from the measurements and the fixture is removed afterward.

The suite measures repository opening, status refresh, the first 100 history entries, a small diff, and Git subprocess overhead. These are service-layer wall-clock measurements. They are not measurements of rendered frame time, application launch, conflict-editor latency, or history scrolling.

## Measured results

The latest Release run is recorded in [Documentation/benchmark-release-preview.json](Documentation/benchmark-release-preview.json), timestamped `2026-11-01T10:54:44Z`. Compilation completed before this run; fixture setup and teardown are outside the samples. Earlier measurements remain in `Documentation/benchmark-results.json`.

| Operation | Median | p95 | Samples |
|---|---:|---:|---:|
| Open repository | 3.25 ms | 3.57 ms | 30 |
| Status, 1,000 tracked files | 5.62 ms | 6.98 ms | 30 |
| First 100 history entries | 10.94 ms | 12.58 ms | 30 |
| Small unstaged diff | 4.07 ms | 4.74 ms | 30 |
| Git version subprocess | 3.14 ms | 3.69 ms | 30 |

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
| Warm app startup | <500 ms | Not measured |
| Idle CPU | Near zero | No measurable CPU-time increase over a 30-second `ps` sample; Instruments pending |
| Typical idle memory | <150 MB | Latest small fixture: 146.50 MiB RSS (153.62 MB); physical footprint and larger repositories unmeasured |
| Small-repository status | <100 ms where Git permits | 5.62 ms median / 6.98 ms p95 on the latest fixture |
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

The Release universal cross-build succeeded for arm64 and x86_64. This is compile/link evidence; the development host cannot verify Intel runtime performance or minimum macOS behavior.

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
