import CoreGraphics
import Foundation
import Testing
@testable import CutterCore

@Suite struct ProcessingTests {
    @Test func innerShapesAreCutFirst() {
        let outer = Polyline(points: [Point(0, 0), Point(100, 0), Point(100, 100), Point(0, 100)], isClosed: true)
        let inner = Polyline(points: [Point(40, 40), Point(60, 40), Point(60, 60), Point(40, 60)], isClosed: true)
        let ordered = PathOptimizer().optimize([outer, inner], startingAt: .zero)
        #expect(ordered.count == 2)
        #expect(abs(ordered[0].bounds.width - 20) < 1e-9)
        #expect(abs(ordered[1].bounds.width - 100) < 1e-9)
    }

    @Test func openPathsAreReversedWhenCloser() {
        let far = Polyline(points: [Point(100, 0), Point(0, 0)])
        let ordered = PathOptimizer().optimize([far], startingAt: .zero)
        #expect(ordered[0].start == Point(0, 0))
    }

    @Test func bladeOffsetExtendsCorners() {
        let square = Polyline(points: [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)], isClosed: true)
        let result = BladeOffsetCompensator(offset: 0.5, overcut: 1).apply(square)
        #expect(!result.isClosed)
        #expect(result.points.count > 8)
        #expect(abs(result.bounds.maxX - 10.5) < 1e-6)
        #expect(abs(result.bounds.maxY - 10.5) < 1e-6)
    }

    @Test func hpglOutput() {
        let square = Polyline(points: [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)], isClosed: true)
        let hpgl = HPGLGenerator().generate([square], options: HPGLOptions(stepsPerMM: 40, speed: 20, force: 80))
        #expect(hpgl.hasPrefix("IN;\nSP1;\nVS20;\nFS80;\n"))
        // (x across, y feed) → plotter (feed, across)
        #expect(hpgl.contains("PU0,0;"))
        #expect(hpgl.contains("PD0,400,400,400,400,0,0,0;"))
        #expect(hpgl.hasSuffix("PU0,0;\nSP0;\n"))
    }

    @Test func plannerMirrorsAndScales() {
        let tri = Polyline(points: [Point(0, 0), Point(10, 0), Point(0, 5)], isClosed: true)
        let doc = CutDocument(name: "t", paths: [tri])
        var settings = JobSettings.defaults(for: .liyuGF1261)
        settings.scale = 2
        settings.mirror = true
        let job = JobPlanner.plan(document: doc, settings: settings, machine: .liyuGF1261)
        #expect(abs(job.bounds.width - 20) < 1e-9)
        #expect(abs(job.bounds.height - 10) < 1e-9)
        #expect(job.fitsMachine)
        #expect(job.hpgl.contains("PD"))
    }
}

@Suite struct DesignTests {
    @Test func shapesProduceOutlines() {
        let rect = DesignObject(name: "r", kind: .rectangle(cornerRadius: 5), frame: Rect(minX: 10, minY: 10, maxX: 60, maxY: 40))
        let out = rect.outlines()
        #expect(out.count == 1 && out[0].isClosed)
        #expect(abs(out[0].bounds.minX - 10) < 0.01 && abs(out[0].bounds.maxX - 60) < 0.01)

        var rotated = rect
        rotated.rotation = 90
        let rb = rotated.outlines().bounds
        #expect(abs(rb.width - 30) < 0.01 && abs(rb.height - 50) < 0.01)
        #expect(rotated.hitTest(Point(35, 25), tolerance: 0.5))
        #expect(!rotated.hitTest(Point(5, 5), tolerance: 0.5))
    }

    @Test func textOutlinesAndRoundTrip() throws {
        let spec = TextSpec(text: "Ab", fontName: "Helvetica", fontSize: 72)
        let size = DesignObject.naturalTextSize(spec)
        #expect(size.width > 10 && size.height > 10)
        let text = DesignObject(name: "t", kind: .text(spec), frame: Rect(origin: Point(0, 0), size: size))
        #expect(!text.outlines().isEmpty)

        var doc = DesignDocument(name: "d")
        doc.objects = [text]
        let data = try DesignDocument.encode(doc)
        let back = try DesignDocument.decode(data)
        #expect(back == doc)
        #expect(!doc.cutDocument().isEmpty)
    }

    @Test func importBecomesArtworkObject() {
        let tri = Polyline(points: [Point(5, 5), Point(25, 5), Point(5, 15)], isClosed: true)
        let design = DesignDocument.fromImport(CutDocument(name: "x", paths: [tri]), sourceName: "x.svg")
        #expect(design.objects.count == 1)
        let b = design.objects[0].outlines().bounds
        #expect(abs(b.width - 20) < 0.01 && abs(b.height - 10) < 0.01)
    }
}

@Suite struct PrintAndCutTests {
    @Test func markLayoutMatchesSignMasterSheet() {
        // The captured SignMaster sheet: 255.41 × 257.17 mm, marks 2.5 mm from the sides,
        // 28.03 mm from the top and 55 mm from the bottom → TB25,10012,6966.
        let layout = RegistrationMarkLayout(markSizeParameter: 25, sideInsetMM: 2.5, topInsetMM: 28.03, bottomInsetMM: 257.17 - 202.18)
        let page = Size(250.29 + 5, 257.17)
        #expect(abs(layout.markDiameterMM - 5) < 1e-9)
        let hpgl = PrintAndCutHPGL.generate(paths: [], page: page, layout: layout)
        #expect(hpgl.hasPrefix("TB25,10012,6966;CT1;" + String(repeating: " ", count: 1024) + "\r\nIN;SP1;"))
        #expect(hpgl.hasSuffix("PU6966,0;PG!;\r\n"))
    }

    @Test func pathsAreRelativeToTopLeftMark() {
        let layout = RegistrationMarkLayout(markSizeParameter: 25, sideInsetMM: 2.5, topInsetMM: 28, bottomInsetMM: 20)
        let page = Size(200, 200)
        // A line 10 mm right of the origin mark and 5 mm down → plotter X (feed) 200, Y (across) 400.
        let line = Polyline(points: [Point(12.5, 33), Point(12.5, 43)])
        let hpgl = PrintAndCutHPGL.generate(paths: [line], page: page, layout: layout)
        #expect(hpgl.contains("PU200,400;PD600,400;"))   // Print & Cut uses no line breaks, like SignMaster
    }

    @Test func plainCutUsesFeedAsX() {
        // Document x (across) → plotter Y, document y (feed) → plotter X.
        let line = Polyline(points: [Point(0, 0), Point(30, 0)])
        let hpgl = HPGLGenerator().generate([line], options: HPGLOptions(originOffset: Point(5, 5)))
        #expect(hpgl.contains("PU200,200;\nPD200,1400;"))
    }

    @Test func printSheetPDFRenders() {
        let layout = RegistrationMarkLayout()
        let data = PrintSheetRenderer.pdfData(page: Size(210, 297), layout: layout, title: "Job 1") { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 40, width: 50, height: 30))
        }
        #expect((data?.count ?? 0) > 500)
        let imported = try? DocumentLoader.load(data: data!, filename: "sheet.pdf")
        // Four mark circles plus the rectangle, label glyphs and arrow come back as paths.
        #expect((imported?.paths.count ?? 0) >= 5)
    }

    @Test func printAndCutPlanKeepsPagePositions() {
        let square = DesignObject(name: "s", kind: .rectangle(cornerRadius: 0), frame: Rect(minX: 50, minY: 60, maxX: 90, maxY: 100))
        var design = DesignDocument(name: "d", canvasSize: Size(210, 297), objects: [square])
        design.printAndCut.isEnabled = true
        let job = JobPlanner.planPrintAndCut(document: design.cutDocument(), page: design.canvasSize, layout: design.printAndCut.layout,
                                             settings: JobSettings.defaults(for: .liyuGF1261), machine: .liyuGF1261)
        #expect(job.isPrintAndCut)
        #expect(job.fitsMachine)
        #expect(abs(job.bounds.minX - 50) < 1e-9)
        #expect(job.hpgl.hasPrefix("TB25,"))
    }
}
