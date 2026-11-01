import XCTest

/// Runs only against fresh temporary repositories, never the user's checkout.
/// Requires full Xcode and an unlocked, logged-in macOS desktop.
@MainActor
final class RepositoryUITests: XCTestCase {
    private var fixture: URL!
    private var app: XCUIApplication!

    private func setUpFixture() throws {
        continueAfterFailure = false
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("GitFlowStudio-UI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main"])
        try git(["config", "user.name", "UI Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try write("base\n")
        try git(["add", "--", "changed.txt"])
        try git(["commit", "-m", "Base fixture"])
        app = XCUIApplication()
        app.launchArguments = ["--repo", fixture.path]
        app.launchEnvironment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
    }

    private func cleanUpFixture() {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    func testOpenStageCommitAndInspectHistory() throws {
        try setUpFixture()
        defer { cleanUpFixture() }
        try write("edited through test fixture\n")
        app.launch()
        let stage = app.buttons["Stage changed.txt"]
        XCTAssertTrue(stage.waitForExistence(timeout: 15))
        stage.click()
        XCTAssertTrue(app.buttons["Unstage changed.txt"].waitForExistence(timeout: 10))
        let message = app.descendants(matching: .any).matching(identifier: "commit-message").firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.click()
        message.typeText("Native UI commit")
        app.buttons["commit-staged"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Your working tree is clean", "Your working tree is clean")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "Native UI commit")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        app.descendants(matching: .any).matching(identifier: "workspace-History").firstMatch.click()
        XCTAssertTrue(app.textFields["Search commit messages"].waitForExistence(timeout: 10))
        // Native List rows may expose a combined accessibility label rather
        // than a separate subject StaticText on different macOS/CPU runners.
        let commit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Native UI commit", "Native UI commit")).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 10))
        commit.click()
        let sha = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .newlines)
        XCTAssertTrue(app.buttons[String(sha.prefix(8))].waitForExistence(timeout: 10))
        attachScreenshot("history")
    }

    func testResolveRealMergeAndContinue() async throws {
        try setUpFixture()
        defer { cleanUpFixture() }
        try git(["switch", "-c", "incoming"])
        try write("incoming\n")
        try git(["commit", "-am", "Incoming change"])
        try git(["switch", "main"])
        try write("current\n")
        try git(["commit", "-am", "Current change"])
        try git(["merge", "incoming"], expectedStatus: 1)
        app.launch()
        let incoming = app.buttons["conflict-use-incoming"]
        XCTAssertTrue(incoming.waitForExistence(timeout: 15))
        incoming.click()
        attachScreenshot("merge-result-preview")
        app.buttons["Mark File Resolved"].click()
        let confirmWrite = app.buttons["conflict-write-stage"]
        XCTAssertTrue(confirmWrite.waitForExistence(timeout: 5))
        confirmWrite.click()
        let continueMerge = app.buttons["conflict-continue"]
        XCTAssertTrue(continueMerge.waitForExistence(timeout: 10))
        continueMerge.click()
        let confirmContinue = app.sheets.buttons["Continue Merge"]
        XCTAssertTrue(confirmContinue.waitForExistence(timeout: 5))
        confirmContinue.click()
        for _ in 0..<150 {
            if try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count == 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count, 3)
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("changed.txt"), encoding: .utf8), "incoming\n")
        XCTAssertEqual(try git(["ls-files", "-u"]), "")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
    }

    func testRebaseConflictRolesAndContinue() async throws { try await resolveReplay(operation: "rebase", expected: "current\n") }
    func testCherryPickConflictContinue() async throws { try await resolveReplay(operation: "cherry-pick", expected: "incoming\n") }
    func testRevertConflictContinue() async throws { try await resolveReplay(operation: "revert", expected: "base\n") }

    private func resolveReplay(operation: String, expected: String) async throws {
        try setUpFixture(); defer { cleanUpFixture() }
        try git(["switch", "-c", "incoming"]); try write("incoming\n"); try git(["commit", "-am", "Incoming change"])
        try git(["switch", "main"]); try write("current\n"); try git(["commit", "-am", "Current change"])
        try git([operation, "incoming"], expectedStatus: 1)
        app.launch()
        let incoming = app.buttons["conflict-use-incoming"]
        XCTAssertTrue(incoming.waitForExistence(timeout: 20))
        if operation == "rebase" {
            XCTAssertEqual(incoming.label, "Use Replayed Commit")
            XCTAssertEqual(app.buttons["conflict-use-current"].label, "Use Destination")
        }
        incoming.click(); app.buttons["Mark File Resolved"].click()
        app.sheets.buttons["conflict-write-stage"].click()
        let proceed = app.buttons["conflict-continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 10)); proceed.click()
        let title = "Continue " + operation.capitalized
        let confirm = app.sheets.buttons[title]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.click()
        for _ in 0..<150 {
            let message = try git(["log", "-1", "--format=%s"])
            if message.contains(operation == "rebase" ? "Current change" : operation == "revert" ? "Revert" : "Incoming change"), try git(["ls-files", "-u"]).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("changed.txt"), encoding: .utf8), expected)
        XCTAssertEqual(try git(["ls-files", "-u"]), "")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        XCTAssertEqual(try git(["rev-list", "--parents", "-n", "1", "HEAD"]).split(separator: " ").count, 2)
        // REBASE_HEAD can remain as a pseudoref after successful completion.
        // Active rebase directories and detached HEAD determine the lifecycle.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/rebase-merge").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git/rebase-apply").path))
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"]).trimmingCharacters(in: .newlines), "main")
        attachScreenshot(operation + "-continued")
    }

    func testConflictEditorInteractionPerformance() throws {
        try setUpFixture(); defer { cleanUpFixture() }
        let base = (0..<100).map { "// Region \($0)\nlet setting\($0) = \"base\"\n" + String(repeating: "// unchanged context\n", count: 8) }.joined()
        try write(base); try git(["commit", "-am", "Large base"])
        try git(["switch", "-c", "incoming"]); try write(base.replacingOccurrences(of: "\"base\"", with: "\"incoming\"")); try git(["commit", "-am", "Large incoming"])
        try git(["switch", "main"]); try write(base.replacingOccurrences(of: "\"base\"", with: "\"current\"")); try git(["commit", "-am", "Large current"])
        try git(["merge", "incoming"], expectedStatus: 1)
        app.launch()
        let current = app.buttons["conflict-use-current"], incoming = app.buttons["conflict-use-incoming"]
        XCTAssertTrue(current.waitForExistence(timeout: 20))
        let editor = app.textViews["Editable merged result"]
        // Only the dedicated profiling workflow creates this gate. Hold the
        // fixture steady until Instruments has attached; normal tests do not wait.
        let profileGate = "/private/tmp/GitFlowStudioProfileGate"
        if FileManager.default.fileExists(atPath: profileGate + "/requested") {
            let deadline = Date().addingTimeInterval(150)
            while !FileManager.default.fileExists(atPath: profileGate + "/ready"), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: profileGate + "/ready"))
        }
        let options = XCTMeasureOptions(); options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            current.click()
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 16)).click()
            editor.typeText(" ")
            incoming.click()
        }
        attachScreenshot("conflict-editor-performance")
        app.typeKey("q", modifierFlags: .command)
        let discard = app.dialogs.buttons["Discard Drafts and Quit"]
        if discard.waitForExistence(timeout: 5) { discard.click() }
    }

    func testWarmApplicationLaunchPerformance() throws {
        try setUpFixture(); defer { cleanUpFixture() }
        let options = XCTMeasureOptions(); options.iterationCount = 3
        options.invocationOptions = [.manuallyStart]
        // The launch-specific metric returns no data (and can assert during
        // harvest) on hosted macOS. Use a wall-clock interval, excluding termination.
        // It includes XCTest's launch/idle synchronization, not just app startup.
        measure(metrics: [XCTClockMetric()], options: options) {
            app.terminate()
            startMeasuring()
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            stopMeasuring()
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: fixture.appendingPathComponent("changed.txt"), options: .atomic)
    }

    @discardableResult
    private func git(_ arguments: [String], expectedStatus: Int32 = 0) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager"] + arguments
        process.currentDirectoryURL = fixture
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        process.environment = environment
        // Test fixture output is bounded; use a regular temporary file to avoid pipe backpressure.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(".uitest-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        guard process.terminationStatus == expectedStatus else {
            throw NSError(domain: "GitFlowStudioUITests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}
