# Implementation checklist

This checklist distinguishes delivered source from production acceptance. A functional engineering preview is the current milestone; full GitHub Desktop parity and every performance target are not claimed.

## Implemented architecture

- [x] Swift 6 package with native SwiftUI executable and independently testable GitCore.
- [x] Installed Git CLI runner with argument arrays, bounded concurrent pipe reads, cancellation, timeout, and errors.
- [x] Porcelain v2 NUL-delimited status and canonical repository opening.
- [x] Shared repository mutation serialization and status coalescing.
- [x] Real stage, unstage, commit, history, branch/remote/stash/tag service operations.
- [x] Unmerged-index conflict detection and operation-aware three-way content model.
- [x] Real temporary Git fixtures and integration tests.
- [x] Xcode project, SPM app packaging, ad hoc signing script, and reproducible benchmarks.

## Verified milestone

- [x] Native Release `.app` built and launched on the Apple Silicon development host.
- [x] 79 Swift Testing tests pass through `./scripts/test.sh` using real temporary Git repositories.
- [x] Real conflict resolved through the GUI by selecting incoming content, staging the file, and explicitly continuing the merge.
- [x] Native GUI working-change staging and commit creation.
- [x] Manual conflict-result edit from timeout `15` to `45`, retained when navigating away from and back to the conflict workspace.
- [x] The manually edited result was staged and continued through the GUI; Git verified the final contents, clean state, and two-parent merge.
- [x] Word highlights, syntax colors, and all resolver controls visually verified after fixing native ruler clipping. Incoming-choice resolution completed through the rebuilt GUI.
- [x] Repository identity, `.gitignore` save, co-authored commit, and linked-worktree creation through the GUI, with Git verification afterward.
- [x] Close/quit prompts retain an unsaved conflict draft when Keep Working is selected.
- [x] Native individual-line stage and unstage, verified against index bytes and preserved working-file edits.
- [x] Release service benchmark: 1,000 files / 100 commits / 30 samples; status median 5.41 ms, p95 6.94 ms on the latest recorded run.

The automated coverage includes status and unusual filenames, staged/unstaged changes, independent hunks and stale patch rejection, branches and unmerged-work protection, hooks, history, stash validation, tags, local remote clone/push/fetch/pull, real merge/rebase/cherry-pick/revert resolution and abort paths, binary/deletion/symlink conflicts, CRLF and no-final-newline preservation, manual edits, external file/index changes, mutation serialization, output limits, cancellation, and timeout behavior. Local remotes do not verify live HTTPS/SSH authentication with third-party hosts.

The GUI checks are manual native-app smoke tests. They do not establish full interaction coverage or replace an XCUITest suite. Rebase, cherry-pick, and revert continuation now also pass native XCUITest coverage with Git assertions on final content and operation state. The latest cases are recorded in [GUI verification](Documentation/GUI_VERIFICATION.md); source-derived parity and gaps are in [Desktop parity](Documentation/DESKTOP_PARITY.md).

## Implemented product scope

- [x] Open, initialize, clone, recent repositories, folder drops, Finder/editor integration, and multiple windows.
- [x] Filtered working changes, staged/unstaged diffs, file and independent text-hunk staging, confirmed discard, commits, and confirmed amend.
- [x] Paginated history, native graph lanes, commit search/details/parents, comparison, cherry-pick, and revert.
- [x] Create, switch, rename, safely delete, track, compare, merge, and rebase branches.
- [x] Fetch, selectable fast-forward/merge/rebase pull, explicit upstream publication, push, remote management, stash actions, and annotated tags.
- [x] Operation-aware conflict overview, TextKit 2 editor, line numbers, native search/undo, basic paragraph highlighting, proportional source scroll synchronization, optional ancestor, region choices, and explicit resolution/continuation/abort.
- [x] Conflict drafts retained across workspace navigation, with confirmation before discarding an unsaved draft when switching repositories.
- [x] Bounded lexical word highlighting for selected conflict regions, native soft-wrapped text, and paragraph recoloring after edits.
- [x] Repository identity, co-author trailers, `.gitignore` editing, linked worktree management, and protected latest-commit undo.
- [x] Shared mutation queue across linked worktrees; nonblocking regular-file validation and bounded reads for `.gitignore`.
- [x] Native close/quit guards for unsaved drafts and running operations; a small command palette.
- [x] Individual-line stage/unstage for ordinary text edits; Unicode, CRLF, multi-hunk offsets, stale selections, and zero-context cases tested.
- [x] Editable diff syntax overrides presentation configuration so custom prefixes cannot redirect a patch to another path. Non-UTF-8 paths and partial patches fail safely.

These entries describe implemented paths. The milestone and automated coverage above identify which paths have been exercised; unlisted GUI combinations still require regression testing.

## Verification before release

- [ ] Review all working UI commands against their Git effects and confirmations.
- [x] Full Xcode 16.4 native project build succeeded on hosted macOS 15.8.2; see GitHub validation runs.
- [x] Add a native XCUITest target for staging/commit and real merge workflows.
- [x] Execute seven native UI tests with hosted Xcode 16.4; staging/commit/history, merge/rebase/cherry-pick/revert continuation, editor interactions and repeated launch pass.
- [x] Intel macOS 15.7.9 executes 79 core and five native UI tests.
- [ ] Final-source minimum macOS 14 GUI acceptance and final signed-binary clean installation; the development host is arm64 macOS 27.
- [x] Capture service CPU, native conflict Allocations and Release editor-interaction CPU traces with raw artifacts and qualified results.
- [ ] Frame-time/scrolling, SwiftUI updates, Git child CPU, long-session retention and large-repository profiling.
- [ ] Developer ID signing, notarization, clean-machine launch, and release packaging.

## Product and hardening backlog

- [ ] General working-diff word highlights, semantically aligned source scrolling, richer language highlighting, and incremental large-document processing.
- [x] Missing-final-newline individual-line staging and unstaging, including CRLF/Unicode and safe refusal of impossible EOF selections. Metadata-changing renames/binary changes still require whole-file staging.
- [ ] Complex rename/rename and file/directory conflicts with a relationship-aware UI.
- [x] Pure submodule commit-reference conflicts with read-only child commit inspection and exact parent-index staging; real tests preserve dirty/untracked child files and complete a merge.
- [x] Remote-branch worktree creation with explicit tracking and stale-SHA checks.
- [ ] Mixed submodule/file conflicts, arbitrary encodings, custom merge drivers, and wider GUI coverage.
- [ ] Fine-grained streaming network progress and detached/escaped descendant handling. Verified isolated process-group cancellation now stops ordinary Git hook children synchronously; cancellation can leave Git locks, which are never removed automatically. The runner has a stdout chunk callback, but the UI currently shows operation-level progress.
- [ ] Commit-graph stress tests, topology fidelity across pagination, and very large repositories.
- [ ] Full VoiceOver and keyboard-only audit, complete command-palette coverage, and macOS notification workflows.
- [x] Local bounded conflict-draft persistence, exact-snapshot restore, stale review/export and corruption/permission tests.
- [ ] GUI recovery regression, multi-file caching and crash-window testing.
- [ ] App Sandbox distribution investigation and explicit filesystem access design if a sandboxed build is required.

Repository safety takes precedence over covering an unsupported case with a misleading success state. Unsupported operations should remain explicit and unclaimed until implemented and verified.

## Local release preparation — November 1, 2026

- [x] Universal Release cross-build (arm64 and x86_64), original app icon, bundled privacy manifest.
- [x] Developer ID/notarytool pipeline with checksum manifests and fail-closed signing checks; local preview archive.
- [x] Worktree existing-branch creation, move, lock/unlock and reviewed prune; real Git tests.
- [x] Git subprocess/operation Instruments intervals and bounded capture script.
- [x] Hosted Instruments Time Profiler service capture retained with environment/hash/TOC; no local xctrace.
- [x] Capture and separately export a 30.48-second native conflict-workspace Allocations trace; recorder code 54 and time-limit SIGKILL are explicitly retained.
- [ ] Inspect heap retention in Instruments; capture UI/child-Git CPU, startup and scrolling traces.
- [ ] Developer ID signing/notarization: no Apple Developer team or certificate configured.
- [ ] Mac App Store submission deferred by the selected mandatory installed-Git/direct-distribution runtime; no bundled runtime or sandbox workaround authorized.

## Direct-distribution continuation — November 2, 2026

- [x] Root-commit undo with compare-and-swap branch removal and shallow-boundary refusal.
- [x] Confirmed detached checkout and soft/mixed ancestor reset with captured HEAD and known-published protection.
- [x] Captured-tag non-forced push, literal untracked-file ignore, and native Terminal opening.
- [x] Seven hosted UI tests, including merge/rebase/cherry-pick/revert continuation and editor/launch exercises.
- [x] Release editor Time Profiler capture synchronized to real native edits; raw physical-memory/CPU/clock metrics retained with scope limitations.
- [x] Dedicated subprocess deadline queue and 16-command pipe-retention stress regression (77 core tests in current source).
- [x] macOS 14.8.9 ARM core execution (76 tests); full minimum-OS GUI acceptance still required. The hosted runner entered retirement brownout before the corrected Xcode-selection run.
- [ ] Minimum-OS GUI host, live HTTPS/SSH, broader accessibility and long-session/frame profiling.

The user explicitly retained mandatory installed Git and selected direct distribution. No bundled Git or App Store sandbox variant is part of this release. Signing/notarization requires the owner's Developer ID identity and local notarization profile; no team currently exists. Prepared artifacts remain local ad hoc previews until those gates pass.

- [x] Diagnose Intel History exit from exported app stderr and replace its Canvas paths with native Core Graphics rendering; runtime revalidation is recorded in RELEASE_STATUS.md.

- [x] Capture and diagnose a Dispatch-worker exhaustion hang under concurrent core testing; bound global Git admission to eight cancellable slots. A queue-cancellation regression brings the final suite to 78 tests.

- [x] Keep automatic Git maintenance in the command/mutation lifecycle; a 1,000-file forced-GC regression verifies object integrity and 21 commits in Debug and Release (79 core tests total). Benchmarks disable only their fixture auto-maintenance and validate it with fsck before sampling.

Final-source (`d1922bb`) ARM validation passes 79 core + seven native UI tests; Intel passes 79 core + five UI workflows. The local universal app and both-architecture dSYM UUIDs verify. See RELEASE_STATUS.md for artifacts, remaining parity/profiling gates and the owner's signing prerequisites.
