import Foundation

public enum GitOperationResult: Sendable { case completed(String), conflicts }

extension GitRepository {
    /// Resolve user-supplied revisions before any mutation. Option-like strings never become flags.
    public func resolveRevision(_ revision: String) async throws -> String {
        try Self.validateArgument(revision)
        let result = try await run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"])
        return result.text.trimmingCharacters(in: .newlines)
    }

    public static func validateArgument(_ value: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            throw GitError.invalidInput("Enter a nonempty name or revision that does not begin with a dash or contain a newline.")
        }
    }

    public func createBranch(name: String, startPoint: String = "HEAD", tracking: Bool = false) async throws {
        try Self.validateArgument(name); try Self.validateArgument(startPoint)
        try await transaction { runner, url in
            _ = try await runner.run(["check-ref-format", "--branch", name], in: url)
            _ = try await runner.run(["branch"] + (tracking ? ["--track"] : ["--no-track"]) + ["--", name, startPoint], in: url)
        }
    }

    public func switchBranch(_ name: String) async throws {
        try Self.validateArgument(name)
        _ = try await perform(["switch", "--", name])
    }

    public func renameBranch(_ old: String, to name: String) async throws {
        try Self.validateArgument(old); try Self.validateArgument(name)
        _ = try await perform(["branch", "-m", "--", old, name])
    }

    public func deleteBranch(_ name: String) async throws {
        try Self.validateArgument(name)
        // Deliberately use -d; Git must refuse branches containing unmerged work.
        _ = try await perform(["branch", "-d", "--", name])
    }

    public func integrate(_ operation: GitOperation, revision: String) async throws -> GitOperationResult {
        guard [.merge, .rebase, .cherryPick, .revert].contains(operation) else { throw GitError.invalidInput("Choose a supported operation.") }
        try Self.validateArgument(revision)
        return try await transaction { runner, url in
            guard try await ConflictService.operation(runner: runner, url: url) == .none else {
                throw GitError.invalidInput("Continue or abort the operation already in progress before starting another.")
            }
            let head = try await runner.run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], in: url)
            let sha = head.text.trimmingCharacters(in: .newlines)
            let status = try await runner.run(["--no-optional-locks", "status", "--porcelain=v2", "-z"], in: url)
            guard try GitStatusParser.parse(status.stdout).files.isEmpty else {
                throw GitError.invalidInput("Commit or stash your working changes before starting \(operation.rawValue).")
            }
            let arguments: [String]
            switch operation {
            case .merge: arguments = ["merge", "--no-edit", "--", sha]
            case .rebase: arguments = ["rebase", "--no-autostash", sha]
            case .cherryPick: arguments = ["cherry-pick", sha]
            case .revert: arguments = ["revert", "--no-edit", sha]
            case .none: throw GitError.invalidInput("Unsupported operation")
            }
            let result = try await runner.run(arguments, in: url, allowedExitCodes: [0, 1, 128], timeout: 600)
            if result.exitCode == 0 { return .completed(result.text) }
            let unmerged = try await runner.run(["ls-files", "-u", "-z"], in: url)
            if !unmerged.stdout.isEmpty { return .conflicts }
            throw GitError.command(result.exitCode, GitProcessRunner.redacted(String(decoding: result.stderr + result.stdout, as: UTF8.self)))
        }
    }

    public func compare(_ from: String, to: String) async throws -> String {
        let lhs = try await resolveRevision(from), rhs = try await resolveRevision(to)
        return try await run(["diff", "--no-ext-diff", "--no-textconv", "--stat", "--patch", lhs, rhs, "--"]).text
    }

    public func addRemote(name: String, url: String) async throws {
        try Self.validateArgument(name); try Self.validateArgument(url)
        _ = try await perform(["remote", "add", "--", name, url])
    }

    public func updateRemote(name: String, url: String) async throws {
        try Self.validateArgument(name); try Self.validateArgument(url)
        _ = try await perform(["remote", "set-url", "--", name, url])
    }

    public func publishBranch(remote: String, branch: String) async throws {
        try Self.validateArgument(remote); try Self.validateArgument(branch)
        _ = try await perform(["push", "--porcelain", "--no-force", "--set-upstream", "--", remote, "refs/heads/" + branch + ":refs/heads/" + branch])
    }

    public func createTag(_ name: String, revision: String = "HEAD", message: String = "") async throws {
        try Self.validateArgument(name)
        let sha = try await resolveRevision(revision)
        _ = try await perform(["tag", "-a", "-m", message, "--", name, sha])
    }

    public func applyStash(_ stash: GitStash, pop: Bool = false) async throws -> GitOperationResult {
        try await transaction { runner, url in
            let current = try await runner.run(["rev-parse", "--verify", stash.reference], in: url)
            guard current.text.trimmingCharacters(in: .newlines) == stash.sha else { throw GitError.staleState }
            let result = try await runner.run(["stash", pop ? "pop" : "apply", stash.reference], in: url, allowedExitCodes: [0, 1])
            if result.exitCode == 0 { return .completed(result.text) }
            if try await runner.run(["ls-files", "-u", "-z"], in: url).stdout.isEmpty == false { return .conflicts }
            throw GitError.command(result.exitCode, String(decoding: result.stderr, as: UTF8.self))
        }
    }

    public func dropStash(_ stash: GitStash) async throws {
        try await transaction { runner, url in
            let current = try await runner.run(["rev-parse", "--verify", stash.reference], in: url)
            guard current.text.trimmingCharacters(in: .newlines) == stash.sha else { throw GitError.staleState }
            _ = try await runner.run(["stash", "drop", stash.reference], in: url)
        }
    }

    public func discardUnstaged(path: String, expectedDiff: String) async throws {
        try Self.validatePath(path)
        try await transaction { runner, url in
            let current = try await runner.run(Self.patchDiffArguments(path: path, staged: false), in: url)
            guard try current.strictText(context: "This file's diff") == expectedDiff else { throw GitError.staleState }
            _ = try await runner.run(["restore", "--worktree", "--", path], in: url)
        }
    }

    public enum PullStrategy: String, Sendable { case fastForward, merge, rebase }
    public func pull(_ strategy: PullStrategy = .fastForward) async throws -> GitOperationResult {
        try await transaction { runner, url in
            let branch = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: url).text.trimmingCharacters(in: .newlines)
            let remote = try await runner.run(["config", "--get", "branch.\(branch).remote"], in: url, allowedExitCodes: [0, 1]).text.trimmingCharacters(in: .newlines)
            if !remote.isEmpty { try Self.validateArgument(remote) }
            guard try await ConflictService.operation(runner: runner, url: url) == .none else {
                throw GitError.invalidInput("Continue or abort the current operation before pulling.")
            }
            let status = try await runner.run(["--no-optional-locks", "status", "--porcelain=v2", "-z"], in: url)
            guard try GitStatusParser.parse(status.stdout).files.isEmpty else { throw GitError.invalidInput("Commit or stash your working changes before pulling.") }
            let mode: [String]
            switch strategy {
            case .fastForward: mode = ["--ff-only", "--no-rebase"]
            case .merge: mode = ["--no-rebase", "--no-edit"]
            case .rebase: mode = ["--rebase", "--no-autostash"]
            }
            let result = try await runner.run(["pull"] + mode, in: url, allowedExitCodes: [0, 1, 128], timeout: 600)
            if result.exitCode == 0 { return .completed(result.text) }
            if try await runner.run(["ls-files", "-u", "-z"], in: url).stdout.isEmpty == false { return .conflicts }
            throw GitError.command(result.exitCode, GitProcessRunner.redacted(String(decoding: result.stderr + result.stdout, as: UTF8.self)))
        }
    }

    /// Explicit branch refspec avoids inheriting wildcard, mirror, or force refspecs.
    public func pushCurrentBranch() async throws {
        try await transaction { runner, url in
            let result = try await runner.run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: url)
            let branch = result.text.trimmingCharacters(in: .newlines)
            try Self.validateArgument(branch)
            let remote = try await runner.run(["config", "--get", "branch.\(branch).remote"], in: url, allowedExitCodes: [0, 1])
            let merge = try await runner.run(["config", "--get", "branch.\(branch).merge"], in: url, allowedExitCodes: [0, 1])
            let remoteName = remote.text.trimmingCharacters(in: .newlines), target = merge.text.trimmingCharacters(in: .newlines)
            if !remoteName.isEmpty { try Self.validateArgument(remoteName) }
            if !target.isEmpty { _ = try await runner.run(["check-ref-format", target], in: url) }
            guard !remoteName.isEmpty, remoteName != ".", target.hasPrefix("refs/heads/"), !target.contains("\n") else {
                throw GitError.invalidInput("This branch has no remote upstream. Open Remotes and choose Publish Current Branch.")
            }
            _ = try await runner.run(["push", "--porcelain", "--no-force", "--", remoteName, "refs/heads/" + branch + ":" + target], in: url, timeout: 600)
        }
    }
}
