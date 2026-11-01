import Foundation
import Darwin

public enum GitOperation: String, Sendable {
    case merge, rebase, cherryPick = "cherry-pick", revert, none
    public var title: String { self == .none ? "Conflict resolution" : rawValue.capitalized }
    public var currentLabel: String { self == .rebase ? "Rebase destination" : "Current version" }
    public var incomingLabel: String { self == .rebase ? "Commit being replayed" : "Incoming version" }
    public var explanation: String {
        switch self {
        case .rebase: "The left side is the destination with commits already replayed. The right side is the original commit now being replayed."
        case .cherryPick: "The left side is your current branch. The right side is the commit being applied."
        case .revert: "The left side is your current branch. The right side is the version Git is applying to reverse a commit."
        case .merge: "The left side is your current branch. The right side is the branch being merged."
        case .none: "These versions come from Git’s unmerged index. Review them and explicitly stage your resolution."
        }
    }
}

public struct ConflictStage: Sendable, Equatable {
    public let number: Int
    public let mode: String
    public let objectID: String
}

public struct ConflictFile: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let stages: [ConflictStage]
    public func stage(_ number: Int) -> ConflictStage? { stages.first { $0.number == number } }
    public var category: String {
        if stages.contains(where: { $0.mode == "160000" }) { return "Submodule" }
        if stages.contains(where: { $0.mode == "120000" }) { return "Symbolic link" }
        if stage(2) == nil || stage(3) == nil { return "Deleted / changed" }
        if stage(1) == nil { return "Both added" }
        if stage(2)?.mode != stage(3)?.mode { return "Content / file mode" }
        return "Both changed"
    }
}

public struct ConflictOverview: Sendable {
    public let operation: GitOperation
    public let files: [ConflictFile]
    public init(operation: GitOperation, files: [ConflictFile]) { self.operation = operation; self.files = files }
}

public struct ConflictSnapshot: Sendable {
    public let file: ConflictFile
    public let operation: GitOperation
    public let current: Data?
    public let base: Data?
    public let incoming: Data?
    public let worktree: Data?
    public let worktreeMode: Int?
    public let isSymbolicLink: Bool
    public let document: MergeDocument?
    public var isText: Bool { document != nil }
    public var supportsVersionSelection: Bool { !file.stages.contains { $0.mode == "160000" } }
}

public enum ConflictResolution: Sendable {
    case text(String)
    case current
    case incoming
    case delete
}

public enum ConflictError: LocalizedError, Sendable {
    case stale, unsafePath, unsupported, invalidMergeOutput, unresolved, noOperation, tooLarge
    public var errorDescription: String? {
        switch self {
        case .stale: "This file or its Git index stages changed outside the resolver. Reload it before saving; your edits have not been written."
        case .unsafePath: "This path passes through a symbolic link or leaves the repository. Resolve it using Git outside the app."
        case .unsupported: "This conflict requires a specialized Git operation. Open the repository in your editor to resolve it, then refresh."
        case .invalidMergeOutput: "Git returned a merge result that could not be parsed safely."
        case .unresolved: "Git still reports unmerged files. Resolve and stage them before continuing."
        case .noOperation: "There is no supported Git operation to continue or abort."
        case .tooLarge: "This conflict exceeds the 8 MB safe editor limit. Resolve it in an external editor, then stage the file."
        }
    }
}

public struct ConflictService: Sendable {
    public let repository: GitRepository
    public init(repository: GitRepository) { self.repository = repository }

    public func overview() async throws -> ConflictOverview {
        async let files = repository.run(["ls-files", "-u", "-z"])
        let operation = try await Self.operation(runner: repository.runner, url: repository.url)
        return ConflictOverview(operation: operation, files: try Self.parseStages(try await files.stdout))
    }

    public func load(path: String) async throws -> ConflictSnapshot {
        let overview = try await overview()
        guard let file = overview.files.first(where: { $0.path == path }) else { throw ConflictError.stale }
        let target = try Self.safeURL(path: path, root: repository.url)
        let worktree = try Self.readWorktree(target)
        var blobs: [Int: Data] = [:]
        for stage in file.stages where stage.mode != "160000" {
            let output = try await repository.runner.run(["cat-file", "blob", stage.objectID], in: repository.url, maxOutputBytes: 8 * 1024 * 1024)
            blobs[stage.number] = output.stdout
        }
        var document: MergeDocument?
        if file.stage(2)?.mode.hasPrefix("100") == true,
           file.stage(3)?.mode.hasPrefix("100") == true,
           file.stage(2)?.mode == file.stage(3)?.mode,
           let current = blobs[2], let incoming = blobs[3],
           Self.isUTF8Text(current), Self.isUTF8Text(incoming), Self.isUTF8Text(blobs[1] ?? Data()) {
            document = try await Self.makeDocument(current: current, base: blobs[1] ?? Data(), incoming: incoming, runner: repository.runner)
            if let working = worktree.data.flatMap({ String(data: $0, encoding: .utf8) }), working.contains("\r\n"), !working.replacingOccurrences(of: "\r\n", with: "").contains("\n") {
                document?.useCRLF()
            }
        }
        return ConflictSnapshot(file: file, operation: overview.operation, current: blobs[2], base: blobs[1], incoming: blobs[3], worktree: worktree.data, worktreeMode: worktree.mode, isSymbolicLink: worktree.symlink, document: document)
    }

    public func resolve(snapshot: ConflictSnapshot, resolution: ConflictResolution) async throws {
        try await repository.transaction { runner, root in
            guard try await Self.operation(runner: runner, url: root) == snapshot.operation else { throw ConflictError.stale }
            let index = try await runner.run(["ls-files", "-u", "-z", "--", snapshot.file.path], in: root)
            guard try Self.parseStages(index.stdout).first == snapshot.file else { throw ConflictError.stale }
            let target = try Self.safeURL(path: snapshot.file.path, root: root)
            let current = try Self.readWorktree(target)
            guard current.data == snapshot.worktree, current.mode == snapshot.worktreeMode, current.symlink == snapshot.isSymbolicLink else { throw ConflictError.stale }
            guard snapshot.supportsVersionSelection else { throw ConflictError.unsupported }
            let data: Data?, mode: String?
            switch resolution {
            case .text(let text):
                guard snapshot.isText else { throw ConflictError.unsupported }
                data = Data(text.utf8); mode = snapshot.file.stage(2)?.mode
            case .current: data = snapshot.current; mode = snapshot.file.stage(2)?.mode
            case .incoming: data = snapshot.incoming; mode = snapshot.file.stage(3)?.mode
            case .delete: data = nil; mode = nil
            }
            if let data, let mode {
                try Self.write(data: data, mode: mode, target: target)
                _ = try await runner.run(["add", "--", snapshot.file.path], in: root)
            } else {
                _ = try await runner.run(["rm", "-f", "--", snapshot.file.path], in: root)
            }
            let remaining = try await runner.run(["ls-files", "-u", "-z", "--", snapshot.file.path], in: root)
            guard remaining.stdout.isEmpty else { throw ConflictError.unresolved }
        }
    }

    public func continueOperation() async throws {
        try await repository.transaction { runner, root in
            let remaining = try await runner.run(["ls-files", "-u", "-z"], in: root)
            guard remaining.stdout.isEmpty else { throw ConflictError.unresolved }
            let operation = try await Self.operation(runner: runner, url: root)
            guard operation != .none else { throw ConflictError.noOperation }
            _ = try await runner.run([operation.rawValue, "--continue"], in: root)
        }
    }

    public func abortOperation() async throws {
        try await repository.transaction { runner, root in
            let operation = try await Self.operation(runner: runner, url: root)
            guard operation != .none else { throw ConflictError.noOperation }
            _ = try await runner.run([operation.rawValue, "--abort"], in: root)
        }
    }

    public static func parseStages(_ data: Data) throws -> [ConflictFile] {
        var entries: [String: [ConflictStage]] = [:]
        for record in data.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9),
                  let header = String(data: Data(record[..<tab]), encoding: .utf8) else {
                throw GitError.invalidInput("Git returned an incomplete or invalid unmerged-index record.")
            }
            let metadata = header.split(separator: " ")
            guard metadata.count == 3, let number = Int(metadata[2]), (1...3).contains(number) else {
                throw GitError.invalidInput("Git returned an incomplete or invalid unmerged-index record.")
            }
            // Never replace invalid UTF-8 with U+FFFD: it may name a different
            // existing file. Fail before constructing any conflict snapshot.
            guard let path = String(data: Data(record[record.index(after: tab)...]), encoding: .utf8), !path.isEmpty else {
                throw GitError.invalidInput("A conflicted filename is not valid UTF-8. GitFlow Studio cannot safely resolve it. Rename or resolve it using Git or another tool, then refresh.")
            }
            entries[path, default: []].append(ConflictStage(number: number, mode: String(metadata[0]), objectID: String(metadata[1])))
        }
        return entries.map { ConflictFile(path: $0.key, stages: $0.value.sorted { $0.number < $1.number }) }.sorted { $0.path < $1.path }
    }

    static func operation(runner: GitProcessRunner, url: URL) async throws -> GitOperation {
        for (path, operation): (String, GitOperation) in [("rebase-merge", .rebase), ("rebase-apply", .rebase), ("MERGE_HEAD", .merge), ("CHERRY_PICK_HEAD", .cherryPick), ("REVERT_HEAD", .revert)] {
            let output = try await runner.run(["rev-parse", "--git-path", path], in: url)
            var value = try output.strictText(context: "Git operation metadata path")
            if value.utf8.last == 10 { value = String(decoding: value.utf8.dropLast(), as: UTF8.self) }
            let full = value.hasPrefix("/") ? URL(fileURLWithPath: value) : url.appendingPathComponent(value)
            if FileManager.default.fileExists(atPath: full.path) { return operation }
        }
        return .none
    }

    private static func isUTF8Text(_ data: Data) -> Bool { !data.contains(0) && String(data: data, encoding: .utf8) != nil }

    private static func makeDocument(current: Data, base: Data, incoming: Data, runner: GitProcessRunner) async throws -> MergeDocument {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gitflow-merge-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try current.write(to: temporary.appendingPathComponent("current"))
        try base.write(to: temporary.appendingPathComponent("base"))
        try incoming.write(to: temporary.appendingPathComponent("incoming"))
        let token = UUID().uuidString
        let labels = ["CURRENT_" + token, "BASE_" + token, "INCOMING_" + token]
        // Choose a marker wider than any possible matching source line.
        var markerSize = 7
        for data in [current, base, incoming] {
            for line in data.split(separator: 10) {
                let count = line.prefix { [UInt8(60), 61, 62, 124].contains($0) }.count
                markerSize = max(markerSize, count + 1)
            }
        }
        let merged = try await runner.run(["merge-file", "--diff3", "--marker-size=\(markerSize)", "-p", "-L", labels[0], "-L", labels[1], "-L", labels[2], "current", "base", "incoming"], in: temporary, allowedExitCodes: Set((0...127).map(Int32.init)), maxOutputBytes: 24 * 1024 * 1024)
        var document = try MergeDocument.parse(merged.text, currentLabel: labels[0], baseLabel: labels[1], incomingLabel: labels[2], markerSize: markerSize)
        document.restoreTerminalNewlines(current: String(decoding: current, as: UTF8.self), base: String(decoding: base, as: UTF8.self), incoming: String(decoding: incoming, as: UTF8.self))
        return document
    }

    private static func safeURL(path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".git") else { throw ConflictError.unsafePath }
        let target = root.appendingPathComponent(path)
        let parent = target.deletingLastPathComponent()
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalParent == canonicalRoot || canonicalParent.hasPrefix(canonicalRoot + "/") else { throw ConflictError.unsafePath }
        guard parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path else { throw ConflictError.unsafePath }
        return target
    }

    private struct Worktree { let data: Data?; let mode: Int?; let symlink: Bool }
    private static func readWorktree(_ url: URL) throws -> Worktree {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return Worktree(data: nil, mode: nil, symlink: false) }
        let isLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
        let mode = attributes[.posixPermissions] as? Int
        if isLink { return Worktree(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8), mode: mode, symlink: true) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ConflictError.unsupported }
        guard (attributes[.size] as? Int ?? 0) <= 8 * 1024 * 1024 else { throw ConflictError.tooLarge }
        return Worktree(data: try Data(contentsOf: url), mode: mode, symlink: false)
    }

    private static func write(data: Data, mode: String, target: URL) throws {
        let manager = FileManager.default
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".gitflow-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        if mode == "120000" {
            guard let destination = String(data: data, encoding: .utf8), !destination.contains("\0") else { throw ConflictError.unsupported }
            try manager.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
        } else if mode.hasPrefix("100") {
            try data.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: mode == "100755" ? 0o755 : 0o644], ofItemAtPath: temporary.path)
        } else { throw ConflictError.unsupported }
        // POSIX rename atomically replaces a regular file or symlink without following the latter.
        let status = temporary.path.withCString { source in target.path.withCString { destination in Darwin.rename(source, destination) } }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
