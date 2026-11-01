import Foundation
import CryptoKit
import Darwin

public struct ConflictDraftContext: Codable, Equatable, Sendable {
    public let repositoryPath: String
    public let path: String
    public let fingerprint: String

    /// Captured once when a conflict is loaded. No repository contents are stored
    /// in the identity: hashes bind recovery to this exact operation and versions.
    public static func capture(repository: GitRepository, snapshot: ConflictSnapshot) async throws -> Self {
        var digest = SHA256()
        func add(_ label: String, _ data: Data?) {
            digest.update(data: Data((label + ":" + String(data?.count ?? -1) + ":").utf8))
            if let data { digest.update(data: data) }
        }
        let root = repository.url.resolvingSymlinksInPath().standardizedFileURL.path
        add("repository", Data(root.utf8)); add("path", Data(snapshot.file.path.utf8))
        add("operation", Data(snapshot.operation.rawValue.utf8))
        for stage in snapshot.file.stages {
            add("stage", Data("\(stage.number) \(stage.mode) \(stage.objectID)".utf8))
        }
        add("base", snapshot.base); add("current", snapshot.current); add("incoming", snapshot.incoming)
        add("working", snapshot.worktree)
        add("mode", Data("\(snapshot.worktreeMode ?? -1):\(snapshot.isSymbolicLink)".utf8))
        let head = try await repository.run(["rev-parse", "--verify", "HEAD"], allowedExitCodes: [0, 128])
        add("HEAD", head.stdout)
        let metadata: [String]
        switch snapshot.operation {
        case .merge: metadata = ["MERGE_HEAD", "ORIG_HEAD"]
        case .cherryPick: metadata = ["CHERRY_PICK_HEAD"]
        case .revert: metadata = ["REVERT_HEAD"]
        case .rebase: metadata = ["rebase-merge/head-name", "rebase-merge/onto", "rebase-merge/orig-head", "rebase-merge/stopped-sha", "rebase-merge/msgnum", "rebase-apply/head-name", "rebase-apply/onto", "rebase-apply/orig-head", "rebase-apply/original-commit", "rebase-apply/next"]
        case .none: metadata = []
        }
        for name in metadata {
            var path = try await repository.run(["rev-parse", "--git-path", name]).strictText(context: "Git operation metadata path")
            if path.utf8.last == 10 { path = String(decoding: path.utf8.dropLast(), as: UTF8.self) }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repository.url.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? Int ?? 0) <= 65_536 else { throw ConflictDraftError.invalidMetadata }
                add(name, try Data(contentsOf: url))
            } else { add(name, nil) }
        }
        return Self(repositoryPath: root, path: snapshot.file.path, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

public struct ConflictDraftDescriptor: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let savedAt: Date
    public let readable: Bool
}

public struct ConflictDraft: Identifiable, Sendable {
    public var id: String { descriptor.id }
    public let descriptor: ConflictDraftDescriptor
    public let context: ConflictDraftContext
    public let document: MergeDocument
}

public enum ConflictDraftRecovery: Sendable {
    case matching(ConflictDraft), stale(ConflictDraft)
    public var draft: ConflictDraft { switch self { case .matching(let draft), .stale(let draft): draft } }
    public var matches: Bool { if case .matching = self { return true }; return false }
}

public enum ConflictDraftError: LocalizedError, Sendable {
    case tooLarge, quota, corrupt, staleExists, unsafeStorage, invalidMetadata
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This draft exceeds the 16 MB local recovery limit. Keep this window open or export the result to preserve it."
        case .quota: "Local draft storage is full. Review and discard older saved drafts before saving another. Your current edits remain in this window."
        case .corrupt: "This saved draft is unreadable or invalid. It has been retained on disk; review the saved-drafts list before discarding it."
        case .staleExists: "A saved draft belongs to an earlier repository state. Review or discard it before saving a new draft for this file."
        case .unsafeStorage: "The local draft location is not a safe regular folder or file. Draft recovery is unavailable."
        case .invalidMetadata: "Git operation metadata could not be validated for safe draft recovery."
        }
    }
}

/// Local-only recovery. One draft per repository/file prevents unbounded version
/// growth. An older-state draft is never overwritten without explicit removal.
public actor ConflictDraftStore {
    public static let shared = ConflictDraftStore()
    public let directory: URL
    private let maximumDraftBytes: Int
    private let maximumTotalBytes: Int
    private let maximumDraftCount: Int
    public init(directory: URL? = nil, maximumDraftBytes: Int = 16 * 1024 * 1024, maximumTotalBytes: Int = 128 * 1024 * 1024, maximumDraftCount: Int = 128) {
        self.directory = (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitFlow Studio/Conflict Drafts", isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL
        self.maximumDraftBytes = maximumDraftBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumDraftCount = maximumDraftCount
    }

    @discardableResult public func save(document: MergeDocument, context: ConflictDraftContext) throws -> ConflictDraftDescriptor {
        try prepareDirectory()
        let id = Self.identifier(context)
        let destination = directory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try readRecord(id: id).context == context else { throw ConflictDraftError.staleExists }
        }
        let textBytes = document.text.utf8.count
        guard textBytes <= maximumDraftBytes, document.regions.count <= 10_000 else { throw ConflictDraftError.tooLarge }
        let snippetBytes = document.regions.reduce(0) { $0 + $1.current.utf8.count + $1.base.utf8.count + $1.incoming.utf8.count }
        guard snippetBytes <= maximumDraftBytes - textBytes else { throw ConflictDraftError.tooLarge }
        let record = DraftRecord(schema: 1, context: context, savedAt: Date(), text: document.text, regions: document.regions.map(DraftRegion.init))
        _ = try record.document()
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumDraftBytes else { throw ConflictDraftError.tooLarge }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]).filter { Self.validIdentifier($0.lastPathComponent) }
        var otherBytes = 0, otherCount = 0
        for item in items where item.lastPathComponent != id {
            otherBytes += (try item.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            otherCount += 1
        }
        guard otherBytes <= maximumTotalBytes - data.count, otherCount < maximumDraftCount else { throw ConflictDraftError.quota }
        let temporary = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return record.descriptor(id: id)
    }

    public func load(context: ConflictDraftContext) throws -> ConflictDraftRecovery? {
        let id = Self.identifier(context)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(id).path) else { return nil }
        let draft = try read(id: id)
        return draft.context == context ? .matching(draft) : .stale(draft)
    }

    public func list(repository: URL) throws -> [ConflictDraftDescriptor] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try prepareDirectory()
        let prefix = Self.hash(repository.resolvingSymlinksInPath().standardizedFileURL.path) + "-"
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && Self.validIdentifier($0.lastPathComponent) }.map { file in
            if let record = try? readRecord(id: file.lastPathComponent) { return record.descriptor(id: file.lastPathComponent) }
            return ConflictDraftDescriptor(id: file.lastPathComponent, path: "Unreadable saved draft", savedAt: (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast, readable: false)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    public func read(_ descriptor: ConflictDraftDescriptor) throws -> ConflictDraft { try read(id: descriptor.id) }
    public func remove(_ descriptor: ConflictDraftDescriptor) throws {
        guard Self.validIdentifier(descriptor.id) else { throw ConflictDraftError.unsafeStorage }
        try prepareDirectory()
        let url = directory.appendingPathComponent(descriptor.id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    /// Removing a current draft never removes an unrelated stale recovery copy.
    public func remove(context: ConflictDraftContext) throws {
        guard let recovery = try load(context: context), recovery.matches else { return }
        try remove(recovery.draft.descriptor)
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory, directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw ConflictDraftError.unsafeStorage }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func read(id: String) throws -> ConflictDraft {
        let record = try readRecord(id: id)
        return ConflictDraft(descriptor: record.descriptor(id: id), context: record.context, document: try record.document())
    }
    private func readRecord(id: String) throws -> DraftRecord {
        try prepareDirectory()
        guard Self.validIdentifier(id) else { throw ConflictDraftError.unsafeStorage }
        let fd = Darwin.open(directory.appendingPathComponent(id).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConflictDraftError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw ConflictDraftError.unsafeStorage }
        guard attributes.st_size <= maximumDraftBytes else { throw ConflictDraftError.tooLarge }
        let data = try handle.read(upToCount: maximumDraftBytes + 1) ?? Data()
        guard data.count <= maximumDraftBytes else { throw ConflictDraftError.tooLarge }
        guard let record = try? JSONDecoder().decode(DraftRecord.self, from: data), record.schema == 1, Self.identifier(record.context) == id else { throw ConflictDraftError.corrupt }
        _ = try record.document()
        return record
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func identifier(_ context: ConflictDraftContext) -> String { hash(context.repositoryPath) + "-" + hash(context.path) + ".json" }
    private static func validIdentifier(_ value: String) -> Bool {
        value.count == 134 && value.hasSuffix(".json") && value.dropLast(5).enumerated().allSatisfy { $0.offset == 64 ? $0.element == "-" : $0.element.isHexDigit && $0.element.isASCII }
    }
}

private struct DraftRecord: Codable {
    let schema: Int
    let context: ConflictDraftContext
    let savedAt: Date
    let text: String
    let regions: [DraftRegion]
    func descriptor(id: String) -> ConflictDraftDescriptor { ConflictDraftDescriptor(id: id, path: context.path, savedAt: savedAt, readable: true) }
    func document() throws -> MergeDocument {
        guard regions.count <= 10_000 else { throw ConflictDraftError.corrupt }
        let length = text.utf16.count
        var ids = Set<Int>()
        let restored: [MergeRegion] = try regions.map { region in
            guard region.id >= 0, ids.insert(region.id).inserted, region.location >= 0, region.length >= 0,
                  region.location <= length, region.length <= length - region.location,
                  let choice = MergeChoice(rawValue: region.choice) else { throw ConflictDraftError.corrupt }
            return MergeRegion(id: region.id, range: NSRange(location: region.location, length: region.length), current: region.current, base: region.base, incoming: region.incoming, choice: choice, supportsChoices: region.supportsChoices)
        }
        return MergeDocument(text: text, regions: restored)
    }
}
private struct DraftRegion: Codable {
    let id: Int, location: Int, length: Int
    let current: String, base: String, incoming: String, choice: String
    let supportsChoices: Bool
    init(_ region: MergeRegion) {
        id = region.id; location = region.range.location; length = region.range.length
        current = region.current; base = region.base; incoming = region.incoming; choice = region.choice.rawValue; supportsChoices = region.supportsChoices
    }
}
