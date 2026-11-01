import Foundation
import Testing
@testable import GitCore

struct ConflictFixture: Sendable {
    let directory: URL
    let repository: GitRepository
    let runner = GitProcessRunner()
    let path: String
    func git(_ args: [String], codes: Set<Int32> = [0]) async throws -> GitOutput { try await runner.run(args, in: directory, allowedExitCodes: codes) }
    func write(_ text: String) throws { try Data(text.utf8).write(to: directory.appendingPathComponent(path)) }
    static func make(path: String = "settings.txt", base: String = "header\ntimeout=10\nfooter\n") async throws -> ConflictFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitflow-conflict-test-" + UUID().uuidString)
        let repository = try await GitRepository.initialize(at: directory)
        let fixture = ConflictFixture(directory: directory, repository: repository, path: path)
        let hooks = directory.appendingPathComponent(".git/gitflow-test-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        _ = try await fixture.git(["config", "core.hooksPath", hooks.path])
        _ = try await fixture.git(["config", "user.name", "GitFlow Test"])
        _ = try await fixture.git(["config", "user.email", "gitflow@example.invalid"])
        _ = try await fixture.git(["config", "commit.gpgsign", "false"])
        _ = try await fixture.git(["config", "core.autocrlf", "false"])
        try fixture.write(base)
        _ = try await fixture.git(["add", "--", path])
        _ = try await fixture.git(["commit", "-m", "base"])
        return fixture
    }
    func diverge(current: String = "header\ntimeout=30\nfooter\n", incoming: String = "header\ntimeout=60\nfooter\n") async throws {
        _ = try await git(["switch", "-c", "incoming"])
        try write(incoming)
        _ = try await git(["commit", "-am", "incoming"])
        _ = try await git(["switch", "main"])
        try write(current)
        _ = try await git(["commit", "-am", "current"])
    }
}

@Test func mergeResolutionStagesCorrectBytesAndContinues() async throws {
    let f = try await ConflictFixture.make(path: "設定 ü\tfile.txt")
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.diverge()
    _ = try await f.git(["merge", "incoming"], codes: [1])
    let service = ConflictService(repository: f.repository)
    let overview = try await service.overview()
    #expect(overview.operation == .merge)
    #expect(overview.files.count == 1)
    let snapshot = try await service.load(path: f.path)
    var document = try #require(snapshot.document)
    #expect(document.regions.count == 1)
    #expect(document.remaining == 1)
    document.choose(.incoming, region: 0)
    // A separate edit after the decision survives staging.
    document.edit(range: NSRange(location: 0, length: 6), replacement: "reviewed")
    #expect(document.remaining == 0)
    try await service.resolve(snapshot: snapshot, resolution: .text(document.text))
    #expect(try await f.git(["ls-files", "-u"]).stdout.isEmpty)
    #expect(try await f.git(["show", ":" + f.path]).text == "reviewed\ntimeout=60\nfooter\n")
    #expect(try await service.overview().operation == .merge)
    try await service.continueOperation()
    #expect(try await service.overview().operation == .none)
    #expect(try await f.git(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " ").count == 3)
}

@Test func rebaseLabelsAndContinueUseRealOperation() async throws {
    let f = try await ConflictFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.diverge()
    _ = try await f.git(["rebase", "incoming"], codes: [1])
    let service = ConflictService(repository: f.repository)
    #expect(try await service.overview().operation == .rebase)
    let snapshot = try await service.load(path: f.path)
    #expect(String(data: snapshot.current ?? Data(), encoding: .utf8)?.contains("60") == true)
    #expect(String(data: snapshot.incoming ?? Data(), encoding: .utf8)?.contains("30") == true)
    try await service.resolve(snapshot: snapshot, resolution: .incoming)
    try await service.continueOperation()
    #expect(try await service.overview().operation == .none)
    #expect(try await f.git(["show", "HEAD:" + f.path]).text.contains("30"))
}

@Test func cherryPickResolvesAndAbortRestoresOriginalHead() async throws {
    let f = try await ConflictFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.diverge()
    let original = try await f.git(["rev-parse", "HEAD"]).text
    _ = try await f.git(["cherry-pick", "incoming"], codes: [1])
    let service = ConflictService(repository: f.repository)
    #expect(try await service.overview().operation == .cherryPick)
    try await service.abortOperation()
    #expect(try await f.git(["rev-parse", "HEAD"]).text == original)
    _ = try await f.git(["cherry-pick", "incoming"], codes: [1])
    let snapshot = try await service.load(path: f.path)
    try await service.resolve(snapshot: snapshot, resolution: .incoming)
    try await service.continueOperation()
    #expect(try await service.overview().operation == .none)
    #expect(try await f.git(["show", "HEAD:" + f.path]).text.contains("60"))
}

@Test func mergeAndRebaseAbortRestoreWorkingTree() async throws {
    for operation in ["merge", "rebase"] {
        let f = try await ConflictFixture.make()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        try await f.diverge()
        let original = try Data(contentsOf: f.directory.appendingPathComponent(f.path))
        _ = try await f.git([operation, "incoming"], codes: [1])
        try await ConflictService(repository: f.repository).abortOperation()
        #expect(try Data(contentsOf: f.directory.appendingPathComponent(f.path)) == original)
        #expect(try await f.git(["ls-files", "-u"]).stdout.isEmpty)
    }
}

@Test func externalEditRejectsStaleResolution() async throws {
    let f = try await ConflictFixture.make()
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.diverge()
    _ = try await f.git(["merge", "incoming"], codes: [1])
    let service = ConflictService(repository: f.repository)
    let snapshot = try await service.load(path: f.path)
    try f.write("External editor work\n")
    await #expect(throws: ConflictError.self) { try await service.resolve(snapshot: snapshot, resolution: .incoming) }
    #expect(try String(contentsOf: f.directory.appendingPathComponent(f.path), encoding: .utf8) == "External editor work\n")
    #expect(try await service.overview().files.count == 1)
}

@Test func binaryAndDeleteModifyUseWholeFileResolution() async throws {
    let f = try await ConflictFixture.make(base: "\0base")
    defer { try? FileManager.default.removeItem(at: f.directory) }
    try await f.diverge(current: "\0current", incoming: "\0incoming")
    _ = try await f.git(["merge", "incoming"], codes: [1])
    let service = ConflictService(repository: f.repository)
    let snapshot = try await service.load(path: f.path)
    #expect(!snapshot.isText)
    try await service.resolve(snapshot: snapshot, resolution: .incoming)
    #expect(try Data(contentsOf: f.directory.appendingPathComponent(f.path)) == Data("\0incoming".utf8))
    try await service.abortOperation()
    _ = try await f.git(["switch", "incoming"])
    _ = try await f.git(["rm", "--", f.path])
    _ = try await f.git(["commit", "-m", "delete"])
    _ = try await f.git(["switch", "main"])
    _ = try await f.git(["merge", "incoming"], codes: [1])
    let deletion = try await service.load(path: f.path)
    #expect(deletion.file.stage(3) == nil)
    try await service.resolve(snapshot: deletion, resolution: .delete)
    #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(f.path).path))
    #expect(try await f.git(["ls-files", "-u"]).stdout.isEmpty)
}

@Test func mergeDecisionsKeepUnrelatedManualEdits() throws {
    let source = "before\n<<<<<<< CURRENT\nours\n||||||| BASE\nbase\n=======\ntheirs\n>>>>>>> INCOMING\nafter\n"
    var document = try MergeDocument.parse(source, currentLabel: "CURRENT", baseLabel: "BASE", incomingLabel: "INCOMING", markerSize: 7)
    document.edit(range: NSRange(location: 0, length: 6), replacement: "a longer introduction")
    document.choose(.incoming, region: 0)
    #expect(document.text == "a longer introduction\ntheirs\nafter\n")
    document.choose(.both, region: 0)
    #expect(document.text == "a longer introduction\nours\ntheirs\nafter\n")
}
