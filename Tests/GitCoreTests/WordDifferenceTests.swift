import Foundation
import Testing
@testable import GitCore

@Test func wordChangesAreBoundedAndRespectUTF16() {
    let before = "let café = \"🐈 30\"\r\n"
    let after = "let café = \"🐈 60\"\r\n"
    let result = WordDifference.compare(current: before, incoming: after)
    #expect(!result.wasLimited)
    #expect(result.current.map { (before as NSString).substring(with: $0) } == ["30"])
    #expect(result.incoming.map { (after as NSString).substring(with: $0) } == ["60"])
    #expect(WordDifference.compare(current: before, incoming: after, tokenLimit: 1).wasLimited)
    #expect(WordDifference.locateUnique("30", in: "30 then 30", ranges: [NSRange(location: 0, length: 2)]).isEmpty)
    #expect(WordDifference.locateUnique("30", in: "prefix 30", ranges: [NSRange(location: 0, length: 2)]).first?.location == 7)
}
