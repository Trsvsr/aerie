import SwiftUI

/// Per-tool logo badge, tinted by session state so the status signal
/// survives the swap from colored dots to logos. Unknown sources fall back
/// to a plain dot.
struct SourceBadge: View {
    let source: String
    let state: AggregateState
    var size: CGFloat = 11
    @State private var pulsing = false

    /// Brand color the tool wears while working; red/gray states override
    /// so the status language stays consistent across tools.
    static func brandColor(_ source: String) -> Color {
        switch source {
        case "claude": return Color(red: 0.85, green: 0.44, blue: 0.24)  // Anthropic coral
        case "codex": return Color(white: 0.92)                          // OpenAI white
        case "antigravity", "gemini":
            return Color(red: 0.31, green: 0.55, blue: 0.96)             // Google blue
        case "cursor": return Color(white: 0.85)                         // Cursor mono
        default: return .orange
        }
    }

    private var tint: Color {
        switch state {
        case .needsInput: return .red
        case .working: return Self.brandColor(source)
        case .off: return .gray.opacity(0.5)
        }
    }

    var body: some View {
        Group {
            switch source {
            case "claude":
                SVGShape(pathData: SourceBadge.claudeMarkPath, viewBox: 100)
                    .fill(tint)
            case "codex":
                SVGShape(pathData: SourceBadge.openAIMarkPath, viewBox: 320)
                    .fill(tint, style: FillStyle(eoFill: true))
            case "antigravity":
                SVGShape(pathData: SourceBadge.antigravityMarkPath, viewBox: 92,
                         origin: CGPoint(x: 9.8, y: 18.4))
                    .fill(tint)
            case "gemini":
                SVGShape(pathData: SourceBadge.geminiMarkPath, viewBox: 52,
                         origin: CGPoint(x: 210.6, y: 0.2))
                    .fill(tint)
            case "cursor":
                CursorCubeShape()
                    .fill(tint, style: FillStyle(eoFill: true))
            default:
                Circle()
                    .fill(tint)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        .opacity(state == .needsInput && pulsing ? 0.3 : 1)
        .animation(
            state == .needsInput
                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                : .default,
            value: pulsing)
        .onAppear { pulsing = true }
    }
}

/// Cursor's isometric cube mark, drawn as a vector (the official site only
/// serves raster-pattern SVGs): hexagon outline with the three visible faces
/// hinted by inner edges from the center.
struct CursorCubeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        // flat-top hexagon vertices, starting at top
        let pts = (0..<6).map { i -> CGPoint in
            let a = CGFloat(i) * .pi / 3 - .pi / 2
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        let inner = r * 0.14  // stroke-ish thickness for the face edges
        // outer hexagon
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        // punch out three inner kite-shaped faces to suggest the cube:
        // top face (between top-left, top, top-right, center)
        var top = Path()
        top.move(to: CGPoint(x: pts[5].x + inner, y: pts[5].y + inner))
        top.addLine(to: CGPoint(x: pts[0].x, y: pts[0].y + inner * 1.4))
        top.addLine(to: CGPoint(x: pts[1].x - inner, y: pts[1].y + inner))
        top.addLine(to: CGPoint(x: c.x, y: c.y - inner * 0.4))
        top.closeSubpath()
        // lower-left face
        var left = Path()
        left.move(to: CGPoint(x: pts[5].x + inner, y: pts[5].y + inner * 2))
        left.addLine(to: CGPoint(x: c.x - inner * 0.8, y: c.y + inner * 0.6))
        left.addLine(to: CGPoint(x: c.x - inner * 0.8, y: pts[3].y - inner * 1.2))
        left.addLine(to: CGPoint(x: pts[4].x + inner, y: pts[4].y - inner))
        left.closeSubpath()
        // lower-right face
        var right = Path()
        right.move(to: CGPoint(x: pts[1].x - inner, y: pts[1].y + inner * 2))
        right.addLine(to: CGPoint(x: c.x + inner * 0.8, y: c.y + inner * 0.6))
        right.addLine(to: CGPoint(x: c.x + inner * 0.8, y: pts[3].y - inner * 1.2))
        right.addLine(to: CGPoint(x: pts[2].x - inner, y: pts[2].y - inner))
        right.closeSubpath()
        p.addPath(top)
        p.addPath(left)
        p.addPath(right)
        return p
    }
}

extension SourceBadge {
    /// OpenAI knot mark (Wikimedia ChatGPT_logo.svg, viewBox 0 0 320 320).
    static let openAIMarkPath = "m297.06 130.97c7.26-21.79 4.76-45.66-6.85-65.48-17.46-30.4-52.56-46.04-86.84-38.68-15.25-17.18-37.16-26.95-60.13-26.81-35.04-.08-66.13 22.48-76.91 55.82-22.51 4.61-41.94 18.7-53.31 38.67-17.59 30.32-13.58 68.54 9.92 94.54-7.26 21.79-4.76 45.66 6.85 65.48 17.46 30.4 52.56 46.04 86.84 38.68 15.24 17.18 37.16 26.95 60.13 26.8 35.06.09 66.16-22.49 76.94-55.86 22.51-4.61 41.94-18.7 53.31-38.67 17.57-30.32 13.55-68.51-9.94-94.51zm-120.28 168.11c-14.03.02-27.62-4.89-38.39-13.88.49-.26 1.34-.73 1.89-1.07l63.72-36.8c3.26-1.85 5.26-5.32 5.24-9.07v-89.83l26.93 15.55c.29.14.48.42.52.74v74.39c-.04 33.08-26.83 59.9-59.91 59.97zm-128.84-55.03c-7.03-12.14-9.56-26.37-7.15-40.18.47.28 1.3.79 1.89 1.13l63.72 36.8c3.23 1.89 7.23 1.89 10.47 0l77.79-44.92v31.1c.02.32-.13.63-.38.83l-64.41 37.19c-28.69 16.52-65.33 6.7-81.92-21.95zm-16.77-139.09c7-12.16 18.05-21.46 31.21-26.29 0 .55-.03 1.52-.03 2.2v73.61c-.02 3.74 1.98 7.21 5.23 9.06l77.79 44.91-26.93 15.55c-.27.18-.61.21-.91.08l-64.42-37.22c-28.63-16.58-38.45-53.21-21.95-81.89zm221.26 51.49-77.79-44.92 26.93-15.54c.27-.18.61-.21.91-.08l64.42 37.19c28.68 16.57 38.51 53.26 21.94 81.94-7.01 12.14-18.05 21.44-31.2 26.28v-75.81c.03-3.74-1.96-7.2-5.2-9.06zm26.8-40.34c-.47-.29-1.3-.79-1.89-1.13l-63.72-36.8c-3.23-1.89-7.23-1.89-10.47 0l-77.79 44.92v-31.1c-.02-.32.13-.63.38-.83l64.41-37.16c28.69-16.55 65.37-6.7 81.91 22 6.99 12.12 9.52 26.31 7.15 40.1zm-168.51 55.43-26.94-15.55c-.29-.14-.48-.42-.52-.74v-74.39c.02-33.12 26.89-59.96 60.01-59.94 14.01 0 27.57 4.92 38.34 13.88-.49.26-1.33.73-1.89 1.07l-63.72 36.8c-3.26 1.85-5.26 5.31-5.24 9.06l-.04 89.79zm14.63-31.54 34.65-20.01 34.65 20v40.01l-34.65 20-34.65-20z"

    /// Gemini four-point star glyph extracted from the Wikimedia
    /// Google_Gemini_logo.svg wordmark (star spans ~52pt at x≈211,y≈0).
    static let geminiMarkPath = "M234.123 41.2204C235.489 44.3354 236.172 47.6638 236.172 51.2055C236.172 47.6638 236.833 44.3354 238.156 41.2204C239.521 38.1054 241.356 35.3958 243.66 33.0916C245.965 30.7873 248.674 28.9738 251.789 27.651C254.904 26.2855 258.233 25.6028 261.774 25.6028C258.233 25.6028 254.904 24.9414 251.789 23.6185C248.674 22.2531 245.965 20.4182 243.66 18.114C241.356 15.8097 239.521 13.1001 238.156 9.98507C236.833 6.87007 236.172 3.54171 236.172 0C236.172 3.54171 235.489 6.87007 234.123 9.98507C232.801 13.1001 230.987 15.8097 228.683 18.114C226.379 20.4182 223.669 22.2531 220.554 23.6185C217.439 24.9414 214.111 25.6028 210.569 25.6028C214.111 25.6028 217.439 26.2855 220.554 27.651C223.669 28.9738 226.379 30.7873 228.683 33.0916C230.987 35.3958 232.801 38.1054 234.123 41.2204Z"

    /// Google Antigravity "A" arch, the primary glyph of the official logo
    /// (Wikimedia Commons "Google Antigravity Logo.svg", glyph spans
    /// x 9.8–101.4, y 18.4–97.2 → viewBox 92 with origin offset).
    static let antigravityMarkPath = "M89.6992 93.695C94.3659 97.195 101.366 94.8617 94.9492 88.445C75.6992 69.7783 79.7825 18.445 55.8659 18.445C31.9492 18.445 36.0325 69.7783 16.7825 88.445C9.78251 95.445 17.3658 97.195 22.0325 93.695C40.1159 81.445 38.9492 59.8617 55.8659 59.8617C72.7825 59.8617 71.6159 81.445 89.6992 93.695Z"

    /// Official Claude AI symbol, path data from the Wikimedia Commons SVG
    /// (viewBox 0 0 100 100), CC — Anthropic brand mark.
    static let claudeMarkPath = "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"
}
