import Foundation
import Darwin
import Testing
@testable import GitCore

struct PathEncodingTests {
    @Test func repositoryPathsEndingInControlNewlinesRemainExact() async throws {
        for suffix in ["\r", "\n", "\r\n"] {
            let fixture = try await CoreFixture.make()
            defer { fixture.remove() }
            let destination = fixture.root.appendingPathComponent("repository" + suffix)
            try FileManager.default.moveItem(at: fixture.url, to: destination)
            let reopened = try await GitRepository.open(destination)
            #expect(reopened.url.path.utf8.elementsEqual(destination.resolvingSymlinksInPath().path.utf8))
            _ = try await reopened.perform(["config", "gitflow.path-test", "exact"])
            #expect(try await reopened.run(["config", "gitflow.path-test"]).text == "exact\n")
        }
    }
    private static let hash = String(repeating: "a", count: 40)
    private static let invalidSequences: [[UInt8]] = [
        [0xff],             // An invalid leading byte.
        [0xc0, 0xaf],       // An overlong UTF-8 encoding.
        [0xed, 0xa0, 0x80], // A UTF-16 surrogate encoded as UTF-8.
        [0xf0, 0x9f, 0x92]  // A truncated four-byte character.
    ]

    @Test func statusRejectsInvalidUTF8InEveryPathBearingRecord() throws {
        let prefixes = [
            "? ",
            "1 .M N... 100644 100644 100644 \(Self.hash) \(Self.hash) ",
            "2 R. N... 100644 100644 100644 \(Self.hash) \(Self.hash) R100 ",
            "u UU N... 100644 100644 100644 100644 \(Self.hash) \(Self.hash) \(Self.hash) "
        ]
        for sequence in Self.invalidSequences {
            for prefix in prefixes {
                var output = Data((prefix + "unsafe-").utf8)
                output.append(contentsOf: sequence)
                output.append(contentsOf: Data(".txt\0".utf8))
                if prefix.hasPrefix("2 ") { output.append(Data("original.txt\0".utf8)) }
                #expect(throws: GitError.self) { try GitStatusParser.parse(output) }
            }
        }
    }

    @Test func strictGitOutputPreservesValidTextAndRejectsLossyIdentifiers() throws {
        let valid = "repository-with-a-final-newline\n\n"
        let output = GitOutput(stdout: Data(valid.utf8), stderr: Data(), exitCode: 0)
        #expect(try output.strictText(context: "Repository path") == valid)
        let invalid = GitOutput(stdout: Data([0xff]), stderr: Data(), exitCode: 0)
        #expect(throws: GitError.self) { try invalid.strictText(context: "Repository path") }
    }

    @Test func renameOriginIsStrictEvenWhenDestinationIsValid() throws {
        var output = Data("2 R. N... 100644 100644 100644 \(Self.hash) \(Self.hash) R100 destination.txt\0source-".utf8)
        output.append(0xff)
        output.append(Data(".txt\0".utf8))
        #expect(throws: GitError.self) { try GitStatusParser.parse(output) }
    }

    @Test func literalReplacementCharacterAndUnicodeRemainValidPaths() throws {
        // U+FFFD itself is a legal filename. Rejecting invalid bytes must not
        // reject its correct three-byte UTF-8 spelling or normalize other paths.
        let names = ["unsafe-\u{fffd}.txt", "日本語 café\tline\nbreak.txt", "emoji-🧑🏽‍💻.txt"]
        for name in names {
            let status = try GitStatusParser.parse(Data(("? " + name + "\0").utf8))
            #expect(status.files.count == 1)
            #expect(status.files.first?.path.utf8.elementsEqual(name.utf8) == true)
            let stages = try ConflictService.parseStages(Data(("100644 " + Self.hash + " 2\t" + name + "\0").utf8))
            #expect(stages.count == 1)
            #expect(stages.first?.path.utf8.elementsEqual(name.utf8) == true)
        }
    }

    @Test func conflictsRejectInvalidPathsBeforeReturningAnyPartialSnapshot() throws {
        let valid = Data("100644 \(Self.hash) 2\tunsafe-\u{fffd}.txt\0".utf8)
        for sequence in Self.invalidSequences {
            var output = valid
            output.append(Data("100644 \(Self.hash) 3\tunsafe-".utf8))
            output.append(contentsOf: sequence)
            output.append(Data(".txt\0".utf8))
            #expect(throws: GitError.self) { try ConflictService.parseStages(output) }
        }
        #expect(throws: GitError.self) { try ConflictService.parseStages(Data("malformed\0".utf8)) }
    }

    @Test func invalidGitIndexPathCannotAliasOrOverwriteReplacementCharacterFile() async throws {
        let fixture = try await CoreFixture.make()
        defer { fixture.remove() }
        let validName = "unsafe-\u{fffd}.txt"
        try fixture.write(validName, "tracked original\n")
        try await fixture.repository.stage(paths: [validName])
        try await fixture.repository.commit(message: "Protect the distinct UTF-8 path")
        let userContent = Data("Keep this uncommitted work exactly.\r\n".utf8)
        let validURL = fixture.url.appendingPathComponent(validName)
        try userContent.write(to: validURL)

        var invalidName = Data("unsafe-".utf8)
        invalidName.append(0xff)
        invalidName.append(Data(".txt".utf8))
        // APFS on current macOS rejects this with EILSEQ. On a filesystem that
        // accepts byte paths, also materialize the separate file and preserve it.
        var rawPath = Array((fixture.url.path + "/").utf8) + Array(invalidName) + [0]
        let descriptor = rawPath.withUnsafeMutableBytes { bytes in
            Darwin.open(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), O_WRONLY | O_CREAT | O_EXCL, 0o600)
        }
        let createError = errno
        let rawContent = Data("invalid-byte-path content\n".utf8)
        if descriptor >= 0 {
            let written = rawContent.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            Darwin.close(descriptor)
            #expect(written == rawContent.count)
        } else {
            #expect(createError == EILSEQ)
        }
        defer {
            if descriptor >= 0 {
                _ = rawPath.withUnsafeMutableBytes { Darwin.unlink($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            }
        }

        let blobOutput = try await fixture.runner.run(["hash-object", "-w", "--stdin"], in: fixture.url, input: rawContent)
        let blob = blobOutput.text.trimmingCharacters(in: .newlines)
        var stageZero = Data("100644 \(blob)\t".utf8)
        stageZero.append(invalidName); stageZero.append(0)
        _ = try await fixture.repository.perform(["update-index", "-z", "--index-info"], input: stageZero)
        await #expect(throws: GitError.self) { try await fixture.repository.status() }
        #expect(try Data(contentsOf: validURL) == userContent)
        #expect(try await fixture.repository.run(["show", ":" + validName]).text == "tracked original\n")

        // The index accepts byte paths even if the filesystem cannot create
        // them. Exercise the real Git unmerged-index output in either case.
        var stages = Data("0 \(String(repeating: "0", count: 40))\t".utf8)
        stages.append(invalidName); stages.append(0)
        for stage in 1...3 {
            stages.append(Data("100644 \(blob) \(stage)\t".utf8))
            stages.append(invalidName); stages.append(0)
        }
        _ = try await fixture.repository.perform(["update-index", "-z", "--index-info"], input: stages)
        let indexBefore = try await fixture.repository.run(["ls-files", "--stage", "-z"]).stdout
        let rawUnmerged = try await fixture.repository.run(["ls-files", "-u", "-z"]).stdout
        #expect(rawUnmerged.contains(0xff))
        let service = ConflictService(repository: fixture.repository)
        await #expect(throws: GitError.self) { try await service.overview() }
        await #expect(throws: GitError.self) { try await service.load(path: validName) }
        #expect(try await fixture.repository.run(["ls-files", "--stage", "-z"]).stdout == indexBefore)
        #expect(try Data(contentsOf: validURL) == userContent)
        #expect(try await fixture.repository.run(["show", ":" + validName]).text == "tracked original\n")
        if descriptor >= 0 {
            let readDescriptor = rawPath.withUnsafeMutableBytes { Darwin.open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_RDONLY) }
            try #require(readDescriptor >= 0)
            defer { Darwin.close(readDescriptor) }
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(readDescriptor, $0.baseAddress!, $0.count) }
            #expect(count == rawContent.count)
            #expect(Data(bytes.prefix(max(0, count))) == rawContent)
        }
    }
}
