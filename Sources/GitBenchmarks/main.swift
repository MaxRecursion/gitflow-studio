import Foundation
import GitCore

struct Measurement: Codable {
    let name: String
    let samples: Int
    let medianMilliseconds: Double
    let p95Milliseconds: Double
}

struct Report: Codable {
    let timestamp: Date
    let operatingSystem: String
    let processors: Int
    let memoryBytes: UInt64
    let gitVersion: String
    let trackedFiles: Int
    let historyCommits: Int
    let measurements: [Measurement]
    let scope: String
}

@main
struct GitBenchmarks {
    static func measure(_ name: String, iterations: Int = 30, operation: @Sendable () async throws -> Void) async throws -> Measurement {
        try await operation() // Warm the filesystem and Git executable once.
        var durations: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            let started = clock.now
            try await operation()
            let elapsed = started.duration(to: clock.now).components
            durations.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        durations.sort()
        return Measurement(name: name, samples: iterations,
                           medianMilliseconds: durations[durations.count / 2],
                           p95Milliseconds: durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))])
    }

    static func main() async throws {
        let quick = CommandLine.arguments.contains("--quick")
        let fileCount = quick ? 100 : 1_000
        let commitCount = quick ? 20 : 100
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitFlowBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = GitProcessRunner()
        _ = try await runner.run(["init", "-b", "main", "--quiet"], in: directory)
        // Keep fixture construction deterministic: detached maintenance can
        // overlap later samples/teardown and is not the operation being measured.
        // These settings affect only this disposable repository, never app Git.
        for (key, value) in [("user.name", "GitFlow Benchmark"), ("user.email", "benchmark@example.invalid"), ("commit.gpgSign", "false"), ("core.hooksPath", "/dev/null"), ("maintenance.auto", "false"), ("gc.auto", "0")] {
            _ = try await runner.run(["config", key, value], in: directory)
        }
        for index in 0..<fileCount {
            try Data("File \(index)\nInitial contents\n".utf8).write(to: directory.appendingPathComponent("file-\(index).txt"))
        }
        _ = try await runner.run(["add", "--all"], in: directory)
        _ = try await runner.run(["commit", "-qm", "Initial files"], in: directory)
        for index in 1..<commitCount {
            try Data("Revision \(index)\n".utf8).write(to: directory.appendingPathComponent("file-0.txt"))
            _ = try await runner.run(["commit", "-qam", "Revision \(index)"], in: directory)
        }
        _ = try await runner.run(["fsck", "--no-dangling"], in: directory)
        try Data("Uncommitted edit\n".utf8).write(to: directory.appendingPathComponent("file-1.txt"))
        let repository = try await GitRepository.open(directory)
        let openTime = try await measure("open_repository") { _ = try await GitRepository.open(directory) }
        let statusTime = try await measure("status_\(fileCount)_tracked_files") { _ = try await repository.status() }
        let historyTime = try await measure("history_first_100") { _ = try await repository.history(limit: 100, skip: 0, search: "") }
        let diffTime = try await measure("small_unstaged_diff") { _ = try await repository.diff(path: "file-1.txt", staged: false) }
        let processTime = try await measure("git_version_subprocess") { _ = try await runner.run(["--version"]) }
        let gitVersion = try await runner.run(["--version"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = Report(timestamp: Date(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            processors: ProcessInfo.processInfo.processorCount, memoryBytes: ProcessInfo.processInfo.physicalMemory,
                            gitVersion: gitVersion, trackedFiles: fileCount, historyCommits: commitCount,
                            measurements: [openTime, statusTime, historyTime, diffTime, processTime],
                            scope: "Warm Git service operations only. Does not measure UI rendering, application startup, idle memory, or scrolling.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let output = try encoder.encode(report)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([10]))
    }
}
