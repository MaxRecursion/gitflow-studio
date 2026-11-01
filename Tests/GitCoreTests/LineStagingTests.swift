import Foundation
import Testing
@testable import GitCore

struct LineStagingTests {
    @Test func leadingCombiningMarksAreFileContentNotPatchPrefixes() async throws {
        let fixture = try await fixture(base: "\u{0301}old\n")
        defer { fixture.remove() }
        let expected = "\u{0301}new\n"
        try fixture.write("file.txt", expected)
        let diff = try await fixture.repository.diff(path: "file.txt")
        let patch = GitPatch(diff: diff)
        #expect(patch.canApplyLines)
        try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: select(patch) { $0.isSelectable }, expectedDiff: diff)
        #expect(try await fixture.repository.run(["show", ":file.txt"]).stdout == Data(expected.utf8))
    }
    @Test func customDiffPresentationCannotRedirectASelectedPatch() async throws {
        for useLines in [false, true] {
            let fixture = try await fixture(base: "old\n\ntail\n")
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try fixture.write("nested/file.txt", "old\n\ntail\n")
            try await fixture.repository.stage(paths: ["nested/file.txt"])
            try await fixture.repository.commit(message: "Same base at two paths")
            for (key, value) in [("diff.noprefix", "true"), ("diff.mnemonicPrefix", "true"),
                                 ("diff.srcPrefix", "unusual/old/"), ("diff.dstPrefix", "unusual/new/"),
                                 ("diff.outputIndicatorNew", "-"), ("diff.outputIndicatorOld", "+"),
                                 ("diff.outputIndicatorContext", "!"), ("diff.suppressBlankEmpty", "true")] {
                _ = try await fixture.repository.perform(["config", key, value])
            }
            try fixture.write("nested/file.txt", "new\n\ntail\n")
            let diff = try await fixture.repository.diff(path: "nested/file.txt")
            #expect(diff.contains("--- a/nested/file.txt\n"))
            #expect(diff.contains("+++ b/nested/file.txt\n"))
            #expect(diff.contains("-old\n+new\n"))
            let patch = GitPatch(diff: diff)
            if useLines {
                try await fixture.repository.applyLines(path: "nested/file.txt", staged: false, selection: select(patch) { $0.isSelectable }, expectedDiff: diff)
            } else {
                try await fixture.repository.applyHunk(path: "nested/file.txt", staged: false, hunkID: 0, expectedDiff: diff)
            }
            #expect(try await fixture.repository.run(["show", ":nested/file.txt"]).text == "new\n\ntail\n")
            #expect(try await contents(fixture) == "old\n\ntail\n")
        }
    }
    @Test func selectedReplacementLinesPreserveOtherEditsAndWorktree() async throws {
        let fixture = try await fixture(base: "head\nold one\nold two\ntail\n")
        defer { fixture.remove() }
        let changed = "head\nnew one\nnew two\ntail\n"
        try fixture.write("file.txt", changed)
        let diff = try await fixture.repository.diff(path: "file.txt")
        let patch = GitPatch(diff: diff)
        #expect(patch.canApplyLines)
        let selection = select(patch) { $0.text == "old one" || $0.text == "new one" }
        try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: selection, expectedDiff: diff)
        #expect(try await contents(fixture) == "head\nold two\nnew one\ntail\n")
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("file.txt"), encoding: .utf8) == changed)
        #expect(try await fixture.repository.diff(path: "file.txt").contains("+new two"))
    }

    @Test func additionsAndDeletionsCanBeChosenIndependently() async throws {
        for chooseAddition in [true, false] {
            let fixture = try await fixture(base: "head\nold\ntail\n")
            defer { fixture.remove() }
            try fixture.write("file.txt", "head\nnew\ntail\n")
            let diff = try await fixture.repository.diff(path: "file.txt")
            let selected = select(GitPatch(diff: diff)) { $0.kind == (chooseAddition ? .addition : .deletion) }
            try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: selected, expectedDiff: diff)
            #expect(try await contents(fixture) == (chooseAddition ? "head\nold\nnew\ntail\n" : "head\ntail\n"))
        }
    }

    @Test func selectionsAcrossHunksRecomputeOffsetsAndSkipUnselectedHunks() async throws {
        let original = (1...45).map { "line \($0)\n" }.joined()
        let fixture = try await fixture(base: original)
        defer { fixture.remove() }
        let changed = original.replacingOccurrences(of: "line 2\n", with: "first insertion\nline 2\n")
            .replacingOccurrences(of: "line 22\n", with: "middle insertion\nline 22\n")
            .replacingOccurrences(of: "line 42\n", with: "last insertion\nline 42\n")
        try fixture.write("file.txt", changed)
        let diff = try await fixture.repository.diff(path: "file.txt")
        let patch = GitPatch(diff: diff)
        #expect(patch.hunks.count == 3)
        let selected = select(patch) { $0.text == "first insertion" || $0.text == "last insertion" }
        try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: selected, expectedDiff: diff)
        #expect(try await contents(fixture) == original.replacingOccurrences(of: "line 2\n", with: "first insertion\nline 2\n").replacingOccurrences(of: "line 42\n", with: "last insertion\nline 42\n"))
    }

    @Test func partialUnstageRestoresOnlySelectedDeletionAndAddition() async throws {
        let original = (1...30).map { "line \($0)\n" }.joined()
        let fixture = try await fixture(base: original)
        defer { fixture.remove() }
        let changed = original.replacingOccurrences(of: "line 2\n", with: "added 2\nextra 2\n").replacingOccurrences(of: "line 28\n", with: "added 28\n")
        try fixture.write("file.txt", changed)
        try await fixture.repository.stage(paths: ["file.txt"])
        let diff = try await fixture.repository.diff(path: "file.txt", staged: true)
        let selected = select(GitPatch(diff: diff)) { $0.text == "line 2" || $0.text == "added 2" || $0.text == "extra 2" }
        try await fixture.repository.applyLines(path: "file.txt", staged: true, selection: selected, expectedDiff: diff)
        #expect(try await contents(fixture) == original.replacingOccurrences(of: "line 28\n", with: "added 28\n"))
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("file.txt"), encoding: .utf8) == changed)
    }

    @Test func unicodeCRLFPreservesExactStagedBytesAndLineNumbers() async throws {
        let fixture = try await fixture(base: "開始\r\n古い\r\n終わり\r\n")
        defer { fixture.remove() }
        _ = try await fixture.repository.perform(["config", "core.autocrlf", "false"])
        let changed = "開始\r\n新しい🙂\r\n追加\r\n終わり\r\n"
        try fixture.write("file.txt", changed)
        let diff = try await fixture.repository.diff(path: "file.txt")
        let patch = GitPatch(diff: diff)
        let oldLine = try #require(patch.hunks.first?.lines.first { $0.kind == .deletion })
        let newLine = try #require(patch.hunks.first?.lines.first { $0.kind == .addition })
        #expect(oldLine.oldLineNumber == 2 && oldLine.newLineNumber == nil)
        #expect(newLine.oldLineNumber == nil && newLine.newLineNumber == 2)
        try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: select(patch) { $0.text == "古い" || $0.text == "新しい🙂" }, expectedDiff: diff)
        #expect(try await fixture.repository.run(["show", ":file.txt"]).stdout == Data("開始\r\n新しい🙂\r\n終わり\r\n".utf8))
    }

    @Test func trackedEmptyFileSupportsZeroContextInsertionAndUnstage() async throws {
        let fixture = try await fixture(base: "")
        defer { fixture.remove() }
        try fixture.write("file.txt", "first\nsecond\n")
        let diff = try await fixture.repository.diff(path: "file.txt")
        let patch = GitPatch(diff: diff)
        try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: select(patch) { $0.text == "second" }, expectedDiff: diff)
        #expect(try await contents(fixture) == "second\n")
        let staged = try await fixture.repository.diff(path: "file.txt", staged: true)
        try await fixture.repository.applyLines(path: "file.txt", staged: true, selection: select(GitPatch(diff: staged)) { $0.isSelectable }, expectedDiff: staged)
        #expect(try await contents(fixture).isEmpty)
    }

    @Test func staleAndInvalidSelectionsNeverModifyTheIndex() async throws {
        let fixture = try await fixture(base: "head\nold\ntail\n")
        defer { fixture.remove() }
        try fixture.write("file.txt", "head\nnew\ntail\n")
        let diff = try await fixture.repository.diff(path: "file.txt")
        let patch = GitPatch(diff: diff)
        let selected = select(patch) { $0.isSelectable }
        for invalid: [Int: Set<Int>] in [[:], [0: []], [0: [999]], [999: [0]], [0: [0]]] {
            await #expect(throws: GitError.self) { try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: invalid, expectedDiff: diff) }
        }
        try fixture.write("file.txt", "head\nexternal edit\ntail\n")
        await #expect(throws: GitError.self) { try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: selected, expectedDiff: diff) }
        #expect(try await contents(fixture) == "head\nold\ntail\n")
    }

    @Test func unsupportedBinaryPatchTypesAreRefused() async throws {
        for (base, changed) in [("\0base\n", "\0change\n")] {
            let fixture = try await fixture(base: base)
            defer { fixture.remove() }
            try fixture.write("file.txt", changed)
            let diff = try await fixture.repository.diff(path: "file.txt")
            #expect(!GitPatch(diff: diff).canApplyLines)
            await #expect(throws: GitError.self) { try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: [0: [0]], expectedDiff: diff) }
            #expect(try await contents(fixture) == base)
        }
        let fixture = try await fixture(base: "base\n")
        defer { fixture.remove() }
        try fixture.write("new.txt", "new\n")
        try await fixture.repository.stage(paths: ["new.txt"])
        let added = try await fixture.repository.diff(path: "new.txt", staged: true)
        #expect(!GitPatch(diff: added).canApplyLines)
        try fixture.write("file.txt", "changed\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.url.appendingPathComponent("file.txt").path)
        let mode = try await fixture.repository.diff(path: "file.txt")
        #expect(!GitPatch(diff: mode).canApplyLines)
    }

    @Test func invalidUTF8CannotBecomeALossyPartialPatch() async throws {
        let fixture = try await fixture(base: "base\n")
        defer { fixture.remove() }
        let bytes = Data([0xFF, 0x0A])
        try bytes.write(to: fixture.url.appendingPathComponent("file.txt"))
        let raw = try await fixture.repository.run(["diff", "--no-ext-diff", "--no-textconv", "--", "file.txt"])
        #expect(String(data: raw.stdout, encoding: .utf8) == nil)
        let lossyDiff = raw.text
        await #expect(throws: GitError.self) { try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: [0: [0, 1]], expectedDiff: lossyDiff) }
        await #expect(throws: GitError.self) { try await fixture.repository.applyHunk(path: "file.txt", staged: false, hunkID: 0, expectedDiff: lossyDiff) }
        #expect(try await contents(fixture) == "base\n")
        try await fixture.repository.stage(paths: ["file.txt"])
        #expect(try await fixture.repository.run(["show", ":file.txt"]).stdout == bytes)
    }

    private func fixture(base: String) async throws -> CoreFixture {
        let fixture = try await CoreFixture.make()
        _ = try await fixture.repository.perform(["config", "core.autocrlf", "false"])
        try fixture.write("file.txt", base)
        try await fixture.repository.stage(paths: ["file.txt"])
        try await fixture.repository.commit(message: "base")
        return fixture
    }
    private func select(_ patch: GitPatch, matching predicate: (GitDiffLine) -> Bool) -> [Int: Set<Int>] {
        Dictionary(uniqueKeysWithValues: patch.hunks.map { ($0.id, Set($0.lines.filter { $0.isSelectable && predicate($0) }.map(\.id))) })
    }
    private func contents(_ fixture: CoreFixture) async throws -> String {
        try await fixture.repository.run(["show", ":file.txt"]).text
    }
    @Test func missingFinalNewlineReplacementStagesAndUnstagesExactBytes() async throws {
        for (base, changed) in [("old", "new"), ("old", "new\n"), ("old\n", "new"), ("開始\r\n末尾", "開始\r\n変更🙂")] {
            let fixture = try await fixture(base: base)
            defer { fixture.remove() }
            try fixture.write("file.txt", changed)
            let diff = try await fixture.repository.diff(path: "file.txt")
            let patch = GitPatch(diff: diff)
            #expect(patch.canApplyLines)
            try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: select(patch) { $0.isSelectable }, expectedDiff: diff)
            #expect(try await contents(fixture) == changed)
            let staged = try await fixture.repository.diff(path: "file.txt", staged: true)
            try await fixture.repository.applyLines(path: "file.txt", staged: true, selection: select(GitPatch(diff: staged)) { $0.isSelectable }, expectedDiff: staged)
            #expect(try await contents(fixture) == base)
            #expect(try String(contentsOf: fixture.url.appendingPathComponent("file.txt"), encoding: .utf8) == changed)
        }
    }

    @Test func selectionPreservesUnselectedEOFAndRefusesImpossibleAppend() async throws {
        let fixture = try await fixture(base: "start\nold\nend")
        defer { fixture.remove() }
        try fixture.write("file.txt", "start\nnew\nend")
        let diff = try await fixture.repository.diff(path: "file.txt")
        try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: select(GitPatch(diff: diff)) { $0.isSelectable }, expectedDiff: diff)
        #expect(try await contents(fixture) == "start\nnew\nend")
        try fixture.write("file.txt", "start\nnew\nreplacement")
        let endDiff = try await fixture.repository.diff(path: "file.txt")
        await #expect(throws: GitError.self) {
            try await fixture.repository.applyLines(path: "file.txt", staged: false, selection: select(GitPatch(diff: endDiff)) { $0.kind == .addition }, expectedDiff: endDiff)
        }
        #expect(try await contents(fixture) == "start\nnew\nend")
    }

}
