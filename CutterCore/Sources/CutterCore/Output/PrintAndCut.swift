import CoreGraphics
import Foundation

/// Where the four registration marks sit on the printed sheet.
/// Defaults reproduce the SignMaster/VinylMaster layout the Liyu's camera is set up for.
public struct RegistrationMarkLayout: Sendable, Hashable, Codable {
    /// First parameter of the cutter's `TB` command (the "mark size" setting in SignMaster).
    /// The printed circle diameter is `markSizeParameter × 0.2 mm`, so 25 → Ø5 mm.
    public var markSizeParameter: Int
    /// Mark centre distance from the left and right page edges, in mm.
    public var sideInsetMM: Double
    /// Mark centre distance from the top edge (room for the feed arrow and job label), in mm.
    public var topInsetMM: Double
    /// Mark centre distance from the bottom edge, in mm.
    public var bottomInsetMM: Double

    public init(markSizeParameter: Int = 25, sideInsetMM: Double = 2.5, topInsetMM: Double = 15, bottomInsetMM: Double = 15) {
        self.markSizeParameter = markSizeParameter
        self.sideInsetMM = sideInsetMM
        self.topInsetMM = topInsetMM
        self.bottomInsetMM = bottomInsetMM
    }

    public var markDiameterMM: Double { Double(markSizeParameter) * 0.2 }

    /// Rectangle through the four mark centres, in page coordinates (mm, origin top-left).
    public func markFrame(for page: Size) -> Rect {
        Rect(minX: sideInsetMM, minY: topInsetMM, maxX: page.width - sideInsetMM, maxY: page.height - bottomInsetMM)
    }

    public func markCenters(for page: Size) -> [Point] {
        let f = markFrame(for: page)
        return [Point(f.minX, f.minY), Point(f.maxX, f.minY), Point(f.minX, f.maxY), Point(f.maxX, f.maxY)]
    }

    /// Area that can safely carry artwork and cut lines (inside the marks, clear of the circles).
    public func safeArea(for page: Size) -> Rect {
        markFrame(for: page).insetBy(markDiameterMM)
    }
}

public struct PrintAndCutSettings: Sendable, Hashable, Codable {
    public var isEnabled: Bool
    public var layout: RegistrationMarkLayout

    public init(isEnabled: Bool = false, layout: RegistrationMarkLayout = RegistrationMarkLayout()) {
        self.isEnabled = isEnabled
        self.layout = layout
    }
}

/// Builds the contour-cut job the Liyu expects after a sheet with registration marks is loaded.
///
/// Stream format (from a SignMaster capture):
///
///     TB<size>,<across steps>,<feed steps>;CT1;<1024 spaces>\r\n
///     IN;SP1;PU…;PD…;…
///     PU<feed steps>,0;PG!;\r\n
///
/// Coordinates are relative to the top-left mark: plotter X along the feed (down the page),
/// plotter Y across the page (left → right), 40 steps/mm.
public enum PrintAndCutHPGL {
    public static let fillerLength = 1024

    /// `paths` are in page coordinates (mm, origin top-left of the sheet).
    public static func generate(paths: [Polyline], page: Size, layout: RegistrationMarkLayout,
                                stepsPerMM: Double = 40, speed: Int? = nil, force: Int? = nil) -> String {
        let frame = layout.markFrame(for: page)
        let across = Int((frame.width * stepsPerMM).rounded())
        let feed = Int((frame.height * stepsPerMM).rounded())
        let options = HPGLOptions(stepsPerMM: stepsPerMM, speed: speed, force: force, swapAxes: true, lineTerminator: "")
        let generator = HPGLGenerator()

        var out = "TB\(layout.markSizeParameter),\(across),\(feed);CT1;"
        out += String(repeating: " ", count: fillerLength)
        out += "\r\n"
        out += generator.header(options: options)
        out += generator.body(paths, options: options) { p in
            HPGLGenerator.steps(across: p.x - frame.minX, feed: p.y - frame.minY, options: options)
        }
        out += "PU\(feed),0;PG!;\r\n"
        return out
    }
}

/// Renders the printable sheet: artwork images, registration marks, feed arrow and job label.
public enum PrintSheetRenderer {
    /// `drawArtwork` is called with a CoreGraphics context in page space (mm, origin top-left, Y down)
    /// and should draw the printed content; marks and labels are added here.
    public static func pdfData(page: Size, layout: RegistrationMarkLayout, title: String,
                               drawArtwork: (CGContext) -> Void) -> Data? {
        let ptPerMM = 72.0 / 25.4
        var mediaBox = CGRect(x: 0, y: 0, width: page.width * ptPerMM, height: page.height * ptPerMM)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle as String: title] as CFDictionary) else {
            return nil
        }
        ctx.beginPDFPage(nil)
        // Page space in millimetres with Y pointing down.
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: ptPerMM, y: -ptPerMM)

        drawArtwork(ctx)
        drawMarks(in: ctx, page: page, layout: layout, title: title)

        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Draws the marks, arrow and label in a millimetre, Y-down context.
    public static func drawMarks(in ctx: CGContext, page: Size, layout: RegistrationMarkLayout, title: String) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        let d = layout.markDiameterMM
        for c in layout.markCenters(for: page) {
            ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        }
        // Feed arrow next to the origin mark (points towards the top edge, like the SignMaster sheet).
        let frame = layout.markFrame(for: page)
        let ax = frame.minX + d + 6, ay = frame.minY
        ctx.move(to: CGPoint(x: ax - 1.5, y: ay + 1.5))
        ctx.addLine(to: CGPoint(x: ax, y: ay - 1.5))
        ctx.addLine(to: CGPoint(x: ax + 1.5, y: ay + 1.5))
        ctx.setLineWidth(0.4)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.strokePath()
        // Job label as outlines (no fonts in the PDF).
        let label = TextOutliner.outlines(TextSpec(text: title, fontName: "Helvetica", fontSize: 8), tolerance: 0.05)
        let lb = label.bounds
        if !lb.isNull {
            let t = AffineTransform.translation(frame.maxX - d - 4 - lb.width - lb.minX, ay - lb.height / 2 - lb.minY)
            for poly in label.transformed(t) {
                guard let f = poly.points.first else { continue }
                ctx.move(to: CGPoint(x: f.x, y: f.y))
                for p in poly.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                ctx.closePath()
            }
            ctx.fillPath(using: .evenOdd)
        }
        ctx.restoreGState()
    }
}
