import Foundation

/// Parses the SVG `d` attribute into a `PathBuilder`.
struct SVGPathData {
    /// Scans numbers, flags and commands directly from the bytes so that compact
    /// forms such as `M1.5.5` or arc flags `a1 1 0 0150 0` are handled.
    private struct Scanner {
        let bytes: [UInt8]
        var i = 0

        init(_ s: String) { bytes = Array(s.utf8) }

        private func isSeparator(_ c: UInt8) -> Bool { c == 0x20 || c == 0x2C || c == 0x09 || c == 0x0A || c == 0x0D }
        private func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        mutating func skipSeparators() {
            while i < bytes.count, isSeparator(bytes[i]) { i += 1 }
        }

        mutating func nextCommand() -> UInt8? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let c = bytes[i]
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
                i += 1
                return c
            }
            return nil
        }

        mutating func hasMoreNumbers() -> Bool {
            skipSeparators()
            guard i < bytes.count else { return false }
            let c = bytes[i]
            return isDigit(c) || c == 0x2E || c == 0x2B || c == 0x2D
        }

        var isAtEnd: Bool {
            var j = i
            while j < bytes.count, isSeparator(bytes[j]) { j += 1 }
            return j >= bytes.count
        }

        mutating func nextNumber() -> Double? {
            skipSeparators()
            let start = i
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            var sawDigit = false, sawDot = false
            while i < bytes.count {
                let c = bytes[i]
                if isDigit(c) { sawDigit = true; i += 1 }
                else if c == 0x2E, !sawDot { sawDot = true; i += 1 }
                else { break }
            }
            if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                let save = i
                i += 1
                if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
                var expDigits = false
                while i < bytes.count, isDigit(bytes[i]) { i += 1; expDigits = true }
                if !expDigits { i = save }
            }
            guard sawDigit else { i = start; return nil }
            return Double(String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard i < bytes.count, bytes[i] == 0x30 || bytes[i] == 0x31 else { return nil }
            let v = bytes[i] == 0x31
            i += 1
            return v
        }
    }

    /// Appends the path to `builder`, transforming every point by `transform`.
    static func parse(_ d: String, into builder: inout PathBuilder, transform: AffineTransform) {
        var sc = Scanner(d)
        var cmd: UInt8? = nil
        var current = Point.zero
        var subpathStart = Point.zero
        var lastCubicControl: Point? = nil
        var lastQuadControl: Point? = nil

        func abs(_ p: Point, relative: Bool) -> Point { relative ? current + p : p }

        while !sc.isAtEnd {
            if let c = sc.nextCommand() {
                cmd = c
            } else if cmd == nil || !sc.hasMoreNumbers() {
                break
            }
            guard let c = cmd else { break }
            let rel = c >= 0x61
            let upper = rel ? c - 0x20 : c
            var nextCubic: Point? = nil
            var nextQuad: Point? = nil

            switch upper {
            case 0x4D: // M
                guard let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                current = abs(Point(x, y), relative: rel)
                subpathStart = current
                builder.move(to: transform.apply(current))
                cmd = rel ? 0x6C : 0x4C
            case 0x4C: // L
                guard let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                current = abs(Point(x, y), relative: rel)
                builder.line(to: transform.apply(current))
            case 0x48: // H
                guard let x = sc.nextNumber() else { return }
                current = Point(rel ? current.x + x : x, current.y)
                builder.line(to: transform.apply(current))
            case 0x56: // V
                guard let y = sc.nextNumber() else { return }
                current = Point(current.x, rel ? current.y + y : y)
                builder.line(to: transform.apply(current))
            case 0x43: // C
                guard let x1 = sc.nextNumber(), let y1 = sc.nextNumber(),
                      let x2 = sc.nextNumber(), let y2 = sc.nextNumber(),
                      let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                let c1 = abs(Point(x1, y1), relative: rel)
                let c2 = abs(Point(x2, y2), relative: rel)
                let p = abs(Point(x, y), relative: rel)
                builder.cubic(to: transform.apply(p), control1: transform.apply(c1), control2: transform.apply(c2))
                current = p
                nextCubic = c2
            case 0x53: // S
                guard let x2 = sc.nextNumber(), let y2 = sc.nextNumber(),
                      let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                let c1 = lastCubicControl.map { current * 2 - $0 } ?? current
                let c2 = abs(Point(x2, y2), relative: rel)
                let p = abs(Point(x, y), relative: rel)
                builder.cubic(to: transform.apply(p), control1: transform.apply(c1), control2: transform.apply(c2))
                current = p
                nextCubic = c2
            case 0x51: // Q
                guard let x1 = sc.nextNumber(), let y1 = sc.nextNumber(),
                      let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                let c1 = abs(Point(x1, y1), relative: rel)
                let p = abs(Point(x, y), relative: rel)
                builder.quad(to: transform.apply(p), control: transform.apply(c1))
                current = p
                nextQuad = c1
            case 0x54: // T
                guard let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                let c1 = lastQuadControl.map { current * 2 - $0 } ?? current
                let p = abs(Point(x, y), relative: rel)
                builder.quad(to: transform.apply(p), control: transform.apply(c1))
                current = p
                nextQuad = c1
            case 0x41: // A
                guard let rx = sc.nextNumber(), let ry = sc.nextNumber(), let rot = sc.nextNumber(),
                      let large = sc.nextFlag(), let sweep = sc.nextFlag(),
                      let x = sc.nextNumber(), let y = sc.nextNumber() else { return }
                let p = abs(Point(x, y), relative: rel)
                // As Bézier pieces, so the arc stays a curve (and stays editable after import).
                for piece in arcCubics(from: current, to: p, rx: rx, ry: ry, rotationDegrees: rot, largeArc: large, sweep: sweep) {
                    if let c1 = piece.c1, let c2 = piece.c2 {
                        builder.cubic(to: transform.apply(piece.p), control1: transform.apply(c1), control2: transform.apply(c2))
                    } else {
                        builder.line(to: transform.apply(piece.p))
                    }
                }
                current = p
            case 0x5A: // Z
                builder.close()
                current = subpathStart
            default:
                return
            }
            lastCubicControl = nextCubic
            lastQuadControl = nextQuad
        }
    }

    /// Converts an SVG endpoint arc into cubic Bézier pieces of at most 90° (end point and control points;
    /// no control points means a straight line, for degenerate radii).
    static func arcCubics(from p1: Point, to p2: Point, rx rxIn: Double, ry ryIn: Double, rotationDegrees: Double,
                          largeArc: Bool, sweep: Bool) -> [(p: Point, c1: Point?, c2: Point?)] {
        if p1.isApproximatelyEqual(to: p2) { return [] }
        var rx = Swift.abs(rxIn), ry = Swift.abs(ryIn)
        if rx == 0 || ry == 0 { return [(p2, nil, nil)] }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? (max(0, num / den)).squareRoot() : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = coef * -ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ u: Point, _ v: Point) -> Double { atan2(u.cross(v), u.dot(v)) }
        let u = Point((x1p - cxp) / rx, (y1p - cyp) / ry)
        let v = Point((-x1p - cxp) / rx, (-y1p - cyp) / ry)
        let theta1 = angle(Point(1, 0), u)
        var dtheta = angle(u, v)
        if !sweep, dtheta > 0 { dtheta -= 2 * .pi }
        if sweep, dtheta < 0 { dtheta += 2 * .pi }

        func point(_ t: Double) -> Point {
            Point(cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: Double) -> Point {
            Point(-rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        let pieces = max(1, Int((Swift.abs(dtheta) / (.pi / 2)).rounded(.up)))
        let step = dtheta / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out: [(p: Point, c1: Point?, c2: Point?)] = []
        for i in 0..<pieces {
            let t0 = theta1 + step * Double(i), t1 = t0 + step
            let end = i == pieces - 1 ? p2 : point(t1)
            out.append((end, point(t0) + derivative(t0) * k, point(t1) - derivative(t1) * k))
        }
        return out
    }

    /// Converts an SVG endpoint arc into points (excluding the start point, including the end point).
    static func arcPoints(from p1: Point, to p2: Point, rx rxIn: Double, ry ryIn: Double, rotationDegrees: Double,
                          largeArc: Bool, sweep: Bool, tolerance: Double) -> [Point] {
        if p1.isApproximatelyEqual(to: p2) { return [] }
        var rx = Swift.abs(rxIn), ry = Swift.abs(ryIn)
        if rx == 0 || ry == 0 { return [p2] }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? (max(0, num / den)).squareRoot() : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = coef * -ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ u: Point, _ v: Point) -> Double { atan2(u.cross(v), u.dot(v)) }
        let u = Point((x1p - cxp) / rx, (y1p - cyp) / ry)
        let v = Point((-x1p - cxp) / rx, (-y1p - cyp) / ry)
        let theta1 = angle(Point(1, 0), u)
        var dtheta = angle(u, v)
        if !sweep, dtheta > 0 { dtheta -= 2 * .pi }
        if sweep, dtheta < 0 { dtheta += 2 * .pi }

        let n = PathBuilder.arcSegmentCount(radius: max(rx, ry), sweep: dtheta, tolerance: tolerance)
        var out: [Point] = []
        out.reserveCapacity(n)
        for k in 1...n {
            let t = theta1 + dtheta * Double(k) / Double(n)
            let ct = cos(t), st = sin(t)
            out.append(Point(cx + rx * ct * cosPhi - ry * st * sinPhi,
                             cy + rx * ct * sinPhi + ry * st * cosPhi))
        }
        if var last = out.last {
            last = p2
            out[out.count - 1] = last
        }
        return out
    }
}
