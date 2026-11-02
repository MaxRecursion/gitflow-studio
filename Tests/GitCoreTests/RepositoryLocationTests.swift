import Foundation
import Testing
@testable import GitCore

struct RepositoryLocationTests {
    @Test func literalPathsPreserveSpecialCharacters() throws {
        for path in ["/tmp/space ' quote $() ;.git ", "/tmp/line\nsecond line", "/tmp/100% # ?"] {
            #expect(Array(try RepositoryLocation.url(from: path).path.utf8) == Array(path.utf8))
        }
        // macOS Foundation applies canonical filesystem Unicode normalization.
        let unicode = "/tmp/répo 🧑🏽‍💻"
        #expect(try RepositoryLocation.url(from: unicode).path == unicode)
    }

    @Test func homeAndLocalFileURLsAreSupported() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try RepositoryLocation.url(from: "~").path == home)
        #expect(try RepositoryLocation.url(from: "~/Projects/Repository").path == home + "/Projects/Repository")
        let url = URL(fileURLWithPath: "/tmp/répo space # ?\nend ", isDirectory: true)
        #expect(Array(try RepositoryLocation.url(from: url.absoluteString).path.utf8) == Array(url.path.utf8))
    }

    @Test func implicitPathsAndAmbiguousURLsAreRejected() {
        for input in ["", "relative/folder", "https://example.invalid/repo", "ssh://server/repo", "~anotheruser/repo", "/tmp/null\0path", "file://server/repo", "file://localhost/repo?query", "file://localhost/repo#fragment", "file://localhost/repo%00name", "file://"] {
            #expect(throws: GitError.self) { try RepositoryLocation.url(from: input) }
        }
    }

    @Test func finderPathOpensARealRepositoryWithAnUnusualRootName() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("répo 👩🏽‍💻\n' $() end ", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.url, to: folder)
        try Data("External content\n".utf8).write(to: folder.appendingPathComponent("pending.txt"))
        let repository = try await GitRepository.open(RepositoryLocation.url(from: folder.path))
        #expect(try await repository.status().files.contains { $0.path == "pending.txt" })
        #expect(Array(repository.url.path.utf8) == Array(folder.resolvingSymlinksInPath().path.utf8))
    }
}
