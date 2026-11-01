import Foundation

public enum GitResetMode: String, CaseIterable, Sendable { case soft, mixed }

extension GitRepository {
    public func checkoutDetached(_ revision: String, expectedHead: String) async throws {
        try Self.validateArgument(revision)
        try await transaction { runner, url in
            try await Self.checkExpectedHead(expectedHead, runner: runner, url: url)
            try await Self.requireIdleClean(runner: runner, url: url)
            let sha = try await runner.run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], in: url).strictText(context: "Commit identifier").trimmingCharacters(in: .newlines)
            _ = try await runner.run(["switch", "--detach", "--", sha], in: url)
        }
    }

    /// Preserves working files. The UI must explain index effects and confirm history changes.
    public func resetHistory(to revision: String, mode: GitResetMode, expectedHead: String) async throws {
        try Self.validateArgument(revision)
        try await transaction { runner, url in
            try await Self.checkExpectedHead(expectedHead, runner: runner, url: url)
            guard try await ConflictService.operation(runner: runner, url: url) == .none else { throw GitError.invalidInput("Finish the active operation before resetting history.") }
            guard try await runner.run(["ls-files", "-u", "-z"], in: url).stdout.isEmpty else { throw GitError.invalidInput("Resolve the unmerged index before resetting history.") }
            let target = try await runner.run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], in: url).strictText(context: "Reset target").trimmingCharacters(in: .newlines)
            let ancestor = try await runner.run(["merge-base", "--is-ancestor", target, expectedHead], in: url, allowedExitCodes: [0, 1])
            guard ancestor.exitCode == 0 else { throw GitError.invalidInput("Select an ancestor of the current branch to reset to.") }
            let shared = try await runner.run(["for-each-ref", "--contains", expectedHead, "--format=%(refname)", "refs/remotes"], in: url)
            guard shared.stdout.isEmpty else { throw GitError.invalidInput("The current commit is in a remote-tracking branch. Revert shared commits instead.") }
            _ = try await runner.run(["reset", "--" + mode.rawValue, target, "--"], in: url)
        }
    }

    public func pushTag(_ tag: GitTag, remote: String) async throws {
        try Self.validateArgument(remote); try Self.validateArgument(tag.name)
        try await transaction { runner, url in
            let ref = "refs/tags/" + tag.name
            let actual = try await runner.run(["rev-parse", "--verify", "--end-of-options", ref], in: url).strictText(context: "Tag identifier").trimmingCharacters(in: .newlines)
            guard actual == tag.sha else { throw GitError.staleState }
            _ = try await runner.run(["push", "--porcelain", "--no-force", "--", remote, ref + ":" + ref], in: url, timeout: 600)
        }
    }

    public func addRemoteBranchWorktree(at destination: URL, localBranch: String, remoteBranch: GitBranch) async throws {
        guard remoteBranch.isRemote else { throw GitError.invalidInput("Select a remote-tracking branch.") }
        try Self.validateArgument(localBranch); try Self.validateArgument(remoteBranch.name)
        try await transaction { runner, url in
            _ = try await runner.run(["check-ref-format", "--branch", localBranch], in: url)
            let ref = "refs/remotes/" + remoteBranch.name
            let symbolic = try await runner.run(["symbolic-ref", "--quiet", ref], in: url, allowedExitCodes: [0, 1])
            guard symbolic.exitCode == 1 else { throw GitError.invalidInput("Choose a remote branch instead of the remote HEAD alias.") }
            let actual = try await runner.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], in: url).strictText(context: "Remote branch identifier").trimmingCharacters(in: .newlines)
            guard actual == remoteBranch.sha else { throw GitError.staleState }
            _ = try await runner.run(["worktree", "add", "--track", "-b", localBranch, "--", destination.path, ref], in: url)
        }
    }

    public func ignoreUntrackedPath(_ path: String) async throws {
        try Self.validatePath(path)
        guard !path.contains("\n"), !path.contains("\r") else { throw GitError.invalidInput("Git ignore patterns cannot represent this filename as a single line. Use the ignore editor to choose an appropriate directory pattern.") }
        let tracked = try await run(["ls-files", "--error-unmatch", "--", path], allowedExitCodes: [0, 1])
        guard tracked.exitCode == 1 else { throw GitError.invalidInput("Ignore rules apply to untracked files. This file is already tracked.") }
        let before = try readIgnore()
        var pattern = "/"
        for scalar in path.unicodeScalars {
            if "\\*?[]#! ".unicodeScalars.contains(scalar) { pattern += "\\" }
            pattern.unicodeScalars.append(scalar)
        }
        let text = String(data: before.data ?? Data(), encoding: .utf8) ?? ""
        let prefix = text.isEmpty || text.utf8.last == 10 ? text : text + "\n"
        if text.components(separatedBy: "\n").contains(pattern) { return }
        try await saveIgnore(prefix + pattern + "\n", expected: before)
    }

    private static func checkExpectedHead(_ expected: String, runner: GitProcessRunner, url: URL) async throws {
        let actual = try await runner.run(["rev-parse", "--verify", "HEAD"], in: url).strictText(context: "Current HEAD").trimmingCharacters(in: .newlines)
        guard actual == expected else { throw GitError.staleState }
    }
    private static func requireIdleClean(runner: GitProcessRunner, url: URL) async throws {
        guard try await ConflictService.operation(runner: runner, url: url) == .none else { throw GitError.invalidInput("Finish the active operation first.") }
        let state = try await runner.run(["--no-optional-locks", "status", "--porcelain=v2", "-z"], in: url)
        guard try GitStatusParser.parse(state.stdout).files.isEmpty else { throw GitError.invalidInput("Commit or stash working changes before checking out a detached commit.") }
    }
}
