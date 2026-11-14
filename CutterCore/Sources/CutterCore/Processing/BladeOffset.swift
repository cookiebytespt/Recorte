import Foundation

/// Compensates for the drag-knife blade offset: the blade tip trails the carriage
/// by `offset` millimetres, so corners are extended and joined with a small arc.
/// Closed shapes also get an `overcut` so the start and end meet cleanly.
public struct BladeOffsetCompensator: Sendable {
    public var offset: Double
    public var overcut: Double
    /// Corners sharper than this (radians) get an arc; gentler corners are joined directly.
    public var arcThreshold: Double

    public init(offset: Double, overcut: Double = 1.0, arcThreshold: Double = 10 * .pi / 180) {
        self.offset = max(0, offset)
        self.overcut = max(0, overcut)
        self.arcThreshold = arcThreshold
    }

    public func apply(_ paths: [Polyline]) -> [Polyline] {
        guard offset > 0 else { return paths }
        return paths.map(apply)
    }

    public func apply(_ input: Polyline) -> Polyline {
        guard offset > 0 else { return input }
        var pts = input.simplified(tolerance: 1e-4).points
        guard pts.count >= 2 else { return input }

        if input.isClosed {
            pts.append(pts[0])
            if overcut > 0 {
                var remaining = overcut
                var i = 0
                while remaining > 0, i + 1 < pts.count {
                    let a = pts[i], b = pts[i + 1]
                    let len = a.distance(to: b)
                    if len >= remaining {
                        pts.append(a.lerp(b, remaining / len))
                        remaining = 0
                    } else {
                        pts.append(b)
                        remaining -= len
                    }
                    i += 1
                }
            }
        }

        var out: [Point] = [pts[0]]
        out.reserveCapacity(pts.count * 2)
        var dirs: [Point] = []
        dirs.reserveCapacity(pts.count)
        for i in 0..<(pts.count - 1) { dirs.append((pts[i + 1] - pts[i]).normalized) }

        for i in 0..<(pts.count - 1) {
            let d = dirs[i]
            out.append(pts[i + 1] + d * offset)
            if i + 1 < dirs.count {
                let next = dirs[i + 1]
                let angle = atan2(d.cross(next), d.dot(next))
                if abs(angle) >= arcThreshold {
                    let steps = max(1, Int((abs(angle) / (15 * .pi / 180)).rounded(.up)))
                    let startAngle = d.angle
                    for s in 1...steps {
                        let a = startAngle + angle * Double(s) / Double(steps)
                        out.append(pts[i + 1] + Point(cos(a), sin(a)) * offset)
                    }
                } else if abs(angle) > 1e-6 {
                    out.append(pts[i + 1] + next * offset)
                }
            }
        }
        return Polyline(points: out, isClosed: false)
    }
}
