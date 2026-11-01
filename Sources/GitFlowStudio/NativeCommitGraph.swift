import AppKit
import SwiftUI

/// Core Graphics keeps graph rows usable on Macs/VMs without a Metal device.
/// A SwiftUI Canvas can enter Metal's shader loader even for these simple paths.
struct NativeCommitGraph: NSViewRepresentable {
    let row: CommitGraph.Row
    let colors: [Color]
    var laneSpacing: CGFloat = 14
    var laneInset: CGFloat = 8
    var lineOpacity: CGFloat = 0.6
    var lineWidth: CGFloat = 1.7
    var nodeOutline: Color?
    var nodeOutlineWidth: CGFloat = 1

    func makeNSView(context: Context) -> GraphDrawingView {
        let view = GraphDrawingView()
        view.setAccessibilityElement(false)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GraphDrawingView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 40, height: proposal.height ?? 60)
    }

    func updateNSView(_ view: GraphDrawingView, context: Context) {
        view.row = row
        view.colors = colors.map { NSColor($0) }
        view.laneSpacing = laneSpacing; view.laneInset = laneInset
        view.lineOpacity = lineOpacity; view.lineWidth = lineWidth
        view.nodeOutline = nodeOutline.map { NSColor($0) }
        view.nodeOutlineWidth = nodeOutlineWidth
        view.needsDisplay = true
    }

    final class GraphDrawingView: NSView {
        var row: CommitGraph.Row?
        var colors: [NSColor] = []
        var laneSpacing: CGFloat = 14
        var laneInset: CGFloat = 8
        var lineOpacity: CGFloat = 0.6
        var lineWidth: CGFloat = 1.7
        var nodeOutline: NSColor?
        var nodeOutlineWidth: CGFloat = 1
        override var isFlipped: Bool { true }
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let row, !colors.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            defer { context.restoreGState() }
            context.clear(bounds)
            context.setLineWidth(lineWidth)
            let mid = bounds.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane) * laneSpacing + laneInset }
            func color(_ lane: Int) -> NSColor { colors[abs(lane % colors.count)] }
            for lane in row.before {
                context.setStrokeColor(color(lane).withAlphaComponent(lineOpacity).cgColor)
                context.move(to: CGPoint(x: x(lane), y: 0))
                context.addLine(to: CGPoint(x: x(lane), y: mid))
                context.strokePath()
            }
            for edge in row.edges {
                context.setStrokeColor(color(edge.from).withAlphaComponent(lineOpacity).cgColor)
                context.move(to: CGPoint(x: x(edge.from), y: mid))
                context.addCurve(to: CGPoint(x: x(edge.to), y: bounds.height),
                                 control1: CGPoint(x: x(edge.from), y: bounds.height * 0.8),
                                 control2: CGPoint(x: x(edge.to), y: bounds.height * 0.8))
                context.strokePath()
            }
            let circle = CGRect(x: x(row.lane) - 4, y: mid - 4, width: 8, height: 8)
            context.setFillColor(color(row.lane).cgColor)
            context.fillEllipse(in: circle)
            if let nodeOutline {
                context.setStrokeColor(nodeOutline.cgColor)
                context.setLineWidth(nodeOutlineWidth)
                context.strokeEllipse(in: circle)
            }
        }
    }
}
