import Foundation

/// Bounded lexical comparison. It describes text changes, never code semantics.
public struct WordDifference: Sendable {
    public let current: [NSRange]
    public let incoming: [NSRange]
    public let wasLimited: Bool

    public static func compare(current: String, incoming: String, tokenLimit: Int = 2_000) -> WordDifference {
        guard current.utf8.count <= 100_000, incoming.utf8.count <= 100_000,
              let pattern = try? NSRegularExpression(pattern: #"\s+|\w+|[^\w\s]"#) else {
            return WordDifference(current: [], incoming: [], wasLimited: true)
        }
        func tokens(_ value: String) -> [(String, NSRange)] {
            let text = value as NSString
            return pattern.matches(in: value, range: NSRange(location: 0, length: text.length)).map { (text.substring(with: $0.range), $0.range) }
        }
        let old = tokens(current), new = tokens(incoming)
        guard old.count <= tokenLimit, new.count <= tokenLimit else { return WordDifference(current: [], incoming: [], wasLimited: true) }
        let changes = new.map(\.0).difference(from: old.map(\.0))
        var removals: [NSRange] = [], additions: [NSRange] = []
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removals.append(old[offset].1)
            case .insert(let offset, _, _): additions.append(new[offset].1)
            }
        }
        return WordDifference(current: removals.sorted { $0.location < $1.location }, incoming: additions.sorted { $0.location < $1.location }, wasLimited: false)
    }

    /// Avoid claiming a location when repeated text makes the source mapping ambiguous.
    public static func locateUnique(_ fragment: String, in source: String, ranges: [NSRange]) -> [NSRange] {
        guard !fragment.isEmpty else { return [] }
        let text = source as NSString
        let first = text.range(of: fragment)
        guard first.location != NSNotFound else { return [] }
        let remainder = NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first))
        guard text.range(of: fragment, range: remainder).location == NSNotFound else { return [] }
        return ranges.compactMap { range in
            guard range.location >= 0, NSMaxRange(range) <= (fragment as NSString).length else { return nil }
            return NSRange(location: first.location + range.location, length: range.length)
        }
    }
}
