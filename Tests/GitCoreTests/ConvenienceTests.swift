import Foundation
import Testing
@testable import GitCore

struct ConvenienceTests {
    private func committed() async throws -> CoreFixture {
        let f = try await CoreFixture.make()
        try f.write("file", "one\n"); try await f.repository.stage(paths: ["file"]); try await f.repository.commit(message: "one")
        return f
    }
    @Test func rootUndoPreservesIndexWorkingFilesAndRestoresMessage() async throws {
        let f = try await committed(); defer { f.remove() }
        let head = try #require(try await f.repository.status().head)
        try f.write("file", "staged\n"); try await f.repository.stage(paths: ["file"])
        try f.write("file", "working\n")
        let index = try await f.repository.run(["ls-files", "--stage", "-z"]).stdout
        #expect(try await f.repository.undoLatestCommit(expectedHead: head) == "one")
        #expect(try await f.repository.status().isUnborn)
        #expect(try await f.repository.run(["ls-files", "--stage", "-z"]).stdout == index)
        #expect(try String(contentsOf: f.url.appendingPathComponent("file"), encoding: .utf8) == "working\n")
    }
    @Test func shallowBoundaryIsNeverMistakenForRootCommit() async throws {
        let f = try await committed(); defer { f.remove() }
        try f.write("file", "two\n"); try await f.repository.stage(paths: ["file"]); try await f.repository.commit(message: "two")
        let destination = f.root.appendingPathComponent("shallow")
        _ = try await f.runner.run(["clone", "--depth=1", "--", f.url.absoluteString, destination.path])
        let shallow = try await GitRepository.open(destination)
        let head = try #require(try await shallow.status().head)
        await #expect(throws: GitError.self) { try await shallow.undoLatestCommit(expectedHead: head) }
        #expect(try await shallow.status().head == head)
    }
    @Test func detachedCheckoutAndSafeResetValidateHeadAndKeepWork() async throws {
        let f = try await committed(); defer { f.remove() }
        let first = try #require(try await f.repository.status().head)
        try f.write("file", "two\n"); try await f.repository.stage(paths: ["file"]); try await f.repository.commit(message: "two")
        let second = try #require(try await f.repository.status().head)
        await #expect(throws: GitError.self) { try await f.repository.checkoutDetached(first, expectedHead: first) }
        try await f.repository.checkoutDetached(first, expectedHead: second)
        #expect(try await f.repository.status().branch == "(detached)")
        try await f.repository.switchBranch("main")
        try f.write("file", "pending\n"); try await f.repository.stage(paths: ["file"])
        let index = try await f.repository.run(["show", ":file"]).stdout
        await #expect(throws: GitError.self) { try await f.repository.checkoutDetached(first, expectedHead: second) }
        try await f.repository.resetHistory(to: first, mode: .soft, expectedHead: second)
        #expect(try await f.repository.run(["show", ":file"]).stdout == index)
        #expect(try String(contentsOf: f.url.appendingPathComponent("file"), encoding: .utf8) == "pending\n")
        try await f.repository.resetHistory(to: first, mode: .mixed, expectedHead: first)
        #expect(try await f.repository.run(["show", ":file"]).text == "one\n")
        #expect(try String(contentsOf: f.url.appendingPathComponent("file"), encoding: .utf8) == "pending\n")
    }
    @Test func literalIgnoreDoesNotMatchOtherWildcardNames() async throws {
        let f = try await committed(); defer { f.remove() }
        try f.write("a[1] #?.tmp", "ignore"); try f.write("a1 x.tmp", "keep")
        try await f.repository.ignoreUntrackedPath("a[1] #?.tmp")
        let files = try await f.repository.status().files.map(\.path)
        #expect(!files.contains("a[1] #?.tmp")); #expect(files.contains("a1 x.tmp"))
        await #expect(throws: GitError.self) { try await f.repository.ignoreUntrackedPath("file") }
    }
    @Test func remoteWorktreeTracksAndTagPushRefusesStaleTag() async throws {
        let f = try await committed(); defer { f.remove() }
        let bare = f.root.appendingPathComponent("remote.git")
        _ = try await f.runner.run(["init", "--bare", "--", bare.path])
        try await f.repository.addRemote(name: "origin", url: bare.path)
        try await f.repository.publishBranch(remote: "origin", branch: "main")
        _ = try await f.repository.perform(["fetch", "origin"])
        let remote = try #require(try await f.repository.branches().first { $0.name == "origin/main" })
        let dest = f.root.appendingPathComponent("tracking")
        try await f.repository.addRemoteBranchWorktree(at: dest, localBranch: "tracking", remoteBranch: remote)
        let linked = try await GitRepository.open(dest)
        #expect(try await linked.status().upstream == "origin/main")
        try await f.repository.createTag("v1", message: "release")
        let tag = try #require(try await f.repository.tags().first)
        try await f.repository.pushTag(tag, remote: "origin")
        #expect(try await f.runner.run(["--git-dir", bare.path, "rev-parse", "refs/tags/v1"]).text.trimmingCharacters(in: .newlines) == tag.sha)
        _ = try await f.repository.perform(["tag", "-d", "v1"])
        try await f.repository.createTag("v1", message: "changed")
        await #expect(throws: GitError.self) { try await f.repository.pushTag(tag, remote: "origin") }
        let head = try #require(try await f.repository.status().head)
        await #expect(throws: GitError.self) { try await f.repository.resetHistory(to: head, mode: .mixed, expectedHead: head) }
    }
}
