import Foundation
import Testing
@testable import GitCore

struct PerformanceDiagnosticsTests {
    @MainActor @Test func diagnosticCreatedByUIActorRunsOffMainActor() async {
        let ranOnMainThread = await withCheckedContinuation { continuation in
            _ = GitPerformance.scheduleDiagnostic(after: .milliseconds(1)) {
                continuation.resume(returning: Thread.isMainThread)
            }
        }
        #expect(!ranOnMainThread)
    }
}
