import CoreGraphics
import CoreText
import Foundation

/// Converts text to outlines with CoreText so it can be cut like any other shape.
public enum TextOutliner {
    /// Outlines in millimetres, Y down, with the first line's left baseline origin near (0, ascent).
    public static func outlines(_ spec: TextSpec, tolerance: Double = 0.1) -> [Polyline] {
        let font = CTFontCreateWithName(spec.fontName as CFString, spec.fontSize, nil)
        let ptToMM = 25.4 / 72
        let lineHeight = spec.fontSize * spec.lineSpacing
        let ascent = CTFontGetAscent(font)
        var builder = PathBuilder(tolerance: tolerance / ptToMM)

        let lines = spec.text.components(separatedBy: "\n")
        for (index, text) in lines.enumerated() where !text.isEmpty {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let baselineY = -(ascent + Double(index) * lineHeight)
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
                CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = (attributes[kCTFontAttributeName as String] as! CTFont?) ?? font
                for g in 0..<count {
                    var t = CGAffineTransform(translationX: positions[g].x, y: positions[g].y + baselineY)
                    guard let path = CTFontCreatePathForGlyph(runFont, glyphs[g], &t) else { continue }
                    append(path, to: &builder)
                }
            }
        }

        // Points (Y up) → millimetres (Y down).
        let flip = AffineTransform(a: ptToMM, b: 0, c: 0, d: -ptToMM, tx: 0, ty: 0)
        return builder.finish().transformed(flip)
    }

    private static func append(_ path: CGPath, to builder: inout PathBuilder) {
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                builder.move(to: Point(e.points[0].x, e.points[0].y))
            case .addLineToPoint:
                builder.line(to: Point(e.points[0].x, e.points[0].y))
            case .addQuadCurveToPoint:
                builder.quad(to: Point(e.points[1].x, e.points[1].y), control: Point(e.points[0].x, e.points[0].y))
            case .addCurveToPoint:
                builder.cubic(to: Point(e.points[2].x, e.points[2].y),
                              control1: Point(e.points[0].x, e.points[0].y),
                              control2: Point(e.points[1].x, e.points[1].y))
            case .closeSubpath:
                builder.close()
            @unknown default:
                break
            }
        }
    }
}
