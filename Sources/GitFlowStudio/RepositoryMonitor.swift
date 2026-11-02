import Foundation
import CoreServices

/// FSEvents is recursive and event driven. No timers or periodic Git polling while idle.
final class RepositoryMonitor: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private final class Callback: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }
    private let callback: Callback
    private let queue = DispatchQueue(label: "studio.repository.events", qos: .utility)

    static func start(paths: [String], onChange: @escaping @Sendable () -> Void) async -> RepositoryMonitor {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: RepositoryMonitor(paths: paths, onChange: onChange))
            }
        }
    }

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        callback = Callback(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context, Array(Set(paths)) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
        if let stream { FSEventStreamSetDispatchQueue(stream, queue); FSEventStreamStart(stream) }
    }

    deinit {
        if let stream {
            let teardown = Teardown(stream: stream, callback: callback, queue: queue)
            DispatchQueue.global(qos: .utility).async { teardown.finish() }
        }
    }

    // A single background job owns teardown; the context remains alive through
    // the callback drain. Repository switches never synchronously wait on FSEvents.
    private final class Teardown: @unchecked Sendable {
        let stream: FSEventStreamRef
        let callback: Callback
        let queue: DispatchQueue
        init(stream: FSEventStreamRef, callback: Callback, queue: DispatchQueue) {
            self.stream = stream; self.callback = callback; self.queue = queue
        }
        func finish() {
            withExtendedLifetime(callback) {
                FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
                queue.sync {}
                FSEventStreamRelease(stream)
            }
        }
    }
}
