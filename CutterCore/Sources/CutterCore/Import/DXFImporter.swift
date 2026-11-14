import Foundation

/// Imports ASCII DXF files: LINE, LWPOLYLINE (with bulges), POLYLINE, CIRCLE, ARC, ELLIPSE and SPLINE.
public struct DXFImporter: Sendable {
    public init() {}

    public func importDocument(data: Data, name: String, options: ImportOptions) throws -> CutDocument {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var pairs: [(Int, String)] = []
        pairs.reserveCapacity(lines.count / 2)
        var i = 0
        while i + 1 < lines.count {
            if let code = Int(lines[i]) { pairs.append((code, lines[i + 1])) }
            i += 2
        }
        guard !pairs.isEmpty else { throw ImportError.parseFailure("not a DXF file") }

        var unitScale = 1.0 // mm per drawing unit
        var section = ""
        var entities: [[(Int, String)]] = []
        var current: [(Int, String)]? = nil
        var idx = 0
        while idx < pairs.count {
            let (code, value) = pairs[idx]
            if code == 0 {
                if let c = current { entities.append(c); current = nil }
                if value == "SECTION", idx + 1 < pairs.count, pairs[idx + 1].0 == 2 {
                    section = pairs[idx + 1].1
                    idx += 2
                    continue
                }
                if value == "ENDSEC" { section = "" }
                else if section == "ENTITIES" { current = [(code, value)] }
            } else if section == "HEADER", code == 9, value == "$INSUNITS", idx + 1 < pairs.count, pairs[idx + 1].0 == 70 {
                switch Int(pairs[idx + 1].1) ?? 0 {
                case 1: unitScale = 25.4
                case 2: unitScale = 304.8
                case 5: unitScale = 10
                case 6: unitScale = 1000
                default: unitScale = 1
                }
            } else if current != nil {
                current?.append((code, value))
            }
            idx += 1
        }
        if let c = current { entities.append(c) }

        var builder = PathBuilder(tolerance: options.tolerance / unitScale)
        var paths: [Polyline] = []
        var unsupported: Set<String> = []
        var pendingPolyline: (points: [Point], closed: Bool)? = nil

        func emit() { paths.append(contentsOf: builder.finish()) }

        for entity in entities {
            let type = entity.first?.1 ?? ""
            let values = entity.dropFirst()
            func first(_ code: Int) -> Double? { values.first { $0.0 == code }.flatMap { Double($0.1) } }
            func all(_ code: Int) -> [Double] { values.filter { $0.0 == code }.compactMap { Double($0.1) } }

            switch type {
            case "LINE":
                guard let x1 = first(10), let y1 = first(20), let x2 = first(11), let y2 = first(21) else { continue }
                builder.move(to: Point(x1, y1))
                builder.line(to: Point(x2, y2))
                emit()
            case "LWPOLYLINE":
                var pts: [Point] = []
                var bulges: [Double] = []
                var pendingX: Double? = nil
                for (code, v) in values {
                    guard let d = Double(v) else { continue }
                    switch code {
                    case 10: pendingX = d
                    case 20:
                        if let x = pendingX { pts.append(Point(x, d)); bulges.append(0); pendingX = nil }
                    case 42:
                        if !bulges.isEmpty { bulges[bulges.count - 1] = d }
                    default: break
                    }
                }
                let closed = (Int(first(70) ?? 0) & 1) == 1
                Self.addPolyline(pts, bulges: bulges, closed: closed, into: &builder)
                emit()
            case "POLYLINE":
                pendingPolyline = ([], (Int(first(70) ?? 0) & 1) == 1)
            case "VERTEX":
                if let x = first(10), let y = first(20) { pendingPolyline?.points.append(Point(x, y)) }
            case "SEQEND":
                if let p = pendingPolyline {
                    Self.addPolyline(p.points, bulges: [], closed: p.closed, into: &builder)
                    emit()
                }
                pendingPolyline = nil
            case "CIRCLE":
                guard let cx = first(10), let cy = first(20), let r = first(40), r > 0 else { continue }
                builder.move(to: Point(cx + r, cy))
                builder.arc(center: Point(cx, cy), radius: r, startAngle: 0, sweep: 2 * .pi)
                builder.close()
                emit()
            case "ARC":
                guard let cx = first(10), let cy = first(20), let r = first(40), r > 0 else { continue }
                let a1 = (first(50) ?? 0) * .pi / 180
                var a2 = (first(51) ?? 360) * .pi / 180
                if a2 <= a1 { a2 += 2 * .pi }
                builder.move(to: Point(cx + r * cos(a1), cy + r * sin(a1)))
                builder.arc(center: Point(cx, cy), radius: r, startAngle: a1, sweep: a2 - a1)
                emit()
            case "ELLIPSE":
                guard let cx = first(10), let cy = first(20), let mx = first(11), let my = first(21), let ratio = first(40) else { continue }
                let a1 = first(41) ?? 0
                var a2 = first(42) ?? 2 * .pi
                if a2 <= a1 { a2 += 2 * .pi }
                let major = Point(mx, my), minor = major.perpendicular * ratio
                let n = PathBuilder.arcSegmentCount(radius: major.length, sweep: a2 - a1, tolerance: builder.tolerance)
                for k in 0...n {
                    let t = a1 + (a2 - a1) * Double(k) / Double(n)
                    let p = Point(cx, cy) + major * cos(t) + minor * sin(t)
                    if k == 0 { builder.move(to: p) } else { builder.line(to: p) }
                }
                if abs((a2 - a1) - 2 * .pi) < 1e-6 { builder.close() }
                emit()
            case "SPLINE":
                let degree = Int(first(71) ?? 3)
                let knots = all(40)
                let cx = all(10), cy = all(20)
                let fx = all(11), fy = all(21)
                let control = zip(cx, cy).map { Point($0, $1) }
                let closed = (Int(first(70) ?? 0) & 1) == 1
                if control.count > degree, knots.count == control.count + degree + 1 {
                    let samples = Self.sampleBSpline(control: control, knots: knots, degree: degree, count: max(16, control.count * 8))
                    for (k, p) in samples.enumerated() { if k == 0 { builder.move(to: p) } else { builder.line(to: p) } }
                    if closed { builder.close() }
                    emit()
                } else if fx.count >= 2 {
                    for (k, p) in zip(fx, fy).enumerated() { if k == 0 { builder.move(to: Point(p.0, p.1)) } else { builder.line(to: Point(p.0, p.1)) } }
                    if closed { builder.close() }
                    emit()
                }
            case "TEXT", "MTEXT", "INSERT", "HATCH", "DIMENSION", "IMAGE", "POINT":
                unsupported.insert(type)
            default:
                break
            }
        }

        // DXF is Y-up; flip and move to the origin.
        let flipped = paths.transformed(AffineTransform(a: unitScale, b: 0, c: 0, d: -unitScale, tx: 0, ty: 0))
        var warnings: [ImportWarning] = []
        if unsupported.contains("TEXT") || unsupported.contains("MTEXT") { warnings.append(.textIgnored(count: 1)) }
        let others = unsupported.subtracting(["TEXT", "MTEXT"])
        if !others.isEmpty { warnings.append(.unsupportedElements(others.sorted())) }
        return CutDocument(name: name, paths: flipped, pageSize: nil, warnings: warnings).normalized()
    }

    private static func addPolyline(_ pts: [Point], bulges: [Double], closed: Bool, into builder: inout PathBuilder) {
        guard pts.count >= 2 else { return }
        builder.move(to: pts[0])
        let segments = closed ? pts.count : pts.count - 1
        for i in 0..<segments {
            let p1 = pts[i], p2 = pts[(i + 1) % pts.count]
            let bulge = i < bulges.count ? bulges[i] : 0
            if abs(bulge) < 1e-9 {
                builder.line(to: p2)
            } else {
                let theta = 4 * atan(bulge)
                let chord = p2 - p1
                let d = chord.length
                guard d > 1e-9 else { continue }
                let mid = p1.lerp(p2, 0.5)
                let left = chord.perpendicular.normalized
                let center = mid + left * ((d / 2) / tan(theta / 2))
                let r = p1.distance(to: center)
                let a1 = (p1 - center).angle
                builder.arc(center: center, radius: r, startAngle: a1, sweep: theta)
                builder.line(to: p2)
            }
        }
        if closed { builder.close() }
    }

    /// Uniform sampling of a non-rational B-spline (de Boor).
    private static func sampleBSpline(control: [Point], knots: [Double], degree p: Int, count: Int) -> [Point] {
        let n = control.count - 1
        let tMin = knots[p], tMax = knots[n + 1]
        var out: [Point] = []
        out.reserveCapacity(count + 1)
        for s in 0...count {
            var t = tMin + (tMax - tMin) * Double(s) / Double(count)
            if s == count { t = tMax - 1e-12 }
            var k = p
            while k < n, knots[k + 1] <= t { k += 1 }
            var d = (0...p).map { control[k - p + $0] }
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = k - p + j
                    let denom = knots[i + p - r + 1] - knots[i]
                    let alpha = denom == 0 ? 0 : (t - knots[i]) / denom
                    d[j] = d[j - 1] * (1 - alpha) + d[j] * alpha
                }
            }
            out.append(d[p])
        }
        return out
    }
}
