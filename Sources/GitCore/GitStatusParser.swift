import Foundation

public enum GitStatusParser {
    public static func parse(_ data: Data) throws -> GitStatus {
        // Paths are passed back to Git verbatim through String arguments. Lossy
        // decoding could turn an unsupported byte path into a different, valid
        // filename containing U+FFFD and make a later action target that file.
        // Reject the complete snapshot before exposing any actionable paths.
        let entries = try data.split(separator: 0, omittingEmptySubsequences: true).map { record in
            guard let entry = String(data: Data(record), encoding: .utf8) else {
                throw GitError.invalidInput("This repository contains a filename or reference that is not valid UTF-8. GitFlow Studio cannot safely display it. Rename it using Git or another tool, then refresh.")
            }
            return entry
        }
        var branch = "HEAD", head: String?, upstream: String?, ahead = 0, behind = 0
        var files: [GitFileChange] = [], index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            if entry.hasPrefix("# branch.head ") { branch = String(entry.dropFirst(14)); continue }
            if entry.hasPrefix("# branch.oid ") {
                let value = String(entry.dropFirst(13)); head = value == "(initial)" ? nil : value; continue
            }
            if entry.hasPrefix("# branch.upstream ") { upstream = String(entry.dropFirst(18)); continue }
            if entry.hasPrefix("# branch.ab ") {
                let parts = entry.split(separator: " ")
                if parts.count == 4 { ahead = Int(parts[2].dropFirst()) ?? 0; behind = Int(parts[3].dropFirst()) ?? 0 }
                continue
            }
            if entry.hasPrefix("# ") || entry.hasPrefix("! ") { continue }
            if entry.hasPrefix("? ") {
                files.append(GitFileChange(path: String(entry.dropFirst(2)), indexStatus: "?", workTreeStatus: "?")); continue
            }
            guard let record = entry.first, ["1", "2", "u"].contains(record) else {
                throw GitError.invalidInput("Git returned an unsupported status record.")
            }
            let count = record == "u" ? 10 : record == "2" ? 9 : 8
            let fields = entry.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard fields.count == count + 1, fields[1].count == 2 else {
                throw GitError.invalidInput("Git returned an incomplete status record.")
            }
            var original: String?
            if record == "2" {
                guard index < entries.count else { throw GitError.invalidInput("Git returned an incomplete rename record.") }
                original = entries[index]; index += 1
            }
            files.append(GitFileChange(path: String(fields[count]), originalPath: original,
                                       indexStatus: String(fields[1].prefix(1)), workTreeStatus: String(fields[1].suffix(1)), isConflicted: record == "u"))
        }
        return GitStatus(branch: branch, head: head, upstream: upstream, ahead: ahead, behind: behind, files: files)
    }
}
