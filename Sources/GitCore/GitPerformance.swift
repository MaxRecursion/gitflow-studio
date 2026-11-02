import OSLog
import Dispatch

/// Local Instruments intervals. Never records paths, arguments, code, or credentials.
public enum GitPerformance {
    public static let signposter = OSSignposter(subsystem: "studio.gitflow", category: "PointsOfInterest")

    /// The Sendable boundary keeps callbacks created by UI actors from inheriting
    /// their actor isolation when invoked by the diagnostic worker queue.
    public static func scheduleDiagnostic(after delay: DispatchTimeInterval,
                                          action: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { @Sendable in action() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}
