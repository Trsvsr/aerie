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
        case "opencode": return Color(red: 0.99, green: 0.87, blue: 0.32) // opencode gold
        case "pi": return Color(red: 0.62, green: 0.55, blue: 0.98)      // Pi violet
        case "copilot": return Color(red: 0.55, green: 0.76, blue: 0.98) // GitHub blue
        case "amp": return Color(red: 0.95, green: 0.35, blue: 0.25)     // Amp red-orange
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
            case "copilot":
                SVGShape(pathData: SourceBadge.copilotMarkPath, viewBox: 48,
                         origin: CGPoint(x: 1, y: 1))
                    .fill(tint, style: FillStyle(eoFill: true))
            case "amp":
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.9, weight: .semibold))
                    .foregroundStyle(tint)
            case "opencode":
                // two-tone like the original mark: bright outer frame,
                // dimmed inner block — opacities of the tint so state
                // colors (red pulse, idle gray) still read
                ZStack {
                    SVGShape(pathData: SourceBadge.opencodeFramePath, viewBox: 320,
                             origin: CGPoint(x: 96, y: 96))
                        .fill(tint, style: FillStyle(eoFill: true))
                    SVGShape(pathData: SourceBadge.opencodeBlockPath, viewBox: 320,
                             origin: CGPoint(x: 96, y: 96))
                        .fill(tint.opacity(0.45))
                }
            case "pi":
                SVGShape(pathData: SourceBadge.piMarkPath, viewBox: 470,
                         origin: CGPoint(x: 165.29, y: 165.29))
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

    /// opencode terminal-frame mark (opencode.ai favicon), two layers:
    /// outer frame (even-odd hollows the center) and the dimmer inner block.
    /// Glyph spans 128–384 of the 512 viewBox → viewBox 320, origin 96/96.
    static let opencodeFramePath = "M384 416H128V96H384V416ZM320 160H192V352H320V160Z"
    static let opencodeBlockPath = "M320 224V352H192V224H320Z"

    /// Pi coding agent mark (pi.dev favicon): blocky π glyph, spans
    /// 165.29–634.72 → viewBox ~470 with origin offset.
    static let piMarkPath = "M165.29 165.29 H517.36 V400 H400 V517.36 H282.65 V634.72 H165.29 Z M282.65 282.65 V400 H400 V282.65 Z M517.36 400 H634.72 V634.72 H517.36 Z"

    /// GitHub Copilot mark (Wikimedia "GitHub_Copilot_(2025).svg" icon
    /// glyph, spans ~1-49 of the wordmark's viewBox): goggled head; eyes
    /// and mouth marks combine with the head outline under even-odd fill.
    static let copilotMarkPath = "M29.8768 25.3531C30.9809 25.3531 31.876 26.2481 31.876 27.3522V31.3505C31.876 32.4545 30.9809 33.3496 29.8768 33.3496C28.7727 33.3496 27.8777 32.4545 27.8777 31.3505V27.3522C27.8777 26.2481 28.7727 25.3531 29.8768 25.3531Z M21.8803 27.3522C21.8803 26.2481 20.9852 25.3531 19.8812 25.3531C18.7771 25.3531 17.882 26.2481 17.882 27.3522V31.3505C17.882 32.4545 18.7771 33.3496 19.8812 33.3496C20.9852 33.3496 21.8803 32.4545 21.8803 31.3505V27.3522Z M48.6801 30.8403C46.9603 33.8278 36.974 40.8772 24.8601 40.8772C12.7462 40.8772 2.75994 33.8278 1.04014 30.8403C0.914376 30.6218 0.873779 30.3723 0.873779 30.1202V24.8018C0.873779 24.5813 0.907813 24.3622 0.989389 24.1574C1.73309 22.2899 3.68082 19.5773 6.19449 18.8495C6.52774 17.994 7.02133 16.7433 7.48186 15.8201C7.40477 15.1138 7.37764 14.3853 7.37764 13.6492C7.37764 10.99 7.9413 8.65743 9.63975 6.92044C10.433 6.10915 11.4174 5.48684 12.5847 5.01903C15.3805 2.74775 19.3616 0.837036 24.8169 0.837036C30.2723 0.837036 34.3398 2.74775 37.1355 5.01903C38.3028 5.48684 39.2872 6.10915 40.0805 6.92044C41.7789 8.65743 42.3426 10.99 42.3426 13.6492C42.3426 14.3853 42.3154 15.1138 42.2384 15.8201C42.6989 16.7433 43.1925 17.994 43.5257 18.8495C46.0394 19.5773 47.9871 22.2899 48.7308 24.1574C48.8124 24.3622 48.8464 24.5813 48.8464 24.8018V30.1202C48.8464 30.3723 48.8058 30.6218 48.6801 30.8403ZM26.485 13.0046C26.4 12.3422 26.3595 11.749 26.3584 11.2191L26.3584 11.1772C26.361 9.63975 26.6971 8.63938 27.2339 8.02499C27.9156 7.2448 29.3246 6.64707 32.2941 6.96844C35.3026 7.29402 36.9842 8.04072 37.9376 9.01574C38.8606 9.95971 39.3455 11.372 39.3455 13.6492C39.3455 16.0687 38.9969 17.4982 38.2302 18.3678C37.5012 19.1946 36.0656 19.8674 32.9214 19.8674C30.5041 19.8674 29.1221 19.0812 28.2386 17.9939C27.2899 16.8264 26.7559 15.1161 26.485 13.0046ZM23.2353 13.0046C23.3203 12.3422 23.3607 11.749 23.3619 11.2191L23.3619 11.1772C23.3592 9.63974 23.0232 8.63937 22.4863 8.02498C21.8046 7.24479 20.3957 6.64707 17.4261 6.96843C14.4176 7.29402 12.736 8.04071 11.7826 9.01573C10.8596 9.9597 10.3747 11.372 10.3747 13.6492C10.3747 16.0687 10.7234 17.4982 11.49 18.3677C12.219 19.1946 13.6546 19.8674 16.7989 19.8674C19.2161 19.8674 20.5981 19.0812 21.4816 17.9939C22.4304 16.8264 22.9643 15.1161 23.2353 13.0046ZM25.2042 18.8676L25.0543 18.8676C24.8715 18.8678 24.6005 18.868 24.516 18.8676C24.3045 19.2218 24.0693 19.5618 23.8075 19.884C22.2697 21.7764 19.9741 22.8644 16.7988 22.8644C13.3524 22.8644 10.8266 22.1471 9.24196 20.3498C9.15187 20.2476 9.07125 20.1406 9.07125 20.1406L8.87613 20.3498V33.5049C11.7429 35.0628 17.8959 37.8586 24.8601 37.8586C31.8243 37.8586 37.9773 35.0628 40.8441 33.5049V20.3498L40.649 20.1406C40.649 20.1406 40.5829 20.231 40.4783 20.3498C38.8936 22.1471 36.3678 22.8644 32.9214 22.8644C29.7461 22.8644 27.4506 21.7764 25.9127 19.884C25.6509 19.5618 25.4157 19.2218 25.2042 18.8676Z"

    /// Official Claude AI symbol, path data from the Wikimedia Commons SVG
    /// (viewBox 0 0 100 100), CC — Anthropic brand mark.
    static let claudeMarkPath = "m19.6 66.5 19.7-11 .3-1-.3-.5h-1l-3.3-.2-11.2-.3L14 53l-9.5-.5-2.4-.5L0 49l.2-1.5 2-1.3 2.9.2 6.3.5 9.5.6 6.9.4L38 49.1h1.6l.2-.7-.5-.4-.4-.4L29 41l-10.6-7-5.6-4.1-3-2-1.5-2-.6-4.2 2.7-3 3.7.3.9.2 3.7 2.9 8 6.1L37 36l1.5 1.2.6-.4.1-.3-.7-1.1L33 25l-6-10.4-2.7-4.3-.7-2.6c-.3-1-.4-2-.4-3l3-4.2L28 0l4.2.6L33.8 2l2.6 6 4.1 9.3L47 29.9l2 3.8 1 3.4.3 1h.7v-.5l.5-7.2 1-8.7 1-11.2.3-3.2 1.6-3.8 3-2L61 2.6l2 2.9-.3 1.8-1.1 7.7L59 27.1l-1.5 8.2h.9l1-1.1 4.1-5.4 6.9-8.6 3-3.5L77 13l2.3-1.8h4.3l3.1 4.7-1.4 4.9-4.4 5.6-3.7 4.7-5.3 7.1-3.2 5.7.3.4h.7l12-2.6 6.4-1.1 7.6-1.3 3.5 1.6.4 1.6-1.4 3.4-8.2 2-9.6 2-14.3 3.3-.2.1.2.3 6.4.6 2.8.2h6.8l12.6 1 3.3 2 1.9 2.7-.3 2-5.1 2.6-6.8-1.6-16-3.8-5.4-1.3h-.8v.4l4.6 4.5 8.3 7.5L89 80.1l.5 2.4-1.3 2-1.4-.2-9.2-7-3.6-3-8-6.8h-.5v.7l1.8 2.7 9.8 14.7.5 4.5-.7 1.4-2.6 1-2.7-.6-5.8-8-6-9-4.7-8.2-.5.4-2.9 30.2-1.3 1.5-3 1.2-2.5-2-1.4-3 1.4-6.2 1.6-8 1.3-6.4 1.2-7.9.7-2.6v-.2H49L43 72l-9 12.3-7.2 7.6-1.7.7-3-1.5.3-2.8L24 86l10-12.8 6-7.9 4-4.6-.1-.5h-.3L17.2 77.4l-4.7.6-2-2 .2-3 1-1 8-5.5Z"
}
