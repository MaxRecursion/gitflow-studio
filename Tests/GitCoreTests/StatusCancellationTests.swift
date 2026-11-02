import Foundation
import Testing
@testable import GitCore

struct StatusCancellationTests {
    @Test func cancellingLastStatusCallerReturnsBeforeSlowGitFinishes() async throws {
        let fixture = try await SlowStatusFixture.make()
        defer { fixture.base.remove() }
        let watchdog = fixture.releaseEventually()
        defer { watchdog.cancel() }
        let read = Task { try await fixture.repository.status() }
        try await fixture.waitUntilStarted()
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.release.path))
        try Data().write(to: fixture.release)
        #expect(try await fixture.repository.status().files.contains { $0.path == "pending.txt" })
    }

    @Test func oneCancelledCallerDoesNotCancelAnotherCoalescedStatusRead() async throws {
        let fixture = try await SlowStatusFixture.make()
        defer { fixture.base.remove() }
        let watchdog = fixture.releaseEventually()
        defer { watchdog.cancel() }
        let first = Task { try await fixture.repository.status() }
        try await fixture.waitUntilStarted()
        let second = Task { try await fixture.repository.status() }
        try await Task.sleep(for: .milliseconds(40))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.release.path))
        try Data().write(to: fixture.release)
        #expect(try await second.value.files.contains { $0.path == "pending.txt" })
        #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "start\n")
    }

    @Test func mutationInvalidatesPendingStatusWithoutStrandingCallers() async throws {
        let fixture = try await SlowStatusFixture.make()
        defer { fixture.base.remove() }
        let watchdog = fixture.releaseEventually()
        defer { watchdog.cancel() }
        let read = Task { try await fixture.repository.status() }
        try await fixture.waitUntilStarted()
        try await fixture.repository.stage(paths: ["pending.txt"])
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.release.path))
        try Data().write(to: fixture.release)
        #expect(try await fixture.repository.status().files.first?.isStaged == true)
    }
}

private struct SlowStatusFixture: Sendable {
    let base: CoreFixture
    let repository: GitRepository
    let starts: URL
    let release: URL

    static func make() async throws -> Self {
        let base = try await CoreFixture.make()
        do {
            try base.write("pending.txt", "pending\n")
            let starts = base.root.appendingPathComponent("status-started")
            let release = base.root.appendingPathComponent("release-status")
            let script = base.root.appendingPathComponent("slow-git")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let text = """
            #!/bin/sh
            for argument do
              if [ "$argument" = status ]; then
                printf 'start\\n' >> \(quote(starts.path))
                while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
                break
              fi
            done
            exec \(quote(base.runner.executable.path)) "$@"
            """
            try Data((text + "\n").utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return Self(base: base, repository: GitRepository(url: base.url, runner: GitProcessRunner(executable: script)), starts: starts, release: release)
        } catch { base.remove(); throw error }
    }

    func waitUntilStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: starts.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: starts.path))
    }

    func releaseEventually() -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(5)); try Data().write(to: release) }
            catch { /* Cancellation keeps normal assertions independent of a timer. */ }
        }
    }
}
