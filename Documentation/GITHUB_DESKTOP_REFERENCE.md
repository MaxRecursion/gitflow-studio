# Git operation reference review

Reviewed GitHub Desktop's `app/src/lib/git` at commit [`c3a5c51ea7bccd98f0d32dd2f6db531296d8215d`](https://github.com/desktop/desktop/tree/c3a5c51ea7bccd98f0d32dd2f6db531296d8215d/app/src/lib/git) on 2026-10-30. A sparse source checkout was used only for reading; it is not a dependency or part of the application. All Swift implementations were written independently.

| Operation | Desktop reference files | Applied to GitFlow Studio |
|---|---|---|
| Execution/errors | `core.ts`, `spawn.ts`, `environment.ts` | Explicit allowed exit codes, bounded output, concurrent pipe drainage, cancellation, preserved helpers/hooks, sanitized diagnostics. Swift uses Foundation Process directly. |
| Status | `status.ts` | Porcelain v2, NUL paths, branch tracking data, and separate operation metadata. |
| Staging | `add.ts`, `update-index.ts`, `stage.ts`, `apply.ts` | Paths passed through NUL-delimited stdin; independent hunk patches checked against the latest displayed diff before cached apply. |
| Diff | `diff.ts` | Disable external diff/text conversion for previews; accept exit 1 for no-index differences; bound output. |
| Commit/coauthors | `commit.ts`, UI `changes/commit-message.tsx` | Commit message via stdin, validated coauthor trailers, hooks preserved; amend requires confirmation. Studio commits the existing index instead of clearing and restaging selected files. |
| Identity and ignores | `config.ts`, `gitignore.ts`, UI `repository-settings` | Local Git identity overrides and root `.gitignore` editing; stale-state checks, no-follow/nonblocking regular-file validation, and explicit byte limits. |
| Latest-commit undo | `reset.ts`, UI `changes/undo-commit.tsx` | Confirmed soft reset after validating HEAD, no active operation, a parent commit, and no containing remote-tracking ref. Files and index are preserved. Known remote refs do not prove a commit was never shared. |
| Worktrees | `worktree.ts`, UI `worktrees` and gated native menu entries | List, create on a new branch, open/reveal, and confirmed non-forced removal. Common-directory mutation serialization covers linked worktrees and symlink aliases. Existing-branch creation, move/lock/prune, and full Desktop worktree parity remain unfinished. |
| History | `log.ts`, `rev-list.ts`, `for-each-ref.ts` | Bounded pages, machine-readable fields, parent IDs and ref decoration. Topological ordering for graph lanes. |
| Branches | `branch.ts`, `checkout.ts` | Validate arguments, use Git for switching and naming, expose tracking and comparisons. Unlike Desktop's low-level forced-delete helper, this app uses `branch -d` so unmerged work cannot be deleted through its UI. |
| Clone | `clone.ts` | Direct argument invocation, destination selection, longer timeout, existing authentication infrastructure. |
| Fetch/push | `fetch.ts`, `push.ts` | Native fetch/prune, explicit upstream publication, explicit push refspec without force. No automatic forced push or remote deletion. |
| Pull | `pull.ts` | Explicit fast-forward, merge, and rebase choices; require clean worktree; inspect actual unmerged index after failure. |
| Merge | `merge.ts`, `merge-tree.ts` | Separate completion/conflict/failure; native continuation and abort, metadata from Git paths. No custom merge algorithm. |
| Rebase | `rebase.ts` | Treat paused rebase as operation state; explain reversed side roles; native continue/abort. Interactive reorder/squash and skip are not exposed. |
| Cherry-pick/revert | `cherry-pick.ts`, `revert.ts` | Classify conflicts separately; native continue/abort. Merge commits require a mainline choice and are intentionally disabled in these actions. |
| Stash | `stash.ts` | Use Git stash operations; retain stash on conflicts; verify stash reference still identifies the displayed object before apply/pop/drop. |
| Remotes/tags | `remote.ts`, `tag.ts` | Git-managed configuration and annotated tags, option boundaries, confirmation for removal. |

Desktop's TypeScript and Dugite code is a behavioral reference, not a correctness proof. The test suite creates real isolated Git repositories to verify bytes, index state, and commit history. Differences from Desktop are deliberate where they reduce scope or preserve safety. Uncovered workflows remain documented in `ROADMAP.md`; this preview is not described as foolproof or production-certified.

The [UI-to-Git parity ledger](DESKTOP_PARITY.md) records the full evidence chain, pinned links, implementation/test/GUI distinctions, and remaining gaps. It follows the official [REA source-analysis routing rule](https://github.com/morluto/rea/blob/22e5aa97af8d726400f3f932cae10e0083412038/.agents/skills/reverse-engineer-anything/SKILL.md); this review did not analyze or observe a shipped GitHub Desktop binary.
