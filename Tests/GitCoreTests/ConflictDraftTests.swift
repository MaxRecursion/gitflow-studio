import Foundation
import Testing
@testable import GitCore

struct ConflictDraftTests {
    private static func mergedFixture() async throws -> (CoreFixture, ConflictSnapshot) {
        let fixture = try await CoreFixture.make()
        do {
            try fixture.write("conflict.txt", "header\ntimeout=10\nfooter\n")
            try await fixture.repository.stage(paths: ["conflict.txt"])
            try await fixture.repository.commit(message: "base")
            _ = try await fixture.repository.perform(["switch", "-c", "incoming"])
            try fixture.write("conflict.txt", "header\ntimeout=60\nfooter\n")
            try await fixture.repository.stage(paths: ["conflict.txt"])
            try await fixture.repository.commit(message: "incoming")
            _ = try await fixture.repository.perform(["switch", "main"])
            try fixture.write("conflict.txt", "header\ntimeout=30\nfooter\n")
            try await fixture.repository.stage(paths: ["conflict.txt"])
            try await fixture.repository.commit(message: "current")
            _ = try await fixture.runner.run(["merge", "incoming"], in: fixture.url, allowedExitCodes: [1])
            return (fixture, try await ConflictService(repository: fixture.repository).load(path: "conflict.txt"))
        } catch { fixture.remove(); throw error }
    }

    @Test func exactSnapshotRecoversTextDecisionsAndPrivatePermissions() async throws {
        let (fixture, snapshot) = try await Self.mergedFixture()
        defer { fixture.remove() }
        let context = try await ConflictDraftContext.capture(repository: fixture.repository, snapshot: snapshot)
        var document = try #require(snapshot.document)
        document.choose(.incoming, region: 0)
        document.edit(range: NSRange(location: 0, length: 6), replacement: "reviewed")
        let directory = fixture.root.appendingPathComponent("drafts")
        let store = ConflictDraftStore(directory: directory)
        let indexBefore = try await fixture.repository.run(["ls-files", "--stage", "-z"]).stdout
        let descriptor = try await store.save(document: document, context: context)
        let restartedStore = ConflictDraftStore(directory: directory)
        let recovered = try #require(try await restartedStore.load(context: context))
        #expect(recovered.matches)
        #expect(recovered.draft.document.text == document.text)
        #expect(recovered.draft.document.regions.first?.choice == .incoming)
        #expect(recovered.draft.document.regions.first?.range == document.regions.first?.range)
        #expect(recovered.draft.document.remaining == 0)
        #expect(try await fixture.repository.run(["ls-files", "--stage", "-z"]).stdout == indexBefore)
        #expect(try Data(contentsOf: fixture.url.appendingPathComponent("conflict.txt")) == snapshot.worktree)
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(descriptor.id).path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        #expect(fileMode == 0o600)
    }

    @Test func externalWorktreeAndOperationChangesKeepStaleDraftWithoutApplyingIt() async throws {
        let (fixture, snapshot) = try await Self.mergedFixture()
        defer { fixture.remove() }
        let service = ConflictService(repository: fixture.repository)
        let context = try await ConflictDraftContext.capture(repository: fixture.repository, snapshot: snapshot)
        let store = ConflictDraftStore(directory: fixture.root.appendingPathComponent("drafts"))
        let document = MergeDocument(text: "my carefully edited resolution\n")
        let descriptor = try await store.save(document: document, context: context)
        try fixture.write("conflict.txt", "external edit\n")
        let changed = try await service.load(path: "conflict.txt")
        let changedContext = try await ConflictDraftContext.capture(repository: fixture.repository, snapshot: changed)
        #expect(changedContext != context)
        let stale = try #require(try await store.load(context: changedContext))
        #expect(!stale.matches)
        #expect(stale.draft.document.text == document.text)
        await #expect(throws: ConflictDraftError.self) { try await store.save(document: MergeDocument(text: "new"), context: changedContext) }
        try await store.remove(context: changedContext)
        #expect(try await store.read(descriptor).document.text == document.text)
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("conflict.txt"), encoding: .utf8) == "external edit\n")
        _ = try await fixture.repository.perform(["update-ref", "ORIG_HEAD", "incoming"])
        let otherOperation = try await ConflictDraftContext.capture(repository: fixture.repository, snapshot: snapshot)
        #expect(otherOperation != context)
        #expect(try await store.load(context: otherOperation)?.matches == false)
        try await service.abortOperation()
        #expect(try await store.list(repository: fixture.url).count == 1)
        try await store.remove(descriptor)
        #expect(try await store.list(repository: fixture.url).isEmpty)
    }

    @Test func sizeAndCountLimitsNeverDeleteExistingRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitFlowDraftLimit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ConflictDraftContext(repositoryPath: root.path, path: "file", fingerprint: "first")
        let store = ConflictDraftStore(directory: root.appendingPathComponent("drafts"), maximumDraftBytes: 1024, maximumTotalBytes: 2048, maximumDraftCount: 1)
        let descriptor = try await store.save(document: MergeDocument(text: "keep"), context: context)
        await #expect(throws: ConflictDraftError.self) { try await store.save(document: MergeDocument(text: String(repeating: "x", count: 2048)), context: context) }
        #expect(try await store.read(descriptor).document.text == "keep")
        let another = ConflictDraftContext(repositoryPath: root.path, path: "another", fingerprint: "second")
        await #expect(throws: ConflictDraftError.self) { try await store.save(document: MergeDocument(text: "another"), context: another) }
        #expect(try await store.read(descriptor).document.text == "keep")
    }

    @Test func corruptAndInvalidRangeDraftsRemainOnDiskForExplicitDiscard() async throws {
        let (fixture, snapshot) = try await Self.mergedFixture()
        defer { fixture.remove() }
        let context = try await ConflictDraftContext.capture(repository: fixture.repository, snapshot: snapshot)
        let directory = fixture.root.appendingPathComponent("drafts")
        let store = ConflictDraftStore(directory: directory)
        let descriptor = try await store.save(document: try #require(snapshot.document), context: context)
        let file = directory.appendingPathComponent(descriptor.id)
        let original = try Data(contentsOf: file)
        try Data("not JSON".utf8).write(to: file)
        await #expect(throws: ConflictDraftError.self) { try await store.load(context: context) }
        #expect(try await store.list(repository: fixture.url).first?.readable == false)
        #expect(try Data(contentsOf: file) == Data("not JSON".utf8))
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var regions = try #require(json["regions"] as? [[String: Any]])
        regions[0]["length"] = Int.max
        json["regions"] = regions
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        await #expect(throws: ConflictDraftError.self) { try await store.load(context: context) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await store.remove(descriptor)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func storedSymlinkIsRejectedWithoutReadingItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitFlowDraftLink-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ConflictDraftContext(repositoryPath: root.path, path: "file", fingerprint: "first")
        let directory = root.appendingPathComponent("drafts")
        let store = ConflictDraftStore(directory: directory)
        let descriptor = try await store.save(document: MergeDocument(text: "keep"), context: context)
        let file = directory.appendingPathComponent(descriptor.id)
        let target = root.appendingPathComponent("outside")
        try Data("private content".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: ConflictDraftError.self) { try await store.load(context: context) }
        #expect(try Data(contentsOf: target) == Data("private content".utf8))
    }
}
