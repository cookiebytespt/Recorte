import CoreGraphics
import Foundation
import Testing
@testable import CutterCore

@Suite struct SVGImportTests {
    @Test func rectInMillimetres() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="50mm" viewBox="0 0 100 50">
          <rect x="10" y="10" width="30" height="20"/>
        </svg>
        """
        let doc = try DocumentLoader.load(data: Data(svg.utf8), filename: "test.svg")
        #expect(doc.paths.count == 1)
        #expect(doc.paths[0].isClosed)
        #expect(doc.pageSize == Size(100, 50))
        let b = doc.bounds
        #expect(abs(b.minX - 10) < 1e-9 && abs(b.width - 30) < 1e-9 && abs(b.height - 20) < 1e-9)
    }

    @Test func pathWithRelativeCommandsAndTransform() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100mm" height="100mm" viewBox="0 0 100 100">
          <g transform="translate(10,10)">
            <path d="m0,0 l10,0 0,10 h-10 z M20 20 C 30 20 30 30 20 30"/>
          </g>
        </svg>
        """
        let doc = try DocumentLoader.load(data: Data(svg.utf8), filename: "t.svg")
        #expect(doc.paths.count == 2)
        let square = doc.paths[0]
        #expect(square.isClosed)
        #expect(abs(square.bounds.minX - 10) < 1e-9 && abs(square.bounds.maxX - 20) < 1e-9)
        #expect(!doc.paths[1].isClosed)
    }

    @Test func arcsAndCompactFlags() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <path d="M50 10a40 40 0 1180 0a40 40 0 1 1-80 0"/>
        </svg>
        """
        let doc = try DocumentLoader.load(data: Data(svg.utf8), filename: "t.svg", options: ImportOptions(unitlessDPI: 25.4))
        #expect(doc.paths.count == 1)
        #expect(doc.paths[0].points.count > 8)
        #expect(abs(doc.bounds.width - 80) < 0.5)
    }

    @Test func textProducesWarning() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm"><text>Hi</text><circle cx="5" cy="5" r="2"/></svg>
        """
        let doc = try DocumentLoader.load(data: Data(svg.utf8), filename: "t.svg")
        #expect(doc.warnings.contains(.textIgnored(count: 1)))
    }

    @Test func unsupportedExtension() {
        #expect(throws: ImportError.unsupportedFormat("png")) {
            try DocumentLoader.load(data: Data(), filename: "x.png")
        }
    }
}

@Suite struct DXFImportTests {
    @Test func lineAndClosedPolyline() throws {
        let dxf = """
        0
        SECTION
        2
        HEADER
        9
        $INSUNITS
        70
        4
        0
        ENDSEC
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        10
        0
        20
        0
        11
        10
        21
        0
        0
        LWPOLYLINE
        70
        1
        10
        0
        20
        0
        10
        10
        20
        0
        10
        10
        20
        10
        0
        ENDSEC
        0
        EOF
        """
        let doc = try DocumentLoader.load(data: Data(dxf.utf8), filename: "t.dxf")
        #expect(doc.paths.count == 2)
        #expect(doc.paths[1].isClosed)
        #expect(abs(doc.bounds.width - 10) < 1e-9)
    }
}

@Suite struct PDFImportTests {
    @Test func rectangleFromGeneratedPDF() throws {
        // Build a one-page PDF with CoreGraphics and read it back.
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 72 * 4, height: 72 * 2) // 4in × 2in
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.addRect(CGRect(x: 72, y: 72, width: 72, height: 36))
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()

        let doc = try DocumentLoader.load(data: data as Data, filename: "t.pdf")
        #expect(doc.paths.count == 1)
        #expect(doc.paths[0].isClosed)
        #expect(abs(doc.bounds.width - 25.4) < 0.01)
        #expect(abs(doc.bounds.height - 12.7) < 0.01)
        // 1in from the left, 1in from the bottom → top of rect at 2in - 1.5in = 0.5in from the top.
        #expect(abs(doc.bounds.minX - 25.4) < 0.01)
        #expect(abs(doc.bounds.minY - 12.7) < 0.01)
        #expect(doc.pageSize == Size(101.6, 50.8))
    }
}
