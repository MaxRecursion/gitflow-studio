# Native GUI verification

Manual native-app checks on Apple M4, macOS 27.0.1, using the packaged Release app. All repository changes below were confined to generated temporary fixtures. These observations supplement the real-Git service tests; they are not an XCUITest suite or complete UI acceptance.

## Conflict completion

1. Opened a real merge conflict created by `scripts/make-conflict-demo.sh`.
2. Visually inspected current/incoming/result panes, native line numbers, syntax colors, word-level highlights, and resolution controls.
3. Chose **Use Incoming**, reviewed the result, and confirmed **Write Result and Stage File**.
4. Confirmed **Continue Merge** only after all index conflicts were resolved.
5. Verified with Git: clean worktree/index, no unmerged entries, and commit `f06365b37dc3de34793cd6f547a2308dd50160f4` with parents `a27abb927fbe2f4a2c142de5ddec48cc1f39ebde` and `7c2b4f4c28ef3da0d92fa0b9ab61b8fe142a6191`. Final `Settings.swift` used timeout `60`, retries `3`, and environment `production`.

An earlier manual-edit check changed timeout `15` to `45`, navigated to Changes and back, then staged and continued the merge. Commit `0b85983ac7242a30a28b459fe3a864d6c36ddebd` had two parents, clean status, and preserved retries `5` and environment `development`.

The visual check caught custom ruler drawing outside its gutter, which covered native text and nearby controls despite valid accessibility content. The ruler and scroll surfaces now clip to their bounds. Text, syntax colors, and word highlights were visually rechecked after the fix. A separate compressed segmented-picker label in Changes was hidden while retaining its accessibility label.

## Draft safeguards

With an unsaved incoming-choice draft, Command-W showed **Close with an unsaved draft?**. **Keep Working** retained the window and draft. Command-Q then showed **Quit with unsaved drafts?**. The generated draft was explicitly discarded to reload the next build. Both close and quit inspect active operations before allowing termination. Crash recovery is not implemented.

## Repository settings and commits

Through Repository Settings, changed only the fixture's local identity to `GUI Test Author <gui@example.invalid>`. The UI confirmed the save. In Ignored Files, entered `*.cache` and saved `.gitignore`; Changes detected it as an untracked file.

Staged `.gitignore` through **Stage All**, entered the message and a coauthor, and committed with **Commit Staged**. Git verified commit `fd44193cf7ce6c7f059c26a62f808ae64a1a7979`, author `GUI Test Author <gui@example.invalid>`, message `Verify ignore settings and co-author`, and trailer `Co-authored-by: GUI Collaborator <collaborator@example.invalid>`. Status was clean.

## Worktrees

Opened Worktrees, selected **New Worktree**, entered branch `gui-worktree` from `HEAD`, selected a new folder with the native save dialog, and created it. The list showed the main and linked worktrees. Git confirmed the new branch, matching HEAD `fd44193cf7ce6c7f059c26a62f808ae64a1a7979`, and the same common Git directory. Dirty removal and symlink-alias serialization are covered by automated service tests; removal was not separately exercised through this GUI session.

## Individual-line staging

Added `build/` and `.DS_Store` below the fixture's existing `*.cache` rule. In **Select Lines**, selected only `build/` and used **Stage Selected Lines**. The native unstaged preview then showed only the `.DS_Store` addition; `git show :.gitignore` contained exactly `*.cache\nbuild/\n`.

Switched to the staged view, opened **Select Lines**, selected `build/`, and used **Unstage Selected Lines**. The index returned to exactly `*.cache\n`, while the working file retained both additions. The sheet was visually inspected and its checkboxes and actions were exercised through native accessibility controls. Generated edits were then cleared from this disposable fixture.

The 56-test suite also checks multiple-hunk offsets, replacements with independent deletion/addition selection, partial unstaging, Unicode and CRLF, leading combining marks, empty tracked files, stale/invalid selections, invalid UTF-8, and rejection of unsupported patch types. A regression sets custom Git prefixes and output indicators with identically named root/nested files; the selected patch changes only the intended nested file.

## Remaining verification

Full rebase/cherry-pick/revert GUI paths, minimum-OS and Intel execution, live-host authentication, dark-appearance visual regression, VoiceOver, keyboard-only coverage, multi-window stress, and XCUITest automation remain outstanding. Service-level integration tests do cover continuation and abort for these Git operations.

## Saved draft recovery — November 1, 2026

The universal Release app opened disposable fixture `gitflow-demo.sAzQAv`. Choosing Incoming changed the result to timeout 60, retries 3 and production, then the native UI showed Saved locally and Saved Drafts (1). The fixture app process was deliberately terminated after that state. On relaunch, the resolver offered a saved draft matching the exact Git state, with editing/staging disabled until an explicit choice. Restore Draft recovered the incoming decision and text.

Mark File Resolved → Write Result and Stage File → Continue → Continue Merge completed through the GUI. Git independently verified commit `9986d0cb5eac20834d79aa2635d74164d352740c`, parents `ccf03fad44832bd1dcebc73555dc336d950e980d` and `8599c9d12c819c5bd06b59a463f68148d5411785`, expected incoming contents and clean status. The screenshot in `Images/merge-workspace.png` shows this generated fixture before termination. No user repository was modified. This verifies one post-autosave termination case, not edits inside the 400 ms debounce window.

The rebuilt quit guard was also exercised after completing the merge: a disposable commit-message draft triggered the native confirmation, Keep Working retained its exact text, and Discard Drafts and Quit completed asynchronous cleanup and terminated the process. No commit was created by this guard test.

## Automated native UI regression — November 1, 2026

[Validation run 41300237355](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41300237355), app/test source revision `feea3a3`, passed the full Xcode build, universal app build, 67 integration tests and both native UI tests. XCTest recorded 2 tests, 0 failures, in 32.75 seconds. `testOpenStageCommitAndInspectHistory` opens a generated repository, stages through the GUI, types and creates a commit, verifies Git history/status, then selects History. `testResolveRealMergeAndContinue` creates an actual conflicting merge, selects Incoming, confirms staging and continuation, then verifies bytes, unmerged index, clean status and merge parents.

The hosted 1,024-point display exposed a clipped default window; the app now caps its initial size to the visible display. Xcode's native app target was renamed `GitFlowStudioApp` to avoid ambiguity with the Swift package executable; the public scheme remains `GitFlowStudio`. Test selectors handle native macOS text values and scope confirmation to its sheet, excluding the Touch Bar copy. The complete `.xcresult`, screenshots and video attachments are retained in the CI artifact and local QA bundle. These tests cover the two stated flows; they do not establish complete UI/accessibility coverage.
