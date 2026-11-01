import Foundation
import Darwin
import OSLog

/// Runs Git directly, with concurrent pipe drainage and bounded capture. No shell is involved.
public struct GitProcessRunner: Sendable {
    public let executable: URL
    private static let logger = Logger(subsystem: "studio.gitflow", category: "git")
    // A timeout must not queue behind the blocking subprocess/drain workers.
    // A default-QoS global timer can starve under many concurrent Git reads.
    private static let deadlines = DispatchQueue(label: "studio.gitflow.git-deadlines", qos: .userInitiated)
    public init() {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        executable = URL(fileURLWithPath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git")
    }
    public init(executable: URL) { self.executable = executable }

    public func run(_ arguments: [String], in directory: URL? = nil, input: Data? = nil,
                    allowedExitCodes: Set<Int32> = [0], timeout: TimeInterval = 60,
                    maxOutputBytes: Int = 16 * 1024 * 1024,
                    onOutput: (@Sendable (Data) -> Void)? = nil) async throws -> GitOutput {
        try Task.checkCancellation()
        let interval = GitPerformance.signposter.beginInterval("Git Subprocess", id: GitPerformance.signposter.makeSignpostID())
        defer { GitPerformance.signposter.endInterval("Git Subprocess", interval) }
        // Each admitted command owns a blocking waiter plus three pipe workers.
        // Bound that budget below Dispatch's thread soft limit; queued callers
        // suspend without occupying a worker and remain promptly cancellable.
        try await GitProcessAdmission.shared.acquire()
        let state = ProcessState()
        do {
            let result: GitOutput = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let output = try execute(arguments, directory: directory, input: input,
                                                     timeout: timeout, limit: maxOutputBytes, state: state, onOutput: onOutput)
                            if !allowedExitCodes.contains(output.exitCode) {
                                let message = Self.redacted(String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                                throw GitError.command(output.exitCode, message)
                            }
                            continuation.resume(returning: output)
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: { state.stop(.cancelled) }
            await GitProcessAdmission.shared.release()
            return result
        } catch {
            await GitProcessAdmission.shared.release()
            throw error
        }
    }

    private func execute(_ arguments: [String], directory: URL?, input: Data?, timeout: TimeInterval,
                         limit: Int, state: ProcessState, onOutput: (@Sendable (Data) -> Void)?) throws -> GitOutput {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw GitError.unavailable }
        guard limit > 0 else { throw GitError.invalidInput("Output limit must be positive.") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_PREFIX"] {
            environment.removeValue(forKey: name)
        }
        // The user's credential helpers, SSH agent, configuration, and hooks remain active.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/true"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let output = Pipe(), errors = Pipe(), standardInput = Pipe()
        process.standardOutput = output; process.standardError = errors; process.standardInput = standardInput
        let timer = DispatchWorkItem { state.stop(.timeout) }
        Self.deadlines.asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
        defer { timer.cancel() }
        try state.launch(process)
        let group = DispatchGroup()
        let capturedOutput = Capture(), capturedError = Capture()
        for (handle, capture, handler) in [(output.fileHandleForReading, capturedOutput, onOutput), (errors.fileHandleForReading, capturedError, nil)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? handle.close(); group.leave() }
                let descriptor = handle.fileDescriptor
                _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while !state.isStopped {
                    var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                    guard poll(&event, 1, 100) > 0 else { continue }
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { continue }
                        state.stop(.readFailure); break
                    }
                    let chunk = Data(buffer.prefix(count))
                    handler?(chunk)
                    if !capture.append(chunk, limit: limit) { state.stop(.limit) }
                }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? standardInput.fileHandleForWriting.close(); group.leave() }
            guard let input else { return }
            let descriptor = standardInput.fileHandleForWriting.fileDescriptor
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            input.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count && !state.isStopped {
                    var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    guard poll(&event, 1, 100) > 0 else { continue }
                    let count = Darwin.write(descriptor, base.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                    if count < 0 {
                        if errno == EAGAIN || errno == EINTR { continue }
                        // Git can reject a command before consuming stdin; preserve its exit and diagnostic.
                        if errno != EPIPE { state.stop(.readFailure) }
                        break
                    }
                    offset += count
                }
            }
        }
        process.waitUntilExit()
        group.wait()
        try state.finish()
        Self.logger.debug("Git subprocess finished with status \(process.terminationStatus)")
        return GitOutput(stdout: capturedOutput.data, stderr: capturedError.data, exitCode: process.terminationStatus)
    }

    public static func redacted(_ value: String) -> String {
        value.replacingOccurrences(of: #"(https?://)[^/@\s]+@"#, with: "$1<redacted>@", options: .regularExpression)
    }
}

/// Internal so the suspension/cancellation contract can be tested independently.
actor GitProcessAdmission {
    static let shared = GitProcessAdmission()
    private let limit: Int
    private var active = 0
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private var waiters: [Waiter] = []
    init(limit: Int = 8) { precondition(limit > 0); self.limit = limit }
    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    func release() {
        precondition(active > 0)
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().continuation.resume() }
    }
}

private final class Capture: @unchecked Sendable {
    // A single drain queue owns writes; reads occur only after DispatchGroup joins.
    var data = Data()
    func append(_ bytes: Data, limit: Int) -> Bool {
        let available = max(0, limit - data.count)
        data.append(bytes.prefix(available))
        return bytes.count <= available
    }
}

private final class ProcessState: @unchecked Sendable {
    enum Reason { case cancelled, timeout, limit, readFailure }
    private let lock = NSLock()
    private var process: Process?
    private var processGroup: pid_t?
    private var reason: Reason?
    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return reason != nil
    }
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        try checkStopReason()
        self.process = process
        try process.run()
        // Foundation creates a separate process group on macOS. Verify that
        // property at runtime before ever sending a negative-PID signal.
        let pid = process.processIdentifier
        if pid > 1, getpgid(pid) == pid, pid != getpgrp() { processGroup = pid }
    }
    func stop(_ reason: Reason) {
        lock.lock(); defer { lock.unlock() }
        guard self.reason == nil else { return }
        self.reason = reason
        // Kill the verified, isolated Git job synchronously. A delayed escalation
        // after returning would permit hooks to mutate after the repository gate
        // was released, and could signal a reused process identifier.
        // SIGKILL can leave Git lock files; never remove those automatically.
        if let group = processGroup {
            _ = kill(-group, SIGKILL)
        } else if let process, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        process = nil; processGroup = nil
        try checkStopReason()
    }
    // Caller holds lock; preserve timeout/output errors even before launch.
    private func checkStopReason() throws {
        switch reason {
        case .cancelled: throw CancellationError()
        case .timeout: throw GitError.timedOut
        case .limit: throw GitError.outputLimit
        case .readFailure: throw GitError.invalidInput("Git output could not be read.")
        case nil: break
        }
    }
}
