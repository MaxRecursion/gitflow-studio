import Foundation
import Darwin
import Testing
@testable import GitCore

@Test func repositoryIdentityAndCoauthorCommit() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let previous = try await fixture.repository.identity()
    let identity = GitIdentity(name: "Local Contributor", email: "local@example.invalid")
    try await fixture.repository.setIdentity(identity, expected: previous)
    #expect(try await fixture.repository.identity() == identity)
    try fixture.write("file", "content")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "With collaborator", coauthors: [GitIdentity(name: "Second Author", email: "second@example.invalid")])
    let message = try await fixture.repository.run(["log", "-1", "--format=%B"]).text
    #expect(message.contains("Co-authored-by: Second Author <second@example.invalid>"))
    #expect(try await fixture.repository.history().first?.author == "Local Contributor")
    await #expect(throws: GitError.self) { try await fixture.repository.setIdentity(previous, expected: previous) }
}

@Test func gitignoreProtectsExternalEditsAndSymlinks() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let initial = try await fixture.repository.readIgnore()
    try await fixture.repository.saveIgnore("*.cache\n", expected: initial)
    try fixture.write("ignored.cache", "cache")
    #expect(try await fixture.repository.status().files.contains(where: { $0.path == "ignored.cache" }) == false)
    let snapshot = try await fixture.repository.readIgnore()
    try fixture.write(".gitignore", "user-edit\n")
    await #expect(throws: GitError.self) { try await fixture.repository.saveIgnore("replacement\n", expected: snapshot) }
    #expect(try String(contentsOf: fixture.url.appendingPathComponent(".gitignore"), encoding: .utf8) == "user-edit\n")
    try FileManager.default.removeItem(at: fixture.url.appendingPathComponent(".gitignore"))
    let outside = fixture.root.appendingPathComponent("outside")
    try Data("keep".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(atPath: fixture.url.appendingPathComponent(".gitignore").path, withDestinationPath: outside.path)
    await #expect(throws: GitError.self) { try await fixture.repository.readIgnore() }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
}

@Test func gitignoreRejectsFIFOsWithoutWaitingForAWriter() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let path = fixture.url.appendingPathComponent(".gitignore").path
    try #require(mkfifo(path, 0o600) == 0)
    let start = ContinuousClock.now
    await #expect(throws: GitError.self) { try await fixture.repository.readIgnore() }
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test func gitignoreReadLimitAcceptsBoundaryAndRejectsOversizedFiles() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let path = fixture.url.appendingPathComponent(".gitignore")
    try Data(repeating: 35, count: 1_048_576).write(to: path)
    #expect(try await fixture.repository.readIgnore().data?.count == 1_048_576)
    try Data(repeating: 35, count: 1_048_577).write(to: path)
    await #expect(throws: GitError.self) { try await fixture.repository.readIgnore() }
}

@Test func worktreeCreationOpeningAndSafeRemoval() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("file", "base")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    let destination = fixture.root.appendingPathComponent("linked café")
    try await fixture.repository.addWorktree(at: destination, branch: "parallel")
    let worktrees = try await fixture.repository.worktrees()
    #expect(worktrees.count == 2)
    let linked = try #require(worktrees.first(where: { !$0.isMain }))
    let other = try await GitRepository.open(destination)
    #expect(try await other.status().branch == "parallel")
    try Data("uncommitted".utf8).write(to: destination.appendingPathComponent("file"))
    await #expect(throws: GitError.self) { try await fixture.repository.removeWorktree(linked) }
    _ = try await other.perform(["restore", "--", "file"])
    try await fixture.repository.removeWorktree(linked)
    #expect(try await fixture.repository.worktrees().count == 1)
}

@Test func undoLatestPreservesWorkAndRejectsStaleHead() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("file", "base")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    try fixture.write("file", "second")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "second")
    let head = try #require(try await fixture.repository.status().head)
    try fixture.write("file", "uncommitted third")
    let message = try await fixture.repository.undoLatestCommit(expectedHead: head)
    #expect(message == "second")
    #expect(try String(contentsOf: fixture.url.appendingPathComponent("file"), encoding: .utf8) == "uncommitted third")
    #expect(try await fixture.repository.run(["show", ":file"]).text == "second")
    #expect(try await fixture.repository.history().first?.subject == "base")
    await #expect(throws: GitError.self) { try await fixture.repository.undoLatestCommit(expectedHead: head) }
}

@Test func configuredOptionLikePullRemoteIsRejectedBeforeExecution() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    _ = try await fixture.repository.perform(["config", "branch.main.remote", "--upload-pack=untrusted"])
    do {
        _ = try await fixture.repository.pull()
        Issue.record("Expected remote validation failure")
    } catch let error as GitError {
        guard case .invalidInput = error else { Issue.record("Expected preflight input validation, got \(error)"); return }
    }
}

@Test func cancelledMutationLeavesQueuePromptly() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let signal = AsyncStream<Void>.makeStream()
    let first = Task {
        try await fixture.repository.transaction { _, _ in
            signal.continuation.yield(())
            try await Task.sleep(for: .milliseconds(600))
        }
    }
    for await _ in signal.stream { break }
    let queued = Task { try await fixture.repository.perform(["status"]) }
    try await Task.sleep(for: .milliseconds(30))
    let start = ContinuousClock.now
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(start.duration(to: .now) < .milliseconds(400))
    _ = try await first.value
}

@Test func linkedWorktreesAndSymlinkAliasesShareMutationGate() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("file", "base")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    let linkedURL = fixture.root.appendingPathComponent("linked")
    try await fixture.repository.addWorktree(at: linkedURL, branch: "linked")
    let aliasURL = fixture.root.appendingPathComponent("linked-alias")
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: linkedURL)
    let linked = try await GitRepository.open(aliasURL)
    #expect(linked.url == linkedURL.resolvingSymlinksInPath())
    let marker = fixture.root.appendingPathComponent("shared-transaction-marker")
    let signal = AsyncStream<Void>.makeStream()
    let first = Task {
        try await fixture.repository.transaction { _, _ in
            try Data("first".utf8).write(to: marker)
            signal.continuation.yield(())
            try await Task.sleep(for: .milliseconds(200))
            #expect(try String(contentsOf: marker, encoding: .utf8) == "first")
        }
    }
    for await _ in signal.stream { break }
    try await linked.transaction { _, _ in try Data("second".utf8).write(to: marker) }
    try await first.value
    #expect(try String(contentsOf: marker, encoding: .utf8) == "second")
}

@Test func separateRepositoriesDoNotShareMutationGate() async throws {
    let firstFixture = try await CoreFixture.make()
    defer { firstFixture.remove() }
    let secondFixture = try await CoreFixture.make()
    defer { secondFixture.remove() }
    let marker = firstFixture.root.appendingPathComponent("independent-gate-marker")
    let signal = AsyncStream<Void>.makeStream()
    let first = Task {
        try await firstFixture.repository.transaction { _, _ in
            signal.continuation.yield(())
            try await Task.sleep(for: .seconds(1))
            try Data("finished".utf8).write(to: marker)
        }
    }
    for await _ in signal.stream { break }
    try await secondFixture.repository.transaction { _, _ in
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
    try await first.value
}

@Test func existingBranchWorktreeMovesWithoutLosingWorkingFiles() async throws {
    let fixture = try await worktreeFixture()
    defer { fixture.remove() }
    try await fixture.repository.createBranch(name: "existing")
    let original = fixture.root.appendingPathComponent("existing checkout")
    try await fixture.repository.addExistingBranchWorktree(at: original, branch: "existing")
    let tree = try #require(try await fixture.repository.worktrees().first { !$0.isMain })
    #expect(tree.branch == "refs/heads/existing")
    try Data("uncommitted content\n".utf8).write(to: original.appendingPathComponent("file"))
    try Data("untracked content\n".utf8).write(to: original.appendingPathComponent("untracked"))
    let moved = fixture.root.appendingPathComponent("moved café checkout")
    try await fixture.repository.moveWorktree(tree, to: moved)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(try String(contentsOf: moved.appendingPathComponent("file"), encoding: .utf8) == "uncommitted content\n")
    #expect(try String(contentsOf: moved.appendingPathComponent("untracked"), encoding: .utf8) == "untracked content\n")
    let opened = try await GitRepository.open(moved)
    #expect(try await opened.status().branch == "existing")
    #expect(try await fixture.repository.worktrees().contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath() })
    await #expect(throws: GitError.self) { try await fixture.repository.removeWorktree(tree) }
    await #expect(throws: GitError.self) { try await fixture.repository.addExistingBranchWorktree(at: original, branch: "existing") }
    await #expect(throws: GitError.self) { try await fixture.repository.addExistingBranchWorktree(at: original, branch: "missing") }
}

@Test func worktreeLocksProtectRemovalAndMoveAndRejectStaleSelections() async throws {
    let fixture = try await worktreeFixture()
    defer { fixture.remove() }
    let location = fixture.root.appendingPathComponent("linked")
    try await fixture.repository.addWorktree(at: location, branch: "linked")
    let original = try #require(try await fixture.repository.worktrees().first { !$0.isMain })
    try await fixture.repository.lockWorktree(original, reason: "Portable drive café")
    let locked = try #require(try await fixture.repository.worktrees().first { !$0.isMain })
    #expect(locked.isLocked)
    #expect(locked.lockReason == "Portable drive café")
    await #expect(throws: GitError.self) { try await fixture.repository.removeWorktree(locked) }
    await #expect(throws: GitError.self) { try await fixture.repository.moveWorktree(locked, to: fixture.root.appendingPathComponent("moved")) }
    await #expect(throws: GitError.self) { try await fixture.repository.removeWorktree(original) }
    try await fixture.repository.unlockWorktree(locked)
    let unlocked = try #require(try await fixture.repository.worktrees().first { !$0.isMain })
    #expect(!unlocked.isLocked)
    try await fixture.repository.removeWorktree(unlocked)
    #expect(try await fixture.repository.worktrees().count == 1)
}

@Test func mainAndActiveWorktreesAndExistingMoveDestinationsAreProtected() async throws {
    let fixture = try await worktreeFixture()
    defer { fixture.remove() }
    let location = fixture.root.appendingPathComponent("linked")
    try await fixture.repository.addWorktree(at: location, branch: "linked")
    let trees = try await fixture.repository.worktrees()
    let main = try #require(trees.first { $0.isMain })
    let linked = try #require(trees.first { !$0.isMain })
    let other = try await GitRepository.open(location)
    let destination = fixture.root.appendingPathComponent("moved")
    await #expect(throws: GitError.self) { try await fixture.repository.moveWorktree(main, to: destination) }
    await #expect(throws: GitError.self) { try await fixture.repository.removeWorktree(main) }
    await #expect(throws: GitError.self) { try await other.moveWorktree(linked, to: destination) }
    await #expect(throws: GitError.self) { try await other.removeWorktree(linked) }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    await #expect(throws: GitError.self) { try await fixture.repository.moveWorktree(linked, to: destination) }
    #expect(FileManager.default.fileExists(atPath: location.appendingPathComponent("file").path))
}

@Test func pruneRequiresUnchangedPreviewAndPreservesLockedMissingWorktrees() async throws {
    let fixture = try await worktreeFixture()
    defer { fixture.remove() }
    let missingURL = fixture.root.appendingPathComponent("missing")
    let protectedURL = fixture.root.appendingPathComponent("protected")
    try await fixture.repository.addWorktree(at: missingURL, branch: "missing")
    try await fixture.repository.addWorktree(at: protectedURL, branch: "protected")
    let trees = try await fixture.repository.worktrees()
    let protected = try #require(trees.first { $0.branch == "refs/heads/protected" })
    try await fixture.repository.lockWorktree(protected, reason: "Disconnected drive")
    try FileManager.default.removeItem(at: missingURL)
    try FileManager.default.removeItem(at: protectedURL)
    let preview = try await fixture.repository.previewWorktreePrune()
    #expect(preview.hasChanges)
    #expect(preview.worktrees.count == 1)
    let missing = try #require(preview.worktrees.first)
    #expect(missing.branch == "refs/heads/missing")
    try await fixture.repository.lockWorktree(missing, reason: "Changed after preview")
    await #expect(throws: GitError.self) { try await fixture.repository.pruneWorktrees(expected: preview) }
    let lockedMissing = try #require(try await fixture.repository.worktrees().first { $0.branch == "refs/heads/missing" })
    try await fixture.repository.unlockWorktree(lockedMissing)
    let fresh = try await fixture.repository.previewWorktreePrune()
    try await fixture.repository.pruneWorktrees(expected: fresh)
    let remaining = try await fixture.repository.worktrees()
    #expect(remaining.count == 2)
    #expect(remaining.contains { $0.branch == "refs/heads/protected" && $0.isLocked })
    #expect(try await fixture.repository.branches().contains { $0.name == "missing" })
    #expect(try await fixture.repository.previewWorktreePrune().hasChanges == false)
}

private func worktreeFixture() async throws -> CoreFixture {
    let fixture = try await CoreFixture.make()
    try fixture.write("file", "base\n")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    return fixture
}
