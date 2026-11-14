import Foundation

/// Imports SVG files (paths, basic shapes, groups and transforms).
/// Text, images, `<use>` references and gradients are ignored and reported as warnings.
public struct SVGImporter: Sendable {
    public init() {}

    public func importDocument(data: Data, name: String, options: ImportOptions) throws -> CutDocument {
        let parser = XMLParser(data: data)
        let delegate = SVGParserDelegate(options: options)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.paths.isEmpty else {
            throw ImportError.parseFailure(parser.parserError?.localizedDescription ?? "invalid SVG")
        }
        guard delegate.sawRoot else { throw ImportError.parseFailure("not an SVG file") }
        return delegate.makeDocument(name: name)
    }
}

final class SVGParserDelegate: NSObject, XMLParserDelegate {
    private let options: ImportOptions
    private var transformStack: [AffineTransform] = [.identity]
    private var skipDepth = 0
    private(set) var sawRoot = false
    private var pageSize: Size?
    private var builder: PathBuilder
    private(set) var paths: [Polyline] = []
    private var textCount = 0
    private var imageCount = 0
    private var unsupported: Set<String> = []

    private static let skippedElements: Set<String> = [
        "defs", "clipPath", "mask", "marker", "pattern", "symbol", "metadata", "title", "desc",
        "style", "script", "linearGradient", "radialGradient", "filter", "foreignObject", "switch",
    ]
    private static let shapeElements: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]

    init(options: ImportOptions) {
        self.options = options
        self.builder = PathBuilder(tolerance: options.tolerance)
    }

    func makeDocument(name: String) -> CutDocument {
        var warnings: [ImportWarning] = []
        if textCount > 0 { warnings.append(.textIgnored(count: textCount)) }
        if imageCount > 0 { warnings.append(.imagesIgnored(count: imageCount)) }
        if !unsupported.isEmpty { warnings.append(.unsupportedElements(unsupported.sorted())) }
        return CutDocument(name: name, paths: paths, pageSize: pageSize, warnings: warnings)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if skipDepth > 0 { skipDepth += 1; return }
        let name = Self.localName(elementName)

        if Self.skippedElements.contains(name) || Self.isHidden(attributes) {
            skipDepth = 1
            return
        }

        var transform = transformStack.last ?? .identity
        if name == "svg", !sawRoot {
            sawRoot = true
            transform = rootTransform(attributes)
        }
        if let t = attributes["transform"], let parsed = SVGTransform.parse(t) {
            transform = transform.concatenating(parsed)
        }
        transformStack.append(transform)

        switch name {
        case "path":
            if let d = attributes["d"] {
                SVGPathData.parse(d, into: &builder, transform: transform)
                paths.append(contentsOf: builder.finish())
            }
        case "rect": addRect(attributes, transform)
        case "circle": addEllipse(attributes, transform, isCircle: true)
        case "ellipse": addEllipse(attributes, transform, isCircle: false)
        case "line": addLine(attributes, transform)
        case "polyline": addPoly(attributes, transform, closed: false)
        case "polygon": addPoly(attributes, transform, closed: true)
        case "text", "tspan", "textPath":
            if name == "text" { textCount += 1 }
        case "image":
            imageCount += 1
        case "svg", "g", "a":
            break
        case "use":
            unsupported.insert(name)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        if transformStack.count > 1 { transformStack.removeLast() }
    }

    // MARK: Shapes

    private func addRect(_ a: [String: String], _ t: AffineTransform) {
        let x = num(a["x"]) ?? 0, y = num(a["y"]) ?? 0
        guard let w = num(a["width"]), let h = num(a["height"]), w > 0, h > 0 else { return }
        var rx = num(a["rx"]), ry = num(a["ry"])
        if rx == nil { rx = ry }
        if ry == nil { ry = rx }
        let rxx = min(max(rx ?? 0, 0), w / 2), ryy = min(max(ry ?? 0, 0), h / 2)
        if rxx <= 0 || ryy <= 0 {
            builder.move(to: t.apply(Point(x, y)))
            builder.line(to: t.apply(Point(x + w, y)))
            builder.line(to: t.apply(Point(x + w, y + h)))
            builder.line(to: t.apply(Point(x, y + h)))
            builder.close()
        } else {
            let k = 0.5522847498
            let kx = rxx * k, ky = ryy * k
            builder.move(to: t.apply(Point(x + rxx, y)))
            builder.line(to: t.apply(Point(x + w - rxx, y)))
            builder.cubic(to: t.apply(Point(x + w, y + ryy)),
                          control1: t.apply(Point(x + w - rxx + kx, y)),
                          control2: t.apply(Point(x + w, y + ryy - ky)))
            builder.line(to: t.apply(Point(x + w, y + h - ryy)))
            builder.cubic(to: t.apply(Point(x + w - rxx, y + h)),
                          control1: t.apply(Point(x + w, y + h - ryy + ky)),
                          control2: t.apply(Point(x + w - rxx + kx, y + h)))
            builder.line(to: t.apply(Point(x + rxx, y + h)))
            builder.cubic(to: t.apply(Point(x, y + h - ryy)),
                          control1: t.apply(Point(x + rxx - kx, y + h)),
                          control2: t.apply(Point(x, y + h - ryy + ky)))
            builder.line(to: t.apply(Point(x, y + ryy)))
            builder.cubic(to: t.apply(Point(x + rxx, y)),
                          control1: t.apply(Point(x, y + ryy - ky)),
                          control2: t.apply(Point(x + rxx - kx, y)))
            builder.close()
        }
        paths.append(contentsOf: builder.finish())
    }

    private func addEllipse(_ a: [String: String], _ t: AffineTransform, isCircle: Bool) {
        let cx = num(a["cx"]) ?? 0, cy = num(a["cy"]) ?? 0
        let rx: Double, ry: Double
        if isCircle {
            guard let r = num(a["r"]), r > 0 else { return }
            rx = r; ry = r
        } else {
            guard let x = num(a["rx"]), let y = num(a["ry"]), x > 0, y > 0 else { return }
            rx = x; ry = y
        }
        let k = 0.5522847498
        let kx = rx * k, ky = ry * k
        builder.move(to: t.apply(Point(cx + rx, cy)))
        builder.cubic(to: t.apply(Point(cx, cy + ry)), control1: t.apply(Point(cx + rx, cy + ky)), control2: t.apply(Point(cx + kx, cy + ry)))
        builder.cubic(to: t.apply(Point(cx - rx, cy)), control1: t.apply(Point(cx - kx, cy + ry)), control2: t.apply(Point(cx - rx, cy + ky)))
        builder.cubic(to: t.apply(Point(cx, cy - ry)), control1: t.apply(Point(cx - rx, cy - ky)), control2: t.apply(Point(cx - kx, cy - ry)))
        builder.cubic(to: t.apply(Point(cx + rx, cy)), control1: t.apply(Point(cx + kx, cy - ry)), control2: t.apply(Point(cx + rx, cy - ky)))
        builder.close()
        paths.append(contentsOf: builder.finish())
    }

    private func addLine(_ a: [String: String], _ t: AffineTransform) {
        let p1 = Point(num(a["x1"]) ?? 0, num(a["y1"]) ?? 0)
        let p2 = Point(num(a["x2"]) ?? 0, num(a["y2"]) ?? 0)
        builder.move(to: t.apply(p1))
        builder.line(to: t.apply(p2))
        paths.append(contentsOf: builder.finish())
    }

    private func addPoly(_ a: [String: String], _ t: AffineTransform, closed: Bool) {
        guard let raw = a["points"] else { return }
        let values = SVGTransform.numbers(in: raw)
        guard values.count >= 4 else { return }
        var i = 0
        var first = true
        while i + 1 < values.count {
            let p = t.apply(Point(values[i], values[i + 1]))
            if first { builder.move(to: p); first = false } else { builder.line(to: p) }
            i += 2
        }
        if closed { builder.close() }
        paths.append(contentsOf: builder.finish())
    }

    // MARK: Root sizing

    private func rootTransform(_ a: [String: String]) -> AffineTransform {
        let unitless = 25.4 / options.unitlessDPI
        var widthMM = length(a["width"], unitless: unitless)
        var heightMM = length(a["height"], unitless: unitless)
        let vb = a["viewBox"].map(SVGTransform.numbers(in:)).flatMap { $0.count == 4 ? $0 : nil }

        if let vb, vb[2] > 0, vb[3] > 0 {
            if widthMM == nil, heightMM == nil {
                widthMM = vb[2] * unitless
                heightMM = vb[3] * unitless
            } else if widthMM == nil {
                widthMM = heightMM! * vb[2] / vb[3]
            } else if heightMM == nil {
                heightMM = widthMM! * vb[3] / vb[2]
            }
            let s = min(widthMM! / vb[2], heightMM! / vb[3])
            pageSize = Size(widthMM!, heightMM!)
            return AffineTransform.scaling(s, s).concatenating(.translation(-vb[0], -vb[1]))
        }
        if let w = widthMM, let h = heightMM { pageSize = Size(w, h) }
        return .scaling(unitless, unitless)
    }

    /// Parses a CSS length into millimetres. Unitless and `px` values use `unitless` mm per unit.
    private func length(_ raw: String?, unitless: Double) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, !s.hasSuffix("%") else { return nil }
        var factor = unitless
        let units: [(String, Double)] = [("mm", 1), ("cm", 10), ("in", 25.4), ("pt", 25.4 / 72), ("pc", 25.4 / 6), ("px", unitless)]
        for (u, f) in units where s.hasSuffix(u) {
            factor = f
            s.removeLast(u.count)
            break
        }
        guard let v = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
        return v * factor
    }

    private func num(_ raw: String?) -> Double? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        for u in ["px", "pt", "mm", "cm", "in"] where s.hasSuffix(u) { s.removeLast(u.count) }
        return Double(s)
    }

    private static func localName(_ qualified: String) -> String {
        if let idx = qualified.lastIndex(of: ":") { return String(qualified[qualified.index(after: idx)...]) }
        return qualified
    }

    private static func isHidden(_ a: [String: String]) -> Bool {
        if a["display"]?.trimmingCharacters(in: .whitespaces) == "none" { return true }
        if let style = a["style"]?.replacingOccurrences(of: " ", with: ""), style.contains("display:none") { return true }
        return false
    }
}

/// Parses SVG `transform` attribute lists.
enum SVGTransform {
    static func numbers(in s: String) -> [Double] {
        var out: [Double] = []
        var token = ""
        func flush() {
            if !token.isEmpty, let v = Double(token) { out.append(v) }
            token = ""
        }
        for ch in s {
            switch ch {
            case "0"..."9", ".", "e", "E":
                token.append(ch)
            case "-", "+":
                // A sign starts a new number unless it follows an exponent marker.
                if let last = token.last, last == "e" || last == "E" { token.append(ch) } else { flush(); token.append(ch) }
            default:
                flush()
            }
        }
        flush()
        return out
    }

    static func parse(_ s: String) -> AffineTransform? {
        var result = AffineTransform.identity
        var rest = Substring(s)
        var any = false
        while let open = rest.firstIndex(of: "(") {
            let name = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            guard let close = rest[open...].firstIndex(of: ")") else { break }
            let args = numbers(in: String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
            let t: AffineTransform?
            switch name {
            case "matrix" where args.count == 6:
                t = AffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case "translate" where !args.isEmpty:
                t = .translation(args[0], args.count > 1 ? args[1] : 0)
            case "scale" where !args.isEmpty:
                t = .scaling(args[0], args.count > 1 ? args[1] : args[0])
            case "rotate" where !args.isEmpty:
                let r = AffineTransform.rotation(radians: args[0] * .pi / 180)
                if args.count >= 3 {
                    t = AffineTransform.translation(args[1], args[2]).concatenating(r).concatenating(.translation(-args[1], -args[2]))
                } else {
                    t = r
                }
            case "skewX" where !args.isEmpty:
                t = AffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY" where !args.isEmpty:
                t = AffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                t = nil
            }
            if let t {
                result = result.concatenating(t)
                any = true
            }
        }
        return any ? result : nil
    }
}
