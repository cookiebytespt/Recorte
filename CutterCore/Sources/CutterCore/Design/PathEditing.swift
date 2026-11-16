import Foundation

// Editing the individual lines and points of artwork objects (imported vectors and cut contours).
// All line geometry here is in frame-local millimetres: x in 0…width, y in 0…height.

extension Polyline {
    /// Douglas–Peucker simplification for open and closed lines; `tolerance` in the line's units.
    public func reduced(tolerance: Double) -> Polyline {
        guard tolerance > 0 else { return self }
        if isClosed {
            guard points.count > 4 else { return self }
            return ContourTracer.simplify(self, tolerance: tolerance)
        }
        guard points.count > 2 else { return self }
        return Polyline(points: ContourTracer.douglasPeucker(points, tolerance), isClosed: false)
    }

    /// Number of segments, counting the closing one of a closed line.
    public var segmentCount: Int {
        guard points.count > 1 else { return 0 }
        return isClosed ? points.count : points.count - 1
    }

    /// The segment nearest to `p`: its index (from `points[index]` to the next point), the distance,
    /// and the nearest point on it.
    public func nearestSegment(to p: Point) -> (index: Int, distance: Double, point: Point)? {
        var best: (index: Int, distance: Double, point: Point)?
        for i in 0..<segmentCount {
            let a = points[i], b = points[(i + 1) % points.count]
            let ab = b - a
            let len2 = ab.dot(ab)
            let t = len2 > 0 ? min(max((p - a).dot(ab) / len2, 0), 1) : 0
            let q = a + ab * t
            let d = p.distance(to: q)
            if best == nil || d < best!.distance { best = (i, d, q) }
        }
        return best
    }

    /// Whether the line still describes something cuttable after points were removed.
    public var isUsable: Bool { isClosed ? points.count >= 3 : points.count >= 2 }
}

extension DesignObject {
    /// Artwork objects (imported vectors and cut contours) have lines and points that can be edited.
    public var isEditableArtwork: Bool {
        if case .artwork = kind { return true } else { return false }
    }

    /// The lines of an artwork object in frame-local mm, or `nil` for other kinds.
    public var artworkLocalCurves: [BezierPath]? {
        guard case .artwork(let art) = kind else { return nil }
        let w = max(frame.width, 0.01), h = max(frame.height, 0.01)
        return art.curves.transformed(.scaling(w, h))
    }

    /// Total number of nodes over all lines of an artwork object.
    public var artworkPointCount: Int {
        guard case .artwork(let art) = kind else { return 0 }
        return art.curves.reduce(0) { $0 + $1.nodes.count }
    }

    /// Whether any line of the artwork has curve handles.
    public var artworkHasCurves: Bool {
        guard case .artwork(let art) = kind else { return false }
        return art.curves.contains(where: \.hasCurves)
    }

    /// Replaces the lines of an artwork object. `curves` are frame-local mm relative to the current frame;
    /// the frame is refitted around them so they keep their position on the page (rotation included).
    public mutating func setArtworkLocalCurves(_ curves: [BezierPath]) {
        guard case .artwork(var art) = kind else { return }
        let kept = curves.filter { !$0.nodes.isEmpty }
        let b = kept.bounds
        guard !b.isNull else {
            art.curves = []
            kind = .artwork(art)
            return
        }
        let w = max(b.width, 0.01), h = max(b.height, 0.01)
        let center = localToDocument.apply(Point(b.minX + w / 2, b.minY + h / 2))
        art.curves = kept.transformed(AffineTransform.scaling(1 / w, 1 / h).concatenating(.translation(-b.minX, -b.minY)))
        kind = .artwork(art)
        frame = Rect(minX: center.x - w / 2, minY: center.y - h / 2, maxX: center.x + w / 2, maxY: center.y + h / 2)
    }

    /// Edits the frame-local lines of an artwork object and refits the frame.
    public mutating func editArtworkCurves(_ body: (inout [BezierPath]) -> Void) {
        guard var curves = artworkLocalCurves else { return }
        body(&curves)
        setArtworkLocalCurves(curves)
    }

    /// Indices of the lines that are not inside another closed line (open lines always count as outer).
    public static func outerPathIndices(_ curves: [BezierPath]) -> [Int] {
        let lines = curves.map { $0.flattened(tolerance: 0.05) }
        return lines.indices.filter { i in
            let line = lines[i]
            guard line.isClosed, let probe = line.points.first else { return true }
            return !lines.indices.contains { j in
                j != i && lines[j].isClosed && lines[j].contains(probe) && lines[j].bounds.contains(line.bounds)
            }
        }
    }

    /// The same object without the lines at `indices`; `nil` when no line would be left.
    public func removingArtworkPaths(_ indices: Set<Int>) -> DesignObject? {
        guard let curves = artworkLocalCurves else { return nil }
        let kept = curves.indices.filter { !indices.contains($0) }.map { curves[$0] }
        guard !kept.isEmpty else { return nil }
        var copy = self
        copy.setArtworkLocalCurves(kept)
        return copy
    }

    /// The same object with only its outer lines (drops holes and lines inside other lines).
    public func keepingOuterArtworkPaths() -> DesignObject {
        guard let curves = artworkLocalCurves else { return self }
        let outer = Set(Self.outerPathIndices(curves))
        return removingArtworkPaths(Set(curves.indices).subtracting(outer)) ?? self
    }

    /// One new object per line, each keeping its place on the page. Names get a number suffix.
    public func splitArtwork() -> [DesignObject] {
        guard let curves = artworkLocalCurves, curves.count > 1 else { return [self] }
        return curves.enumerated().map { i, curve in
            var part = self
            part.id = UUID()
            part.name = "\(name) \(i + 1)"
            part.setArtworkLocalCurves([curve])
            return part
        }
    }

    /// Replaces the lines with smooth Bézier curves that stay within `toleranceMM` of them
    /// (`only` limits it to one line). Sharp turns stay corners.
    public func smoothingArtwork(toleranceMM: Double, only pathIndex: Int? = nil) -> DesignObject {
        var copy = self
        copy.editArtworkCurves { curves in
            for i in curves.indices where pathIndex == nil || pathIndex == i {
                let line = curves[i].flattened(tolerance: toleranceMM / 4)
                let fitted = BezierPath.fitted(to: line, tolerance: toleranceMM)
                if fitted.isUsable { curves[i] = fitted }
            }
        }
        return copy
    }

    /// Removes one node. A line left with too few nodes is removed; `nil` when nothing would be left.
    public func deletingArtworkPoint(path pathIndex: Int, point pointIndex: Int) -> DesignObject? {
        guard let curves = artworkLocalCurves, curves.indices.contains(pathIndex),
              curves[pathIndex].nodes.indices.contains(pointIndex) else { return self }
        var line = curves[pathIndex]
        line.nodes.remove(at: pointIndex)
        if !line.isUsable { return removingArtworkPaths([pathIndex]) }
        var copy = self
        copy.editArtworkCurves { $0[pathIndex] = line }
        return copy
    }

    /// Adds a node on `segment` at curve parameter `t` without changing the shape; returns its index.
    public mutating func insertArtworkPoint(path pathIndex: Int, segment: Int, at t: Double) -> Int? {
        guard let curves = artworkLocalCurves, curves.indices.contains(pathIndex),
              segment >= 0, segment < curves[pathIndex].segmentCount else { return nil }
        var index: Int?
        editArtworkCurves { index = $0[pathIndex].split(segment: segment, at: t) }
        return index
    }

    /// Makes a node smooth (handles along its neighbours) or a corner (no handles).
    public func settingArtworkPoint(path pathIndex: Int, point k: Int, smooth: Bool) -> DesignObject {
        var copy = self
        copy.editArtworkCurves { curves in
            guard curves.indices.contains(pathIndex) else { return }
            if smooth { curves[pathIndex].makeSmooth(k) } else { curves[pathIndex].makeCorner(k) }
        }
        return copy
    }
}

extension DesignObject {
    /// The lines grown (positive) or shrunk (negative) by `distanceMM`, in frame-local mm.
    /// `only` limits it to one line; otherwise all closed lines are offset together (holes stay holes).
    public func offsetArtworkCurves(distanceMM: Double, only pathIndex: Int? = nil) -> [BezierPath] {
        guard let curves = artworkLocalCurves else { return [] }
        let source = pathIndex.map { curves.indices.contains($0) ? [curves[$0]] : [] } ?? curves
        return ContourTracer.offset(source, distanceMM: distanceMM)
    }

    /// The same object with the offset lines in place of the originals (`only`: just that line; open lines stay).
    /// `nil` when the offset leaves nothing (e.g. shrinking a shape thinner than twice the distance).
    public func replacingWithOffset(_ offset: [BezierPath], only pathIndex: Int? = nil) -> DesignObject? {
        guard var curves = artworkLocalCurves, !offset.isEmpty || curves.contains(where: { !$0.isClosed }) else { return nil }
        if let p = pathIndex, curves.indices.contains(p) {
            curves.replaceSubrange(p...p, with: offset)
        } else {
            curves = curves.filter { !$0.isClosed } + offset
        }
        guard !curves.isEmpty else { return nil }
        var copy = self
        copy.setArtworkLocalCurves(curves)
        return copy
    }

    /// A new artwork object holding `offset` lines (frame-local mm of this object), at the same place and rotation.
    public func offsetCopy(_ offset: [BezierPath], name: String) -> DesignObject? {
        guard !offset.isEmpty, case .artwork(let art) = kind else { return nil }
        var copy = self
        copy.id = UUID()
        copy.name = name
        copy.kind = .artwork(ArtworkSpec(sourceName: art.sourceName, curves: []))
        // Same frame first, so the frame-local lines land in the same place, then refit.
        copy.setArtworkLocalCurves(offset)
        return copy
    }
}
