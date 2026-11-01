import Foundation

public struct GitDiffHunk: Identifiable, Sendable, Hashable {
    public let id: Int
    public let title: String
    public let text: String
    public var lines: [GitDiffLine] { (try? parsedLines().lines) ?? [] }
}

public struct GitDiffLine: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable { case context = " ", addition = "+", deletion = "-", noNewline = "\\" }
    /// Zero-based body row within the hunk. The @@ header is excluded.
    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public var isSelectable: Bool { kind == .addition || kind == .deletion }
    let rawContent: String
}

/// A single-file unified patch. Lines retain their terminators, including no-newline markers.
public struct GitPatch: Sendable {
    public let header: String
    public let hunks: [GitDiffHunk]
    public let canApplyHunks: Bool
    /// Line selection currently requires an ordinary regular-file text patch with final newlines.
    public var canApplyLines: Bool {
        guard canApplyHunks, !header.contains("old mode "), !header.contains("new mode "),
              header.components(separatedBy: "\n").filter({ $0.hasPrefix("diff --git ") }).count == 1,
              header.components(separatedBy: "\n").contains(where: {
                  $0.hasPrefix("index ") && ($0.hasSuffix(" 100644") || $0.hasSuffix(" 100755"))
              }) else { return false }
        return hunks.allSatisfy { hunk in
            guard let parsed = try? hunk.parsedLines() else { return false }
            return !parsed.lines.contains { $0.kind == .noNewline }
        }
    }
    public init(diff: String) {
        var header = "", hunks: [GitDiffHunk] = [], current = "", title = ""
        // NSString splitting would normalize neither CRLF nor Unicode; preserve bytes instead.
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let fullLine = String(line) + (index < lines.count - 1 ? "\n" : "")
            if line.hasPrefix("@@ ") {
                if !current.isEmpty { hunks.append(GitDiffHunk(id: hunks.count, title: title, text: current)) }
                current = fullLine; title = String(line)
            } else if title.isEmpty { header += fullLine }
            else { current += fullLine }
        }
        if !current.isEmpty { hunks.append(GitDiffHunk(id: hunks.count, title: title, text: current)) }
        self.header = header; self.hunks = hunks
        canApplyHunks = !hunks.isEmpty && !header.contains("rename from ") && !header.contains("copy from ") && !header.contains("new file mode ") && !header.contains("deleted file mode ") && !header.contains("GIT binary patch")
    }
}

struct ParsedGitHunk {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [GitDiffLine]
}

extension GitDiffHunk {
    func parsedLines() throws -> ParsedGitHunk {
        let unsupported = GitError.invalidInput("This patch cannot be split into individual lines safely. Stage or unstage the whole file.")
        let expression = try NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(?:.*)$"#)
        let titleString = title as NSString
        guard let match = expression.firstMatch(in: title, range: NSRange(location: 0, length: titleString.length)) else { throw unsupported }
        func number(_ group: Int, default defaultValue: Int? = nil) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? defaultValue : Int(titleString.substring(with: range))
        }
        guard let oldStart = number(1), let oldCount = number(2, default: 1),
              let newStart = number(3), let newCount = number(4, default: 1),
              (oldCount == 0 || oldStart > 0), (newCount == 0 || newStart > 0),
              oldStart <= Int.max - oldCount, newStart <= Int.max - newCount else { throw unsupported }
        var rows = text.components(separatedBy: "\n")
        guard rows.first == title, text.utf8.last == 10 else { throw unsupported }
        rows.removeFirst(); rows.removeLast()
        var oldLine = oldStart, newLine = newStart, lines: [GitDiffLine] = []
        for (id, row) in rows.enumerated() {
            // Patch prefixes are ASCII bytes. A leading combining mark in file
            // content may share a Swift Character with '+' or '-'.
            guard let first = row.utf8.first, let kind = GitDiffLine.Kind(rawValue: String(UnicodeScalar(first))) else { throw unsupported }
            if kind == .noNewline {
                guard row == "\\ No newline at end of file", id > 0 else { throw unsupported }
            }
            let oldNumber = kind == .addition || kind == .noNewline ? nil : oldLine
            let newNumber = kind == .deletion || kind == .noNewline ? nil : newLine
            let content = String(decoding: row.utf8.dropFirst(), as: UTF8.self)
            let rawContent = content + "\n"
            var display = content
            if display.hasSuffix("\r") { display.removeLast() }
            lines.append(GitDiffLine(id: id, kind: kind, text: display, oldLineNumber: oldNumber, newLineNumber: newNumber, rawContent: rawContent))
            if oldNumber != nil { oldLine += 1 }
            if newNumber != nil { newLine += 1 }
        }
        guard oldLine - oldStart == oldCount, newLine - newStart == newCount else { throw unsupported }
        return ParsedGitHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, lines: lines)
    }
}

extension GitRepository {
    /// Editable patches must have stable syntax and a single a/b path prefix,
    /// regardless of the user's presentation-oriented diff configuration.
    static let patchDiffOptions = ["--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                                   "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= "]
    static func patchDiffArguments(path: String, staged: Bool) -> [String] {
        ["-c", "diff.suppressBlankEmpty=false", "diff"] + patchDiffOptions + (staged ? ["--cached"] : []) + ["--", path]
    }
    /// Checks the complete displayed patch under the shared mutation gate before applying a hunk.
    public func applyHunk(path: String, staged: Bool, hunkID: Int, expectedDiff: String) async throws {
        try Self.validatePath(path)
        try await transaction { runner, url in
            let args = Self.patchDiffArguments(path: path, staged: staged)
            let current = try await runner.run(args, in: url)
            guard try current.strictText(context: "This file's diff") == expectedDiff else { throw GitError.staleState }
            let patch = GitPatch(diff: expectedDiff)
            guard patch.canApplyHunks, let hunk = patch.hunks.first(where: { $0.id == hunkID }) else {
                throw GitError.invalidInput("Stage this file as a whole; its metadata cannot be split into independent hunks.")
            }
            let input = Data((patch.header + hunk.text).utf8)
            let command = ["apply", "--cached", "--recount", "--whitespace=nowarn"] + (staged ? ["--reverse"] : [])
            _ = try await runner.run(command + ["--check", "-"], in: url, input: input)
            _ = try await runner.run(command + ["-"], in: url, input: input)
        }
    }
}
