import Foundation

public enum MergeChoice: String, Sendable, CaseIterable { case current, incoming, both, manual, unresolved }

public struct MergeRegion: Identifiable, Sendable {
    public let id: Int
    public var range: NSRange
    public internal(set) var current: String
    public internal(set) var base: String
    public internal(set) var incoming: String
    public var choice: MergeChoice
    public var supportsChoices = true
}

/// UTF-16 ranges match TextKit edits. Replacing one region never rebuilds unrelated text.
public struct MergeDocument: Sendable {
    public private(set) var text: String
    public private(set) var regions: [MergeRegion]
    public var remaining: Int { regions.filter { $0.choice == .unresolved }.count }

    public init(text: String, regions: [MergeRegion] = []) {
        self.text = text
        self.regions = regions
    }

    public mutating func choose(_ choice: MergeChoice, region id: Int) {
        guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
        guard regions[index].supportsChoices || choice == .manual else { return }
        let region = regions[index]
        let replacement: String
        switch choice {
        case .current, .unresolved: replacement = region.current
        case .incoming: replacement = region.incoming
        case .both:
            let separator = !region.current.isEmpty && !region.incoming.isEmpty && !region.current.hasSuffix("\n") ? (region.incoming.contains("\r\n") ? "\r\n" : "\n") : ""
            replacement = region.current + separator + region.incoming
        case .manual: regions[index].choice = .manual; return
        }
        replace(range: region.range, with: replacement, resolving: index)
        regions[index].choice = choice
    }

    public mutating func edit(range: NSRange, replacement: String) {
        replace(range: range, with: replacement, resolving: nil)
    }

    private mutating func replace(range: NSRange, with replacement: String, resolving: Int?) {
        let oldLength = (text as NSString).length
        guard range.location >= 0, NSMaxRange(range) <= oldLength else { return }
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        let length = (replacement as NSString).length
        let delta = length - range.length
        for index in regions.indices {
            let old = regions[index].range
            if index == resolving {
                regions[index].range.length = length
            } else if old.location >= NSMaxRange(range) && !(range.length == 0 && old.location == range.location) {
                regions[index].range.location += delta
            } else if NSMaxRange(old) <= range.location {
                continue
            } else {
                // Manual edits that intersect a region become an explicit manual resolution.
                let start = min(old.location, range.location)
                let end = max(range.location + length, NSMaxRange(old) + delta)
                regions[index].range = NSRange(location: start, length: max(0, end - start))
                regions[index].choice = .manual
                if range.location < old.location || NSMaxRange(range) > NSMaxRange(old) {
                    regions[index].supportsChoices = false
                }
            }
        }
    }

    /// Parse only markers from our isolated `git merge-file` invocation, never repository state.
    static func parse(_ merged: String, currentLabel: String, baseLabel: String, incomingLabel: String, markerSize: Int) throws -> MergeDocument {
        let start = String(repeating: "<", count: markerSize) + " " + currentLabel
        let ancestor = String(repeating: "|", count: markerSize) + " " + baseLabel
        let divider = String(repeating: "=", count: markerSize)
        let end = String(repeating: ">", count: markerSize) + " " + incomingLabel
        // Split bytes' LF separator, not Swift Characters (CRLF is a single Character).
        let lines = merged.components(separatedBy: "\n")
        var result = "", current = "", base = "", incoming = ""
        var regions: [MergeRegion] = []
        enum State { case normal, current, base, incoming }
        var state = State.normal
        for (index, raw) in lines.enumerated() {
            let line = String(raw) + (index < lines.count - 1 ? "\n" : "")
            let comparison = String(raw).trimmingCharacters(in: .newlines)
            switch state {
            case .normal:
                if comparison == start { state = .current; current = ""; base = ""; incoming = "" }
                else { result += line }
            case .current:
                if comparison == ancestor { state = .base } else { current += line }
            case .base:
                if comparison == divider { state = .incoming } else { base += line }
            case .incoming:
                if comparison == end {
                    let range = NSRange(location: (result as NSString).length, length: (current as NSString).length)
                    regions.append(MergeRegion(id: regions.count, range: range, current: current, base: base, incoming: incoming, choice: .unresolved))
                    result += current
                    state = .normal
                } else { incoming += line }
            }
        }
        guard state == .normal else { throw ConflictError.invalidMergeOutput }
        return MergeDocument(text: result, regions: regions)
    }

    /// merge-file adds a separator newline before conflict markers at EOF. Remove
    /// only that synthetic terminator when the corresponding original has none.
    mutating func restoreTerminalNewlines(current: String, base: String, incoming: String) {
        guard let last = regions.indices.last, NSMaxRange(regions[last].range) == (text as NSString).length else { return }
        func restored(_ region: String, source: String) -> String {
            guard !source.isEmpty, !source.hasSuffix("\n"), region.hasSuffix("\n") else { return region }
            let candidate = String(region.dropLast())
            return source.hasSuffix(candidate) ? candidate : region
        }
        let newCurrent = restored(regions[last].current, source: current)
        regions[last].base = restored(regions[last].base, source: base)
        regions[last].incoming = restored(regions[last].incoming, source: incoming)
        let range = regions[last].range
        regions[last].current = newCurrent
        text = (text as NSString).replacingCharacters(in: range, with: newCurrent)
        regions[last].range.length = (newCurrent as NSString).length
    }

    mutating func useCRLF() {
        func converted(_ value: String) -> String { value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") }
        let old = text as NSString
        let boundaries = Set(regions.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
        var locations: [Int: Int] = [:], previous = 0, convertedOffset = 0
        for boundary in boundaries {
            convertedOffset += (converted(old.substring(with: NSRange(location: previous, length: boundary - previous))) as NSString).length
            locations[boundary] = convertedOffset
            previous = boundary
        }
        for index in regions.indices {
            let start = locations[regions[index].range.location]!, end = locations[NSMaxRange(regions[index].range)]!
            regions[index].range = NSRange(location: start, length: end - start)
            regions[index].current = converted(regions[index].current)
            regions[index].base = converted(regions[index].base)
            regions[index].incoming = converted(regions[index].incoming)
        }
        text = converted(text)
    }
}
