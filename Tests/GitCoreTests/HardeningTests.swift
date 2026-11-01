import Foundation
import Testing
@testable import GitCore

@Test func multipleConflictRegionsAndSpanningManualEdits() async throws {
    let original = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let fixture = try await ConflictFixture.make(base: original)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let current = original.replacingOccurrences(of: "line 2\n", with: "current two\n").replacingOccurrences(of: "line 23\n", with: "current 23\n")
    let incoming = original.replacingOccurrences(of: "line 2\n", with: "incoming two\n").replacingOccurrences(of: "line 23\n", with: "incoming 23\n")
    try await fixture.diverge(current: current, incoming: incoming)
    _ = try await fixture.repository.integrate(.merge, revision: "incoming")
    let service = ConflictService(repository: fixture.repository)
    let snapshot = try await service.load(path: fixture.path)
    var document = try #require(snapshot.document)
    #expect(document.regions.count == 2)
    document.choose(.incoming, region: 0)
    document.choose(.current, region: 1)
    #expect(document.remaining == 0)
    #expect(document.text.contains("incoming two\n"))
    #expect(document.text.contains("current 23\n"))
    let region = document.regions[0]
    document.edit(range: NSRange(location: 0, length: NSMaxRange(region.range)), replacement: "manual introduction and region\n")
    let preserved = document.text
    document.choose(.current, region: 0)
    #expect(document.text == preserved)
    #expect(!document.regions[0].supportsChoices)
}

@Test func addAddWithoutBaseAndExternalIndexChange() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("seed", "base")
    try await fixture.repository.stage(paths: ["seed"])
    try await fixture.repository.commit(message: "base")
    try await fixture.repository.createBranch(name: "incoming")
    try await fixture.repository.switchBranch("incoming")
    try fixture.write("added", "incoming\n")
    try await fixture.repository.stage(paths: ["added"])
    try await fixture.repository.commit(message: "incoming")
    try await fixture.repository.switchBranch("main")
    try fixture.write("added", "current\n")
    try await fixture.repository.stage(paths: ["added"])
    try await fixture.repository.commit(message: "current")
    _ = try await fixture.repository.integrate(.merge, revision: "incoming")
    let service = ConflictService(repository: fixture.repository)
    let snapshot = try await service.load(path: "added")
    #expect(snapshot.base == nil)
    #expect(snapshot.file.category == "Both added")
    try await fixture.repository.stage(paths: ["added"])
    await #expect(throws: ConflictError.self) { try await service.resolve(snapshot: snapshot, resolution: .incoming) }
}

@Test func revertConflictCanContinueAndAbort() async throws {
    let fixture = try await ConflictFixture.make(base: "zero\n")
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try fixture.write("one\n")
    _ = try await fixture.git(["commit", "-am", "one"])
    let target = try await fixture.git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    try fixture.write("two\n")
    _ = try await fixture.git(["commit", "-am", "two"])
    let original = try await fixture.git(["rev-parse", "HEAD"]).text
    _ = try await fixture.repository.integrate(.revert, revision: target)
    let service = ConflictService(repository: fixture.repository)
    #expect(try await service.overview().operation == .revert)
    try await service.abortOperation()
    #expect(try await fixture.git(["rev-parse", "HEAD"]).text == original)
    _ = try await fixture.repository.integrate(.revert, revision: target)
    let snapshot = try await service.load(path: fixture.path)
    try await service.resolve(snapshot: snapshot, resolution: .incoming)
    try await service.continueOperation()
    #expect(try await service.overview().operation == .none)
    #expect(try await fixture.git(["show", "HEAD:" + fixture.path]).text == "zero\n")
}

@Test func transactionsSerializeAcrossRepositoryInstances() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let second = try await GitRepository.open(fixture.url)
    async let first: Void = fixture.repository.transaction { _, url in
        try Data("first".utf8).write(to: url.appendingPathComponent("marker"))
        try await Task.sleep(for: .milliseconds(40))
        #expect(try String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8) == "first")
    }
    try await Task.sleep(for: .milliseconds(10))
    async let other: Void = second.transaction { _, url in try Data("second".utf8).write(to: url.appendingPathComponent("marker")) }
    _ = try await (first, other)
    #expect(try String(contentsOf: fixture.url.appendingPathComponent("marker"), encoding: .utf8) == "second")
}

@Test func timeoutCoversPipesHeldByDescendants() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gitflow-timeout-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fixture")
    try Data("#!/bin/sh\n/bin/sleep 10 &\nexit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let started = ContinuousClock.now
    await #expect(throws: GitError.self) { try await GitProcessRunner(executable: script).run([], timeout: 0.05) }
    // Leave scheduler headroom on shared CI hosts while remaining well below
    // the descendant's ten-second lifetime.
    #expect(started.duration(to: .now) < .seconds(5))
}

@Test func staleDiscardIsRejected() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("file", "base")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    try fixture.write("file", "first edit")
    let diff = try await fixture.repository.diff(path: "file")
    try fixture.write("file", "new external edit")
    await #expect(throws: GitError.self) { try await fixture.repository.discardUnstaged(path: "file", expectedDiff: diff) }
    #expect(try String(contentsOf: fixture.url.appendingPathComponent("file"), encoding: .utf8) == "new external edit")
}

@Test func typedRemotePublishPushPullAndTag() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let remote = fixture.root.appendingPathComponent("remote.git")
    _ = try await fixture.runner.run(["init", "--bare", "--initial-branch=main", remote.path])
    try fixture.write("file", "one\n")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "one")
    try await fixture.repository.addRemote(name: "origin", url: remote.path)
    try await fixture.repository.publishBranch(remote: "origin", branch: "main")
    let clone = try await GitRepository.clone(remote: remote.path, to: fixture.root.appendingPathComponent("clone"))
    try fixture.write("file", "two\n")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "two")
    try await fixture.repository.pushCurrentBranch()
    let result = try await clone.pull()
    guard case .completed = result else { Issue.record("Expected successful fast-forward pull"); return }
    #expect(try await clone.history().first?.subject == "two")
    try await fixture.repository.createTag("v1.0", message: "Release")
    #expect(try await fixture.repository.tags().first?.subject == "Release")
    #expect(try await fixture.repository.compare("HEAD~1", to: "HEAD").contains("+two"))
}

@Test func stashReferencesAreValidatedBeforeDropping() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("file", "base")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    try fixture.write("file", "first stash")
    _ = try await fixture.repository.perform(["stash", "push", "-m", "first"])
    let old = try #require(try await fixture.repository.stashes().first)
    try fixture.write("file", "second stash")
    _ = try await fixture.repository.perform(["stash", "push", "-m", "second"])
    await #expect(throws: GitError.self) { try await fixture.repository.dropStash(old) }
    #expect(try await fixture.repository.stashes().count == 2)
    let latest = try #require(try await fixture.repository.stashes().first)
    _ = try await fixture.repository.applyStash(latest, pop: true)
    #expect(try String(contentsOf: fixture.url.appendingPathComponent("file"), encoding: .utf8) == "second stash")
    #expect(try await fixture.repository.stashes().count == 1)
}
