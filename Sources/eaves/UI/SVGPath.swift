import SwiftUI

/// Minimal SVG path-data parser covering the commands used by simple logo
/// marks (M/m, L/l + implicit repeats, H/h, V/v, C/c, S/s, Q/q, Z/z).
/// Coordinates are produced in the path's own viewBox space; wrap in a
/// `Shape` that scales to `rect`.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var p = Path()
        var i = d.startIndex
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCmd: Character = " "

        func skipSeparators() {
            while i < d.endIndex, d[i] == " " || d[i] == "," || d[i] == "\n" { i = d.index(after: i) }
        }

        func number() -> CGFloat? {
            skipSeparators()
            var s = ""
            var seenDot = false
            while i < d.endIndex {
                let ch = d[i]
                if ch.isNumber {
                    s.append(ch)
                } else if ch == "." {
                    if seenDot { break }   // "1.5.3" = 1.5 then .3
                    seenDot = true
                    s.append(ch)
                } else if (ch == "-" || ch == "+") && s.isEmpty {
                    s.append(ch)
                } else if ch == "e" || ch == "E" {
                    s.append(ch)
                    i = d.index(after: i)
                    if i < d.endIndex, d[i] == "-" || d[i] == "+" { s.append(d[i]); i = d.index(after: i) }
                    continue
                } else {
                    break
                }
                i = d.index(after: i)
            }
            return s.isEmpty || s == "-" ? nil : Double(s).map { CGFloat($0) }
        }

        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while i < d.endIndex {
            skipSeparators()
            guard i < d.endIndex else { break }
            let ch = d[i]
            var cmd = ch
            if ch.isLetter {
                i = d.index(after: i)
            } else {
                // implicit repeat: after M/m it's L/l, others repeat themselves
                cmd = lastCmd == "M" ? "L" : (lastCmd == "m" ? "l" : lastCmd)
            }

            let rel = cmd.isLowercase
            switch Character(cmd.uppercased()) {
            case "M":
                guard let pt = point(relative: rel) else { return p }
                p.move(to: pt); current = pt; start = pt; lastControl = nil
            case "L":
                guard let pt = point(relative: rel) else { return p }
                p.addLine(to: pt); current = pt; lastControl = nil
            case "H":
                guard let x = number() else { return p }
                let pt = CGPoint(x: rel ? current.x + x : x, y: current.y)
                p.addLine(to: pt); current = pt; lastControl = nil
            case "V":
                guard let y = number() else { return p }
                let pt = CGPoint(x: current.x, y: rel ? current.y + y : y)
                p.addLine(to: pt); current = pt; lastControl = nil
            case "C":
                guard let c1 = point(relative: rel), let c2 = point(relative: rel),
                      let pt = point(relative: rel) else { return p }
                p.addCurve(to: pt, control1: c1, control2: c2)
                current = pt; lastControl = c2
            case "S":
                guard let c2 = point(relative: rel), let pt = point(relative: rel) else { return p }
                let c1 = lastControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                p.addCurve(to: pt, control1: c1, control2: c2)
                current = pt; lastControl = c2
            case "Q":
                guard let c1 = point(relative: rel), let pt = point(relative: rel) else { return p }
                p.addQuadCurve(to: pt, control: c1)
                current = pt; lastControl = c1
            case "Z":
                p.closeSubpath(); current = start; lastControl = nil
            default:
                return p // unsupported command — bail with what we have
            }
            lastCmd = cmd
        }
        return p
    }
}

/// A `Shape` that renders SVG path data, scaled uniformly from its viewBox
/// into the target rect. `origin` supports glyphs extracted from a larger
/// artwork whose coordinates don't start at 0,0.
struct SVGShape: Shape {
    let pathData: String
    let viewBox: CGFloat
    var origin: CGPoint = .zero

    func path(in rect: CGRect) -> Path {
        let base = SVGPath.parse(pathData)
        let scale = min(rect.width, rect.height) / viewBox
        let transform = CGAffineTransform(translationX: rect.midX - viewBox * scale / 2,
                                          y: rect.midY - viewBox * scale / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -origin.x, y: -origin.y)
        return base.applying(transform)
    }
}
