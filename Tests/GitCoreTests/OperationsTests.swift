import Foundation
import Testing
@testable import GitCore

@Test func typedBranchOperationsProtectUnmergedWork() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    try fixture.write("file", "base\n")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "base")
    try await fixture.repository.createBranch(name: "feature")
    try await fixture.repository.switchBranch("feature")
    try fixture.write("file", "feature\n")
    try await fixture.repository.stage(paths: ["file"])
    try await fixture.repository.commit(message: "feature")
    try await fixture.repository.switchBranch("main")
    await #expect(throws: GitError.self) { try await fixture.repository.deleteBranch("feature") }
    try await fixture.repository.renameBranch("feature", to: "renamed")
    let result = try await fixture.repository.integrate(.merge, revision: "renamed")
    guard case .completed = result else { Issue.record("Expected fast-forward merge"); return }
    try await fixture.repository.deleteBranch("renamed")
    #expect(try await fixture.repository.status().files.isEmpty)
    await #expect(throws: GitError.self) { try await fixture.repository.resolveRevision("--help") }
    await #expect(throws: GitError.self) { try await fixture.repository.createBranch(name: "--force") }
    await #expect(throws: GitError.self) { try await fixture.repository.addRemote(name: "-bad", url: "https://example.invalid") }
}

@Test func operationConflictsAreStructuredAndDirtyChangesAreProtected() async throws {
    let fixture = try await ConflictFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await fixture.diverge()
    try fixture.write("my uncommitted edit\n")
    await #expect(throws: GitError.self) { try await fixture.repository.integrate(.merge, revision: "incoming") }
    #expect(try String(contentsOf: fixture.directory.appendingPathComponent(fixture.path), encoding: .utf8) == "my uncommitted edit\n")
    _ = try await fixture.git(["restore", "--", fixture.path])
    let result = try await fixture.repository.integrate(.merge, revision: "incoming")
    guard case .conflicts = result else { Issue.record("Expected a structured conflict result"); return }
    let service = ConflictService(repository: fixture.repository)
    #expect(try await service.overview().files.count == 1)
    await #expect(throws: GitError.self) { try await fixture.repository.integrate(.rebase, revision: "incoming") }
    try await service.abortOperation()
}

@Test func deletedModifyAndSymlinkResolutionsPreserveTypes() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let path = fixture.url.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "base")
    try await fixture.repository.stage(paths: ["link"])
    try await fixture.repository.commit(message: "base")
    try await fixture.repository.createBranch(name: "incoming")
    try await fixture.repository.switchBranch("incoming")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "incoming")
    try await fixture.repository.stage(paths: ["link"])
    try await fixture.repository.commit(message: "incoming")
    try await fixture.repository.switchBranch("main")
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: "current")
    try await fixture.repository.stage(paths: ["link"])
    try await fixture.repository.commit(message: "current")
    _ = try await fixture.repository.integrate(.merge, revision: "incoming")
    let service = ConflictService(repository: fixture.repository)
    let snapshot = try await service.load(path: "link")
    #expect(snapshot.file.category == "Symbolic link")
    try await service.resolve(snapshot: snapshot, resolution: .incoming)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == "incoming")
    #expect(try await fixture.repository.run(["ls-files", "--stage", "--", "link"]).text.hasPrefix("120000"))
    try await service.continueOperation()
}

@Test func conflictChoicesPreserveCRLFAndNoFinalNewline() async throws {
    for newline in ["", "\r\n"] {
        let fixture = try await ConflictFixture.make(base: "base" + newline)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.diverge(current: "current" + newline, incoming: "incoming" + newline)
        _ = try await fixture.git(["merge", "incoming"], codes: [0, 1])
        let service = ConflictService(repository: fixture.repository)
        let snapshot = try await service.load(path: fixture.path)
        var document = try #require(snapshot.document)
        document.choose(.incoming, region: 0)
        #expect(document.text == "incoming" + newline)
        try await service.resolve(snapshot: snapshot, resolution: .text(document.text))
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent(fixture.path)) == Data(("incoming" + newline).utf8))
    }
}

@Test func hooksAreRespectedAndFailuresLeaveIndexStaged() async throws {
    let fixture = try await CoreFixture.make()
    defer { fixture.remove() }
    let hook = fixture.url.appendingPathComponent(".git/gitflow-test-hooks/pre-commit")
    try Data("#!/bin/sh\nprintf 'test hook rejected commit\\n' >&2\nexit 1\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try fixture.write("file", "content")
    try await fixture.repository.stage(paths: ["file"])
    await #expect(throws: GitError.self) { try await fixture.repository.commit(message: "blocked") }
    #expect(try await fixture.repository.status().files.first?.isStaged == true)
}
