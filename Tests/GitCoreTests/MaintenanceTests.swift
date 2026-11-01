import Foundation
import Testing
@testable import GitCore

struct MaintenanceTests {
    @Test func automaticMaintenancePreservesLargeFixtureAcrossSequentialCommits() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        // Force the automatic GC path rather than merely checking our arguments.
        _ = try await fixture.repository.perform(["config", "gc.auto", "1"])
        _ = try await fixture.repository.perform(["config", "gc.autoDetach", "true"])
        _ = try await fixture.repository.perform(["config", "maintenance.autoDetach", "true"])
        _ = try await fixture.repository.perform(["config", "maintenance.strategy", "gc"])
        for index in 0..<1000 { try fixture.write("file-\(index).txt", "File \(index)\nInitial contents\n") }
        try await fixture.repository.stage(paths: (0..<1000).map { "file-\($0).txt" })
        try await fixture.repository.commit(message: "Initial thousand files")
        for index in 1...20 {
            try fixture.write("file-0.txt", "Revision \(index)\n")
            try await fixture.repository.stage(paths: ["file-0.txt"])
            try await fixture.repository.commit(message: "Revision \(index)")
        }
        _ = try await fixture.repository.perform(["fsck", "--no-dangling"])
        #expect(try await fixture.repository.history(limit: 30, skip: 0, search: "").count == 21)
        #expect(try await fixture.repository.status().files.isEmpty)
        #expect(try await fixture.repository.perform(["show", "HEAD:file-0.txt"]).text == "Revision 20\n")
        let packs = try FileManager.default.contentsOfDirectory(atPath: fixture.url.appendingPathComponent(".git/objects/pack").path)
        #expect(packs.contains { $0.hasSuffix(".pack") })
    }
}
