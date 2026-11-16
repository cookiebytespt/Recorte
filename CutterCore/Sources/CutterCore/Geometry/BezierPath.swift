import Foundation

/// One node (anchor) of a Bézier line, with optional control points ("handles") in absolute coordinates.
/// A missing handle means the segment on that side is straight at this node.
public struct BezierNode: Hashable, Sendable, Codable {
    public var point: Point
    /// Control point towards the previous node.
    public var handleIn: Point?
    /// Control point towards the next node.
    public var handleOut: Point?

    public init(_ point: Point, in handleIn: Point? = nil, out handleOut: Point? = nil) {
        self.point = point
        self.handleIn = handleIn
        self.handleOut = handleOut
    }

    public var hasHandles: Bool { handleIn != nil || handleOut != nil }

    /// Both handles exist and point in opposite directions (a smooth, tangent-continuous node).
    public var isSmooth: Bool {
        guard let i = handleIn, let o = handleOut else { return false }
        let a = point - i, b = o - point
        guard a.length > 1e-9, b.length > 1e-9 else { return false }
        return a.normalized.dot(b.normalized) > 0.998   // within ~3.5°
    }

    public func transformed(_ t: AffineTransform) -> BezierNode {
        BezierNode(t.apply(point), in: handleIn.map(t.apply), out: handleOut.map(t.apply))
    }

    /// Moves the anchor together with its handles.
    public func moved(by d: Point) -> BezierNode {
        BezierNode(point + d, in: handleIn.map { $0 + d }, out: handleOut.map { $0 + d })
    }
}

/// A line made of cubic Bézier segments (straight where a node has no handle on that side).
/// Cut lines are flattened from this just before cutting.
public struct BezierPath: Hashable, Sendable, Codable {
    public var nodes: [BezierNode]
    public var isClosed: Bool

    public init(nodes: [BezierNode], isClosed: Bool) {
        self.nodes = nodes
        self.isClosed = isClosed
    }

    /// A Bézier line through the polyline's points with straight segments.
    public init(_ polyline: Polyline) {
        nodes = polyline.points.map { BezierNode($0) }
        isClosed = polyline.isClosed
    }

    public var hasCurves: Bool { nodes.contains(where: \.hasHandles) }

    /// The anchors as a polyline (ignores the handles).
    public var anchorPolyline: Polyline { Polyline(points: nodes.map(\.point), isClosed: isClosed) }

    public var segmentCount: Int {
        guard nodes.count > 1 else { return 0 }
        return isClosed ? nodes.count : nodes.count - 1
    }

    /// Still describes something cuttable.
    public var isUsable: Bool { isClosed ? nodes.count >= (hasCurves ? 2 : 3) : nodes.count >= 2 }

    /// Control points of segment `i`: from node `i` to the next node. Missing handles sit on the anchors.
    public func segment(_ i: Int) -> (p0: Point, c1: Point, c2: Point, p3: Point) {
        let a = nodes[i], b = nodes[(i + 1) % nodes.count]
        return (a.point, a.handleOut ?? a.point, b.handleIn ?? b.point, b.point)
    }

    public func isStraight(_ i: Int) -> Bool {
        nodes[i].handleOut == nil && nodes[(i + 1) % nodes.count].handleIn == nil
    }

    public func point(segment i: Int, at t: Double) -> Point {
        let s = segment(i)
        return Self.evaluate(s.p0, s.c1, s.c2, s.p3, t)
    }

    static func evaluate(_ p0: Point, _ c1: Point, _ c2: Point, _ p3: Point, _ t: Double) -> Point {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return Point(a * p0.x + b * c1.x + c * c2.x + d * p3.x, a * p0.y + b * c1.y + c * c2.y + d * p3.y)
    }

    public func transformed(_ t: AffineTransform) -> BezierPath {
        BezierPath(nodes: nodes.map { $0.transformed(t) }, isClosed: isClosed)
    }

    /// Straight segments within `tolerance` of the curve.
    public func flattened(tolerance: Double) -> Polyline {
        guard let first = nodes.first else { return Polyline(points: [], isClosed: isClosed) }
        var pts = [first.point]
        let tol = max(tolerance, 1e-4)
        for i in 0..<segmentCount {
            let s = segment(i)
            if isStraight(i) {
                pts.append(s.p3)
            } else {
                let length = s.p0.distance(to: s.c1) + s.c1.distance(to: s.c2) + s.c2.distance(to: s.p3)
                let n = PathBuilder.segmentCount(for: length, tolerance: tol)
                for k in 1...n { pts.append(Self.evaluate(s.p0, s.c1, s.c2, s.p3, Double(k) / Double(n))) }
            }
        }
        if isClosed, pts.count > 1 { pts.removeLast() }   // the closing segment ends on the first point
        return Polyline(points: pts, isClosed: isClosed)
    }

    /// Exact bounds of the curve (not of the control points).
    public var bounds: Rect {
        var r = nodes.reduce(Rect.null) { $0.including($1.point) }
        for i in 0..<segmentCount where !isStraight(i) {
            let s = segment(i)
            for t in Self.extremaParameters(s.p0.x, s.c1.x, s.c2.x, s.p3.x) + Self.extremaParameters(s.p0.y, s.c1.y, s.c2.y, s.p3.y) {
                r = r.including(Self.evaluate(s.p0, s.c1, s.c2, s.p3, t))
            }
        }
        return r
    }

    /// Parameters in (0, 1) where one coordinate of a cubic has a minimum or maximum.
    static func extremaParameters(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> [Double] {
        let a = -p0 + 3 * p1 - 3 * p2 + p3, b = 2 * (p0 - 2 * p1 + p2), c = p1 - p0
        var roots: [Double] = []
        if abs(a) < 1e-12 {
            if abs(b) > 1e-12 { roots = [-c / b] }
        } else {
            let disc = b * b - 4 * a * c
            if disc >= 0 {
                let s = disc.squareRoot()
                roots = [(-b + s) / (2 * a), (-b - s) / (2 * a)]
            }
        }
        return roots.filter { $0 > 0 && $0 < 1 }
    }

    /// The segment nearest to `p`: its index, the curve parameter, the distance and the nearest point.
    public func nearestSegment(to p: Point) -> (index: Int, t: Double, distance: Double, point: Point)? {
        var best: (index: Int, t: Double, distance: Double, point: Point)?
        for i in 0..<segmentCount {
            let s = segment(i)
            var t: Double
            if isStraight(i) {
                let ab = s.p3 - s.p0
                let len2 = ab.dot(ab)
                t = len2 > 0 ? min(max((p - s.p0).dot(ab) / len2, 0), 1) : 0
            } else {
                // Coarse samples, then narrow down around the best one.
                let n = 32
                t = 0
                var d = Double.infinity
                for k in 0...n {
                    let u = Double(k) / Double(n)
                    let dk = Self.evaluate(s.p0, s.c1, s.c2, s.p3, u).distance(to: p)
                    if dk < d { d = dk; t = u }
                }
                var lo = max(0, t - 1.0 / Double(n)), hi = min(1, t + 1.0 / Double(n))
                for _ in 0..<24 {
                    let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                    if Self.evaluate(s.p0, s.c1, s.c2, s.p3, m1).distance(to: p) < Self.evaluate(s.p0, s.c1, s.c2, s.p3, m2).distance(to: p) {
                        hi = m2
                    } else {
                        lo = m1
                    }
                }
                t = (lo + hi) / 2
            }
            let q = Self.evaluate(s.p0, s.c1, s.c2, s.p3, t)
            let d = q.distance(to: p)
            if best == nil || d < best!.distance { best = (i, t, d, q) }
        }
        return best
    }

    /// Adds a node on segment `i` at parameter `t` without changing the shape. Returns the new node's index.
    @discardableResult
    public mutating func split(segment i: Int, at t: Double) -> Int {
        let j = (i + 1) % nodes.count
        let s = segment(i)
        let k = i + 1
        if isStraight(i) {
            nodes.insert(BezierNode(s.p0.lerp(s.p3, t)), at: k)
            return k
        }
        let a = s.p0.lerp(s.c1, t), b = s.c1.lerp(s.c2, t), c = s.c2.lerp(s.p3, t)
        let d = a.lerp(b, t), e = b.lerp(c, t), f = d.lerp(e, t)
        nodes[i].handleOut = a
        nodes[j].handleIn = c
        nodes.insert(BezierNode(f, in: d, out: e), at: k)
        return k
    }

    /// Gives node `k` handles along the direction of its neighbours (a smooth node).
    public mutating func makeSmooth(_ k: Int) {
        guard nodes.indices.contains(k), nodes.count > 1 else { return }
        let p = nodes[k].point
        let prev: Point? = (k > 0 || isClosed) ? nodes[(k - 1 + nodes.count) % nodes.count].point : nil
        let next: Point? = (k < nodes.count - 1 || isClosed) ? nodes[(k + 1) % nodes.count].point : nil
        let tangent: Point
        switch (prev, next) {
        case let (a?, b?): tangent = (b - a).normalized
        case let (a?, nil): tangent = (p - a).normalized
        case let (nil, b?): tangent = (b - p).normalized
        default: return
        }
        guard tangent.length > 0.5 else { return }
        nodes[k].handleIn = prev.map { p - tangent * (p.distance(to: $0) / 3) }
        nodes[k].handleOut = next.map { p + tangent * (p.distance(to: $0) / 3) }
    }

    /// Removes the handles of node `k` (a corner node with straight segments on its sides at this node).
    public mutating func makeCorner(_ k: Int) {
        guard nodes.indices.contains(k) else { return }
        nodes[k].handleIn = nil
        nodes[k].handleOut = nil
    }

    /// Moves one handle of node `k`. With `keepSmooth`, the opposite handle turns with it (keeping its length).
    public mutating func moveHandle(of k: Int, out isOut: Bool, to position: Point, keepSmooth: Bool) {
        guard nodes.indices.contains(k) else { return }
        let p = nodes[k].point
        if isOut { nodes[k].handleOut = position } else { nodes[k].handleIn = position }
        guard keepSmooth, let other = isOut ? nodes[k].handleIn : nodes[k].handleOut else { return }
        let dir = (position - p)
        guard dir.length > 1e-9 else { return }
        let mirrored = p - dir.normalized * other.distance(to: p)
        if isOut { nodes[k].handleIn = mirrored } else { nodes[k].handleOut = mirrored }
    }
}

// MARK: - Fitting curves to traced lines

extension BezierPath {
    /// Smooth Bézier curves through a polyline (e.g. a traced cut contour), staying within `tolerance`.
    /// Sharp turns of more than `cornerAngle` degrees are kept as corners; elsewhere nodes are smooth.
    /// Algorithm: P. J. Schneider, "An Algorithm for Automatically Fitting Digitized Curves" (Graphics Gems, 1990).
    public static func fitted(to line: Polyline, tolerance: Double, cornerAngle: Double = 60) -> BezierPath {
        let tol = max(tolerance, 1e-4)
        var pts: [Point] = []
        for p in line.points where pts.last.map({ $0.distance(to: p) > tol * 0.01 }) ?? true { pts.append(p) }
        if line.isClosed, pts.count > 1, pts[0].distance(to: pts[pts.count - 1]) <= tol * 0.01 { pts.removeLast() }
        guard pts.count >= (line.isClosed ? 4 : 3) else { return BezierPath(Polyline(points: pts, isClosed: line.isClosed)) }
        // Long straight runs get intermediate points, so the fit can see (and keep) them straight
        // instead of bending them along the tangents of their ends.
        pts = densified(pts, closed: line.isClosed, spacing: max(tol * 5, 0.25))

        let window = max(tol * 4, 0.5)
        let corners = detectCorners(pts, closed: line.isClosed, window: window, angle: cornerAngle)

        // Runs of points between breakpoints; each is fitted on its own.
        var runs: [[Point]] = []
        var smoothJoin = false   // closed line without corners: the start node is smooth
        if line.isClosed {
            if corners.isEmpty {
                runs = [pts + [pts[0]]]
                smoothJoin = true
            } else {
                let n = pts.count
                for (c, start) in corners.enumerated() {
                    let end = corners[(c + 1) % corners.count]
                    var run: [Point] = []
                    var i = start
                    repeat { run.append(pts[i]); i = (i + 1) % n } while i != end
                    run.append(pts[end])
                    runs.append(run)
                }
            }
        } else {
            let breaks = [0] + corners.filter { $0 > 0 && $0 < pts.count - 1 } + [pts.count - 1]
            for b in 0..<(breaks.count - 1) { runs.append(Array(pts[breaks[b]...breaks[b + 1]])) }
        }

        var segments: [[Point]] = []
        for run in runs {
            guard run.count >= 2 else { continue }
            var t1 = startTangent(run, reach: window / 2)
            var t2 = endTangent(run, reach: window / 2)
            if smoothJoin {
                // Same tangent leaving and entering the start point.
                let prev = run[run.count - 2], next = run[1]
                let c = (next - prev).normalized
                if c.length > 0.5 { t1 = c; t2 = -c }
            }
            var out: [[Point]] = []
            fitCubic(run, 0, run.count - 1, t1, t2, tol, &out, depth: 0)
            segments.append(contentsOf: out)
        }
        guard !segments.isEmpty else { return BezierPath(line) }

        // Segments → nodes; nearly straight segments lose their handles.
        var nodes: [BezierNode] = segments.map { BezierNode($0[0]) }
        if !line.isClosed { nodes.append(BezierNode(segments[segments.count - 1][3])) }
        for (k, s) in segments.enumerated() {
            let straight = DesignObject.distance(from: s[1], toSegment: s[0], s[3]) <= tol * 0.25
                && DesignObject.distance(from: s[2], toSegment: s[0], s[3]) <= tol * 0.25
            if straight { continue }
            nodes[k].handleOut = s[1]
            nodes[(k + 1) % nodes.count].handleIn = s[2]
        }
        return BezierPath(nodes: nodes, isClosed: line.isClosed)
    }

    static func densified(_ pts: [Point], closed: Bool, spacing: Double) -> [Point] {
        var out: [Point] = []
        let count = closed ? pts.count : pts.count - 1
        for i in 0..<count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            out.append(a)
            let n = Int((a.distance(to: b) / spacing).rounded(.up))
            if n > 1 { for k in 1..<n { out.append(a.lerp(b, Double(k) / Double(n))) } }
        }
        if !closed, let last = pts.last { out.append(last) }
        return out
    }

    /// Indices of sharp turns, at least `window` apart (arc length), strongest first kept.
    static func detectCorners(_ pts: [Point], closed: Bool, window: Double, angle: Double) -> [Int] {
        let n = pts.count
        func neighbour(_ i: Int, step: Int) -> Int? {
            var j = i, travelled = 0.0
            for _ in 0..<(n / 2) {
                let next = j + step
                let k: Int
                if closed { k = (next + n) % n } else { guard next >= 0, next < n else { return j == i ? nil : j }; k = next }
                travelled += pts[j].distance(to: pts[k])
                j = k
                if travelled >= window { break }
            }
            return j == i ? nil : j
        }
        let threshold = cos(angle * .pi / 180)
        var candidates: [(index: Int, cosine: Double)] = []
        for i in 0..<n {
            guard let b = neighbour(i, step: -1), let f = neighbour(i, step: 1) else { continue }
            let din = (pts[i] - pts[b]).normalized, dout = (pts[f] - pts[i]).normalized
            let c = din.dot(dout)
            if c < threshold { candidates.append((i, c)) }
        }
        // Arc length along the line, to keep corners apart.
        var s = [0.0]
        for i in 1..<n { s.append(s[i - 1] + pts[i - 1].distance(to: pts[i])) }
        let total = s[n - 1] + (closed ? pts[n - 1].distance(to: pts[0]) : 0)
        func gap(_ a: Int, _ b: Int) -> Double {
            let d = abs(s[a] - s[b])
            return closed ? min(d, total - d) : d
        }
        var kept: [Int] = []
        for c in candidates.sorted(by: { $0.cosine < $1.cosine }) where !kept.contains(where: { gap($0, c.index) < window }) {
            kept.append(c.index)
        }
        return kept.sorted()
    }

    static func startTangent(_ run: [Point], reach: Double) -> Point {
        let p = run[0]
        var q = run[1]
        for r in run.dropFirst() { q = r; if r.distance(to: p) >= reach { break } }
        let t = (q - p).normalized
        return t.length > 0.5 ? t : (run[run.count - 1] - p).normalized
    }

    static func endTangent(_ run: [Point], reach: Double) -> Point {
        let p = run[run.count - 1]
        var q = run[run.count - 2]
        for r in run.reversed().dropFirst() { q = r; if r.distance(to: p) >= reach { break } }
        let t = (q - p).normalized
        return t.length > 0.5 ? t : (run[0] - p).normalized
    }

    private static func fitCubic(_ d: [Point], _ first: Int, _ last: Int, _ t1: Point, _ t2: Point,
                                 _ error: Double, _ out: inout [[Point]], depth: Int) {
        let p0 = d[first], p3 = d[last]
        if last - first == 1 || depth > 32 {
            let dist = p0.distance(to: p3) / 3
            out.append([p0, p0 + t1 * dist, p3 + t2 * dist, p3])
            return
        }
        var u = chordLengthParameterize(d, first, last)
        var bez = generateBezier(d, first, last, u, t1, t2)
        var (maxError, split) = maxDistance(d, first, last, bez, u)
        if maxError < error { out.append(bez); return }
        if maxError < error * 4 {
            for _ in 0..<6 {
                u = reparameterize(d, first, last, u, bez)
                bez = generateBezier(d, first, last, u, t1, t2)
                (maxError, split) = maxDistance(d, first, last, bez, u)
                if maxError < error { out.append(bez); return }
            }
        }
        split = min(max(split, first + 1), last - 1)
        var center = (d[split - 1] - d[split + 1]).normalized
        if center.length < 0.5 { center = (d[split - 1] - d[split]).normalized }
        fitCubic(d, first, split, t1, center, error, &out, depth: depth + 1)
        fitCubic(d, split, last, -center, t2, error, &out, depth: depth + 1)
    }

    private static func chordLengthParameterize(_ d: [Point], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last { u.append(u[u.count - 1] + d[i].distance(to: d[i - 1])) }
        let total = u[u.count - 1]
        return total > 0 ? u.map { $0 / total } : u.indices.map { Double($0) / Double(max(u.count - 1, 1)) }
    }

    private static func generateBezier(_ d: [Point], _ first: Int, _ last: Int, _ u: [Double],
                                       _ t1: Point, _ t2: Point) -> [Point] {
        let p0 = d[first], p3 = d[last]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for (i, t) in u.enumerated() {
            let mt = 1 - t
            let b0 = mt * mt * mt, b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t, b3 = t * t * t
            let a0 = t1 * b1, a1 = t2 * b2
            c00 += a0.dot(a0); c01 += a0.dot(a1); c11 += a1.dot(a1)
            let tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += a0.dot(tmp); x1 += a1.dot(tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alphaL = abs(det) > 1e-12 ? (x0 * c11 - x1 * c01) / det : 0
        var alphaR = abs(det) > 1e-12 ? (c00 * x1 - c01 * x0) / det : 0
        let segLength = p0.distance(to: p3)
        let epsilon = 1e-6 * segLength
        if !alphaL.isFinite || !alphaR.isFinite || alphaL < epsilon || alphaR < epsilon {
            alphaL = segLength / 3; alphaR = segLength / 3
        }
        return [p0, p0 + t1 * alphaL, p3 + t2 * alphaR, p3]
    }

    private static func maxDistance(_ d: [Point], _ first: Int, _ last: Int, _ bez: [Point], _ u: [Double]) -> (Double, Int) {
        var maxD = 0.0
        var split = (first + last) / 2
        for i in (first + 1)..<last {
            let dist = evaluate(bez[0], bez[1], bez[2], bez[3], u[i - first]).distance(to: d[i])
            if dist > maxD { maxD = dist; split = i }
        }
        return (maxD, split)
    }

    private static func reparameterize(_ d: [Point], _ first: Int, _ last: Int, _ u: [Double], _ bez: [Point]) -> [Double] {
        let q1 = [(bez[1] - bez[0]) * 3, (bez[2] - bez[1]) * 3, (bez[3] - bez[2]) * 3]
        let q2 = [(q1[1] - q1[0]) * 2, (q1[2] - q1[1]) * 2]
        return u.enumerated().map { i, t in
            let p = d[first + i]
            let q = evaluate(bez[0], bez[1], bez[2], bez[3], t)
            let mt = 1 - t
            let qd = q1[0] * (mt * mt) + q1[1] * (2 * mt * t) + q1[2] * (t * t)
            let qdd = q2[0] * mt + q2[1] * t
            let num = (q - p).dot(qd)
            let den = qd.dot(qd) + (q - p).dot(qdd)
            guard abs(den) > 1e-12 else { return t }
            let next = t - num / den
            return next.isFinite ? min(max(next, 0), 1) : t
        }
    }
}

extension Array where Element == BezierPath {
    public var bounds: Rect { reduce(Rect.null) { $0.union($1.bounds) } }
    public func transformed(_ t: AffineTransform) -> [BezierPath] { map { $0.transformed(t) } }
}
