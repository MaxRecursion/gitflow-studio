import Foundation

extension GitRepository {
    /// Selection keys are hunk IDs; values are addition/deletion row IDs from that hunk's `lines`.
    /// The worktree is never written. A staged selection reverses only the selected changes in the index.
    public func applyLines(path: String, staged: Bool, selection: [Int: Set<Int>], expectedDiff: String) async throws {
        try Self.validatePath(path)
        try await transaction { runner, url in
            let args = Self.patchDiffArguments(path: path, staged: staged)
            let current = try await runner.run(args, in: url)
            let currentText = try current.strictText(context: "This file's diff")
            guard currentText == expectedDiff else { throw GitError.staleState }
            let patch = try GitPatch(diff: expectedDiff).selectedLines(selection, reversed: staged)
            let input = Data(patch.utf8)
            // Some legitimate text edits have zero context (for example an empty tracked file).
            // The full original diff has just been checked, and Git checks this patch against the index.
            let command = ["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn"]
            _ = try await runner.run(command + ["--check", "-"], in: url, input: input)
            _ = try await runner.run(command + ["-"], in: url, input: input)
        }
    }
}

extension GitPatch {
    func selectedLines(_ selection: [Int: Set<Int>], reversed: Bool) throws -> String {
        guard canApplyLines else {
            throw GitError.invalidInput("Individual-line selection requires an ordinary text edit with a final newline. Use whole-file staging for metadata, binary, renamed, new, deleted, or no-final-newline files.")
        }
        guard selection.values.contains(where: { !$0.isEmpty }) else { throw GitError.invalidInput("Select at least one added or removed line.") }
        guard Set(selection.keys).isSubset(of: Set(hunks.map(\.id))) else { throw GitError.invalidInput("The selected hunk is no longer available.") }
        // An original index hash describes the complete diff, not the selected lines. Omit it;
        // existing regular-file mode and Git's quoted path headers remain unchanged.
        let patchHeader = header.components(separatedBy: "\n").filter { !$0.hasPrefix("index ") }.joined(separator: "\n")
        var result = patchHeader, cumulativeDelta = 0
        for hunk in hunks {
            let parsed = try hunk.parsedLines()
            let selected = selection[hunk.id] ?? []
            guard selected.isSubset(of: Set(parsed.lines.filter(\.isSelectable).map(\.id))) else {
                throw GitError.invalidInput("Only added and removed lines can be selected.")
            }
            guard !selected.isEmpty else { continue }
            var body = "", sourceCount = 0, targetCount = 0
            for line in parsed.lines {
                let kind: GitDiffLine.Kind
                if reversed && line.kind == .addition { kind = .deletion }
                else if reversed && line.kind == .deletion { kind = .addition }
                else { kind = line.kind }
                switch kind {
                case .context:
                    body += " " + line.rawContent; sourceCount += 1; targetCount += 1
                case .addition:
                    if selected.contains(line.id) { body += "+" + line.rawContent; targetCount += 1 }
                case .deletion:
                    sourceCount += 1
                    if selected.contains(line.id) { body += "-" + line.rawContent }
                    else { body += " " + line.rawContent; targetCount += 1 }
                case .noNewline:
                    throw GitError.invalidInput("Use whole-file staging for a file without a final newline.")
                }
            }
            let sourceStart = reversed ? parsed.newStart : parsed.oldStart
            let originalSourceCount = reversed ? parsed.newCount : parsed.oldCount
            guard sourceCount == originalSourceCount else { throw GitError.invalidInput("The selected patch has inconsistent line counts.") }
            let sourceOffset = sourceCount == 0 ? sourceStart : sourceStart - 1
            let targetOffset = sourceOffset + cumulativeDelta
            guard targetOffset >= 0 else { throw GitError.invalidInput("The selected patch has invalid line positions.") }
            let oldStart = sourceCount == 0 ? sourceOffset : sourceOffset + 1
            let newStart = targetCount == 0 ? targetOffset : targetOffset + 1
            result += "@@ -\(oldStart),\(sourceCount) +\(newStart),\(targetCount) @@\n" + body
            cumulativeDelta += targetCount - sourceCount
        }
        return result
    }
}
