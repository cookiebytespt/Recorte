import Foundation

/// Things the importer could not translate into cut lines.
public enum ImportWarning: Hashable, Sendable {
    /// Text objects were skipped; they must be converted to outlines in the design app.
    case textIgnored(count: Int)
    /// Raster images were skipped.
    case imagesIgnored(count: Int)
    /// Unsupported elements were skipped (SVG element names or DXF entity types).
    case unsupportedElements([String])
    /// The file has more pages / artboards; only one was imported.
    case extraPagesIgnored(count: Int)
}

/// An imported design: a set of polylines in millimetres (origin top-left, Y down).
public struct CutDocument: Hashable, Sendable {
    public var name: String
    public var paths: [Polyline]
    /// The same lines as Bézier curves (one per path, same order) when the importer kept them.
    public var curves: [BezierPath]?
    /// Page or artboard size in millimetres when the file declares one.
    public var pageSize: Size?
    public var warnings: [ImportWarning]

    public init(name: String, paths: [Polyline], curves: [BezierPath]? = nil, pageSize: Size? = nil,
                warnings: [ImportWarning] = []) {
        self.name = name
        self.paths = paths
        self.curves = curves.flatMap { $0.count == paths.count ? $0 : nil }
        self.pageSize = pageSize
        self.warnings = warnings
    }

    public var bounds: Rect { paths.bounds }
    public var totalLength: Double { paths.totalLength }
    public var isEmpty: Bool { paths.allSatisfy(\.isEmpty) }

    public func transformed(_ t: AffineTransform) -> CutDocument {
        var copy = self
        copy.paths = paths.transformed(t)
        copy.curves = curves?.transformed(t)
        return copy
    }

    /// Moves the design so that its bounding box starts at (0, 0).
    public func normalized() -> CutDocument {
        let b = bounds
        guard !b.isNull else { return self }
        return transformed(.translation(-b.minX, -b.minY))
    }

    /// Drops degenerate polylines and merges duplicate points.
    public func cleaned(tolerance: Double = 0.01) -> CutDocument {
        var copy = self
        let simplified = paths.map { $0.simplified(tolerance: tolerance) }
        let keep = simplified.indices.filter { !simplified[$0].isEmpty }
        copy.paths = keep.map { simplified[$0] }
        if let curves { copy.curves = keep.map { curves[$0] } }
        return copy
    }
}
