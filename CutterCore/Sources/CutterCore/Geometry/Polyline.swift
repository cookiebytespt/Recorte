import Foundation

/// A sequence of straight segments. All curves are flattened into polylines
/// before being sent to the cutter.
public struct Polyline: Hashable, Sendable, Codable {
    public var points: [Point]
    /// When `true`, the last point connects back to the first one.
    public var isClosed: Bool

    public init(points: [Point], isClosed: Bool = false) {
        self.points = points
        self.isClosed = isClosed
    }

    public var isEmpty: Bool { points.count < 2 }
    public var start: Point? { points.first }
    public var end: Point? { points.last }

    public var bounds: Rect {
        points.reduce(Rect.null) { $0.including($1) }
    }

    /// Total length including the closing segment for closed polylines.
    public var length: Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += points[i - 1].distance(to: points[i]) }
        if isClosed, let f = points.first, let l = points.last { total += l.distance(to: f) }
        return total
    }

    /// Shoelace signed area (positive when counter-clockwise in a Y-up frame).
    public var signedArea: Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let p = points[i], q = points[(i + 1) % points.count]
            sum += p.x * q.y - q.x * p.y
        }
        return sum / 2
    }

    public func transformed(_ t: AffineTransform) -> Polyline {
        Polyline(points: points.map(t.apply), isClosed: isClosed)
    }

    public func reversed() -> Polyline {
        Polyline(points: points.reversed(), isClosed: isClosed)
    }

    /// For closed polylines: returns the same loop starting at `index`.
    public func rotated(startingAt index: Int) -> Polyline {
        guard isClosed, points.count > 1, index > 0, index < points.count else { return self }
        return Polyline(points: Array(points[index...] + points[..<index]), isClosed: true)
    }

    /// Even-odd point-in-polygon test. Always `false` for open polylines.
    public func contains(_ p: Point) -> Bool {
        guard isClosed, points.count > 2, bounds.contains(p) else { return false }
        var inside = false
        var j = points.count - 1
        for i in 0..<points.count {
            let pi = points[i], pj = points[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Removes consecutive duplicate points and collinear points within `tolerance`.
    public func simplified(tolerance: Double = 0.01) -> Polyline {
        guard points.count > 2 else { return self }
        var out: [Point] = []
        out.reserveCapacity(points.count)
        for p in points {
            if let last = out.last, last.distance(to: p) <= tolerance { continue }
            if out.count >= 2 {
                let a = out[out.count - 2], b = out[out.count - 1]
                let ab = b - a, bp = p - b
                let crossMag = abs(ab.cross(bp))
                if crossMag <= tolerance * max(ab.length, 1e-9), ab.dot(bp) > 0 {
                    out[out.count - 1] = p
                    continue
                }
            }
            out.append(p)
        }
        if isClosed, out.count > 2, let f = out.first, let l = out.last, f.distance(to: l) <= tolerance {
            out.removeLast()
        }
        return Polyline(points: out, isClosed: isClosed)
    }
}

extension Array where Element == Polyline {
    public var bounds: Rect { reduce(Rect.null) { $0.union($1.bounds) } }
    public var totalLength: Double { reduce(0) { $0 + $1.length } }
    public func transformed(_ t: AffineTransform) -> [Polyline] { map { $0.transformed(t) } }
}
