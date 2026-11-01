import Foundation

public struct GitOutput: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public var text: String { String(decoding: stdout, as: UTF8.self) }
    /// Use for identifiers and editable patches; lossy decoding can name a
    /// different path or silently replace bytes when a patch is staged.
    public func strictText(context: String = "Git output") throws -> String {
        guard let value = String(data: stdout, encoding: .utf8) else {
            throw GitError.invalidInput("\(context) contains non-UTF-8 bytes and cannot be represented safely as text.")
        }
        return value
    }
    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

public enum GitError: Error, LocalizedError, Sendable {
    case unavailable, invalidRepository, invalidInput(String), command(Int32, String), timedOut, outputLimit, staleState
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Git is unavailable. Install the Xcode Command Line Tools or Git, then try again."
        case .invalidRepository: "This folder is not a Git working repository."
        case .invalidInput(let reason): reason
        case .command(let code, let message): message.isEmpty ? "Git exited with status \(code)." : message
        case .timedOut: "Git took too long and was stopped. Refresh the repository before retrying."
        case .outputLimit: "This output is too large to display safely. Use a narrower selection."
        case .staleState: "The repository changed outside this window. Refresh and review the changes before retrying."
        }
    }
}

public struct GitFileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let workTreeStatus: String
    public let isConflicted: Bool
    public var isUntracked: Bool { indexStatus == "?" }
    public var isStaged: Bool { indexStatus != "." && indexStatus != "?" && !isConflicted }
    public var isUnstaged: Bool { workTreeStatus != "." || isUntracked }
    public var statusLabel: String {
        if isConflicted { return "Conflict" }
        if isUntracked { return "New file" }
        if indexStatus == "R" || workTreeStatus == "R" { return "Renamed" }
        if indexStatus == "D" || workTreeStatus == "D" { return "Deleted" }
        if indexStatus == "A" { return "Added" }
        return "Modified"
    }
    public init(path: String, originalPath: String? = nil, indexStatus: String, workTreeStatus: String, isConflicted: Bool = false) {
        self.path = path; self.originalPath = originalPath; self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus; self.isConflicted = isConflicted
    }
}

public struct GitStatus: Sendable {
    public let branch: String
    public let head: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let files: [GitFileChange]
    public var conflicts: [GitFileChange] { files.filter(\.isConflicted) }
    public var isUnborn: Bool { head == nil }
    public init(branch: String, head: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, files: [GitFileChange] = []) {
        self.branch = branch; self.head = head; self.upstream = upstream; self.ahead = ahead; self.behind = behind; self.files = files
    }
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public var id: String { sha }
    public let sha: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let subject: String
    public let decorations: String
    public var shortSHA: String { String(sha.prefix(8)) }
}

public struct GitBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let sha: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public let upstream: String?
    public let tracking: String
}

public struct GitRemote: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let fetchURL: String
    public let pushURL: String
}

public struct GitStash: Identifiable, Hashable, Sendable {
    public var id: String { reference }
    public let reference: String
    public let sha: String
    public let subject: String
}

public struct GitTag: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let sha: String
    public let subject: String
}
