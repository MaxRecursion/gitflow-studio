import AppKit
import SwiftUI

/// Native TextKit 2 editor. Edits are forwarded as UTF-16 deltas so merge decisions
/// can update one region while keeping edits elsewhere in the document intact.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = false
    var selectedRange: NSRange?
    var selectionID: Int?
    var onEdit: ((NSRange, String) -> Void)?
    var accessibilityName = "Code editor"
    var scrollGroup: EditorScrollGroup?
    var highlightedRanges: [NSRange] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 200)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.wantsLayer = true
        scroll.clipsToBounds = true
        scroll.contentView.clipsToBounds = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NSTextView(usingTextLayoutManager: true)
        editor.frame = scroll.contentView.bounds
        editor.wantsLayer = true
        editor.isRichText = false
        editor.isEditable = editable
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.clipsToBounds = true
        editor.textContainerInset = NSSize(width: 12, height: 10)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        // Soft-wrap long lines within each resizable pane.
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(accessibilityName)
        editor.string = text
        scroll.documentView = editor
        let ruler = LineNumberRuler(editor: editor, scroll: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.editor = editor
        context.coordinator.ruler = ruler
        if let scrollGroup {
            scrollGroup.add(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            context.coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll, weak scrollGroup] _ in
                MainActor.assumeIsolated { if let scroll { scrollGroup?.synchronize(from: scroll) } }
            }
        }
        ruler.reindex(text)
        context.coordinator.highlight(initial: true)
        context.coordinator.highlightChanges(highlightedRanges)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isEditable = editable
        let replaced = editor.string != text
        if replaced {
            let previous = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(previous.location, (text as NSString).length), length: 0))
            context.coordinator.ruler?.reindex(text)
            context.coordinator.highlight(initial: true)
        }
        if let selectedRange, (replaced || context.coordinator.lastRequestedRange == nil || selectionID != context.coordinator.lastSelectionID),
           NSMaxRange(selectedRange) <= (text as NSString).length {
            editor.setSelectedRange(selectedRange)
            editor.scrollRangeToVisible(selectedRange)
            context.coordinator.lastRequestedRange = selectedRange
            context.coordinator.lastSelectionID = selectionID
        }
        if replaced || context.coordinator.changeRanges != highlightedRanges { context.coordinator.highlightChanges(highlightedRanges) }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        weak var editor: NSTextView?
        weak var ruler: LineNumberRuler?
        var lastRequestedRange: NSRange?
        var lastSelectionID: Int?
        var scrollObserver: NSObjectProtocol?
        var changeRanges: [NSRange] = []
        init(_ parent: NativeCodeEditor) { self.parent = parent }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let replacementString {
                parent.onEdit?(affectedCharRange, replacementString)
                ruler?.applyEdit(affectedCharRange, replacement: replacementString)
            }
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            if parent.onEdit == nil { parent.text = editor.string }
            ruler?.needsDisplay = true
            highlight()
        }
        private static let syntaxRules: [(NSRegularExpression, NSColor)] = [
            (#"\b(func|let|var|if|else|return|class|struct|import|public|private|const|function|def|async|await|throw|try|enum|case|switch|for|while|true|false|null|nil)\b"#, NSColor.systemPurple),
            (#"\"(?:[^\"\\]|\\.)*\""#, NSColor.systemRed),
            (#"//[^\n]*|#[^\n]*"#, NSColor.secondaryLabelColor)
        ].compactMap { pattern, color in (try? NSRegularExpression(pattern: pattern)).map { ($0, color) } }
        func highlight(initial: Bool = false) {
            guard let editor, let storage = editor.textStorage else { return }
            // Only recolor the edited paragraph. Large documents do not undergo a
            // full syntax pass on each keystroke. This deliberately is not a parser.
            let string = storage.string as NSString
            let selection = min(editor.selectedRange().location, string.length)
            let range = initial && string.length < 200_000 ? NSRange(location: 0, length: string.length) : string.paragraphRange(for: NSRange(location: selection, length: 0))
            guard range.length < 200_000 else { return }
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            for (expression, color) in Self.syntaxRules {
                for match in expression.matches(in: storage.string, range: range) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
            storage.endEditing()
        }
        func highlightChanges(_ ranges: [NSRange]) {
            guard let storage = editor?.textStorage else { return }
            storage.beginEditing()
            for range in changeRanges where NSMaxRange(range) <= storage.length { storage.removeAttribute(.backgroundColor, range: range) }
            for range in ranges where range.location >= 0 && NSMaxRange(range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.22), range: range)
            }
            storage.endEditing()
            changeRanges = ranges
        }
    }
}

/// Proportional source scrolling keeps differently sized versions navigable together.
@MainActor final class EditorScrollGroup {
    private let views = NSHashTable<NSScrollView>.weakObjects()
    private var syncing = false
    var enabled = true
    func add(_ view: NSScrollView) { views.add(view) }
    func synchronize(from source: NSScrollView) {
        guard enabled, !syncing, let document = source.documentView else { return }
        syncing = true
        defer { syncing = false }
        let maximum = max(1, document.bounds.height - source.contentView.bounds.height)
        let fraction = source.contentView.bounds.minY / maximum
        for destination in views.allObjects where destination !== source {
            guard let other = destination.documentView else { continue }
            let y = fraction * max(0, other.bounds.height - destination.contentView.bounds.height)
            guard abs(destination.contentView.bounds.minY - y) > 0.5 || abs(destination.contentView.bounds.minX - source.contentView.bounds.minX) > 0.5 else { continue }
            destination.contentView.scroll(to: NSPoint(x: source.contentView.bounds.minX, y: y))
            destination.reflectScrolledClipView(destination.contentView)
        }
    }
}

@MainActor final class LineNumberRuler: NSRulerView {
    weak var editor: NSTextView?
    var starts = [0]
    init(editor: NSTextView, scroll: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 48
        clipsToBounds = true
    }
    required init(coder: NSCoder) { fatalError("Not used") }
    func reindex(_ text: String) {
        starts = [0]
        for (index, character) in text.utf16.enumerated() where character == 10 { starts.append(index + 1) }
        needsDisplay = true
    }
    func applyEdit(_ range: NSRange, replacement: String) {
        let delta = replacement.utf16.count - range.length
        starts = starts.filter { $0 <= range.location || $0 > NSMaxRange(range) }.map { $0 > NSMaxRange(range) ? $0 + delta : $0 }
        starts += replacement.utf16.enumerated().compactMap { $0.element == 10 ? range.location + $0.offset + 1 : nil }
        starts.sort()
    }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let manager = editor.textLayoutManager, let content = manager.textContentManager else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(rect).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let location = manager.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        manager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var low = 0, high = self.starts.count
            while low < high { let mid = (low + high) / 2; if self.starts[mid] <= offset { low = mid + 1 } else { high = mid } }
            let y = fragment.layoutFragmentFrame.minY + editor.textContainerInset.height - (self.scrollView?.contentView.bounds.minY ?? 0)
            if y > self.bounds.maxY { return false }
            let number = "\(max(1, low))" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            return true
        }
    }
}
