import Foundation

/// Text content of a text object. Font size is in points, like in design apps.
public struct TextSpec: Codable, Hashable, Sendable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var lineSpacing: Double

    public init(text: String, fontName: String = "Helvetica", fontSize: Double = 36, lineSpacing: Double = 1.2) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
    }
}

/// Imported vector artwork, stored normalised to a 0…1 box so it scales with its frame.
public struct ArtworkSpec: Codable, Hashable, Sendable {
    public var sourceName: String
    public var paths: [Polyline]

    public init(sourceName: String, paths: [Polyline]) {
        self.sourceName = sourceName
        self.paths = paths
    }
}

/// Printed artwork (PDF, AI, PNG or JPEG). Images are printed on the Print & Cut sheet and never cut.
public struct ImageSpec: Codable, Hashable, Sendable {
    public var sourceName: String
    /// File contents; the UTI-like `format` is "pdf", "png" or "jpeg".
    public var data: Data
    public var format: String

    public init(sourceName: String, data: Data, format: String) {
        self.sourceName = sourceName
        self.data = data
        self.format = format
    }
}

public enum ShapeKind: Codable, Hashable, Sendable {
    case rectangle(cornerRadius: Double)
    case ellipse
    /// Diagonal of the frame; `reversed` uses the other diagonal.
    case line(reversed: Bool)
    case polygon(sides: Int)
    case star(points: Int, innerRatio: Double)
    /// Points normalised to the frame (0…1).
    case freehand(points: [Point], closed: Bool)
    case text(TextSpec)
    case artwork(ArtworkSpec)
    /// Printed artwork; not cut.
    case image(ImageSpec)

    public var isImage: Bool { if case .image = self { return true } else { return false } }
    public var isText: Bool { if case .text = self { return true } else { return false } }
    public var isLine: Bool { if case .line = self { return true } else { return false } }
}

/// One item on the canvas. Position and size are in millimetres; rotation in degrees around the frame centre.
public struct DesignObject: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ShapeKind
    public var frame: Rect
    public var rotation: Double
    public var isVisible: Bool
    public var isLocked: Bool
    /// Set on cut lines made by Create Cut Contour: the printed image they were traced from.
    public var contourSourceID: UUID?

    public init(id: UUID = UUID(), name: String, kind: ShapeKind, frame: Rect, rotation: Double = 0,
                isVisible: Bool = true, isLocked: Bool = false, contourSourceID: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.frame = frame
        self.rotation = rotation
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.contourSourceID = contourSourceID
    }

    public var center: Point { frame.center }
    public var isCutContour: Bool { contourSourceID != nil }

    /// Bounding box of the rotated frame in document space (cheap; no outlining).
    public var documentBounds: Rect {
        let t = localToDocument
        return [Point(0, 0), Point(frame.width, 0), Point(frame.width, frame.height), Point(0, frame.height)]
            .reduce(Rect.null) { $0.including(t.apply($1)) }
    }

    /// Transform from frame-local millimetres (origin at the frame's top-left) to document space.
    public var localToDocument: AffineTransform {
        let c = frame.center
        return AffineTransform.translation(c.x, c.y)
            .concatenating(.rotation(radians: rotation * .pi / 180))
            .concatenating(.translation(-frame.width / 2, -frame.height / 2))
    }

    /// Outlines in document space (mm).
    public func outlines(tolerance: Double = 0.1) -> [Polyline] {
        localOutlines(tolerance: tolerance).transformed(localToDocument)
    }

    /// Outlines in frame-local space: x in 0…width, y in 0…height.
    public func localOutlines(tolerance: Double = 0.1) -> [Polyline] {
        let w = max(frame.width, 0.01), h = max(frame.height, 0.01)
        var b = PathBuilder(tolerance: tolerance)
        let k = 0.5522847498

        switch kind {
        case .rectangle(let radius):
            let r = min(max(radius, 0), min(w, h) / 2)
            if r <= 0 {
                b.move(to: Point(0, 0)); b.line(to: Point(w, 0)); b.line(to: Point(w, h)); b.line(to: Point(0, h)); b.close()
            } else {
                let kr = r * k
                b.move(to: Point(r, 0))
                b.line(to: Point(w - r, 0))
                b.cubic(to: Point(w, r), control1: Point(w - r + kr, 0), control2: Point(w, r - kr))
                b.line(to: Point(w, h - r))
                b.cubic(to: Point(w - r, h), control1: Point(w, h - r + kr), control2: Point(w - r + kr, h))
                b.line(to: Point(r, h))
                b.cubic(to: Point(0, h - r), control1: Point(r - kr, h), control2: Point(0, h - r + kr))
                b.line(to: Point(0, r))
                b.cubic(to: Point(r, 0), control1: Point(0, r - kr), control2: Point(r - kr, 0))
                b.close()
            }
            return b.finish()

        case .ellipse:
            let rx = w / 2, ry = h / 2, cx = rx, cy = ry
            b.move(to: Point(cx + rx, cy))
            b.cubic(to: Point(cx, cy + ry), control1: Point(cx + rx, cy + ry * k), control2: Point(cx + rx * k, cy + ry))
            b.cubic(to: Point(cx - rx, cy), control1: Point(cx - rx * k, cy + ry), control2: Point(cx - rx, cy + ry * k))
            b.cubic(to: Point(cx, cy - ry), control1: Point(cx - rx, cy - ry * k), control2: Point(cx - rx * k, cy - ry))
            b.cubic(to: Point(cx + rx, cy), control1: Point(cx + rx * k, cy - ry), control2: Point(cx + rx, cy - ry * k))
            b.close()
            return b.finish()

        case .line(let reversed):
            return reversed ? [Polyline(points: [Point(0, h), Point(w, 0)])] : [Polyline(points: [Point(0, 0), Point(w, h)])]

        case .polygon(let sides):
            let n = max(3, sides)
            let pts = (0..<n).map { i -> Point in
                let a = -Double.pi / 2 + Double(i) / Double(n) * 2 * .pi
                return Point(w / 2 + w / 2 * cos(a), h / 2 + h / 2 * sin(a))
            }
            return [Polyline(points: pts, isClosed: true)]

        case .star(let points, let innerRatio):
            let n = max(3, points)
            let ratio = min(max(innerRatio, 0.05), 0.95)
            let pts = (0..<(n * 2)).map { i -> Point in
                let a = -Double.pi / 2 + Double(i) / Double(n * 2) * 2 * .pi
                let f = i.isMultiple(of: 2) ? 1.0 : ratio
                return Point(w / 2 + w / 2 * f * cos(a), h / 2 + h / 2 * f * sin(a))
            }
            return [Polyline(points: pts, isClosed: true)]

        case .freehand(let points, let closed):
            return [Polyline(points: points.map { Point($0.x * w, $0.y * h) }, isClosed: closed)]

        case .text(let spec):
            let natural = TextOutliner.outlines(spec, tolerance: tolerance)
            let nb = natural.bounds
            guard !nb.isNull, nb.width > 0, nb.height > 0 else { return [] }
            let t = AffineTransform.scaling(w / nb.width, h / nb.height).concatenating(.translation(-nb.minX, -nb.minY))
            return natural.transformed(t)

        case .artwork(let art):
            return art.paths.transformed(.scaling(w, h))

        case .image:
            return []
        }
    }

    /// Natural size of a text object at its font size, in millimetres.
    public static func naturalTextSize(_ spec: TextSpec) -> Size {
        let b = TextOutliner.outlines(spec, tolerance: 0.2).bounds
        return b.isNull ? Size(10, 10) : Size(max(b.width, 1), max(b.height, 1))
    }

    /// Hit test in document space; `tolerance` in mm.
    public func hitTest(_ p: Point, tolerance: Double) -> Bool {
        guard let inv = localToDocument.inverted() else { return false }
        let lp = inv.apply(p)
        let local = Rect(minX: 0, minY: 0, maxX: frame.width, maxY: frame.height).insetBy(-tolerance)
        guard local.contains(lp) else { return false }
        switch kind {
        case .image:
            return true
        case .line, .freehand:
            for poly in localOutlines(tolerance: 0.5) {
                let pts = poly.isClosed ? poly.points + [poly.points[0]] : poly.points
                for i in 1..<pts.count where Self.distance(from: lp, toSegment: pts[i - 1], pts[i]) <= tolerance { return true }
            }
            return false
        default:
            return true
        }
    }

    static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 0 else { return p.distance(to: a) }
        let t = min(max((p - a).dot(ab) / len2, 0), 1)
        return p.distance(to: a + ab * t)
    }
}

/// A Recorte project: a canvas with objects. Saved as JSON (`.recorte`; older `.cookiecut` files load too).
public struct DesignDocument: Codable, Hashable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    public var name: String
    public var canvasSize: Size
    public var objects: [DesignObject]
    public var printAndCut: PrintAndCutSettings

    public init(name: String = "Untitled", canvasSize: Size = Size(300, 200), objects: [DesignObject] = [],
                printAndCut: PrintAndCutSettings = PrintAndCutSettings()) {
        self.version = Self.formatVersion
        self.name = name
        self.canvasSize = canvasSize
        self.objects = objects
        self.printAndCut = printAndCut
    }

    private enum CodingKeys: String, CodingKey { case version, name, canvasSize, objects, printAndCut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decode(String.self, forKey: .name)
        canvasSize = try c.decode(Size.self, forKey: .canvasSize)
        objects = try c.decode([DesignObject].self, forKey: .objects)
        printAndCut = try c.decodeIfPresent(PrintAndCutSettings.self, forKey: .printAndCut) ?? PrintAndCutSettings()
    }

    /// Objects that get cut (everything visible except printed images).
    public var cutObjects: [DesignObject] { objects.filter { $0.isVisible && !$0.kind.isImage } }
    /// Objects that get printed on a Print & Cut sheet.
    public var imageObjects: [DesignObject] { objects.filter { $0.isVisible && $0.kind.isImage } }

    /// Wraps an imported file as a single artwork object on a canvas sized to fit it.
    public static func fromImport(_ cut: CutDocument, sourceName: String) -> DesignDocument {
        let b = cut.bounds
        guard !b.isNull, b.width > 0, b.height > 0 else { return DesignDocument(name: cut.name) }
        let normalized = cut.paths.transformed(
            AffineTransform.scaling(1 / b.width, 1 / b.height).concatenating(.translation(-b.minX, -b.minY)))
        let object = DesignObject(
            name: sourceName,
            kind: .artwork(ArtworkSpec(sourceName: sourceName, paths: normalized)),
            frame: Rect(origin: Point(10, 10), size: b.size)
        )
        let canvas = cut.pageSize.map { Size(max($0.width, b.width + 20), max($0.height, b.height + 20)) }
            ?? Size(b.width + 20, b.height + 20)
        return DesignDocument(name: cut.name, canvasSize: canvas, objects: [object])
    }

    /// Everything visible, flattened for cutting. `only` limits it to those object ids (e.g. the selection).
    public func cutDocument(tolerance: Double = 0.1, only ids: Set<UUID>? = nil) -> CutDocument {
        let objects = ids.map { ids in cutObjects.filter { ids.contains($0.id) } } ?? cutObjects
        let paths = objects.flatMap { $0.outlines(tolerance: tolerance) }
        return CutDocument(name: name, paths: paths, pageSize: canvasSize).cleaned()
    }

    /// Bounding box of everything visible (printed and cut), used to place marks around the artwork.
    public var artworkBounds: Rect {
        objects.filter(\.isVisible).reduce(Rect.null) { $0.union($1.documentBounds) }
    }

    /// The Print & Cut sheet for this canvas with the marks resolved.
    public var printSheet: PrintSheet {
        PrintSheet(page: canvasSize, layout: printAndCut.layout, artwork: artworkBounds, title: name)
    }

    public func object(_ id: UUID) -> DesignObject? { objects.first { $0.id == id } }

    public mutating func update(_ id: UUID, _ change: (inout DesignObject) -> Void) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        change(&objects[i])
    }

    public static func encode(_ doc: DesignDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(doc)
    }

    public static func decode(_ data: Data) throws -> DesignDocument {
        try JSONDecoder().decode(DesignDocument.self, from: data)
    }
}
