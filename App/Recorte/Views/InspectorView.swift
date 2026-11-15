import AppKit
import CoreGraphics
import CutterCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The Output sheet lives in OutputSheetView.swift and the Cut wizard in CutWizardView.swift.
// This file keeps the print-sheet export helpers they share.

// MARK: - Print sheet export

/// Builds the printable Print & Cut sheet (artwork + registration marks) as PDF data.
enum PrintSheetExport {
    static func pdfData(design: DesignDocument) -> Data? {
        PrintSheetRenderer.pdfData(sheet: design.printSheet) { ctx in
            drawArtwork(design: design, in: ctx)
        }
    }

    /// The sheet as a PNG or TIFF bitmap for a RIP or print shop.
    static func imageData(design: DesignDocument, format: PrintSheetRenderer.ImageFormat, dpi: Int) -> Data? {
        PrintSheetRenderer.imageData(sheet: design.printSheet, format: format, dpi: Double(dpi)) { ctx in
            drawArtwork(design: design, in: ctx)
        }
    }

    /// Draws all printed images into a millimetre, Y-down context.
    static func drawArtwork(design: DesignDocument, in ctx: CGContext) {
        for object in design.imageObjects {
            guard case .image(let spec) = object.kind else { continue }
            draw(spec, object: object, in: ctx)
        }
    }

    /// Prints the sheet directly (artwork + marks) at 100 % on paper the size of the canvas.
    /// Returns `false` when the user cancelled the print dialog.
    @MainActor @discardableResult
    static func print(design: DesignDocument) -> Bool {
        let ptPerMM = 72.0 / 25.4
        let page = design.canvasSize
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: page.width * ptPerMM, height: page.height * ptPerMM)
        info.orientation = page.width > page.height ? .landscape : .portrait
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.scalingFactor = 1
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        let view = PrintSheetNSView(design: design, frame: NSRect(origin: .zero, size: info.paperSize))
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = design.name + " print sheet"
        op.showsPrintPanel = true
        return op.run()
    }

    /// Draws one image object into a millimetre, Y-down context, honouring its frame and rotation.
    private static func draw(_ spec: ImageSpec, object: DesignObject, in ctx: CGContext) {
        let f = object.frame
        ctx.saveGState()
        ctx.translateBy(x: f.center.x, y: f.center.y)
        ctx.rotate(by: object.rotation * .pi / 180)
        // Back to Y-up for CoreGraphics image/PDF drawing, centred on the frame.
        ctx.scaleBy(x: 1, y: -1)
        let target = CGRect(x: -f.width / 2, y: -f.height / 2, width: f.width, height: f.height)

        if spec.format == "pdf" {
            if let provider = CGDataProvider(data: spec.data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) {
                ctx.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(page)
            }
        } else if let source = CGImageSourceCreateWithData(spec.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: target)
        }
        ctx.restoreGState()
    }
}

/// Binary document used by the “Save as PDF…” and “Save as image…” exporters.
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf, .png, .tiff]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


/// AppKit view that draws the Print & Cut sheet for `NSPrintOperation`.
final class PrintSheetNSView: NSView {
    private let design: DesignDocument

    init(design: DesignDocument, frame: NSRect) {
        self.design = design
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        ctx.saveGState()
        let ptPerMM = 72.0 / 25.4
        ctx.scaleBy(x: ptPerMM, y: ptPerMM)   // view is flipped: millimetres, Y down
        PrintSheetExport.drawArtwork(design: design, in: ctx)
        PrintSheetRenderer.drawMarks(in: ctx, sheet: design.printSheet)
        ctx.restoreGState()
    }
}
