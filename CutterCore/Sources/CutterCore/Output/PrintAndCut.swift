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
/// Mark size, artwork gap, arrow and job-name positions follow SignMaster/VinylMaster.
public struct RegistrationMarkLayout: Sendable, Hashable, Codable {
    /// Smallest mark the Liyu's sensor reliably finds: 25 → Ø5 mm. Smaller marks are not detected.
    public static let minimumMarkSizeParameter = 25
    /// Default gap (mark centre to artwork) for new sheets: SignMaster's *Mark Position*.
    public static let defaultArtworkDistanceMM = 20.5
    /// SignMaster prints the feed arrow 20 mm from the origin mark's centre, on the mark line.
    public static let arrowDistanceMM = 20.0
    /// SignMaster ends the job number about 41 mm before the top-right mark's centre, keeping the mark's surroundings blank.
    public static let jobNameDistanceMM = 41.0
    /// Clearance kept between the marks and the page edge, for printers that can't print right to the edge.
    public static let printerMarginMM = 3.0

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
                placement: MarkPlacement = .aroundArtwork, artworkDistanceMM: Double = RegistrationMarkLayout.defaultArtworkDistanceMM,
                printsMarks: Bool = true, printsJobName: Bool = true) {
        self.markSizeParameter = max(markSizeParameter, Self.minimumMarkSizeParameter)
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
        markSizeParameter = max(try c.decodeIfPresent(Int.self, forKey: .markSizeParameter) ?? 25, Self.minimumMarkSizeParameter)
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

    /// Smallest allowed mark-to-artwork distance: the mark circle stays clear of the artwork.
    public var minimumArtworkDistanceMM: Double { markDiameterMM }

    /// The feed arrow goes beside the origin mark when the gap allows it, otherwise above it.
    var arrowBesideOriginMark: Bool { artworkDistanceMM >= markDiameterMM + 9 }

    /// Height of the printed job name (8 pt Helvetica), in mm.
    public static let jobNameHeightMM = 3.0

    /// How far the marks, arrow and job name reach above the top mark centres, in mm.
    var extentAboveMarksMM: Double {
        let r = markDiameterMM / 2
        var top = r
        if printsMarks && placement == .aroundArtwork && !arrowBesideOriginMark { top = max(top, markDiameterMM + 3.5) }
        if printsJobName && placement == .aroundArtwork { top = max(top, Self.jobNameGapMM + Self.jobNameHeightMM) }
        return top
    }

    /// Around the artwork the job name sits this far above the artwork's top edge.
    static let jobNameGapMM = 1.0

    /// Distance from the origin mark's centre to the feed arrow when the arrow is beside the mark.
    func arrowOffsetMM(frameWidth: Double) -> Double {
        let d = markDiameterMM
        switch placement {
        case .aroundArtwork: return min(Self.arrowDistanceMM, max(artworkDistanceMM - 2.5, d + 6))
        case .pageEdges: return min(Self.arrowDistanceMM, max(d + 6, frameWidth / 2))
        }
    }

    /// Where artwork can go on a page so that the marks (and arrow and job name) still fit on it,
    /// `printerMarginMM` clear of the page edges.
    public func artworkArea(for page: Size, printerMarginMM: Double = RegistrationMarkLayout.printerMarginMM) -> Rect {
        let full = Rect(origin: .zero, size: page)
        switch placement {
        case .pageEdges:
            return safeArea(for: page)
        case .aroundArtwork:
            let r = markDiameterMM / 2
            let side = artworkDistanceMM + r + printerMarginMM
            let r2 = Rect(minX: side, minY: extentAboveMarksMM + printerMarginMM,
                          maxX: page.width - side, maxY: page.height - r - printerMarginMM)
            return r2.width > 0 && r2.height > 0 ? r2 : full
        }
    }

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

    /// Where the job name goes: its right end and vertical centre, for a label `width` × `height` mm.
    /// Like SignMaster it stays well clear of the top-right mark (41 mm when the sheet is wide enough).
    public func jobNameTrailing(width: Double, height: Double = RegistrationMarkLayout.jobNameHeightMM) -> Point {
        let f = markFrame, d = markDiameterMM
        let offset = min(RegistrationMarkLayout.jobNameDistanceMM, max(d + 4, (f.width - width) / 2))
        let y = layout.placement == .aroundArtwork ? f.minY - RegistrationMarkLayout.jobNameGapMM - height / 2 : f.minY
        return Point(f.maxX - offset, y)
    }
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
            // Feed arrow on the mark line, 20 mm from the origin mark like the SignMaster sheet (it points
            // towards the top edge). Around the artwork it goes above the mark when the gap is too narrow.
            let beside = around ? layout.arrowBesideOriginMark : frame.width >= d + 9
            let (ax, ay): (Double, Double) = beside
                ? (frame.minX + layout.arrowOffsetMM(frameWidth: frame.width), frame.minY)
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
                // Page edges: on the mark line between the top marks. Around the artwork: just above the artwork.
                // Either way it ends well before the top-right mark, so the sensor sees a blank area around it.
                let end = sheet.jobNameTrailing(width: lb.width, height: lb.height)
                let t = AffineTransform.translation(end.x - lb.width - lb.minX, end.y - lb.height / 2 - lb.minY)
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
