import SwiftUI
import AppKit

/// Shared, appearance-aware surfaces for the native workspaces.
enum StudioTheme {
    static let accent = color("StudioAccent", light: (0.38, 0.26, 0.75), dark: (0.73, 0.65, 1.0))
    static let canvas = color("StudioCanvas", light: (0.96, 0.97, 0.985), dark: (0.075, 0.085, 0.105))
    static let surface = color("StudioSurface", light: (0.99, 0.992, 1.0), dark: (0.105, 0.12, 0.15))
    static let elevated = color("StudioElevated", light: (1.0, 1.0, 1.0), dark: (0.135, 0.15, 0.185))
    static let border = Color.primary.opacity(0.10)
    static let success = color("StudioSuccess", light: (0.12, 0.44, 0.33), dark: (0.51, 0.84, 0.69))

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private static func color(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }
}

struct StudioBadge: View {
    let title: String
    let systemImage: String?
    let tint: Color

    init(_ title: String, systemImage: String? = nil, tint: Color = .accentColor) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

struct StudioFileIcon: View {
    let path: String

    private var appearance: (symbol: String, tint: Color) {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return ("swift", .orange)
        case "js", "jsx", "ts", "tsx", "rs", "py", "go", "c", "h", "cpp":
            return ("chevron.left.forwardslash.chevron.right", StudioTheme.accent)
        case "css", "scss", "sass": return ("paintpalette", .purple)
        case "json", "yaml", "yml", "toml", "plist": return ("curlybraces", .orange)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "icns": return ("photo", .teal)
        case "md", "txt", "rst": return ("doc.text", .blue)
        default: return ("doc", .secondary)
        }
    }

    var body: some View {
        Image(systemName: appearance.symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(appearance.tint)
            .frame(width: 30, height: 34)
            .background(appearance.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}
