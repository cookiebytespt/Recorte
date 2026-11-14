import Foundation

/// A 2D point. Document units are millimetres, origin top-left, Y pointing down.
public struct Point: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)

    public static func + (l: Point, r: Point) -> Point { Point(l.x + r.x, l.y + r.y) }
    public static func - (l: Point, r: Point) -> Point { Point(l.x - r.x, l.y - r.y) }
    public static func * (l: Point, r: Double) -> Point { Point(l.x * r, l.y * r) }
    public static func / (l: Point, r: Double) -> Point { Point(l.x / r, l.y / r) }
    public static prefix func - (p: Point) -> Point { Point(-p.x, -p.y) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Point {
        let l = length
        return l > 0 ? self / l : .zero
    }
    /// Perpendicular vector rotated 90° counter-clockwise (in a Y-up frame).
    public var perpendicular: Point { Point(-y, x) }

    public func distance(to p: Point) -> Double { (self - p).length }
    public func dot(_ p: Point) -> Double { x * p.x + y * p.y }
    public func cross(_ p: Point) -> Double { x * p.y - y * p.x }
    public func lerp(_ p: Point, _ t: Double) -> Point { self + (p - self) * t }
    public var angle: Double { atan2(y, x) }

    public func isApproximatelyEqual(to p: Point, tolerance: Double = 1e-6) -> Bool {
        abs(x - p.x) <= tolerance && abs(y - p.y) <= tolerance
    }
}

public struct Size: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Hashable, Sendable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init(origin: Point, size: Size) {
        minX = origin.x
        minY = origin.y
        maxX = origin.x + size.width
        maxY = origin.y + size.height
    }

    /// The empty rectangle; `union` with any rect yields that rect.
    public static let null = Rect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public var isNull: Bool { minX > maxX || minY > maxY }
    public var width: Double { isNull ? 0 : maxX - minX }
    public var height: Double { isNull ? 0 : maxY - minY }
    public var origin: Point { Point(minX, minY) }
    public var size: Size { Size(width, height) }
    public var center: Point { Point((minX + maxX) / 2, (minY + maxY) / 2) }

    public func union(_ r: Rect) -> Rect {
        if isNull { return r }
        if r.isNull { return self }
        return Rect(minX: min(minX, r.minX), minY: min(minY, r.minY),
                    maxX: max(maxX, r.maxX), maxY: max(maxY, r.maxY))
    }

    public func including(_ p: Point) -> Rect {
        if isNull { return Rect(minX: p.x, minY: p.y, maxX: p.x, maxY: p.y) }
        return Rect(minX: min(minX, p.x), minY: min(minY, p.y),
                    maxX: max(maxX, p.x), maxY: max(maxY, p.y))
    }

    public func contains(_ p: Point) -> Bool {
        !isNull && p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func contains(_ r: Rect) -> Bool {
        !isNull && !r.isNull && r.minX >= minX && r.maxX <= maxX && r.minY >= minY && r.maxY <= maxY
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(minX: minX + d, minY: minY + d, maxX: maxX - d, maxY: maxY - d)
    }
}

/// 2D affine transform using the same convention as PDF/SVG/CoreGraphics:
///
///     | a c tx |
///     | b d ty |
///
/// `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
public struct AffineTransform: Hashable, Sendable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ x: Double, _ y: Double) -> AffineTransform {
        AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scaling(_ sx: Double, _ sy: Double) -> AffineTransform {
        AffineTransform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public static func rotation(radians r: Double) -> AffineTransform {
        let cs = cos(r), sn = sin(r)
        return AffineTransform(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }

    public func apply(_ p: Point) -> Point {
        Point(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    /// Applies only the linear part (no translation). Useful for direction vectors.
    public func applyVector(_ v: Point) -> Point {
        Point(a * v.x + c * v.y, b * v.x + d * v.y)
    }

    /// Returns the transform that applies `inner` first and then `self`
    /// (i.e. `self.concatenating(inner).apply(p) == self.apply(inner.apply(p))`).
    public func concatenating(_ inner: AffineTransform) -> AffineTransform {
        AffineTransform(
            a: a * inner.a + c * inner.b,
            b: b * inner.a + d * inner.b,
            c: a * inner.c + c * inner.d,
            d: b * inner.c + d * inner.d,
            tx: a * inner.tx + c * inner.ty + tx,
            ty: b * inner.tx + d * inner.ty + ty
        )
    }

    /// Returns the transform that applies `self` first and then `outer`.
    public func then(_ outer: AffineTransform) -> AffineTransform {
        outer.concatenating(self)
    }

    public var determinant: Double { a * d - b * c }
    public var isInvertible: Bool { abs(determinant) > 1e-12 }

    public func inverted() -> AffineTransform? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return AffineTransform(a: ia, b: ib, c: ic, d: id,
                               tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }

    /// Approximate uniform scale factor (geometric mean of the axis scales).
    public var meanScale: Double { abs(determinant).squareRoot() }
}
