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

With an unsaved incoming-choice draft, Command-W showed **Close with an unsaved draft?**. **Keep Working** retained the window and draft. Command-Q then showed **Quit with unsaved drafts?**. The generated draft was explicitly discarded to reload the next build. Both close and quit inspect active operations before allowing termination. Disk-backed draft recovery was added and exercised later; see the saved draft section below.

## Repository settings and commits

Through Repository Settings, changed only the fixture's local identity to `GUI Test Author <gui@example.invalid>`. The UI confirmed the save. In Ignored Files, entered `*.cache` and saved `.gitignore`; Changes detected it as an untracked file.

Staged `.gitignore` through **Stage All**, entered the message and a coauthor, and committed with **Commit Staged**. Git verified commit `fd44193cf7ce6c7f059c26a62f808ae64a1a7979`, author `GUI Test Author <gui@example.invalid>`, message `Verify ignore settings and co-author`, and trailer `Co-authored-by: GUI Collaborator <collaborator@example.invalid>`. Status was clean.

## Worktrees

Opened Worktrees, selected **New Worktree**, entered branch `gui-worktree` from `HEAD`, selected a new folder with the native save dialog, and created it. The list showed the main and linked worktrees. Git confirmed the new branch, matching HEAD `fd44193cf7ce6c7f059c26a62f808ae64a1a7979`, and the same common Git directory. Dirty removal and symlink-alias serialization are covered by automated service tests; removal was not separately exercised through this GUI session.

## Individual-line staging

Added `build/` and `.DS_Store` below the fixture's existing `*.cache` rule. In **Select Lines**, selected only `build/` and used **Stage Selected Lines**. The native unstaged preview then showed only the `.DS_Store` addition; `git show :.gitignore` contained exactly `*.cache\nbuild/\n`.

Switched to the staged view, opened **Select Lines**, selected `build/`, and used **Unstage Selected Lines**. The index returned to exactly `*.cache\n`, while the working file retained both additions. The sheet was visually inspected and its checkboxes and actions were exercised through native accessibility controls. Generated edits were then cleared from this disposable fixture.

The current 76-test suite also checks multiple-hunk offsets, replacements with independent deletion/addition selection, partial unstaging, Unicode and CRLF, leading combining marks, empty tracked files, stale/invalid selections, invalid UTF-8, and rejection of unsupported patch types. A regression sets custom Git prefixes and output indicators with identically named root/nested files; the selected patch changes only the intended nested file.

## Remaining verification

Live-host authentication, dark-appearance visual regression, VoiceOver, keyboard-only coverage, multi-window stress, and GUI coverage of the newly added submodule/tag/worktree/history actions remain outstanding. The expanded automated section below records real rebase/cherry-pick/revert GUI continuation. Service tests cover their abort paths; platform results are tracked in RELEASE_STATUS.md.

## Saved draft recovery — November 1, 2026

The universal Release app opened disposable fixture `gitflow-demo.sAzQAv`. Choosing Incoming changed the result to timeout 60, retries 3 and production, then the native UI showed Saved locally and Saved Drafts (1). The fixture app process was deliberately terminated after that state. On relaunch, the resolver offered a saved draft matching the exact Git state, with editing/staging disabled until an explicit choice. Restore Draft recovered the incoming decision and text.

Mark File Resolved → Write Result and Stage File → Continue → Continue Merge completed through the GUI. Git independently verified commit `9986d0cb5eac20834d79aa2635d74164d352740c`, parents `ccf03fad44832bd1dcebc73555dc336d950e980d` and `8599c9d12c819c5bd06b59a463f68148d5411785`, expected incoming contents and clean status. The screenshot in `Images/merge-workspace.png` shows this generated fixture before termination. No user repository was modified. This verifies one post-autosave termination case, not edits inside the 400 ms debounce window.

The rebuilt quit guard was also exercised after completing the merge: a disposable commit-message draft triggered the native confirmation, Keep Working retained its exact text, and Discard Drafts and Quit completed asynchronous cleanup and terminated the process. No commit was created by this guard test.

## Automated native UI regression — November 1, 2026

[Validation run 41300237355](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41300237355), app/test source revision `feea3a3`, passed the full Xcode build, universal app build, 67 integration tests and both native UI tests. XCTest recorded 2 tests, 0 failures, in 32.75 seconds. `testOpenStageCommitAndInspectHistory` opens a generated repository, stages through the GUI, types and creates a commit, verifies Git history/status, then selects History. `testResolveRealMergeAndContinue` creates an actual conflicting merge, selects Incoming, confirms staging and continuation, then verifies bytes, unmerged index, clean status and merge parents.

The hosted 1,024-point display exposed a clipped default window; the app now caps its initial size to the visible display. Xcode's native app target was renamed `GitFlowStudioApp` to avoid ambiguity with the Swift package executable; the public scheme remains `GitFlowStudio`. Test selectors handle native macOS text values and scope confirmation to its sheet, excluding the Touch Bar copy. The complete `.xcresult`, screenshots and video attachments are retained in the CI artifact and local QA bundle. These tests cover the two stated flows; they do not establish complete UI/accessibility coverage.

## Expanded native regression — November 2, 2026

[Run 41304840161](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41304840161), revision `0bcf3d57e9119a741bcada4a4d9e63fa1a86b91d`, passes 76 integration tests, native Xcode and universal builds, and **seven native UI tests**. In addition to the original staging/history and merge flows, the suite creates actual rebase, cherry-pick and revert conflicts, resolves them through native controls, stages the result and explicitly continues. Git assertions verify final bytes, unmerged entries, clean status and operation metadata; rebase also checks the operation-correct side descriptions and restored branch. Rebase completion uses lifecycle directories rather than assuming Git deletes the retained `REBASE_HEAD` pseudoref.

The other two tests exercise a 100-conflict native editor with five measured decision/edit sequences and three application launches. Only editor metrics were exported by that first run; the launch metric was unavailable. The separate Release Instruments run and its screenshot were inspected, showing native current/incoming/result panes, selected word highlights, a saved result and 99 remaining decisions after resolving the first of 100 regions. See PERFORMANCE.md for actual measurements and limitations. This test leaves the remaining conflicts unresolved and explicitly discards the draft; it does not pretend the entire 100-region file was resolved.

New submodule commit-reference choices, tag push, remote worktree creation, root undo and ancestor reset have real-Git service tests and connected native controls. Their full GUI paths have not yet been individually automated. Current source adds a concurrent-deadline regression, bringing the core suite to 77; RELEASE_STATUS.md records the final source/platform run rather than retroactively changing the earlier 76-test result.

## Final 0.2 execution

At app source `d1922bb`, [ARM run 41344239348](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41344239348) passes 79 core tests and all seven native UI tests. [Intel run 41344239987](https://github.com/MaxRecursion/gitflow-studio/actions/runs/41344239987) passes 79 core tests and all five critical UI workflows (editor/launch measurement tests excluded on that runner). The final artifacts retain full result bundles and attachments. History selection uses a stable SHA-based row identifier and verifies the selected commit's details; Core Graphics replaces the Intel VM's failing Metal-backed Canvas paths. These are source/build-specific results, not final signed-binary clean-machine approval or a full accessibility audit.
