import AppKit
import CoreGraphics
import CutterCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The “Cut…” dialog: preview on the left, material/size/position settings on the right.
struct CutSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CutterController.self) private var cutter
    @State private var session: CutSession
    @State private var showExport = false
    @State private var showPrintExport = false
    private let design: DesignDocument
    private let images: [UUID: NSImage]
    private let isEmpty: Bool

    init(design: DesignDocument, images: [UUID: NSImage] = [:]) {
        self.design = design
        self.images = images
        let session = CutSession(design: design)
        isEmpty = session.document.isEmpty
        _session = State(initialValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                JobPreview(session: session, design: design, images: images)
                    .frame(minWidth: 460)
                    .layoutPriority(1)
                CutSettingsForm(session: session)
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
            }
            Divider()
            HStack {
                if session.isPrintAndCut {
                    Button("Print sheet…") { PrintSheetExport.print(design: design) }
                        .help("Prints the artwork with the four registration marks at 100 %. Load the sheet, put the needle on the arrow dot, then press Cut.")
                    Button("Save as PDF…") { showPrintExport = true }
                        .help("The same sheet as a PDF, to print elsewhere.")
                }
                Button("Save HPGL…") { showExport = true }
                    .disabled(isEmpty)
                Spacer()
                Text(String(format: "%.1f × %.1f mm", session.job.sizeMM.width, session.job.sizeMM.height))
                    .foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Cut") { cutter.send(hpgl: session.job.hpgl) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty || cutter.isSending || !cutter.hasDevice || !session.job.fitsMachine)
            }
            .padding(12)
        }
        .frame(minWidth: 920, idealWidth: 980, minHeight: 600, idealHeight: 660)
        .sheet(isPresented: Binding(get: { cutter.status != .idle }, set: { if !$0 { cutter.dismissStatus() } })) {
            SendProgressView()
        }
        .fileExporter(isPresented: $showExport, document: HPGLFile(text: session.job.hpgl),
                      contentType: .plainText, defaultFilename: session.document.name + ".plt") { _ in }
        .fileExporter(isPresented: $showPrintExport, document: PDFFile(data: PrintSheetExport.pdfData(design: design) ?? Data()),
                      contentType: .pdf, defaultFilename: session.document.name + " print sheet.pdf") { _ in }
    }
}

/// Shows the media, the design as it will be cut and the knife travel.
struct JobPreview: View {
    let session: CutSession
    var design: DesignDocument? = nil
    var images: [UUID: NSImage] = [:]
    @State private var showToolpaths = false
    private let padding: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let job = session.job
            let sheet = session.printSheet
            // Plain cuts: world = media width × job height with margins. Print & Cut: world = the sheet.
            let margin = sheet == nil ? CGPoint(x: session.settings.marginX, y: session.settings.marginY) : .zero
            let mediaWidth = sheet?.page.width ?? session.machine.cutWidthMM
            let worldWidth = sheet?.page.width ?? max(mediaWidth, job.bounds.width + margin.x)
            let worldHeight = sheet?.page.height ?? max(job.bounds.height + margin.y * 2, 100)
            let scale = min((geo.size.width - padding * 2) / worldWidth, (geo.size.height - padding * 2) / worldHeight)
            let origin = CGPoint(x: (geo.size.width - worldWidth * scale) / 2, y: (geo.size.height - worldHeight * scale) / 2)

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Canvas { ctx, _ in
                    func pt(_ p: Point) -> CGPoint {
                        CGPoint(x: origin.x + (p.x + margin.x) * scale, y: origin.y + (p.y + margin.y) * scale)
                    }
                    let media = sheet == nil
                        ? CGRect(x: origin.x, y: origin.y - padding * 0.5, width: mediaWidth * scale, height: worldHeight * scale + padding)
                        : CGRect(x: origin.x, y: origin.y, width: worldWidth * scale, height: worldHeight * scale)
                    ctx.fill(Path(media), with: .color(.white))
                    ctx.stroke(Path(media), with: .color(.gray.opacity(0.5)), lineWidth: 1)

                    if let sheet, let design {
                        for object in design.imageObjects {
                            guard let image = images[object.id] ?? (object.kind.isImage ? {
                                if case .image(let spec) = object.kind { return NSImage(data: spec.data) } else { return nil }
                            }() : nil) else { continue }
                            let c = pt(object.center)
                            let w = object.frame.width * scale, h = object.frame.height * scale
                            ctx.drawLayer { layer in
                                layer.translateBy(x: c.x, y: c.y)
                                layer.rotate(by: .degrees(object.rotation))
                                layer.draw(Image(nsImage: image), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                            }
                        }
                        let d = sheet.layout.markDiameterMM * scale
                        for m in sheet.layout.markCenters(for: sheet.page) {
                            let c = pt(m)
                            ctx.fill(Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)), with: .color(.black))
                        }
                        let safe = sheet.layout.safeArea(for: sheet.page)
                        let r = CGRect(p1: pt(safe.origin), p2: pt(Point(safe.maxX, safe.maxY)))
                        ctx.stroke(Path(r), with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    }

                    var design = Path()
                    for poly in job.cutPaths {
                        guard let first = poly.points.first else { continue }
                        design.move(to: pt(first))
                        for p in poly.points.dropFirst() { design.addLine(to: pt(p)) }
                        if poly.isClosed { design.closeSubpath() }
                    }
                    ctx.stroke(design, with: .color(job.fitsMachine ? .accentColor : .red), lineWidth: 1.5)

                    if showToolpaths {
                        var travel = Path()
                        var last: Point? = nil
                        for poly in job.toolpaths {
                            guard let first = poly.points.first else { continue }
                            if let last { travel.move(to: pt(last)); travel.addLine(to: pt(first)) }
                            last = poly.points.last
                        }
                        ctx.stroke(travel, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if sheet == nil {
                        var marker = Path()
                        marker.move(to: CGPoint(x: origin.x - 8, y: origin.y)); marker.addLine(to: CGPoint(x: origin.x + 8, y: origin.y))
                        marker.move(to: CGPoint(x: origin.x, y: origin.y - 8)); marker.addLine(to: CGPoint(x: origin.x, y: origin.y + 8))
                        ctx.stroke(marker, with: .color(.secondary), lineWidth: 1)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 12) {
                    Toggle(isOn: $showToolpaths) { Label("Show knife travel", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                        .toggleStyle(.button)
                    Spacer()
                    if !job.fitsMachine {
                        Label(session.isPrintAndCut ? "Cut lines must stay inside the marks" : "Too wide for the cutter", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                .controlSize(.small)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
    }
}

struct CutSettingsForm: View {
    @Bindable var session: CutSession
    @Environment(CutterController.self) private var cutter
    @Environment(\.openSettings) private var openSettings
    @State private var showAdvanced = false

    private var mm: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(1)) }

    var body: some View {
        Form {
            if !session.document.warnings.isEmpty {
                Section {
                    ForEach(Array(session.document.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(message(for: warning), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }

            Section("Material") {
                Picker("Material", selection: $session.materialID) {
                    ForEach(MaterialPreset.all) { preset in
                        Text(LocalizedStringKey(preset.nameKey)).tag(preset.id)
                    }
                }
                .labelsHidden()
                DisclosureGroup("Speed and pressure", isExpanded: $showAdvanced) {
                    Stepper(value: Binding(get: { session.settings.speed }, set: { session.settings.speed = $0; session.markCustomMaterial() }), in: 1...80) {
                        LabeledContent("Speed", value: "\(session.settings.speed) cm/s")
                    }
                    Stepper(value: Binding(get: { session.settings.force }, set: { session.settings.force = $0; session.markCustomMaterial() }), in: 10...500, step: 10) {
                        LabeledContent("Pressure", value: "\(session.settings.force) g")
                    }
                    Toggle("Send speed and pressure to the cutter", isOn: $session.settings.sendSpeedAndForce)
                }
            }

            if session.isPrintAndCut {
                Section("Print & Cut") {
                    Text("The cutter reads the four marks first; the cut lines stay exactly where they are on the printed sheet. Size and position come from the canvas.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
            Section("Size") {
                TextField("Width (mm)", value: $session.widthMM, format: mm)
                TextField("Height (mm)", value: $session.heightMM, format: mm)
                TextField("Scale (%)", value: $session.scalePercent, format: .number.precision(.fractionLength(0...1)))
                Button("Original size") { session.settings.scale = 1 }
                    .disabled(session.settings.scale == 1)
                Toggle("Rotate 90°", isOn: $session.settings.rotate90)
                Toggle("Mirror (heat-transfer vinyl)", isOn: $session.settings.mirror)
            }

            Section("Position") {
                TextField("From the left (mm)", value: $session.settings.marginX, format: mm)
                TextField("From the start (mm)", value: $session.settings.marginY, format: mm)
            }
            }

            Section("Cutting") {
                Toggle("Cut inner shapes first", isOn: $session.settings.innerFirst)
                Toggle("Shortest knife path", isOn: $session.settings.optimizeOrder)
                TextField("Blade offset (mm)", value: $session.settings.bladeOffsetMM, format: .number.precision(.fractionLength(2)))
                TextField("Overcut (mm)", value: $session.settings.overcutMM, format: mm)
            }

            Section("Cutter") {
                LabeledContent("Machine", value: session.machine.name)
                if cutter.hasDevice {
                    LabeledContent("Connection", value: cutter.deviceDescription)
                } else {
                    Label("No cutter found", systemImage: "cable.connector.slash").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh") { cutter.refreshDevices() }
                    Button("Settings…") { openSettings() }
                    Spacer()
                    Button("Test cut") { cutter.sendTestCut() }
                        .disabled(!cutter.hasDevice || cutter.isSending)
                        .help("Cuts a small square and circle to check blade depth and pressure")
                }
            }

            Section("Summary") {
                LabeledContent("Shapes", value: "\(session.job.cutPaths.count)")
                LabeledContent("Cut length", value: lengthText(session.job.cutLength))
                LabeledContent("Estimated time", value: session.estimatedDuration.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func lengthText(_ mm: Double) -> String {
        mm >= 1000 ? String(format: "%.2f m", mm / 1000) : String(format: "%.0f mm", mm)
    }

    private func message(for warning: ImportWarning) -> String {
        switch warning {
        case .textIgnored:
            return String(localized: "Text was skipped. In Illustrator, select it and choose Type ▸ Create Outlines before saving.")
        case .imagesIgnored:
            return String(localized: "Images were skipped. Only vector lines can be cut.")
        case .unsupportedElements(let names):
            return String(localized: "Some elements were skipped: \(names.joined(separator: ", ")).")
        case .extraPagesIgnored(let count):
            return String(localized: "Only the first artboard was imported (\(count) more ignored).")
        }
    }
}

// MARK: - Print sheet export

/// Builds the printable Print & Cut sheet (artwork + registration marks) as PDF data.
enum PrintSheetExport {
    static func pdfData(design: DesignDocument) -> Data? {
        PrintSheetRenderer.pdfData(page: design.canvasSize, layout: design.printAndCut.layout, title: design.name) { ctx in
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
    @MainActor
    static func print(design: DesignDocument) {
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
        op.run()
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

/// PDF document used by the “Save print sheet…” exporter.
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
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
        PrintSheetRenderer.drawMarks(in: ctx, page: design.canvasSize, layout: design.printAndCut.layout, title: design.name)
        ctx.restoreGState()
    }
}
