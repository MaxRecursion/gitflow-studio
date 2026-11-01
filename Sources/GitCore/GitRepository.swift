import Foundation

/// Repository operations share a mutation gate across windows and linked worktrees.
/// Git still owns its index and ref locks against other applications.
public actor GitRepository {
    public nonisolated let url: URL
    public nonisolated let runner: GitProcessRunner
    private var statusTask: Task<GitStatus, Error>?
    private var statusRequestID: UUID?
    private var commonDirectoryKey: String?
    public init(url: URL, runner: GitProcessRunner = GitProcessRunner()) {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath(); self.runner = runner
    }
    public static func open(_ url: URL) async throws -> GitRepository {
        let interval = GitPerformance.signposter.beginInterval("Repository Open", id: GitPerformance.signposter.makeSignpostID())
        defer { GitPerformance.signposter.endInterval("Repository Open", interval) }
        let runner = GitProcessRunner()
        let result = try await runner.run(["rev-parse", "--show-toplevel"], in: url)
        var path = try result.strictText(context: "The repository path")
        if path.utf8.last == 10 { path = String(decoding: path.utf8.dropLast(), as: UTF8.self) }
        guard !path.isEmpty else { throw GitError.invalidRepository }
        return GitRepository(url: URL(fileURLWithPath: path), runner: runner)
    }
    public static func initialize(at url: URL) async throws -> GitRepository {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcessRunner().run(["init", "--initial-branch=main", "--", url.path])
        return try await open(url)
    }
    public static func clone(remote: String, to destination: URL) async throws -> GitRepository {
        guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains("\0") else { throw GitError.invalidInput("Enter a valid remote URL.") }
        _ = try await GitProcessRunner().run(["clone", "--", remote, destination.path], timeout: 600)
        return try await open(destination)
    }
    public func run(_ arguments: [String], allowedExitCodes: Set<Int32> = [0]) async throws -> GitOutput {
        try await runner.run(arguments, in: url, allowedExitCodes: allowedExitCodes)
    }
    public func transaction<T: Sendable>(_ body: @Sendable (GitProcessRunner, URL) async throws -> T) async throws -> T {
        let key = try await mutationKey()
        try await MutationGate.shared.acquire(key)
        do {
            try Task.checkCancellation()
            let result = try await body(runner, url)
            statusTask?.cancel(); statusTask = nil
            await MutationGate.shared.release(key)
            return result
        } catch {
            statusTask?.cancel(); statusTask = nil
            await MutationGate.shared.release(key)
            throw error
        }
    }
    private func mutationKey() async throws -> String {
        if let commonDirectoryKey { return commonDirectoryKey }
        let result = try await runner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: url)
        var path = try result.strictText(context: "The common Git directory path")
        if path.utf8.last == 10 { path = String(decoding: path.utf8.dropLast(), as: UTF8.self) }
        guard !path.isEmpty, path.hasPrefix("/") else { throw GitError.invalidRepository }
        let key = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        commonDirectoryKey = key
        return key
    }
    public func perform(_ arguments: [String], input: Data? = nil) async throws -> GitOutput {
        try await transaction { runner, url in
            try await runner.run(arguments, in: url, input: input, timeout: 600)
        }
    }
    public func status() async throws -> GitStatus {
        if let statusTask { return try await statusTask.value }
        let runner = runner, url = url
        let task = Task {
            let interval = GitPerformance.signposter.beginInterval("Repository Status", id: GitPerformance.signposter.makeSignpostID())
            defer { GitPerformance.signposter.endInterval("Repository Status", interval) }
            let result = try await runner.run(["--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: url)
            return try GitStatusParser.parse(result.stdout)
        }
        let requestID = UUID()
        statusTask = task; statusRequestID = requestID
        defer { if statusRequestID == requestID { statusTask = nil; statusRequestID = nil } }
        return try await task.value
    }
    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try paths.forEach(Self.validatePath)
        _ = try await perform(["add", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Self.pathspec(paths))
    }
    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try paths.forEach(Self.validatePath)
        try await transaction { runner, url in
            let head = try await runner.run(["rev-parse", "--verify", "HEAD"], in: url, allowedExitCodes: [0, 128])
            if head.exitCode == 0 {
                _ = try await runner.run(["restore", "--staged", "--pathspec-from-file=-", "--pathspec-file-nul"], in: url, input: Self.pathspec(paths))
            } else {
                _ = try await runner.run(["rm", "--cached", "--pathspec-from-file=-", "--pathspec-file-nul"], in: url, input: Self.pathspec(paths))
            }
        }
    }
    public func commit(message: String, amend: Bool = false, coauthors: [GitIdentity] = []) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitError.invalidInput("Write a commit summary first.") }
        try coauthors.forEach { try $0.validate() }
        let trailers = coauthors.flatMap { ["--trailer", "Co-authored-by: \($0.name) <\($0.email)>"] }
        _ = try await perform(["commit"] + (amend ? ["--amend"] : []) + trailers + ["--file=-"], input: Data(message.utf8))
    }
    public func diff(path: String, staged: Bool = false) async throws -> String {
        try Self.validatePath(path)
        let result = try await run(Self.patchDiffArguments(path: path, staged: staged))
        if !result.stdout.isEmpty || staged { return try result.strictText(context: "This file's diff") }
        let tracked = try await run(["ls-files", "--error-unmatch", "--", path], allowedExitCodes: [0, 1])
        if tracked.exitCode == 1 {
            // --no-index lets Git classify binaries, symlinks, and unusual line endings itself.
            let untracked = try await run(["-c", "diff.suppressBlankEmpty=false", "diff"] + Self.patchDiffOptions + ["--no-index", "--", "/dev/null", url.appendingPathComponent(path).path], allowedExitCodes: [0, 1])
            return try untracked.strictText(context: "This file's diff")
        }
        return "No changes in this view."
    }
    public func history(limit: Int = 100, skip: Int = 0, search: String = "") async throws -> [GitCommit] {
        let interval = GitPerformance.signposter.beginInterval("History Page", id: GitPerformance.signposter.makeSignpostID())
        defer { GitPerformance.signposter.endInterval("History Page", interval) }
        let exists = try await run(["rev-parse", "--verify", "HEAD"], allowedExitCodes: [0, 128])
        guard exists.exitCode == 0 else { return [] }
        var args = ["log", "--all", "--topo-order", "--no-show-signature", "--max-count=\(min(max(limit, 1), 500))", "--skip=\(max(skip, 0))", "-z", "--format=%H%x00%P%x00%an%x00%at%x00%s%x00%D"]
        if !search.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--grep", search] }
        let result = try await run(args)
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var commits: [GitCommit] = [], index = 0
        while index + 5 < fields.count {
            commits.append(GitCommit(sha: fields[index], parents: fields[index + 1].split(separator: " ").map(String.init),
                                     author: fields[index + 2], date: Date(timeIntervalSince1970: Double(fields[index + 3]) ?? 0),
                                     subject: fields[index + 4], decorations: fields[index + 5]))
            index += 6
        }
        return commits
    }
    public func branches() async throws -> [GitBranch] {
        let result = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)", "refs/heads", "refs/remotes"])
        return try result.strictText(context: "Branch names").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 5 else { return nil }
            let remote = parts[0].hasPrefix("refs/remotes/")
            let name = String(parts[0].dropFirst(remote ? 13 : 11))
            return GitBranch(name: name, sha: parts[1], isCurrent: parts[2] == "*", isRemote: remote,
                             upstream: parts[3].isEmpty ? nil : parts[3], tracking: parts[4])
        }
    }
    public func remotes() async throws -> [GitRemote] {
        let result = try await run(["remote"])
        var remotes: [GitRemote] = []
        for name in try result.strictText(context: "Remote names").split(separator: "\n").map(String.init) {
            let fetch = try await run(["remote", "get-url", "--", name])
            let push = try await run(["remote", "get-url", "--push", "--", name])
            remotes.append(GitRemote(name: name, fetchURL: GitProcessRunner.redacted(fetch.text.trimmingCharacters(in: .newlines)),
                                     pushURL: GitProcessRunner.redacted(push.text.trimmingCharacters(in: .newlines))))
        }
        return remotes
    }
    public func stashes() async throws -> [GitStash] {
        let result = try await run(["stash", "list", "-z", "--format=%gd%x00%H%x00%s"])
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var values: [GitStash] = [], index = 0
        while index + 2 < fields.count {
            values.append(GitStash(reference: fields[index], sha: fields[index + 1], subject: fields[index + 2])); index += 3
        }
        return values
    }
    public func tags() async throws -> [GitTag] {
        let result = try await run(["for-each-ref", "--sort=-creatordate", "--format=%(refname:short)%00%(objectname)%00%(subject)", "refs/tags"])
        return try result.strictText(context: "Tag names").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            return GitTag(name: parts[0], sha: parts[1], subject: parts[2])
        }
    }
    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            throw GitError.invalidInput("The selected path is not inside this repository.")
        }
    }
    private static func pathspec(_ paths: [String]) -> Data { Data((paths.joined(separator: "\0") + "\0").utf8) }
}

private actor MutationGate {
    static let shared = MutationGate()
    private var active: Set<String> = []
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [String: [Waiter]] = [:]
    func acquire(_ path: String) async throws {
        try Task.checkCancellation()
        if active.insert(path).inserted { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[path, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(path, id: id) } }
    }
    private func cancel(_ path: String, id: UUID) {
        guard let index = waiters[path]?.firstIndex(where: { $0.id == id }), let waiter = waiters[path]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
    func release(_ path: String) {
        if var queue = waiters[path], !queue.isEmpty {
            let first = queue.removeFirst(); waiters[path] = queue.isEmpty ? nil : queue; first.continuation.resume()
        } else { active.remove(path) }
    }
}
