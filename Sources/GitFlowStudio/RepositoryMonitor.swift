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
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            // Drain delivered callbacks before releasing their unretained context.
            queue.sync {}
            FSEventStreamRelease(stream)
        }
    }
}
