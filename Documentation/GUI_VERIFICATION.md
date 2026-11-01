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
