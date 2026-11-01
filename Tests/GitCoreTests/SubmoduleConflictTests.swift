import Foundation
import Testing
@testable import GitCore

struct SubmoduleConflictTests {
    private func fixture() async throws -> (CoreFixture, CoreFixture, URL, String, String) {
        let child = try await CoreFixture.make(), parent = try await CoreFixture.make()
        do {
            try child.write("child.txt", "base\n"); try await child.repository.stage(paths: ["child.txt"]); try await child.repository.commit(message: "base")
            let base = try #require(try await child.repository.status().head)
            try await child.repository.createBranch(name: "incoming"); try await child.repository.switchBranch("incoming")
            try child.write("child.txt", "incoming\n"); try await child.repository.stage(paths: ["child.txt"]); try await child.repository.commit(message: "incoming")
            let incoming = try #require(try await child.repository.status().head)
            try await child.repository.switchBranch("main")
            try child.write("child.txt", "current\n"); try await child.repository.stage(paths: ["child.txt"]); try await child.repository.commit(message: "current")
            let current = try #require(try await child.repository.status().head)
            _ = try await parent.repository.perform(["-c", "protocol.file.allow=always", "-c", "core.hooksPath=/dev/null", "submodule", "add", "--", child.url.path, "module"])
            let module = parent.url.appendingPathComponent("module")
            _ = try await parent.runner.run(["config", "core.hooksPath", "/dev/null"], in: module)
            _ = try await parent.runner.run(["switch", "--detach", base], in: module)
            try await parent.repository.stage(paths: [".gitmodules", "module"]); try await parent.repository.commit(message: "submodule base")
            try await parent.repository.createBranch(name: "incoming"); try await parent.repository.switchBranch("incoming")
            _ = try await parent.runner.run(["switch", "--detach", incoming], in: module)
            try await parent.repository.stage(paths: ["module"]); try await parent.repository.commit(message: "incoming submodule")
            try await parent.repository.switchBranch("main")
            _ = try await parent.runner.run(["switch", "--detach", current], in: module)
            try await parent.repository.stage(paths: ["module"]); try await parent.repository.commit(message: "current submodule")
            let result = try await parent.repository.integrate(.merge, revision: "incoming")
            guard case .conflicts = result else { throw GitError.invalidInput("Expected a real submodule merge conflict") }
            return (parent, child, module, current, incoming)
        } catch { child.remove(); parent.remove(); throw error }
    }

    @Test func selectedGitlinkResolvesParentWithoutChangingChildEdits() async throws {
        let (parent, child, module, current, incoming) = try await fixture()
        defer { parent.remove(); child.remove() }
        let service = ConflictService(repository: parent.repository)
        let snapshot = try await service.load(path: "module")
        #expect(snapshot.isSubmodule && snapshot.supportsVersionSelection && !snapshot.isText)
        #expect(snapshot.file.stage(2)?.objectID == current)
        #expect(snapshot.file.stage(3)?.objectID == incoming)
        #expect(try await service.submoduleCommitDetails(snapshot: snapshot, stage: 3).contains("incoming"))
        try Data("private work\n".utf8).write(to: module.appendingPathComponent("local.txt"))
        try Data("edited current\n".utf8).write(to: module.appendingPathComponent("child.txt"))
        try await service.resolve(snapshot: snapshot, resolution: .incoming)
        #expect(try await service.overview().files.isEmpty)
        #expect(try await parent.repository.run(["rev-parse", ":module"]).text.trimmingCharacters(in: .newlines) == incoming)
        #expect(try await parent.runner.run(["rev-parse", "HEAD"], in: module).text.trimmingCharacters(in: .newlines) == current)
        #expect(try String(contentsOf: module.appendingPathComponent("child.txt"), encoding: .utf8) == "edited current\n")
        #expect(try String(contentsOf: module.appendingPathComponent("local.txt"), encoding: .utf8) == "private work\n")
        try await service.continueOperation()
        #expect(try await parent.repository.run(["rev-parse", "HEAD:module"]).text.trimmingCharacters(in: .newlines) == incoming)
        #expect(try await parent.repository.history(limit: 1).first?.parents.count == 2)
    }

    @Test func externalIndexResolutionInvalidatesSubmoduleChoice() async throws {
        let (parent, child, module, current, _) = try await fixture()
        defer { parent.remove(); child.remove() }
        let service = ConflictService(repository: parent.repository)
        let snapshot = try await service.load(path: "module")
        _ = try await parent.repository.perform(["update-index", "--add", "--cacheinfo", "160000", current, "module"])
        await #expect(throws: ConflictError.self) { try await service.resolve(snapshot: snapshot, resolution: .incoming) }
        #expect(try await parent.repository.run(["rev-parse", ":module"]).text.trimmingCharacters(in: .newlines) == current)
        #expect(try await parent.runner.run(["rev-parse", "HEAD"], in: module).text.trimmingCharacters(in: .newlines) == current)
    }
}
