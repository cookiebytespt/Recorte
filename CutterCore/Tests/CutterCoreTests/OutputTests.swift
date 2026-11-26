import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CutterCore

@Suite struct MarkPlacementTests {
    @Test func aroundArtworkMatchesSignMasterJob() {
        // SignMaster: artwork 209.291 × 174.150 mm, Mark Position 20.5 mm → TB25,10012,6966.
        let artwork = Rect(origin: Point(20, 40), size: Size(209.291, 174.150))
        let sheet = PrintSheet(page: Size(297, 420), layout: RegistrationMarkLayout(artworkDistanceMM: 20.5), artwork: artwork, title: "Job")
        #expect(abs(sheet.markSpacing.width - 250.291) < 1e-9)
        #expect(abs(sheet.markSpacing.height - 174.150) < 1e-9)
        #expect(abs(sheet.originMark.x - (20 - 20.5)) < 1e-9)   // marks can't go off the page…
        #expect(!sheet.marksFitPage)                              // …and that is reported
        let hpgl = PrintAndCutHPGL.generate(paths: [], sheet: sheet)
        #expect(hpgl.hasPrefix("TB25,10012,6966;CT1;"))
    }

    @Test func matchesSignMasterOnA330mmSheet() {
        // SignMaster job 100010 ("biscoitos"): artwork 286.28 × 423.33 mm, Mark Position 20.5 → TB25,13091,16933.
        let artwork = Rect(origin: Point(21.86, 25), size: Size(286.28, 423.33))
        let sheet = PrintSheet(page: Size(330, 480), layout: RegistrationMarkLayout(), artwork: artwork, title: "biscoitos")
        #expect(PrintAndCutHPGL.generate(paths: [], sheet: sheet).hasPrefix("TB25,13091,16933;CT1;"))
        #expect(!sheet.marksFitPage)   // the circles hang 1.15 mm off a 330 mm sheet: a warning, like SignMaster's 332 mm page
        // The job name ends 41 mm before the top-right mark and sits just above the artwork.
        let end = sheet.jobNameTrailing(width: 12)
        #expect(abs(sheet.markFrame.maxX - end.x - 41) < 1e-9)
        #expect(end.y < artwork.minY && end.y > artwork.minY - 4)
        // The feed arrow is 18 mm from the origin mark (20 mm would touch the artwork at a 20.5 mm gap).
        #expect(abs(sheet.layout.arrowOffsetMM(frameWidth: sheet.markFrame.width) - 18) < 1e-9)
    }

    @Test func gentleCurvesGetOnePointPerVertex() {
        // A 20 mm circle flattened into 120 segments: 3° per vertex, well under the corner threshold.
        let circle = Polyline(points: (0..<120).map { i in
            let a = Double(i) / 120 * 2 * .pi
            return Point(10 + 10 * cos(a), 10 + 10 * sin(a))
        }, isClosed: true)
        let out = BladeOffsetCompensator(offset: 0.25, overcut: 0).apply(circle)
        #expect(out.points.count <= 122)
        // The carriage leads the blade by the offset along the tangent: it stays about √(r² + offset²) from the centre.
        for p in out.points.dropFirst().dropLast() {
            #expect(abs(p.distance(to: Point(10, 10)) - (100 + 0.0625).squareRoot()) < 0.01)
        }
    }

    @Test func hpglSendsEachPositionOnce() {
        let line = Polyline(points: [Point(0, 0), Point(0.005, 0), Point(0.01, 0), Point(10, 0)], isClosed: false)
        let hpgl = HPGLGenerator().generate([line], options: HPGLOptions(stepsPerMM: 40))
        #expect(hpgl.contains("PU0,0;PD0,400;"))
    }

    @Test func designDocumentPlacesMarksAroundItsObjects() {
        let square = DesignObject(name: "s", kind: .rectangle(cornerRadius: 0), frame: Rect(minX: 50, minY: 60, maxX: 90, maxY: 100))
        var design = DesignDocument(name: "d", canvasSize: Size(210, 297), objects: [square])
        design.printAndCut.isEnabled = true
        design.printAndCut.layout.artworkDistanceMM = 20.5
        let sheet = design.printSheet
        #expect(sheet.markFrame == Rect(minX: 29.5, minY: 60, maxX: 110.5, maxY: 100))
        #expect(sheet.marksFitPage)
        var settings = JobSettings.defaults(for: .liyuGF1261)
        settings.bladeOffsetMM = 0
        settings.overcutMM = 0
        let job = JobPlanner.planPrintAndCut(document: design.cutDocument(), sheet: sheet, settings: settings, machine: .liyuGF1261)
        #expect(job.fitsMachine)
        // The square's top-left corner is 20.5 mm right of the origin mark: plotter X (feed) 0, Y (across) 820.
        #expect(job.hpgl.contains(",820;") || job.hpgl.contains(",820,"))
    }

    @Test func olderProjectsKeepPageEdgeMarks() throws {
        let json = #"{"markSizeParameter":25,"sideInsetMM":2.5,"topInsetMM":15,"bottomInsetMM":15}"#
        let layout = try JSONDecoder().decode(RegistrationMarkLayout.self, from: Data(json.utf8))
        #expect(layout.placement == .pageEdges)
        #expect(layout.printsMarks && layout.printsJobName)
        #expect(RegistrationMarkLayout().placement == .aroundArtwork)
    }

    @Test func marksNeverSmallerThanTheSensorCanFind() throws {
        #expect(RegistrationMarkLayout(markSizeParameter: 15).markSizeParameter == 25)
        let json = #"{"markSizeParameter":20}"#
        let layout = try JSONDecoder().decode(RegistrationMarkLayout.self, from: Data(json.utf8))
        #expect(layout.markSizeParameter == 25)
        #expect(RegistrationMarkLayout(markSizeParameter: 30).markSizeParameter == 30)
    }

    @Test func artworkAreaLeavesJustEnoughRoomForTheMarks() {
        let a4 = Size(210, 297)
        // Default (SignMaster's 20.5 mm gap) + mark radius + 3 mm printer margin at the sides.
        let area = RegistrationMarkLayout().artworkArea(for: a4)
        #expect(abs(area.minX - 26) < 1e-9 && abs(area.maxX - 184) < 1e-9)
        #expect(abs(area.minY - 7) < 1e-9)       // job name 1 mm above the artwork, 3 mm tall, plus 3 mm margin
        #expect(abs(area.maxY - (297 - 5.5)) < 1e-9)
        // A narrow gap puts the feed arrow above the origin mark: 5 + 3.5, plus 3 mm margin.
        let tight = RegistrationMarkLayout(artworkDistanceMM: 10).artworkArea(for: a4)
        #expect(abs(tight.minX - 15.5) < 1e-9 && abs(tight.minY - 11.5) < 1e-9)
        // Without the job name and with a wide gap (arrow beside the mark) only the mark itself is above.
        let bare = RegistrationMarkLayout(artworkDistanceMM: 20.5, printsJobName: false).artworkArea(for: a4)
        #expect(abs(bare.minY - 5.5) < 1e-9)
    }

    @Test func sheetExportsAsImage() throws {
        let sheet = PrintSheet(page: Size(50, 40), layout: RegistrationMarkLayout(placement: .pageEdges), title: "T")
        let data = try #require(PrintSheetRenderer.imageData(sheet: sheet, format: .png, dpi: 150) { _ in })
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Int((50 * 150 / 25.4).rounded()))
    }

    @Test func plainCutCopiesFollowAlongTheFeed() {
        let doc = CutDocument(name: "x", paths: [Polyline(points: [Point(0, 0), Point(10, 0), Point(10, 20), Point(0, 20)], isClosed: true)])
        var settings = JobSettings.defaults(for: .liyuGF1261)
        settings.copies = 3
        settings.copyGapMM = 5
        let job = JobPlanner.plan(document: doc, settings: settings, machine: .liyuGF1261)
        #expect(job.cutPaths.count == 3)
        #expect(abs(job.bounds.height - (20 * 3 + 5 * 2)) < 1e-9)
        #expect(abs(job.bounds.width - 10) < 1e-9)
    }
}

@Suite struct ContourTracerTests {
    private func squareMask(size: Int = 40, from: Int = 10, to: Int = 30, hole: ClosedRange<Int>? = nil) -> BitMask {
        var m = BitMask(width: size, height: size)
        for y in from..<to { for x in from..<to { m[x, y] = true } }
        if let hole { for y in hole { for x in hole { m[x, y] = false } } }
        return m
    }

    @Test func tracesASquareAtZeroDistance() {
        let loops = ContourTracer.trace(mask: squareMask(), pixelsPerMM: 1,
                                        options: ContourOptions(distanceMM: 0, minimumSpeckMM: 0))
        #expect(loops.count == 1)
        let b = loops[0].bounds
        // Marching-squares vertices sit on edge midpoints, so corners are cut by half a pixel.
        #expect(abs(b.minX - 10) <= 0.5 && abs(b.maxX - 30) <= 0.5)
        #expect(abs(b.minY - 10) <= 0.5 && abs(b.maxY - 30) <= 0.5)
    }

    @Test func roundOffsetGrowsByTheDistance() {
        let loops = ContourTracer.trace(mask: squareMask(), pixelsPerMM: 1,
                                        options: ContourOptions(distanceMM: 4, corners: .round, minimumSpeckMM: 0))
        #expect(loops.count == 1)
        let b = loops[0].bounds
        #expect(abs(b.minX - 6) <= 1 && abs(b.maxX - 34) <= 1)
    }

    @Test func sharpOffsetKeepsSquareCorners() {
        let loops = ContourTracer.trace(mask: squareMask(), pixelsPerMM: 1,
                                        options: ContourOptions(distanceMM: 4, corners: .sharp, minimumSpeckMM: 0))
        #expect(loops.count == 1)
        let b = loops[0].bounds
        #expect(abs(b.minX - 6) <= 1 && abs(b.maxY - 34) <= 1)
        #expect(loops[0].points.count <= 12)
    }

    @Test func holesAreOptional() {
        let mask = squareMask(hole: 17...22)
        let with = ContourTracer.trace(mask: mask, pixelsPerMM: 1, options: ContourOptions(distanceMM: 0, cutHoles: true, minimumSpeckMM: 0))
        let without = ContourTracer.trace(mask: mask, pixelsPerMM: 1, options: ContourOptions(distanceMM: 0, cutHoles: false, minimumSpeckMM: 0))
        #expect(with.count == 2)
        #expect(without.count == 1)
    }

    @Test func specksAreIgnored() {
        var mask = squareMask()
        mask[2, 2] = true
        let loops = ContourTracer.trace(mask: mask, pixelsPerMM: 1, options: ContourOptions(distanceMM: 0, minimumSpeckMM: 3))
        #expect(loops.count == 1)
    }

    @Test func diagonalNeighboursStaySeparate() {
        var mask = BitMask(width: 20, height: 20)
        for y in 2..<8 { for x in 2..<8 { mask[x, y] = true } }
        for y in 8..<14 { for x in 8..<14 { mask[x, y] = true } }
        let loops = ContourTracer.trace(mask: mask, pixelsPerMM: 1, options: ContourOptions(distanceMM: 0, minimumSpeckMM: 0))
        #expect(loops.count == 2)
    }

    @Test func tracesAPlacedPNG() throws {
        // 200 × 200 px transparent PNG with an opaque disc, placed at 20 × 20 mm.
        let w = 200
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 50, y: 50, width: 100, height: 100))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        let object = DesignObject(name: "img", kind: .image(ImageSpec(sourceName: "d.png", data: data as Data, format: "png")),
                                  frame: Rect(minX: 100, minY: 50, maxX: 120, maxY: 70))
        let loops = ContourTracer.contours(for: object, options: ContourOptions(distanceMM: 2))
        #expect(loops.count == 1)
        let b = loops[0].bounds
        // Disc Ø10 mm centred at (110, 60), grown by 2 mm → Ø14 mm.
        #expect(abs(b.width - 14) < 0.4 && abs(b.center.x - 110) < 0.3 && abs(b.center.y - 60) < 0.3)

        let box = ContourTracer.contours(for: object, options: ContourOptions(shape: .rectangle, distanceMM: 1))
        #expect(box.count == 1)
        #expect(abs(box[0].bounds.width - 12) < 0.3)
    }
}


/// SignMaster *Save as PLT* files (docs/debugging/captures/signmaster/plt/) are the reference for job bytes.
@Suite struct SignMasterGoldenTests {
    static let pltFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/debugging/captures/signmaster/plt")

    static func golden(_ name: String) throws -> String {
        try String(contentsOf: pltFolder.appendingPathComponent(name), encoding: .ascii)
    }

    /// Splits `PU…;PD…;` commands into polylines of plotter steps (X along the feed, Y across).
    static func parsePaths(_ body: Substring) -> [[(Int, Int)]] {
        var paths: [[(Int, Int)]] = []
        for command in body.split(separator: ";") {
            let op = command.prefix(2)
            let nums = command.dropFirst(2).split(separator: ",").compactMap { Int($0) }
            guard nums.count == 2 else { continue }
            if op == "PU" { paths.append([(nums[0], nums[1])]) }
            else if op == "PD", !paths.isEmpty { paths[paths.count - 1].append((nums[0], nums[1])) }
        }
        return paths
    }

    /// The Print & Cut sheet SignMaster used: marks 250.29 × 174.15 mm apart → TB25,10012,6966.
    static let captureSheet = PrintSheet(page: Size(255.29, 257.17),
                                         layout: RegistrationMarkLayout(markSizeParameter: 25, sideInsetMM: 2.5, topInsetMM: 28.03,
                                                                        bottomInsetMM: 257.17 - 202.18, placement: .pageEdges))

    @Test(arguments: [("contour-speed451-force70.plt", 451, 70), ("contour-speed451-force120.plt", 451, 120),
                      ("contour-speed100-force120.plt", 100, 120), ("contour-speed120-force120.plt", 120, 120)])
    func printAndCutJobMatchesSignMaster(file: String, speed: Int, force: Int) throws {
        let golden = try Self.golden(file)
        let sheet = Self.captureSheet
        // Rebuild SignMaster's cut paths (lead-in stroke included) in page millimetres and regenerate.
        let bodyStart = try #require(golden.range(of: "\r\nIN;SP1;"))
        let trailer = try #require(golden.range(of: "PU6966,0;PG!;", options: .backwards))
        let paths = Self.parsePaths(golden[bodyStart.upperBound..<trailer.lowerBound]).map { steps in
            Polyline(points: steps.map { Point(Double($0.1) / 40 + sheet.markFrame.minX, Double($0.0) / 40 + sheet.markFrame.minY) })
        }
        let ours = PrintAndCutHPGL.generate(paths: paths, sheet: sheet, speed: speed, force: force)
        #expect(ours.hasPrefix("TB25,10012,6966;CT1;SP1;VS\(speed);HS\(force);" + String(repeating: " ", count: 1024) + "\r\nIN;SP1;"))
        #expect(ours == golden)
    }

    @Test func printAndCutWithoutSpeedKeepsTheCapturedHeader() {
        let ours = PrintAndCutHPGL.generate(paths: [], sheet: Self.captureSheet)
        #expect(ours.hasPrefix("TB25,10012,6966;CT1;" + String(repeating: " ", count: 1024) + "\r\nIN;SP1;PU"))
    }

    @Test(arguments: ["plain-black-passes1.plt", "plain-black-spooler-cleared.plt", "plain-rectangle-speed120-force70.plt"])
    func plainJobMatchesSignMaster(file: String) throws {
        let golden = try Self.golden(file)
        #expect(golden.hasPrefix("IN;SP1;SP1;VS120;HS70;"))
        let trailerStart = try #require(golden.range(of: ";PU", options: .backwards))
        let body = golden[golden.index(golden.startIndex, offsetBy: "IN;SP1;SP1;VS120;HS70;".count)...trailerStart.lowerBound]
        let advance = try #require(Int(golden[trailerStart.upperBound...].prefix { $0.isNumber }))
        let steps = Self.parsePaths(body)
        let minAcross = steps.flatMap { $0 }.map(\.1).min()!, minFeed = steps.flatMap { $0 }.map(\.0).min()!
        let paths = steps.map { Polyline(points: $0.map { Point(Double($0.1) / 40, Double($0.0) / 40) }) }
        let options = HPGLOptions(speed: 120, force: 70, originOffset: Point(Double(minAcross) / 40, Double(minFeed) / 40),
                                  advanceFeedMM: Double(advance) / 40)
        let ours = HPGLGenerator().generate(paths, options: options)
        #expect(ours.hasSuffix("PU\(advance),0;PG;\r\n"))
        #expect(ours == golden)
    }

    @Test func plannedPlainJobUsesSignMasterFraming() {
        let rect = Polyline(points: [Point(0, 0), Point(104, 0), Point(104, 86), Point(0, 86)], isClosed: true)
        var settings = JobSettings.defaults(for: .liyuGF1261)
        settings.sendSpeedAndForce = true
        settings.speed = 120
        settings.force = 70
        settings.marginX = 2
        settings.marginY = 2
        let job = JobPlanner.plan(document: CutDocument(name: "r", paths: [rect]), settings: settings, machine: .liyuGF1261)
        // The rectangle's corner sits exactly 2 mm from the origin (80 steps); blade loops may go past it.
        #expect(job.hpgl.hasPrefix("IN;SP1;SP1;VS120;HS70;PU80,80;"))
        // Advance to the design's far edge: (86 + 2) mm × 40 = 3520 steps (blade loops don't count).
        #expect(job.hpgl.hasSuffix("PU3520,0;PG;\r\n"))
        #expect(job.hpgl.filter(\.isNewline).count == 1)

        settings.sendSpeedAndForce = false
        let quiet = JobPlanner.plan(document: CutDocument(name: "r", paths: [rect]), settings: settings, machine: .liyuGF1261)
        #expect(quiet.hpgl.hasPrefix("IN;SP1;PU"))
        #expect(!quiet.hpgl.contains("VS") && !quiet.hpgl.contains("HS") && !quiet.hpgl.contains("FS"))
    }

    @Test func defaultsFollowSignMaster() {
        #expect(!MachineProfile.liyuGF1261.sendsSpeedAndForce)
        #expect(MaterialPreset.standardVinyl.speed == 300)   // mm/s (was 30 cm/s)
        #expect(!JobSettings.defaults(for: .liyuGF1261).sendSpeedAndForce)
    }
}
