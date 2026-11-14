import Testing
@testable import CutterCore

@Suite struct GeometryTests {
    @Test func transformConcatenationOrder() {
        let scale = AffineTransform.scaling(2, 2)
        let move = AffineTransform.translation(10, 0)
        // scale first, then move
        let t = move.concatenating(scale)
        #expect(t.apply(Point(1, 1)).isApproximatelyEqual(to: Point(12, 2)))
        #expect(scale.then(move).apply(Point(1, 1)).isApproximatelyEqual(to: Point(12, 2)))
        let inv = t.inverted()!
        #expect(inv.apply(Point(12, 2)).isApproximatelyEqual(to: Point(1, 1)))
    }

    @Test func cubicFlatteningStaysWithinTolerance() {
        var b = PathBuilder(tolerance: 0.05)
        // Quarter circle of radius 100 approximated by a cubic.
        let k = 0.5522847498 * 100
        b.move(to: Point(100, 0))
        b.cubic(to: Point(0, 100), control1: Point(100, k), control2: Point(k, 100))
        let polys = b.finish()
        #expect(polys.count == 1)
        #expect(polys[0].points.count > 10)
        for p in polys[0].points {
            #expect(abs(p.length - 100) < 0.2)
        }
    }

    @Test func pointInPolygon() {
        let square = Polyline(points: [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)], isClosed: true)
        #expect(square.contains(Point(5, 5)))
        #expect(!square.contains(Point(15, 5)))
        #expect(abs(square.signedArea) == 100)
    }
}
