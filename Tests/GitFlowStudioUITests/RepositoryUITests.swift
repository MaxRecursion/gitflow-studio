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
        XCTAssertTrue(app.staticTexts["Your working tree is clean"].waitForExistence(timeout: 15))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .newlines), "Native UI commit")
        XCTAssertEqual(try git(["status", "--porcelain"]), "")
        app.staticTexts["History"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Native UI commit"].firstMatch.waitForExistence(timeout: 10))
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
        let confirmContinue = app.buttons["Continue Merge"]
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
