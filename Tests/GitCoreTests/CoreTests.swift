import Foundation
import Testing
@testable import GitCore

struct CoreTests {
    @Test func statusStagingCommitAndOddFilenames() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let names = ["hello.txt", "日本語 café.txt", "line\nbreak.txt", ":(glob)*.txt", "--option.txt"]
        for name in names { try fixture.write(name, "first\n") }
        let initial = try await fixture.repository.status()
        #expect(initial.isUnborn)
        #expect(Set(initial.files.map(\.path)) == Set(names))
        #expect(initial.files.allSatisfy { $0.isUntracked })
        try await fixture.repository.stage(paths: names)
        #expect(try await fixture.repository.status().files.allSatisfy { $0.isStaged })
        try await fixture.repository.unstage(paths: [names[3]])
        #expect(try await fixture.repository.status().files.first { $0.path == names[3] }?.isUntracked == true)
        try await fixture.repository.stage(paths: [names[3]])
        try await fixture.repository.commit(message: "Initial content")
        #expect(try await fixture.repository.status().files.isEmpty)
        try fixture.write(names[1], "second\n")
        let diff = try await fixture.repository.diff(path: names[1])
        #expect(diff.contains("+second"))
        try await fixture.repository.stage(paths: [names[1]])
        try await fixture.repository.unstage(paths: [names[1]])
        #expect(try await fixture.repository.status().files.first?.isStaged == false)
    }

    @Test func renameParserKeepsOriginalPaths() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        try fixture.write("old name.txt", "some unchanged content\n")
        try await fixture.repository.stage(paths: ["old name.txt"])
        try await fixture.repository.commit(message: "Initial")
        _ = try await fixture.repository.perform(["mv", "--", "old name.txt", "new\nname.txt"])
        let status = try await fixture.repository.status()
        #expect(status.files.count == 1)
        #expect(status.files.first?.path == "new\nname.txt")
        #expect(status.files.first?.originalPath == "old name.txt")
        #expect(status.files.first?.indexStatus == "R")
    }

    @Test func branchesHistoryStashTagsAndRevert() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        try fixture.write("file.txt", "base\n")
        try await fixture.repository.stage(paths: ["file.txt"])
        try await fixture.repository.commit(message: "Initial")
        _ = try await fixture.repository.perform(["switch", "-c", "feature"])
        try fixture.write("feature.txt", "feature\n")
        try await fixture.repository.stage(paths: ["feature.txt"])
        try await fixture.repository.commit(message: "Add feature")
        #expect(try await fixture.repository.branches().contains { $0.name == "feature" && $0.isCurrent })
        let history = try await fixture.repository.history(limit: 1)
        #expect(history.count == 1)
        #expect(history.first?.subject == "Add feature")
        #expect(try await fixture.repository.history(limit: 1, skip: 1).first?.subject == "Initial")
        #expect(try await fixture.repository.history(search: "Add feature").count == 1)
        _ = try await fixture.repository.perform(["tag", "v1.0"])
        #expect(try await fixture.repository.tags().first?.name == "v1.0")
        try fixture.write("file.txt", "dirty\n")
        _ = try await fixture.repository.perform(["stash", "push", "-m", "Work in progress"])
        #expect(try await fixture.repository.stashes().first?.subject.contains("Work in progress") == true)
        #expect(try await fixture.repository.status().files.isEmpty)
        _ = try await fixture.repository.perform(["stash", "pop"])
        #expect(try await fixture.repository.status().files.count == 1)
        _ = try await fixture.repository.perform(["restore", "--", "file.txt"])
        _ = try await fixture.repository.perform(["revert", "--no-edit", history[0].sha])
        #expect(!FileManager.default.fileExists(atPath: fixture.url.appendingPathComponent("feature.txt").path))
    }

    @Test func realLocalRemotePushFetchClone() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let remote = fixture.root.appendingPathComponent("remote.git")
        _ = try await fixture.runner.run(["init", "--bare", "--initial-branch=main", "--", remote.path])
        try fixture.write("file", "hello\n")
        try await fixture.repository.stage(paths: ["file"])
        try await fixture.repository.commit(message: "Initial")
        _ = try await fixture.repository.perform(["remote", "add", "origin", remote.path])
        #expect(try await fixture.repository.remotes().first?.name == "origin")
        _ = try await fixture.repository.perform(["push", "--set-upstream", "origin", "main"])
        _ = try await fixture.repository.perform(["fetch", "origin"])
        let clone = try await GitRepository.clone(remote: remote.path, to: fixture.root.appendingPathComponent("clone"))
        #expect(try await clone.history().first?.subject == "Initial")
        #expect(try await clone.status().upstream == "origin/main")
    }

    @Test func failuresCancellationAndOutputBounds() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        await #expect(throws: GitError.self) { try await fixture.repository.perform(["switch", "does-not-exist"]) }
        await #expect(throws: GitError.self) { try await fixture.runner.run(["--help"], maxOutputBytes: 10) }
        let task = Task { try await fixture.runner.run(["status"], in: fixture.url) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(GitProcessRunner.redacted("https://name:secret@example.com/repo").contains("secret") == false)
    }

    @Test func externalChangesAreVisibleAndOpenNormalizesRoot() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let child = fixture.url.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let opened = try await GitRepository.open(child)
        #expect(opened.url == fixture.repository.url)
        #expect(try await opened.status().files.isEmpty)
        try fixture.write("external.txt", "external\n")
        #expect(try await opened.status().files.first?.path == "external.txt")
    }

    @Test func partialHunksPreserveOtherChangesAndRejectStaleDiffs() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let original = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try fixture.write("file.txt", original)
        try await fixture.repository.stage(paths: ["file.txt"])
        try await fixture.repository.commit(message: "Initial")
        let changed = original.replacingOccurrences(of: "line 2\n", with: "changed 2\n").replacingOccurrences(of: "line 28\n", with: "changed 28\n")
        try fixture.write("file.txt", changed)
        let diff = try await fixture.repository.diff(path: "file.txt")
        #expect(GitPatch(diff: diff).hunks.count == 2)
        try await fixture.repository.applyHunk(path: "file.txt", staged: false, hunkID: 0, expectedDiff: diff)
        let staged = try await fixture.repository.diff(path: "file.txt", staged: true)
        #expect(staged.contains("+changed 2"))
        #expect(!staged.contains("+changed 28"))
        await #expect(throws: GitError.self) {
            try await fixture.repository.applyHunk(path: "file.txt", staged: false, hunkID: 1, expectedDiff: diff)
        }
        try await fixture.repository.applyHunk(path: "file.txt", staged: true, hunkID: 0, expectedDiff: staged)
        #expect(try await fixture.repository.status().files.first?.isStaged == false)
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("file.txt"), encoding: .utf8) == changed)
    }
}

struct CoreFixture: Sendable {
    let root: URL
    let url: URL
    let runner: GitProcessRunner
    let repository: GitRepository
    static func make() async throws -> CoreFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitFlowCoreTests-\(UUID().uuidString)")
        let url = root.appendingPathComponent("repository")
        let repository = try await GitRepository.initialize(at: url)
        let hooks = url.appendingPathComponent(".git/gitflow-test-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        _ = try await repository.perform(["config", "core.hooksPath", hooks.path])
        _ = try await repository.perform(["config", "user.name", "GitFlow Test"])
        _ = try await repository.perform(["config", "user.email", "test@example.invalid"])
        _ = try await repository.perform(["config", "commit.gpgsign", "false"])
        return CoreFixture(root: root, url: url, runner: GitProcessRunner(), repository: repository)
    }
    func write(_ path: String, _ content: String) throws { try Data(content.utf8).write(to: url.appendingPathComponent(path)) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
