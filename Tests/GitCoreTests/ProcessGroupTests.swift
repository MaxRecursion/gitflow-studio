import Foundation
import Testing
@testable import GitCore

struct ProcessGroupTests {
    @Test func deadlinesRemainLiveDuringConcurrentPipeDrainage() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let script = fixture.root.appendingPathComponent("held-pipes")
        try Data("#!/bin/sh\n/bin/sleep 10 &\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let started = ContinuousClock.now
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try await GitProcessRunner(executable: script).run([], timeout: 0.1)
                        return false
                    } catch GitError.timedOut { return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(outcomes.count == 16 && outcomes.allSatisfy { $0 })
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func cancelledCommitStopsHookChildrenBeforeReturning() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("late-write")
        let ready = fixture.root.appendingPathComponent("hook-ready")
        let release = fixture.root.appendingPathComponent("release-hook-child")
        try await installHook(fixture, marker: marker, ready: ready, release: release)
        let task = Task { try await fixture.repository.commit(message: "cancel me") }
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // Release only after cancellation has returned. A fixed delayed write can
        // happen before cancellation on an oversubscribed CI host, testing its
        // scheduler rather than whether the descendant survived cancellation.
        try Data().write(to: release)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func timedOutCommitStopsHookChildrenBeforeReturning() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("late-write")
        let ready = fixture.root.appendingPathComponent("hook-ready")
        let release = fixture.root.appendingPathComponent("release-hook-child")
        try await installHook(fixture, marker: marker, ready: ready, release: release)
        await #expect(throws: GitError.self) {
            try await fixture.runner.run(["commit", "-m", "timeout"], in: fixture.url, timeout: 2)
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        try Data().write(to: release)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func installHook(_ fixture: CoreFixture, marker: URL, ready: URL, release: URL) async throws {
        try fixture.write("file.txt", "pending\n")
        try await fixture.repository.stage(paths: ["file.txt"])
        _ = try await fixture.repository.perform(["config", "core.hooksPath", ".git/hooks"])
        let hook = fixture.url.appendingPathComponent(".git/hooks/pre-commit")
        // UUID temporary paths are shell-quoted defensively; test-only fixture.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\ntrap '' TERM\n(while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.05; done; printf late > \(quote(marker.path))) &\nprintf ready > \(quote(ready.path))\nwait\n"
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }
}
