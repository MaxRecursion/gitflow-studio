# Design

GitFlow Studio uses the macOS visual language: system typography, SF Symbols, standard window chrome, semantic system colors, native toolbars, and resizable panes. Appearance follows the system. Color supports labels rather than replacing them.

## Repository workflow

The sidebar separates Changes, History, Branches, Remotes, Stashes, Tags, and Worktrees. Repository context remains visible while the selected task changes. Files can be searched, inspected, staged, and unstaged before committing. Repository settings expose local identity and ignore patterns; the commit form accepts a coauthor. A busy state explains ongoing work; errors retain Git's useful diagnostics. A disabled action reflects unavailable state rather than simulated functionality.

## Conflict workflow

The conflict workspace is the primary product focus. Its file list gives an overview; the main workspace places current and incoming content above an editable merged result. The base can be inspected in advanced mode. Labels adapt to rebase so “current” does not falsely mean the user's original branch.

Choices are local to conflict regions, with direct current/incoming/both selection and an editable result. The interface describes deterministic differences and operation state, without generated claims about code semantics. Binary and deletion choices make their filesystem effects explicit.

Native text views provide line numbers, soft wrapping, find, undo, and basic keyword/string/comment coloring, with paragraph-only recoloring after an edit. Bounded word differences highlight changed tokens in the selected region's current and incoming sources. The panes can scroll together proportionally; this is positional synchronization, not semantic line alignment. The existing working file can be previewed or adopted when it contains edits made before the resolver opened. Drafts survive workspace navigation within the window. Closing, quitting, or switching repositories asks before discarding unsaved conflict edits or commit messages.

Resolution has three distinct decisions: edit the result, mark and stage the file as resolved, and continue the Git operation. A choice in the editor never silently commits. The user can review the final staged changes before continuation. External file/index changes require review instead of silently overwriting newer content.

## Accessibility and scale

Native controls expose accessibility semantics, text views support standard keyboard editing and undo, and content remains selectable. Resizable panes accommodate smaller displays. Large results are bounded, history is paginated, and file lists use native lazy rendering.

VoiceOver end-to-end validation, full keyboard-only conflict navigation, semantically aligned source scrolling, general working-diff word highlighting, complete syntax support, command-palette coverage, and native UI automation are release work. Basic native controls alone do not establish complete accessibility compliance.
