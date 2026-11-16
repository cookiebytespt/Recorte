import Foundation

/// Builds flattened polylines from move/line/curve commands.
/// Curves are approximated with straight segments within `tolerance` (same units as the points).
/// The same commands are also kept as Bézier curves (`lastCurves`), one per polyline, so imported
/// artwork can stay editable as curves.
public struct PathBuilder: Sendable {
    public var tolerance: Double

    private var polylines: [Polyline] = []
    private var current: [Point] = []
    private var subpathStart: Point?
    private var curves: [BezierPath] = []
    private var nodes: [BezierNode] = []

    /// The Bézier version of the polylines returned by the last `finish()`, in the same order.
    public private(set) var lastCurves: [BezierPath] = []

    public init(tolerance: Double = 0.1) {
        self.tolerance = max(tolerance, 1e-4)
    }

    public var currentPoint: Point? { current.last ?? subpathStart }

    public mutating func move(to p: Point) {
        flush(closed: false)
        current = [p]
        nodes = [BezierNode(p)]
        subpathStart = p
    }

    public mutating func line(to p: Point) {
        if current.isEmpty {
            if let s = subpathStart {
                current = [s]
                nodes = [BezierNode(s)]
            } else {
                current = [p]
                nodes = [BezierNode(p)]
                subpathStart = p
                return
            }
        }
        current.append(p)
        nodes.append(BezierNode(p))
    }

    public mutating func cubic(to p: Point, control1 c1: Point, control2 c2: Point) {
        let p0 = currentPoint ?? c1
        if current.isEmpty { line(to: p0) }
        let approxLength = p0.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: p)
        let n = Self.segmentCount(for: approxLength, tolerance: tolerance)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let mt = 1 - t
            let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
            current.append(Point(
                a * p0.x + b * c1.x + c * c2.x + d * p.x,
                a * p0.y + b * c1.y + c * c2.y + d * p.y
            ))
        }
        // Handles that sit on their anchor are the same as no handle.
        if !nodes.isEmpty, !c1.isApproximatelyEqual(to: p0, tolerance: 1e-9) { nodes[nodes.count - 1].handleOut = c1 }
        nodes.append(BezierNode(p, in: c2.isApproximatelyEqual(to: p, tolerance: 1e-9) ? nil : c2))
    }

    public mutating func quad(to p: Point, control c: Point) {
        let p0 = currentPoint ?? c
        // Elevate to cubic.
        let c1 = p0 + (c - p0) * (2.0 / 3.0)
        let c2 = p + (c - p) * (2.0 / 3.0)
        cubic(to: p, control1: c1, control2: c2)
    }

    /// Adds a circular arc around `center`, from `startAngle` sweeping by `sweep` radians
    /// (positive = counter-clockwise in a Y-up frame). The first point of the arc is
    /// connected with a line from the current point.
    public mutating func arc(center: Point, radius: Double, startAngle: Double, sweep: Double) {
        guard radius > 0, sweep != 0 else { return }
        func at(_ t: Double) -> Point { Point(center.x + radius * cos(t), center.y + radius * sin(t)) }
        let start = at(startAngle)
        if let cp = currentPoint, cp.isApproximatelyEqual(to: start, tolerance: 1e-6), !current.isEmpty {
            // Already there.
        } else {
            line(to: start)
        }
        // Flattened samples.
        let n = Self.arcSegmentCount(radius: radius, sweep: sweep, tolerance: tolerance)
        for i in 1...n { current.append(at(startAngle + sweep * Double(i) / Double(n))) }
        // Bézier pieces of at most 90°.
        let pieces = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let step = sweep / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        for i in 0..<pieces {
            let a0 = startAngle + step * Double(i), a1 = a0 + step
            let p0 = at(a0), p1 = at(a1)
            let c1 = p0 + Point(-sin(a0), cos(a0)) * (k * radius)
            let c2 = p1 - Point(-sin(a1), cos(a1)) * (k * radius)
            nodes[nodes.count - 1].handleOut = c1
            nodes.append(BezierNode(p1, in: c2))
        }
    }

    public mutating func close() {
        if current.count >= 2 {
            polylines.append(Polyline(points: current, isClosed: true))
            curves.append(Self.closedCurve(nodes))
        }
        current = []
        nodes = []
        if let s = subpathStart { current = [s]; nodes = [BezierNode(s)] }
    }

    public mutating func finish() -> [Polyline] {
        flush(closed: false)
        let result = polylines
        lastCurves = curves
        polylines = []
        curves = []
        subpathStart = nil
        return result
    }

    private mutating func flush(closed: Bool) {
        if current.count >= 2 {
            polylines.append(Polyline(points: current, isClosed: closed))
            curves.append(closed ? Self.closedCurve(nodes) : BezierPath(nodes: nodes, isClosed: false))
        }
        current = []
        nodes = []
    }

    /// A closed curve: a last node that returns onto the first one merges into it.
    private static func closedCurve(_ nodes: [BezierNode]) -> BezierPath {
        var nodes = nodes
        if nodes.count > 1, let first = nodes.first, let last = nodes.last,
           first.point.isApproximatelyEqual(to: last.point, tolerance: 1e-9) {
            nodes[0].handleIn = last.handleIn
            nodes.removeLast()
        }
        return BezierPath(nodes: nodes, isClosed: true)
    }

    static func segmentCount(for length: Double, tolerance: Double) -> Int {
        guard length.isFinite, length > 0 else { return 1 }
        let n = (length * 0.5 / tolerance).squareRoot().rounded(.up)
        return Int(min(max(n, 2), 500))
    }

    static func arcSegmentCount(radius: Double, sweep: Double, tolerance: Double) -> Int {
        let ratio = max(0, min(1, tolerance / radius))
        var step = 2 * acos(1 - ratio)
        if !step.isFinite || step <= 0 { step = 0.05 }
        step = min(max(step, 0.02), .pi / 4)
        return Int(max(1, (abs(sweep) / step).rounded(.up)))
    }
}
