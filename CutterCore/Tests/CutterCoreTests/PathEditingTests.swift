import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CutterCore

@Suite struct WhiteBackgroundTests {
    /// Opaque white 200 × 200 px PNG with a blue square and a white "letter" (bar) inside it, placed at 20 × 20 mm.
    private func whiteLetterImage() -> DesignObject {
        let w = 200
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))
        ctx.setFillColor(CGColor(red: 0.6, green: 0.8, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 70, y: 60, width: 60, height: 80))   // 6 × 8 mm white area inside
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dest)
        return DesignObject(name: "img", kind: .image(ImageSpec(sourceName: "w.png", data: data as Data, format: "png")),
                            frame: Rect(minX: 0, minY: 0, maxX: 20, maxY: 20))
    }

    @Test func enclosedWhiteStaysArtwork() {
        let loops = ContourTracer.contours(for: whiteLetterImage(),
                                           options: ContourOptions(distanceMM: 1, cutHoles: true, whiteIsBackground: true))
        #expect(loops.count == 1)
        #expect(abs(loops[0].bounds.width - 14) < 0.4)   // 12 mm square + 1 mm each side
    }

    @Test func enclosedWhiteCanStillBeCut() {
        let loops = ContourTracer.contours(for: whiteLetterImage(),
                                           options: ContourOptions(distanceMM: 1, cutHoles: true, whiteIsBackground: true,
                                                                   cutEnclosedWhite: true))
        #expect(loops.count == 2)
        // The hole shrinks by the distance: 6 × 8 mm → 4 × 6 mm.
        let hole = loops.min { $0.bounds.width < $1.bounds.width }!
        #expect(abs(hole.bounds.width - 4) < 0.4 && abs(hole.bounds.height - 6) < 0.4)
    }

    @Test func transparentHolesAreStillHoles() {
        var opaque = BitMask(width: 30, height: 30)
        for y in 5..<25 { for x in 5..<25 { opaque[x, y] = true } }
        for y in 12..<18 { for x in 12..<18 { opaque[x, y] = false } }
        let white = BitMask(width: 30, height: 30)
        let mask = ContourTracer.artworkMask(opaque: opaque, white: white, cutEnclosedWhite: false)
        #expect(!mask[15, 15])
        #expect(mask[8, 8])
    }
}

@Suite struct PathEditingTests {
    private func square(_ x: Double, _ y: Double, _ s: Double) -> BezierPath {
        BezierPath(Polyline(points: [Point(x, y), Point(x + s, y), Point(x + s, y + s), Point(x, y + s)], isClosed: true))
    }

    /// Artwork with an outer 100 mm square and two holes, at (10, 20) on the page.
    private func contour(rotation: Double = 0) -> DesignObject {
        var o = DesignObject(name: "Contour", kind: .artwork(ArtworkSpec(sourceName: "t", curves: [])),
                             frame: Rect(minX: 10, minY: 20, maxX: 110, maxY: 120), rotation: rotation,
                             contourSourceID: UUID())
        o.setArtworkLocalCurves([square(0, 0, 100), square(10, 10, 20), square(60, 60, 30)])
        return o
    }

    private func same(_ a: [Polyline], _ b: [Polyline]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.points.count == y.points.count && zip(x.points, y.points).allSatisfy { $0.isApproximatelyEqual(to: $1, tolerance: 1e-6) }
        }
    }

    @Test func outerLinesAreFound() {
        let o = contour()
        #expect(DesignObject.outerPathIndices(o.artworkLocalCurves!) == [0])
        let outer = o.keepingOuterArtworkPaths()
        guard case .artwork(let art) = outer.kind else { Issue.record("not artwork"); return }
        #expect(art.curves.count == 1)
        #expect(outer.frame.origin.isApproximatelyEqual(to: o.frame.origin) && abs(outer.frame.width - o.frame.width) < 1e-9)
    }

    @Test func removingALineKeepsThePageGeometry() {
        for rotation in [0.0, 30] {
            let o = contour(rotation: rotation)
            let removed = o.removingArtworkPaths([0])!
            #expect(same(removed.outlines(), Array(o.outlines().dropFirst())))
            #expect(removed.frame.width < 90)
            #expect(removed.contourSourceID == o.contourSourceID)
        }
        #expect(contour().removingArtworkPaths([0, 1, 2]) == nil)
    }

    @Test func splitMakesOneObjectPerLine() {
        let o = contour(rotation: 15)
        let parts = o.splitArtwork()
        #expect(parts.count == 3)
        #expect(Set(parts.map(\.id)).count == 3)
        #expect(same(parts.flatMap { $0.outlines() }, o.outlines()))
    }

    @Test func pointsCanBeDeletedAndInserted() {
        var o = contour()
        let index = o.insertArtworkPoint(path: 0, segment: 0, at: 0.5)
        #expect(index == 1)
        #expect(o.artworkLocalCurves![0].nodes.count == 5)
        var moved = o
        moved.editArtworkCurves { $0[0].nodes[1] = $0[0].nodes[1].moved(by: Point(0, -10)) }
        #expect(abs(moved.frame.minY - 10) < 1e-9)   // the frame grew to include the moved node
        let fewer = moved.deletingArtworkPoint(path: 0, point: 1)!
        #expect(fewer.artworkLocalCurves![0].nodes.count == 4)
        #expect(abs(fewer.frame.minY - 20) < 1e-9)
        // A triangle that loses a node is no longer a line, so the line goes.
        var tri = contour()
        tri.setArtworkLocalCurves([BezierPath(Polyline(points: [Point(0, 0), Point(10, 0), Point(5, 8)], isClosed: true)), square(20, 0, 5)])
        #expect(tri.deletingArtworkPoint(path: 0, point: 0)!.artworkLocalCurves!.count == 1)
    }

    @Test func smoothingATracedCircleGivesFewSmoothNodes() {
        let circle = Polyline(points: (0..<400).map { i in
            let a = Double(i) / 400 * 2 * .pi
            return Point(50 + 40 * cos(a), 50 + 40 * sin(a))
        }, isClosed: true)
        var o = contour()
        o.setArtworkLocalCurves([BezierPath(circle)])
        let smooth = o.smoothingArtwork(toleranceMM: 0.1)
        let curve = smooth.artworkLocalCurves![0]
        #expect(curve.nodes.count <= 12)
        let allSmooth = curve.nodes.allSatisfy { $0.isSmooth }
        #expect(allSmooth)
        // Every point of the result stays near the circle.
        let flat = smooth.outlines(tolerance: 0.01)[0]
        let c = smooth.frame.center
        let nearCircle = flat.points.allSatisfy { abs($0.distance(to: c) - 40) < 0.15 }
        #expect(nearCircle)
        #expect(abs(smooth.frame.width - 80) < 0.2)
    }

    @Test func nearestSegmentIncludesTheClosingOne() {
        let hit = square(0, 0, 10).nearestSegment(to: Point(-1, 5))!
        #expect(hit.index == 3)
        #expect(abs(hit.distance - 1) < 1e-9)
    }
}

@Suite struct BezierPathTests {
    private func arc() -> BezierPath {
        // Quarter circle-ish curve from (0, 0) to (10, 10).
        BezierPath(nodes: [BezierNode(Point(0, 0), out: Point(5.5, 0)), BezierNode(Point(10, 10), in: Point(10, 4.5))], isClosed: false)
    }

    @Test func splittingKeepsTheShape() {
        var c = arc()
        let before = c.flattened(tolerance: 0.0005).points
        let k = c.split(segment: 0, at: 0.3)
        #expect(k == 1 && c.nodes.count == 3)
        #expect(c.nodes[1].isSmooth)
        for p in c.flattened(tolerance: 0.0005).points {
            let d = (1..<before.count).map { DesignObject.distance(from: p, toSegment: before[$0 - 1], before[$0]) }.min()!
            #expect(d < 0.005)
        }
    }

    @Test func boundsFollowTheCurveNotTheHandles() {
        let bulge = BezierPath(nodes: [BezierNode(Point(0, 0), out: Point(0, -10)), BezierNode(Point(10, 0), in: Point(10, -10))], isClosed: false)
        let b = bulge.bounds
        #expect(abs(b.minY - -7.5) < 1e-9)   // the curve reaches 3/4 of the handle height
        #expect(abs(b.maxY) < 1e-9)
    }

    @Test func smoothAndCornerNodes() {
        var c = BezierPath(Polyline(points: [Point(0, 0), Point(10, 5), Point(20, 0)]))
        c.makeSmooth(1)
        #expect(c.nodes[1].isSmooth)
        #expect(c.nodes[1].handleIn!.y == 5 && c.nodes[1].handleOut!.y == 5)   // horizontal tangent
        c.moveHandle(of: 1, out: true, to: Point(14, 9), keepSmooth: true)
        #expect(c.nodes[1].isSmooth)
        c.moveHandle(of: 1, out: true, to: Point(14, 0), keepSmooth: false)
        #expect(!c.nodes[1].isSmooth)
        c.makeCorner(1)
        #expect(!c.nodes[1].hasHandles)
    }

    @Test func fittingKeepsSharpCorners() {
        // A 20 mm square traced with many points per side.
        var pts: [Point] = []
        for side in 0..<4 {
            for i in 0..<50 {
                let t = Double(i) / 50 * 20
                switch side {
                case 0: pts.append(Point(t, 0))
                case 1: pts.append(Point(20, t))
                case 2: pts.append(Point(20 - t, 20))
                default: pts.append(Point(0, 20 - t))
                }
            }
        }
        let fitted = BezierPath.fitted(to: Polyline(points: pts, isClosed: true), tolerance: 0.1)
        #expect(fitted.nodes.count == 4)
        #expect(!fitted.hasCurves)
        let b = fitted.bounds
        #expect(abs(b.width - 20) < 1e-6 && abs(b.height - 20) < 1e-6)
    }

    @Test func artworkFilesStayCompatible() throws {
        // Straight lines are saved as plain point lists (the old format); curves under "curves".
        let straight = ArtworkSpec(sourceName: "s", paths: [Polyline(points: [Point(0, 0), Point(1, 1)])])
        let json = String(decoding: try JSONEncoder().encode(straight), as: UTF8.self)
        #expect(json.contains("\"paths\"") && !json.contains("\"curves\""))
        #expect(try JSONDecoder().decode(ArtworkSpec.self, from: Data(json.utf8)) == straight)
        let curved = ArtworkSpec(sourceName: "c", curves: [arc()])
        let data = try JSONEncoder().encode(curved)
        #expect(String(decoding: data, as: UTF8.self).contains("\"curves\""))
        #expect(try JSONDecoder().decode(ArtworkSpec.self, from: data) == curved)
    }
}

@Suite struct CurveImportTests {
    @Test func svgCurvesAndArcsStayCurves() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" viewBox="0 0 100 100">
          <circle cx="50" cy="50" r="20"/>
          <path d="M10 10 L30 10 C 40 10 40 30 30 30 Z"/>
          <path d="M50 10a40 40 0 1180 0a40 40 0 1 1-80 0"/>
        </svg>
        """
        let doc = try DocumentLoader.load(data: Data(svg.utf8), filename: "c.svg")
        let curves = try #require(doc.curves)
        #expect(curves.count == doc.paths.count && curves.count == 3)
        let circleSmooth = curves[0].nodes.allSatisfy { $0.isSmooth }
        #expect(curves[0].nodes.count == 4 && curves[0].isClosed && circleSmooth)
        #expect(curves[1].nodes.count == 3 && curves[1].hasCurves)
        #expect(curves[2].nodes.count <= 6 && abs(curves[2].bounds.width - 80) < 0.05)
        let design = DesignDocument.fromImport(doc, sourceName: "c.svg")
        #expect(design.objects[0].artworkHasCurves)
    }

    @Test func pdfAndDXFKeepCurves() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 288, height: 144)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.addEllipse(in: CGRect(x: 72, y: 36, width: 72, height: 72))
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()
        let pdf = try DocumentLoader.load(data: data as Data, filename: "t.pdf")
        let ellipse = try #require(pdf.curves?.first)
        #expect(ellipse.hasCurves && ellipse.isClosed && abs(ellipse.bounds.width - 25.4) < 0.01)

        let dxf = "0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n10\n50\n20\n50\n40\n10\n0\nENDSEC\n0\nEOF\n"
        let circle = try #require(try DocumentLoader.load(data: Data(dxf.utf8), filename: "t.dxf").curves?.first)
        #expect(circle.isClosed && circle.nodes.count == 4 && abs(circle.bounds.width - 20) < 0.01)
    }
}

@Suite struct OffsetTests {
    private let square = BezierPath(Polyline(points: [Point(0, 0), Point(20, 0), Point(20, 20), Point(0, 20)], isClosed: true))
    private let hole = BezierPath(Polyline(points: [Point(5, 5), Point(15, 5), Point(15, 15), Point(5, 15)], isClosed: true))

    @Test func growAndShrink() {
        let grown = ContourTracer.offset([square], distanceMM: 2)
        #expect(grown.count == 1 && abs(grown[0].bounds.width - 24) < 0.25)
        let shrunk = ContourTracer.offset([square], distanceMM: -2)
        #expect(shrunk.count == 1 && abs(shrunk[0].bounds.width - 16) < 0.1)
        #expect(ContourTracer.offset([square], distanceMM: -11).isEmpty)
    }

    @Test func holesShrinkAndClose() {
        let ring = ContourTracer.offset([square, hole], distanceMM: 1)
        #expect(ring.count == 2)
        let hasShrunkHole = ring.contains { abs($0.bounds.width - 8) < 0.15 }
        #expect(hasShrunkHole)
        #expect(ContourTracer.offset([square, hole], distanceMM: 6).count == 1)
    }

    @Test func offsetObjectsKeepTheirPlace() {
        var o = DesignObject(name: "C", kind: .artwork(ArtworkSpec(sourceName: "t", curves: [])),
                             frame: Rect(minX: 10, minY: 20, maxX: 30, maxY: 40), rotation: 30)
        o.setArtworkLocalCurves([square])
        let offset = o.offsetArtworkCurves(distanceMM: 2)
        let replaced = o.replacingWithOffset(offset)!
        #expect(replaced.id == o.id && replaced.frame.center.distance(to: o.frame.center) < 0.1)
        let copy = o.offsetCopy(offset, name: "copy")!
        #expect(copy.id != o.id && copy.rotation == 30 && copy.frame.center.distance(to: o.frame.center) < 0.1)
    }
}

@Suite struct ColorPickTests {
    /// Opaque 200 × 200 px PNG at 20 × 20 mm: white background, a 12 mm blue square with a 6 × 8 mm red bar inside.
    private func image() -> DesignObject {
        let w = 200
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))
        ctx.setFillColor(CGColor(red: 0.6, green: 0.8, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.35, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 70, y: 60, width: 60, height: 80))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dest)
        return DesignObject(name: "img", kind: .image(ImageSpec(sourceName: "p.png", data: data as Data, format: "png")),
                            frame: Rect(minX: 0, minY: 0, maxX: 20, maxY: 20))
    }

    @Test func clickingTheBackgroundRemovesIt() {
        let lines = ContourTracer.contours(for: image(), options: ContourOptions(distanceMM: 1, picks: [ColorPick(point: Point(0.02, 0.02), tolerance: 10)]))
        #expect(lines.count == 1)
        #expect(abs(lines[0].bounds.width - 14) < 0.4)   // the 12 mm square + 1 mm each side
    }

    @Test func picksStackAndCanPutAreasBack() {
        let corner = ColorPick(point: Point(0.02, 0.02), tolerance: 10)
        let blue = ColorPick(point: Point(0.25, 0.25), tolerance: 10)   // inside the blue square, outside the bar
        let removed = ContourTracer.contours(for: image(), options: ContourOptions(distanceMM: 0, picks: [corner, blue]))
        #expect(removed.count == 1 && abs(removed[0].bounds.width - 6) < 0.4)   // only the red bar is left
        var back = blue
        back.keep = true
        let restored = ContourTracer.contours(for: image(), options: ContourOptions(distanceMM: 0, picks: [corner, blue, back]))
        #expect(restored.count == 1 && abs(restored[0].bounds.width - 12) < 0.4)
    }

    @Test func toleranceDecidesWhatIsTaken() {
        // The blue is far from white: a small tolerance stops at it, a huge one takes everything connected.
        let small = ContourTracer.artworkMask(for: image(), options: ContourOptions(picks: [ColorPick(point: Point(0.02, 0.02), tolerance: 10)]), pixelsPerMM: 10)!
        let huge = ContourTracer.artworkMask(for: image(), options: ContourOptions(picks: [ColorPick(point: Point(0.02, 0.02), tolerance: 100)]), pixelsPerMM: 10)!
        #expect(small[100, 100] && !small[5, 5])
        #expect(!huge[100, 100])
    }
}
