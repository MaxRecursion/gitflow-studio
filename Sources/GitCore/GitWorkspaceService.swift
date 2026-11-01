import Foundation
import Darwin

public struct GitIdentity: Sendable, Equatable {
    public let name: String
    public let email: String
    public init(name: String, email: String) { self.name = name; self.email = email }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !email.isEmpty,
              !name.contains(where: { "\n\r\0<>".contains($0) }),
              !email.contains(where: { "\n\r\0<> ".contains($0) }), email.contains("@") else {
            throw GitError.invalidInput("Enter a name and email address without line breaks or angle brackets.")
        }
    }
}

public struct GitIgnoreSnapshot: Sendable {
    public let data: Data?
    let mode: mode_t
    public var text: String { data.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

public struct GitWorktree: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let head: String
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public let lockReason: String?
    public let pruneReason: String?
}

public struct GitWorktreePrunePreview: Sendable {
    public let worktrees: [GitWorktree]
    public let details: String
    public var hasChanges: Bool { !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let snapshot: [GitWorktree]
}

extension GitRepository {
    public func identity() async throws -> GitIdentity {
        let name = try await run(["config", "--get", "user.name"], allowedExitCodes: [0, 1]).text.trimmingCharacters(in: .newlines)
        let email = try await run(["config", "--get", "user.email"], allowedExitCodes: [0, 1]).text.trimmingCharacters(in: .newlines)
        return GitIdentity(name: name, email: email)
    }
    public func setIdentity(_ identity: GitIdentity?, expected: GitIdentity) async throws {
        try identity?.validate()
        try await transaction { runner, url in
            let currentName = try await runner.run(["config", "--get", "user.name"], in: url, allowedExitCodes: [0, 1]).text.trimmingCharacters(in: .newlines)
            let currentEmail = try await runner.run(["config", "--get", "user.email"], in: url, allowedExitCodes: [0, 1]).text.trimmingCharacters(in: .newlines)
            guard GitIdentity(name: currentName, email: currentEmail) == expected else { throw GitError.staleState }
            if let identity {
                _ = try await runner.run(["config", "--local", "user.name", identity.name], in: url)
                _ = try await runner.run(["config", "--local", "user.email", identity.email], in: url)
            } else {
                for key in ["user.name", "user.email"] { _ = try await runner.run(["config", "--local", "--unset-all", key], in: url, allowedExitCodes: [0, 5]) }
            }
        }
    }

    public func readIgnore() throws -> GitIgnoreSnapshot { try Self.readIgnore(at: url) }
    private static func readIgnore(at root: URL) throws -> GitIgnoreSnapshot {
        let path = root.appendingPathComponent(".gitignore").path
        // Opening a FIFO without O_NONBLOCK waits for a writer before fstat can reject it.
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return GitIgnoreSnapshot(data: nil, mode: 0o644) }
            throw GitError.invalidInput("Cannot read .gitignore. It must be a regular file, not a symbolic link.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 1_048_576 else {
            throw GitError.invalidInput("The .gitignore editor supports regular UTF-8 files up to 1 MB.")
        }
        // A regular file can grow after fstat. Bound the read itself, not only the size check.
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, 1_048_577 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 1_048_576 else { throw GitError.invalidInput("The .gitignore editor supports regular UTF-8 files up to 1 MB.") }
        }
        guard String(data: data, encoding: .utf8) != nil else { throw GitError.invalidInput("The .gitignore file is not UTF-8 text.") }
        return GitIgnoreSnapshot(data: data, mode: metadata.st_mode & 0o777)
    }
    public func saveIgnore(_ text: String, expected: GitIgnoreSnapshot) async throws {
        guard text.utf8.count <= 1_048_576, !text.contains("\0") else { throw GitError.invalidInput("The .gitignore text is too large or contains a NUL byte.") }
        try await transaction { _, root in
            let current = try Self.readIgnore(at: root)
            guard current.data == expected.data, current.mode == expected.mode else { throw GitError.staleState }
            let target = root.appendingPathComponent(".gitignore")
            let temporary = root.appendingPathComponent(".gitflow-ignore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: Int(expected.mode)], ofItemAtPath: temporary.path)
            guard Darwin.rename(temporary.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }

    public func worktrees() async throws -> [GitWorktree] {
        try await Self.readWorktrees(runner: runner, at: url)
    }
    private static func readWorktrees(runner: GitProcessRunner, at url: URL) async throws -> [GitWorktree] {
        let output = try await runner.run(["worktree", "list", "--porcelain", "-z"], in: url)
        var result: [GitWorktree] = [], fields: [String] = []
        for bytes in output.stdout.split(separator: 0, omittingEmptySubsequences: false) {
            if !bytes.isEmpty {
                guard let field = String(data: Data(bytes), encoding: .utf8) else { throw GitError.invalidInput("A worktree path contains non-UTF-8 bytes and cannot be represented safely.") }
                fields.append(field); continue
            }
            guard let path = fields.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            let branch = fields.first(where: { $0.hasPrefix("branch ") }).map { String($0.dropFirst(7)) }
            let head = fields.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst(5)) } ?? ""
            let lock = fields.first(where: { $0 == "locked" || $0.hasPrefix("locked ") })
            let prune = fields.first(where: { $0 == "prunable" || $0.hasPrefix("prunable ") })
            result.append(GitWorktree(path: String(path.dropFirst(9)), head: head, branch: branch,
                                      isMain: result.isEmpty, isLocked: lock != nil, isPrunable: prune != nil,
                                      lockReason: lock.flatMap { $0.count > 7 ? String($0.dropFirst(7)) : nil },
                                      pruneReason: prune.flatMap { $0.count > 9 ? String($0.dropFirst(9)) : nil }))
            fields = []
        }
        return result
    }
    public func addWorktree(at destination: URL, branch: String, from revision: String = "HEAD") async throws {
        try Self.validateArgument(branch); try Self.validateArgument(revision)
        guard destination.isFileURL else { throw GitError.invalidInput("Choose a local destination.") }
        _ = try await perform(["worktree", "add", "-b", branch, "--", destination.path, revision])
    }
    public func addExistingBranchWorktree(at destination: URL, branch: String) async throws {
        try Self.validateArgument(branch)
        guard destination.isFileURL else { throw GitError.invalidInput("Choose a local destination.") }
        try await transaction { runner, root in
            _ = try await runner.run(["check-ref-format", "refs/heads/" + branch], in: root)
            _ = try await runner.run(["show-ref", "--verify", "--", "refs/heads/" + branch], in: root)
            _ = try await runner.run(["worktree", "add", "--no-guess-remote", "--", destination.path, branch], in: root)
        }
    }
    public func removeWorktree(_ worktree: GitWorktree) async throws {
        try await transaction { runner, root in
            try await Self.validateWorktree(worktree, runner: runner, root: root, allowActive: false)
            guard !worktree.isLocked else { throw GitError.invalidInput("Unlock this worktree before removing it.") }
            _ = try await runner.run(["worktree", "remove", "--", worktree.path], in: root)
        }
    }
    public func moveWorktree(_ worktree: GitWorktree, to destination: URL) async throws {
        guard destination.isFileURL else { throw GitError.invalidInput("Choose a local destination.") }
        try await transaction { runner, root in
            try await Self.validateWorktree(worktree, runner: runner, root: root, allowActive: false)
            guard !worktree.isLocked else { throw GitError.invalidInput("Unlock this worktree before moving it.") }
            var attributes = stat()
            guard lstat(destination.path, &attributes) != 0, errno == ENOENT else {
                throw GitError.invalidInput("Choose a destination that does not already exist.")
            }
            _ = try await runner.run(["worktree", "move", "--", worktree.path, destination.path], in: root)
        }
    }
    public func lockWorktree(_ worktree: GitWorktree, reason: String = "") async throws {
        guard !reason.contains("\0") else { throw GitError.invalidInput("The lock reason cannot contain a NUL byte.") }
        try await transaction { runner, root in
            try await Self.validateWorktree(worktree, runner: runner, root: root)
            guard !worktree.isLocked else { throw GitError.invalidInput("This worktree is already locked.") }
            _ = try await runner.run(["worktree", "lock"] + (reason.isEmpty ? [] : ["--reason", reason]) + ["--", worktree.path], in: root)
        }
    }
    public func unlockWorktree(_ worktree: GitWorktree) async throws {
        try await transaction { runner, root in
            try await Self.validateWorktree(worktree, runner: runner, root: root)
            guard worktree.isLocked else { throw GitError.invalidInput("This worktree is not locked.") }
            _ = try await runner.run(["worktree", "unlock", "--", worktree.path], in: root)
        }
    }
    public func previewWorktreePrune() async throws -> GitWorktreePrunePreview {
        let trees = try await Self.readWorktrees(runner: runner, at: url)
        let details = try await Self.pruneDetails(runner: runner, root: url)
        return GitWorktreePrunePreview(worktrees: trees.filter { $0.isPrunable && !$0.isLocked && !$0.isMain }, details: details, snapshot: trees)
    }
    public func pruneWorktrees(expected: GitWorktreePrunePreview) async throws {
        guard expected.hasChanges else { throw GitError.invalidInput("There are no missing worktree registrations to prune.") }
        try await transaction { runner, root in
            let current = try await Self.readWorktrees(runner: runner, at: root)
            guard current == expected.snapshot, try await Self.pruneDetails(runner: runner, root: root) == expected.details else { throw GitError.staleState }
            _ = try await runner.run(["worktree", "prune", "--verbose", "--expire=now"], in: root)
        }
    }
    private static func pruneDetails(runner: GitProcessRunner, root: URL) async throws -> String {
        let result = try await runner.run(["worktree", "prune", "--dry-run", "--verbose", "--expire=now"], in: root)
        guard let details = String(data: result.stdout + result.stderr, encoding: .utf8) else { throw GitError.invalidInput("The prune preview cannot be displayed safely.") }
        return details
    }
    private static func validateWorktree(_ expected: GitWorktree, runner: GitProcessRunner, root: URL, allowActive: Bool = true) async throws {
        let current = try await readWorktrees(runner: runner, at: root)
        guard current.first(where: { $0.path == expected.path }) == expected else { throw GitError.staleState }
        let target = URL(fileURLWithPath: expected.path).standardizedFileURL.resolvingSymlinksInPath()
        let active = root.standardizedFileURL.resolvingSymlinksInPath()
        guard !expected.isMain else { throw GitError.invalidInput("The main worktree cannot be locked, moved, or removed.") }
        guard allowActive || target != active else { throw GitError.invalidInput("The active worktree cannot be moved or removed from this window.") }
    }

    public func undoLatestCommit(expectedHead: String) async throws -> String {
        try await transaction { runner, url in
            let head = try await runner.run(["rev-parse", "--verify", "HEAD"], in: url).text.trimmingCharacters(in: .newlines)
            guard head == expectedHead else { throw GitError.staleState }
            guard try await ConflictService.operation(runner: runner, url: url) == .none else { throw GitError.invalidInput("Finish the operation in progress before undoing a commit.") }
            guard try await runner.run(["ls-files", "-u", "-z"], in: url).stdout.isEmpty else { throw GitError.invalidInput("Resolve the unmerged index before undoing a commit.") }
            let remoteRefs = try await runner.run(["for-each-ref", "--contains", head, "--format=%(refname)", "refs/remotes"], in: url)
            guard remoteRefs.stdout.isEmpty else { throw GitError.invalidInput("This commit is present in a remote-tracking branch. Use Revert to preserve shared history.") }
            let parent = try await runner.run(["rev-parse", "--verify", "HEAD^"], in: url, allowedExitCodes: [0, 128])
            let message = try await runner.run(["log", "-1", "--format=%B"], in: url).text.trimmingCharacters(in: .newlines)
            if parent.exitCode == 0 {
                _ = try await runner.run(["reset", "--soft", parent.text.trimmingCharacters(in: .newlines), "--"], in: url)
            } else {
                let object = try await runner.run(["cat-file", "commit", head], in: url)
                let headers = object.stdout.split(separator: 10, omittingEmptySubsequences: false).prefix { !$0.isEmpty }
                guard !headers.contains(where: { $0.starts(with: Data("parent ".utf8)) }) else { throw GitError.invalidInput("The parent commit is unavailable. Fetch more history before undoing this commit.") }
                let symbolic = try await runner.run(["symbolic-ref", "--quiet", "HEAD"], in: url, allowedExitCodes: [0, 1])
                guard symbolic.exitCode == 0 else { throw GitError.invalidInput("Create a branch before undoing a detached root commit.") }
                let ref = try symbolic.strictText(context: "Current branch").trimmingCharacters(in: .newlines)
                guard ref.hasPrefix("refs/heads/") else { throw GitError.invalidInput("HEAD does not name a local branch.") }
                // Git's compare-and-swap deletion makes the branch unborn, while
                // retaining every staged and working byte, including extra edits.
                _ = try await runner.run(["update-ref", "-d", ref, expectedHead], in: url)
            }
            return message
        }
    }
}
