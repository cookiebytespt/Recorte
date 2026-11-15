import CoreGraphics
import Foundation
import ImageIO

/// Where the registration marks go on the printed sheet.
public enum MarkPlacement: String, Sendable, Hashable, Codable, CaseIterable {
    /// SignMaster's default: marks a set distance left and right of the artwork, level with its top and bottom.
    case aroundArtwork
    /// Marks near the corners of the page (insets from the page edges).
    case pageEdges
}

/// Where the four registration marks sit on the printed sheet.
/// Defaults reproduce the SignMaster/VinylMaster layout the Liyu's camera is set up for.
public struct RegistrationMarkLayout: Sendable, Hashable, Codable {
    /// First parameter of the cutter's `TB` command (the "mark size" setting in SignMaster).
    /// The printed circle diameter is `markSizeParameter × 0.2 mm`, so 25 → Ø5 mm.
    public var markSizeParameter: Int
    /// Page-edge placement: mark centre distance from the left and right page edges, in mm.
    public var sideInsetMM: Double
    /// Page-edge placement: mark centre distance from the top edge, in mm.
    public var topInsetMM: Double
    /// Page-edge placement: mark centre distance from the bottom edge, in mm.
    public var bottomInsetMM: Double
    public var placement: MarkPlacement
    /// Around-the-artwork placement: mark centre distance left and right of the artwork (SignMaster "Mark Position").
    public var artworkDistanceMM: Double
    /// Print the marks and feed arrow (off when the sheet already carries them).
    public var printsMarks: Bool
    /// Print the job name on the sheet.
    public var printsJobName: Bool

    public init(markSizeParameter: Int = 25, sideInsetMM: Double = 2.5, topInsetMM: Double = 15, bottomInsetMM: Double = 15,
                placement: MarkPlacement = .aroundArtwork, artworkDistanceMM: Double = 20.5,
                printsMarks: Bool = true, printsJobName: Bool = true) {
        self.markSizeParameter = markSizeParameter
        self.sideInsetMM = sideInsetMM
        self.topInsetMM = topInsetMM
        self.bottomInsetMM = bottomInsetMM
        self.placement = placement
        self.artworkDistanceMM = artworkDistanceMM
        self.printsMarks = printsMarks
        self.printsJobName = printsJobName
    }

    private enum CodingKeys: String, CodingKey {
        case markSizeParameter, sideInsetMM, topInsetMM, bottomInsetMM, placement, artworkDistanceMM, printsMarks, printsJobName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markSizeParameter = try c.decodeIfPresent(Int.self, forKey: .markSizeParameter) ?? 25
        sideInsetMM = try c.decodeIfPresent(Double.self, forKey: .sideInsetMM) ?? 2.5
        topInsetMM = try c.decodeIfPresent(Double.self, forKey: .topInsetMM) ?? 15
        bottomInsetMM = try c.decodeIfPresent(Double.self, forKey: .bottomInsetMM) ?? 15
        // Projects saved before the placement option keep their page-edge marks.
        placement = try c.decodeIfPresent(MarkPlacement.self, forKey: .placement) ?? .pageEdges
        artworkDistanceMM = try c.decodeIfPresent(Double.self, forKey: .artworkDistanceMM) ?? 20.5
        printsMarks = try c.decodeIfPresent(Bool.self, forKey: .printsMarks) ?? true
        printsJobName = try c.decodeIfPresent(Bool.self, forKey: .printsJobName) ?? true
    }

    public var markDiameterMM: Double { Double(markSizeParameter) * 0.2 }

    /// Rectangle through the four mark centres, in page coordinates (mm, origin top-left).
    /// `artwork` is the bounding box of everything printed or cut; it is only used for `.aroundArtwork`.
    public func markFrame(for page: Size, artwork: Rect? = nil) -> Rect {
        if placement == .aroundArtwork, let a = artwork, !a.isNull, a.width > 0, a.height > 0 {
            return Rect(minX: a.minX - artworkDistanceMM, minY: a.minY, maxX: a.maxX + artworkDistanceMM, maxY: a.maxY)
        }
        return Rect(minX: sideInsetMM, minY: topInsetMM, maxX: page.width - sideInsetMM, maxY: page.height - bottomInsetMM)
    }

    public func markCenters(for page: Size, artwork: Rect? = nil) -> [Point] {
        let f = markFrame(for: page, artwork: artwork)
        return [Point(f.minX, f.minY), Point(f.maxX, f.minY), Point(f.minX, f.maxY), Point(f.maxX, f.maxY)]
    }

    /// Area that can safely carry artwork and cut lines (inside the marks, clear of the circles).
    public func safeArea(for page: Size, artwork: Rect? = nil) -> Rect {
        let f = markFrame(for: page, artwork: artwork)
        if placement == .aroundArtwork, let a = artwork, !a.isNull, a.width > 0, a.height > 0 {
            // The marks are level with the artwork's top and bottom; only keep clear of them sideways.
            let d = markDiameterMM
            return Rect(minX: f.minX + d, minY: f.minY, maxX: f.maxX - d, maxY: f.maxY)
        }
        return f.insetBy(markDiameterMM)
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

/// A resolved Print & Cut sheet: the page, the mark layout and where the marks actually land.
public struct PrintSheet: Sendable, Hashable {
    public var page: Size
    public var layout: RegistrationMarkLayout
    /// Rectangle through the four mark centres (page mm, origin top-left). Its top-left corner is the origin mark.
    public var markFrame: Rect
    public var safeArea: Rect
    public var title: String

    public init(page: Size, layout: RegistrationMarkLayout, artwork: Rect? = nil, title: String = "") {
        self.page = page
        self.layout = layout
        self.markFrame = layout.markFrame(for: page, artwork: artwork)
        self.safeArea = layout.safeArea(for: page, artwork: artwork)
        self.title = title
    }

    public var markDiameterMM: Double { layout.markDiameterMM }
    public var originMark: Point { markFrame.origin }

    public var markCenters: [Point] {
        let f = markFrame
        return [Point(f.minX, f.minY), Point(f.maxX, f.minY), Point(f.minX, f.maxY), Point(f.maxX, f.maxY)]
    }

    /// `false` when a mark circle would fall off the page (then the printer can't print it).
    public var marksFitPage: Bool {
        let r = markDiameterMM / 2
        let page = Rect(origin: .zero, size: self.page)
        return markFrame.width > 0 && markFrame.height > 0 && page.contains(markFrame.insetBy(-r))
    }

    /// Distances between mark centres (across × along the feed), in mm — the values the `TB` command carries.
    public var markSpacing: Size { markFrame.size }
}

/// Builds the contour-cut job the Liyu expects after a sheet with registration marks is loaded.
///
/// Stream format (SignMaster capture and *Save as PLT* files):
///
///     TB<size>,<across steps>,<feed steps>;CT1;[SP1;VS<mm/s>;HS<g>;]<1024 spaces>\r\n
///     IN;SP1;PU…;PD…;…
///     PU<feed steps>,0;PG!;\r\n
///
/// Speed and pressure, when sent, go on the TB line (not after `IN;`). Coordinates are relative to the
/// top-left mark: plotter X along the feed (down the page), plotter Y across the page, 40 steps/mm.
public enum PrintAndCutHPGL {
    public static let fillerLength = 1024

    /// `paths` are in page coordinates (mm, origin top-left of the sheet).
    public static func generate(paths: [Polyline], sheet: PrintSheet,
                                stepsPerMM: Double = 40, speed: Int? = nil, force: Int? = nil) -> String {
        let frame = sheet.markFrame
        let across = Int((frame.width * stepsPerMM).rounded())
        let feed = Int((frame.height * stepsPerMM).rounded())
        // Speed and pressure travel on the TB line, so the body header carries neither.
        let options = HPGLOptions(stepsPerMM: stepsPerMM, swapAxes: true, lineTerminator: "")
        let generator = HPGLGenerator()

        var out = "TB\(sheet.layout.markSizeParameter),\(across),\(feed);CT1;"
        out += HPGLGenerator.speedAndPressure(speed: speed, force: force)
        out += String(repeating: " ", count: fillerLength)
        out += "\r\n"
        out += generator.header(options: options)
        out += generator.body(paths, options: options) { p in
            HPGLGenerator.steps(across: p.x - frame.minX, feed: p.y - frame.minY, options: options)
        }
        out += "PU\(feed),0;PG!;\r\n"
        return out
    }

    /// Page-edge (or artwork-less) layouts.
    public static func generate(paths: [Polyline], page: Size, layout: RegistrationMarkLayout,
                                stepsPerMM: Double = 40, speed: Int? = nil, force: Int? = nil) -> String {
        generate(paths: paths, sheet: PrintSheet(page: page, layout: layout), stepsPerMM: stepsPerMM, speed: speed, force: force)
    }
}

/// Renders the printable sheet: artwork images, registration marks, feed arrow and job label.
public enum PrintSheetRenderer {
    public enum ImageFormat: String, Sendable, CaseIterable, Hashable {
        case png, tiff
        var uti: String { self == .png ? "public.png" : "public.tiff" }
        public var fileExtension: String { self == .png ? "png" : "tiff" }
    }

    /// `drawArtwork` is called with a CoreGraphics context in page space (mm, origin top-left, Y down)
    /// and should draw the printed content; marks and labels are added here.
    public static func pdfData(sheet: PrintSheet, drawArtwork: (CGContext) -> Void) -> Data? {
        let ptPerMM = 72.0 / 25.4
        var mediaBox = CGRect(x: 0, y: 0, width: sheet.page.width * ptPerMM, height: sheet.page.height * ptPerMM)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle as String: sheet.title] as CFDictionary) else {
            return nil
        }
        ctx.beginPDFPage(nil)
        // Page space in millimetres with Y pointing down.
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: ptPerMM, y: -ptPerMM)

        drawArtwork(ctx)
        drawMarks(in: ctx, sheet: sheet)

        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    public static func pdfData(page: Size, layout: RegistrationMarkLayout, title: String,
                               drawArtwork: (CGContext) -> Void) -> Data? {
        pdfData(sheet: PrintSheet(page: page, layout: layout, title: title), drawArtwork: drawArtwork)
    }

    /// Renders the sheet as a bitmap (white background) for a RIP or print shop.
    public static func imageData(sheet: PrintSheet, format: ImageFormat, dpi: Double,
                                 drawArtwork: (CGContext) -> Void) -> Data? {
        let pxPerMM = dpi / 25.4
        let width = max(1, Int((sheet.page.width * pxPerMM).rounded()))
        let height = max(1, Int((sheet.page.height * pxPerMM).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: pxPerMM, y: -pxPerMM)
        ctx.interpolationQuality = .high
        drawArtwork(ctx)
        drawMarks(in: ctx, sheet: sheet)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, format.uti as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Draws the marks, arrow and label in a millimetre, Y-down context.
    public static func drawMarks(in ctx: CGContext, sheet: PrintSheet) {
        let layout = sheet.layout
        let frame = sheet.markFrame
        let d = layout.markDiameterMM
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        let around = layout.placement == .aroundArtwork

        if layout.printsMarks {
            for c in sheet.markCenters {
                ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            }
            // Feed arrow next to the origin mark (points towards the top edge, like the SignMaster sheet).
            // Around the artwork it goes in the gap beside the mark, or above it when the gap is narrow.
            let besideRoom = around ? layout.artworkDistanceMM : frame.width
            let (ax, ay): (Double, Double) = besideRoom >= d + 9
                ? (frame.minX + d + 6, frame.minY)
                : (frame.minX, frame.minY - d - 2)
            ctx.move(to: CGPoint(x: ax - 1.5, y: ay + 1.5))
            ctx.addLine(to: CGPoint(x: ax, y: ay - 1.5))
            ctx.addLine(to: CGPoint(x: ax + 1.5, y: ay + 1.5))
            ctx.setLineWidth(0.4)
            ctx.strokePath()
        }

        // Job label as outlines (no fonts in the PDF).
        if layout.printsJobName, !sheet.title.isEmpty {
            let label = TextOutliner.outlines(TextSpec(text: sheet.title, fontName: "Helvetica", fontSize: 8), tolerance: 0.05)
            let lb = label.bounds
            if !lb.isNull {
                // Page edges: on the mark line between the top marks. Around the artwork: just above the top marks.
                let y = around ? frame.minY - d / 2 - 2 - lb.height / 2 : frame.minY
                let t = AffineTransform.translation(frame.maxX - d - 4 - lb.width - lb.minX, y - lb.height / 2 - lb.minY)
                for poly in label.transformed(t) {
                    guard let f = poly.points.first else { continue }
                    ctx.move(to: CGPoint(x: f.x, y: f.y))
                    for p in poly.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    ctx.closePath()
                }
                ctx.fillPath(using: .evenOdd)
            }
        }
        ctx.restoreGState()
    }

    public static func drawMarks(in ctx: CGContext, page: Size, layout: RegistrationMarkLayout, title: String) {
        drawMarks(in: ctx, sheet: PrintSheet(page: page, layout: layout, title: title))
    }
}
