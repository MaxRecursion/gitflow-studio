import OSLog

/// Local Instruments intervals. Never records paths, arguments, code, or credentials.
public enum GitPerformance {
    public static let signposter = OSSignposter(subsystem: "studio.gitflow", category: "performance")
}
