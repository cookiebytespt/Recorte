import AppKit
import CutterCore
import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// The Output sheet (⌘P): Cut only / Print & Cut settings with a live preview, then the Cut wizard
/// on the same sheet. Replaces the old single “Cut…” dialog; the flow follows SignMaster's
/// Contour Cut Wizard so people switching from it recognise the steps.
struct OutputSheetView: View {
    enum Stage: Equatable { case settings, wizard }

    @Environment(\.dismiss) private var dismiss
    @Environment(CutterController.self) private var cutter
    @Bindable var editor: EditorState
    @State private var session: CutSession
    @State private var stage: Stage = .settings
    @State private var showHPGLExport = false
    @State private var showPDFExport = false
    @State private var showImageExport = false

    init(editor: EditorState) {
        self.editor = editor
        _session = State(initialValue: CutSession(design: editor.design, selection: editor.selection) { [weak editor] design in
            editor?.change { $0 = design }
        })
    }

    var body: some View {
        Group {
            switch stage {
            case .settings:
                settings
            case .wizard:
                CutWizardView(session: session, onBack: { stage = .settings }, onPrintAnother: { stage = .settings },
                              onClose: { dismiss() })
            }
        }
        .onChange(of: editor.design) { _, new in session.designChanged(new) }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                OutputPreview(session: session, images: editor.imageCache)
                    .frame(minWidth: 480, idealWidth: 560)
                    .layoutPriority(1)
                Divider()
                OutputSettingsForm(session: session, onCreateContour: openCreateContour)
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 420)
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1040, minHeight: 640, idealHeight: 720)
        .fileExporter(isPresented: $showHPGLExport, document: HPGLFile(text: session.job.hpgl),
                      contentType: .plainText, defaultFilename: session.design.name + ".plt") { _ in }
        .fileExporter(isPresented: $showPDFExport, document: PDFFile(data: PrintSheetExport.pdfData(design: session.design) ?? Data()),
                      contentType: .pdf, defaultFilename: session.design.name + " print sheet.pdf") { result in
            if case .success = result { stage = .wizard }
        }
        .fileExporter(isPresented: $showImageExport,
                      document: PDFFile(data: showImageExport ? PrintSheetExport.imageData(design: session.design, format: session.imageFormat, dpi: session.imageDPI) ?? Data() : Data()),
                      contentType: session.imageFormat == .png ? .png : .tiff,
                      defaultFilename: session.design.name + " print sheet." + session.imageFormat.fileExtension) { result in
            if case .success = result { stage = .wizard }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Output").font(.headline)
                Text(session.design.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)
            Spacer()
            Picker("Output mode", selection: $session.mode) {
                Text("Cut only").tag(CutSession.Mode.cutOnly)
                Text("Print & Cut").tag(CutSession.Mode.printAndCut)
            }
            .help("Cut only: cut shapes out of plain vinyl. Print & Cut: print the artwork with registration marks, then cut around it. In SignMaster: Contour cut / ARMS.")
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Group {
                if session.isPrintAndCut { Text("1 Print  ›  2 Cut") } else { Text(" ") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 260, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Test cut") {
                TestCutTip().invalidate(reason: .actionPerformed)
                cutter.sendTestCut()
            }
            .popoverTip(TestCutTip())
                .disabled(!cutter.hasDevice || cutter.isSending)
                .help(cutter.hasDevice ? HelpText.testCut : "Connect the machine to make a test cut.")
            Button("Save HPGL…") { showHPGLExport = true }
                .disabled(session.isEmpty)
                .help("Saves the cutting job as a file, for other cutting software or for support. Not needed to cut.")
            Spacer()
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Shapes to cut, total cutting length and an estimate of the time, based on the speed.")
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.hasBlockingIssue)
                .help(session.hasBlockingIssue ? "Fix the problems shown at the top first." : primaryHelp)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .sheet(isPresented: Binding(get: { stage == .settings && cutter.status != .idle },
                                    set: { if !$0 { cutter.dismissStatus() } })) {
            // Only the test cut sends from this stage.
            SendProgressView()
        }
    }

    private var summary: String {
        let length = session.job.cutLength >= 1000
            ? String(format: "%.1f m", session.job.cutLength / 1000)
            : String(format: "%.0f mm", session.job.cutLength)
        let minutes = Int((Double(session.estimatedDuration.components.seconds) / 60).rounded(.up))
        return String(localized: "\(session.job.cutPaths.count) shapes · \(length) · about \(max(minutes, 1)) min")
    }

    private var primaryTitle: LocalizedStringKey {
        guard session.isPrintAndCut else { return "Cut…" }
        switch session.printChoice {
        case .print: return "Print…"
        case .pdf: return "Save PDF…"
        case .image: return "Save Image…"
        case .skip: return "Skip to Cut"
        }
    }

    private var primaryHelp: LocalizedStringKey {
        guard session.isPrintAndCut else { return "Shows how to load the vinyl, then sends the job to the machine." }
        switch session.printChoice {
        case .print: return "Prints the sheet, then shows how to load it in the machine."
        case .pdf: return "Saves the sheet as a PDF to print elsewhere, then shows how to load it."
        case .image: return "Saves the sheet as an image to print elsewhere, then shows how to load it."
        case .skip: return "Goes straight to cutting a sheet that is already printed."
        }
    }

    private func primaryAction() {
        guard session.isPrintAndCut else { stage = .wizard; return }
        switch session.printChoice {
        case .print:
            if PrintSheetExport.print(design: session.design) { stage = .wizard }
        case .pdf: showPDFExport = true
        case .image: showImageExport = true
        case .skip: stage = .wizard
        }
    }

    private func openCreateContour() {
        dismiss()
        DispatchQueue.main.async { editor.showContourSheet = true }
    }
}

// MARK: - Settings

struct OutputSettingsForm: View {
    @Bindable var session: CutSession
    var onCreateContour: () -> Void = {}
    @Environment(CutterController.self) private var cutter
    @Environment(\.openSettings) private var openSettings
    @State private var showBlade: Bool

    init(session: CutSession, onCreateContour: @escaping () -> Void = {}, showBlade: Bool = false) {
        self.session = session
        self.onCreateContour = onCreateContour
        _showBlade = State(initialValue: showBlade)
    }

    private var mm: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(1)) }

    var body: some View {
        Form {
            OutputIssues(session: session, onCreateContour: onCreateContour)

            if !session.document.warnings.isEmpty {
                Section {
                    ForEach(Array(session.document.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(Self.message(for: warning), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }

            if session.isPrintAndCut {
                marksSection
                printingSection
            } else {
                sizeSection
            }
            cuttingSection
            cutSection
        }
        .formStyle(.grouped)
    }

    // MARK: Print & Cut

    private var layout: RegistrationMarkLayout { session.design.printAndCut.layout }

    private var marksSection: some View {
        Section {
            Toggle("Print the marks", isOn: Binding(get: { layout.printsMarks }, set: { v in session.updateLayout { $0.printsMarks = v } }))
                .help(HelpText.printsMarks)
            Picker("Mark size", selection: Binding(get: { layout.markSizeParameter }, set: { v in session.updateLayout { $0.markSizeParameter = v } })) {
                ForEach(Array(Set([15, 20, 25, 30, 35, 40, layout.markSizeParameter])).sorted(), id: \.self) { size in
                    Text(String(format: "%d · Ø %.0f mm", size, Double(size) * 0.2)).tag(size)
                }
            }
            .help(HelpText.markSize)
            Picker(selection: Binding(get: { layout.placement }, set: { v in session.updateLayout { $0.placement = v } })) {
                Text("Around the artwork").tag(MarkPlacement.aroundArtwork)
                Text("At the page edges").tag(MarkPlacement.pageEdges)
            } label: {
                HStack(spacing: 4) { Text("Place the marks"); InfoButton(topic: .markPlacement) }
            }
            .help(HelpText.placeMarks)
            if layout.placement == .aroundArtwork {
                LabeledContent {
                    TextField("Distance from the artwork", value: Binding(get: { layout.artworkDistanceMM },
                                                                          set: { v in session.updateLayout { $0.artworkDistanceMM = max(v, layout.markDiameterMM) } }),
                              format: mm)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("mm").foregroundStyle(.secondary)
                } label: {
                    Text("Distance from the artwork")
                    Text("Left and right of the artwork")
                }
                .help(HelpText.markDistance)
            } else {
                insetField("Side inset", \.sideInsetMM)
                insetField("Top inset", \.topInsetMM)
                insetField("Bottom inset", \.bottomInsetMM)
            }
            Toggle("Job name on the sheet", isOn: Binding(get: { layout.printsJobName }, set: { v in session.updateLayout { $0.printsJobName = v } }))
                .help(HelpText.jobName)
        } header: {
            HStack(spacing: 4) { Text("Registration marks"); InfoButton(topic: .registrationMarks) }
        }
    }

    private func insetField(_ title: LocalizedStringKey, _ key: WritableKeyPath<RegistrationMarkLayout, Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { layout[keyPath: key] },
                                            set: { v in session.updateLayout { $0[keyPath: key] = max(v, layout.markDiameterMM / 2) } }), format: mm)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text("mm").foregroundStyle(.secondary)
        }
        .help(HelpText.markInset)
    }

    private var printingSection: some View {
        Section("Printing") {
            Picker("Printing", selection: $session.printChoice) {
                choice("Print…", "System print dialog, 100 % scale, no margins").tag(CutSession.PrintChoice.print)
                choice("Save as PDF…", "To print on another computer").tag(CutSession.PrintChoice.pdf)
                choice("Save as image…", "For a RIP or a print shop").tag(CutSession.PrintChoice.image)
                choice("Skip printing", "The sheet is already printed").tag(CutSession.PrintChoice.skip)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .help("How to get the sheet on paper. Print it at 100 % scale with no margins, or the marks won't line up. In SignMaster: Print Direct / Save PDF / Save as Image / Skip.")
            if session.printChoice == .image {
                Picker("Format", selection: $session.imageFormat) {
                    Text("PNG").tag(PrintSheetRenderer.ImageFormat.png)
                    Text("TIFF").tag(PrintSheetRenderer.ImageFormat.tiff)
                }
                .help("PNG for most uses. TIFF for print shops and RIP software that ask for it.")
                Picker("Resolution", selection: $session.imageDPI) {
                    ForEach([150, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                }
                .help("300 dpi is enough for most printers. 600 dpi for fine detail; the file is four times bigger.")
            }
        }
    }

    private func choice(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Cut only

    private var sizeSection: some View {
        Section {
            LabeledContent("Size") {
                TextField("Width (mm)", value: $session.widthMM, format: mm).labelsHidden().frame(width: 64)
                Text("×").foregroundStyle(.secondary)
                TextField("Height (mm)", value: $session.heightMM, format: mm).labelsHidden().frame(width: 64)
                Text("mm").foregroundStyle(.secondary)
            }
            .help("Size of the design on the vinyl. Changing one side keeps the proportions.")
            LabeledContent("Scale") {
                Button("Original size") { session.settings.scale = 1 }
                    .help("Back to the size on the canvas (100 %).")
                    .disabled(session.settings.scale == 1)
                TextField("Scale (%)", value: $session.scalePercent, format: .number.precision(.fractionLength(0...1))).labelsHidden().frame(width: 52)
                Text("%").foregroundStyle(.secondary)
            }
            .help("Scales the design for this cut only; the canvas doesn't change.")
            Toggle("Rotate 90°", isOn: $session.settings.rotate90)
                .help("Turns the design a quarter turn, for example to fit a long design across the vinyl.")
            Toggle(isOn: $session.settings.mirror) {
                Text("Mirror")
                Text("For heat-transfer vinyl")
            }
            .help("Heat-transfer vinyl is cut from the back, so the design must be mirrored to read the right way once pressed.")
            LabeledContent {
                TextField("From the right (mm)", value: $session.settings.marginX, format: mm).labelsHidden().frame(width: 64)
                Text("mm").foregroundStyle(.secondary)
            } label: {
                Text("From the right")
                Text("Measured from the blade side")
            }
            .help("Distance across the vinyl from its right edge, where the blade starts, to the design.")
            LabeledContent("From the start") {
                TextField("From the start (mm)", value: $session.settings.marginY, format: mm).labelsHidden().frame(width: 64)
                Text("mm").foregroundStyle(.secondary)
            }
            .help("Distance along the vinyl from where the blade starts to the design.")
            Toggle(isOn: $session.settings.advanceAfterCut) {
                Text("Advance the vinyl after cutting")
                Text("Feeds the vinyl past the design so it is easy to cut off")
            }
            .help("Off: the blade goes back to where it started. In SignMaster: Advance After Plot.")
        } header: {
            HStack(spacing: 4) { Text("Size and position"); InfoButton(topic: .cutStart) }
        }
    }

    // MARK: Shared

    private var bladeSummary: String {
        let blade = String(format: "%.2f mm", session.settings.bladeOffsetMM)
        guard session.settings.sendSpeedAndForce else {
            return String(localized: "Machine's own speed and pressure · \(blade)")
        }
        return String(format: "%d mm/s · %d g · ", session.settings.speed, session.settings.force) + blade
    }

    private var cuttingSection: some View {
        Section("Cutting") {
            LabeledContent("Machine") {
                HStack(spacing: 6) {
                    Circle().fill(machineColor).frame(width: 8, height: 8)
                    Text(session.machine.name + " · ") + Text(machineState)
                }
            }
            .help(machineHelp)
            Picker("Material", selection: $session.materialID) {
                ForEach(MaterialPreset.all) { preset in
                    Text(LocalizedStringKey(preset.nameKey)).tag(preset.id)
                }
            }
            .help(HelpText.material)
            DisclosureGroup(isExpanded: $showBlade) {
                Toggle(isOn: $session.settings.sendSpeedAndForce) {
                    HStack(spacing: 4) { Text("Send speed and pressure to the machine"); InfoButton(topic: .speedAndPressure) }
                    Text(session.settings.sendSpeedAndForce ? "Sent with the job" : "The machine uses the settings on its panel")
                }
                    .help(HelpText.sendSpeedAndPressure)
                LabeledContent("Speed") {
                    TextField("Speed (mm/s)", value: Binding(get: { session.settings.speed },
                                                             set: { session.settings.speed = min(max($0, 10), 800); session.markCustomMaterial() }),
                              format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("Speed", value: Binding(get: { session.settings.speed }, set: { session.settings.speed = $0; session.markCustomMaterial() }),
                            in: 10...800, step: 10)
                        .labelsHidden()
                    Text("mm/s").foregroundStyle(.secondary)
                }
                .disabled(!session.settings.sendSpeedAndForce)
                .help(HelpText.speed)
                LabeledContent("Pressure") {
                    TextField("Pressure (g)", value: Binding(get: { session.settings.force },
                                                             set: { session.settings.force = min(max($0, 10), 600); session.markCustomMaterial() }),
                              format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper("Pressure", value: Binding(get: { session.settings.force }, set: { session.settings.force = $0; session.markCustomMaterial() }),
                            in: 10...600, step: 5)
                        .labelsHidden()
                    Text("g").foregroundStyle(.secondary)
                }
                .disabled(!session.settings.sendSpeedAndForce)
                .help(HelpText.pressure)
                LabeledContent {
                    TextField("Blade offset (mm)", value: $session.settings.bladeOffsetMM, format: .number.precision(.fractionLength(2))).labelsHidden().frame(width: 64)
                    Text("mm").foregroundStyle(.secondary)
                } label: {
                    HStack(spacing: 4) { Text("Blade offset"); InfoButton(topic: .bladeOffset) }
                }
                .help(HelpText.bladeOffset)
                LabeledContent("Overcut") {
                    TextField("Overcut (mm)", value: $session.settings.overcutMM, format: mm).labelsHidden().frame(width: 64)
                    Text("mm").foregroundStyle(.secondary)
                }
                .help(HelpText.overcut)
                Toggle("Cut inner shapes first", isOn: $session.settings.innerFirst)
                    .help("Cuts holes and inner shapes before the shapes around them, so small pieces don't move. In SignMaster: Cut Insides First.")
                Toggle("Shortest knife path", isOn: $session.settings.optimizeOrder)
                    .help("Reorders the shapes so the knife travels less between them. Doesn't change what is cut.")
            } label: {
                HStack {
                    Text("Speed, pressure and blade")
                    Spacer()
                    if !showBlade { Text(bladeSummary).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var machineState: LocalizedStringKey {
        if cutter.hasDevice { return "Ready" }
        return "Not connected"
    }

    private var machineHelp: LocalizedStringKey {
        if cutter.hasDevice { return "The machine is connected and ready to cut." }
        return "Connect the machine with the USB cable and switch it on."
    }

    private var machineColor: Color {
        cutter.hasDevice ? .green : .secondary
    }

    private var cutSection: some View {
        Section("Cut") {
            Stepper(value: $session.copies, in: 1...99) {
                LabeledContent("Copies", value: "\(session.copies)")
            }
            .help(session.isPrintAndCut ? "Number of printed sheets to cut one after another" : "Copies are cut one after another along the vinyl")
            Picker("Objects", selection: $session.scope) {
                Text("Whole canvas").tag(CutSession.Scope.canvas)
                Text("Selection only").tag(CutSession.Scope.selection)
            }
            .pickerStyle(.segmented)
            .disabled(!session.hasSelection)
            .help(session.hasSelection ? "Cut everything on the canvas, or only the objects you selected." : "Select objects on the canvas first to cut only those.")
        }
    }

    static func message(for warning: ImportWarning) -> String {
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

/// Error states shared by the Output sheet and the Cut wizard.
struct OutputIssues: View {
    let session: CutSession
    var onCreateContour: (() -> Void)? = nil
    var showsJobIssues = true
    @Environment(CutterController.self) private var cutter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if !cutter.hasDevice {
            issue("The machine is not connected", "Connect it with the USB cable and switch it on, then check again.", "cable.connector.slash", .orange) {
                Button("Check again") { cutter.refreshDevices() }
                    .help("Looks for the machine again.")
                Button("Settings…") { openSettings() }
                    .help("Opens the connection settings.")
            }
        }
        if showsJobIssues {
            if session.needsCutContour, let onCreateContour {
                issue("There are no cut lines yet", "Make a cut line around the printed images, or draw one.", "scissors", .accentColor) {
                    Button("Create Cut Contour…", action: onCreateContour)
                        .help(HelpText.createCutContour)
                }
            } else if session.isEmpty {
                issue("Nothing to cut", "Draw, write or import something to cut first.", "scissors", .secondary) { EmptyView() }
            }
            if session.marksOffPage {
                issue("The marks don't fit on the page", "Move the artwork away from the edges, use a bigger page or a smaller distance.", "exclamationmark.triangle.fill", .red) { EmptyView() }
            }
            if session.outsideMarks {
                issue("Cut lines must stay inside the marks", "Move the shapes that cross the marks, or place the marks around the artwork.", "exclamationmark.triangle.fill", .red) { EmptyView() }
            }
            if session.tooWide {
                issue("Too wide for the machine", "Make the design smaller, rotate it, or move it closer to the right.", "exclamationmark.triangle.fill", .red) { EmptyView() }
            }
        }
    }

    private func issue<Actions: View>(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ symbol: String, _ tint: Color,
                                      @ViewBuilder actions: () -> Actions) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack { actions() }.padding(.top, 2)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Preview

/// Live preview: the printed sheet with marks (Print & Cut), or the vinyl as it lies in the machine (Cut only).
struct OutputPreview: View {
    @Bindable var session: CutSession
    var images: [UUID: NSImage] = [:]
    private let padding: CGFloat = 36

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let sheet = session.sheet {
                sheetPreview(sheet)
            } else {
                vinylPreview
            }
        }
        .overlay(alignment: .top) {
            if let sheet = session.sheet {
                Text(caption(sheet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
        .overlay(alignment: .bottom) { controls }
    }

    private func caption(_ sheet: PrintSheet) -> String {
        let size = String(format: "%.1f × %.1f mm", sheet.markSpacing.width, sheet.markSpacing.height)
        return String(localized: "\(session.design.name) · Marks \(size) · \(pageName(sheet.page))")
    }

    private func pageName(_ page: Size) -> String {
        let known: [(String, Size)] = [("A4", Size(210, 297)), ("A3", Size(297, 420)), ("SRA3", Size(320, 450)),
                                       ("Letter", Size(215.9, 279.4)), ("Tabloid", Size(279.4, 431.8))]
        for (name, s) in known {
            if abs(s.width - page.width) < 0.5 && abs(s.height - page.height) < 0.5 { return name }
            if abs(s.width - page.height) < 0.5 && abs(s.height - page.width) < 0.5 { return name }
        }
        return String(format: "%.0f × %.0f mm", page.width, page.height)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if session.isPrintAndCut {
                Picker("Show", selection: $session.previewLayers) {
                    Text("Both").tag(CutSession.PreviewLayers.both)
                    Text("Print").tag(CutSession.PreviewLayers.print)
                    Text("Cut").tag(CutSession.PreviewLayers.cut)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the printed sheet, the cut lines, or both. In SignMaster: View both / View Print only / View Cut only.")
            }
            Toggle("Knife travel", isOn: $session.showKnifeTravel)
                .toggleStyle(.checkbox)
                .help("Shows the moves the knife makes with the blade up, between shapes.")
            Spacer()
            if let sheet = session.sheet {
                HStack(spacing: 10) {
                    Text(String(format: String(localized: "● Marks Ø %.0f mm"), sheet.markDiameterMM))
                    Text("◌ Safe area")
                    Text("◎ Origin mark").foregroundStyle(.primary)
                }
                .foregroundStyle(.secondary)
            } else {
                Text(String(format: "%.1f × %.1f mm", session.job.sizeMM.width, session.job.sizeMM.height))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    // MARK: Print & Cut sheet

    private func sheetPreview(_ sheet: PrintSheet) -> some View {
        let job = session.job
        let design = session.design
        let layers = session.previewLayers
        let travel = session.showKnifeTravel
        return GeometryReader { (geo: GeometryProxy) in
            Canvas { (ctx: inout GraphicsContext, _: CGSize) in
                drawSheet(sheet, job: job, design: design, layers: layers, travel: travel, size: geo.size, in: ctx)
            }
        }
    }

    // Kept out of the ViewBuilder closures above: as one big expression the Release compiler
    // could not type-check it in reasonable time.
    private func drawSheet(_ sheet: PrintSheet, job: CutJob, design: DesignDocument,
                           layers: CutSession.PreviewLayers, travel: Bool, size: CGSize, in ctx: GraphicsContext) {
        let page = sheet.page
        let scaleX: CGFloat = (size.width - padding * 2) / CGFloat(page.width)
        let scaleY: CGFloat = (size.height - padding * 2 - 50) / CGFloat(page.height)
        let scale: CGFloat = min(scaleX, scaleY)
        let originX: CGFloat = (size.width - CGFloat(page.width) * scale) / 2
        let originY: CGFloat = (size.height - CGFloat(page.height) * scale) / 2 - 8
        let origin = CGPoint(x: originX, y: originY)
        func pt(_ p: Point) -> CGPoint { CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale) }
        let paper = CGRect(x: origin.x, y: origin.y, width: CGFloat(page.width) * scale, height: CGFloat(page.height) * scale)
        ctx.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.2), radius: 4, y: 1))
            l.fill(Path(paper), with: .color(.white))
        }

        if layers != .cut {
            for object in design.imageObjects {
                guard let image = images[object.id] ?? Self.decode(object) else { continue }
                let c = pt(object.center)
                let w = object.frame.width * scale, h = object.frame.height * scale
                ctx.drawLayer { layer in
                    layer.translateBy(x: c.x, y: c.y)
                    layer.rotate(by: .degrees(object.rotation))
                    layer.draw(Image(nsImage: image), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                }
            }
            let safe = sheet.safeArea
            ctx.stroke(Path(CGRect(p1: pt(safe.origin), p2: pt(Point(safe.maxX, safe.maxY)))),
                       with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            let d = sheet.markDiameterMM * scale
            for m in sheet.markCenters {
                let c = pt(m)
                let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                if sheet.layout.printsMarks {
                    ctx.fill(Path(ellipseIn: r), with: .color(.black))
                } else {
                    ctx.stroke(Path(ellipseIn: r), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            // Origin mark ring: the blade goes on this one.
            let o = pt(sheet.originMark)
            ctx.stroke(Path(ellipseIn: CGRect(x: o.x - d * 1.1, y: o.y - d * 1.1, width: d * 2.2, height: d * 2.2)),
                       with: .color(.accentColor), lineWidth: 1.5)
            if sheet.layout.printsJobName {
                let f = sheet.markFrame
                let y = sheet.layout.placement == .aroundArtwork ? f.minY - sheet.markDiameterMM - 2 : f.minY
                ctx.draw(Text(design.name).font(.system(size: max(7, 3 * scale))).foregroundStyle(.black),
                         at: pt(Point(f.maxX - sheet.markDiameterMM - 4, y)), anchor: .trailing)
            }
        }

        if layers != .print {
            var path = Path()
            for poly in job.cutPaths { path.addPolyline(poly, pt) }
            ctx.stroke(path, with: .color(job.fitsMachine ? .accentColor : .red), lineWidth: 1.5)
        }
        if travel { Self.drawTravel(job.toolpaths, start: sheet.originMark, in: ctx, pt) }
    }

    // MARK: Cut only: the vinyl in the machine

    /// True top view with the user at the front (bottom of the preview): the origin is the vinyl's
    /// front-right corner by the blade, and the design runs back and to the left from there, the same
    /// way round as a Print & Cut sheet. The design therefore shows rotated by 180°: that is how it comes out.
    private var vinylPreview: some View {
        let job = session.job
        let settings = session.settings
        let mediaWidth = session.machine.cutWidthMM
        let travel = session.showKnifeTravel
        return GeometryReader { (geo: GeometryProxy) in
            Canvas { (ctx: inout GraphicsContext, _: CGSize) in
                drawVinyl(job: job, settings: settings, mediaWidth: mediaWidth, travel: travel, size: geo.size, in: ctx)
            }
        }
    }

    private func drawVinyl(job: CutJob, settings: JobSettings, mediaWidth: Double, travel: Bool,
                           size: CGSize, in ctx: GraphicsContext) {
        let width = CGFloat(mediaWidth)
        let length: CGFloat = max(CGFloat(job.bounds.height + settings.marginY + 60), width * 0.55)
        let scaleX: CGFloat = (size.width - padding * 2) / width
        let scaleY: CGFloat = (size.height - padding * 2 - 70) / length
        let scale: CGFloat = min(scaleX, scaleY)
        let left: CGFloat = (size.width - width * scale) / 2
        let front: CGFloat = (size.height + length * scale) / 2 - 20   // y of the vinyl's front edge
        // Plotter position (across from the right, feed from the front) → view.
        let toView: (Point) -> CGPoint = { (p: Point) -> CGPoint in
            let x: CGFloat = left + CGFloat(mediaWidth - (settings.marginX + p.x)) * scale
            let y: CGFloat = front - CGFloat(settings.marginY + p.y) * scale
            return CGPoint(x: x, y: y)
        }
        let vinyl = CGRect(x: left, y: front - length * scale, width: width * scale, height: length * scale)
        ctx.fill(Path(vinyl), with: .color(Color(red: 0.97, green: 0.96, blue: 0.93)))
        ctx.stroke(Path(vinyl), with: .color(.gray.opacity(0.6)), lineWidth: 1)

        var path = Path()
        for poly in job.cutPaths { path.addPolyline(poly, toView) }
        ctx.stroke(path, with: .color(job.fitsMachine ? .accentColor : .red), lineWidth: 1.5)
        if travel { Self.drawTravel(job.toolpaths, start: .zero, in: ctx, toView) }

        // Origin crosshair at the front right, by the blade.
        let o = CGPoint(x: vinyl.maxX, y: front)
        var cross = Path()
        cross.move(to: CGPoint(x: o.x - 10, y: o.y)); cross.addLine(to: CGPoint(x: o.x + 10, y: o.y))
        cross.move(to: CGPoint(x: o.x, y: o.y - 10)); cross.addLine(to: CGPoint(x: o.x, y: o.y + 10))
        ctx.stroke(cross, with: .color(.accentColor), lineWidth: 1.5)
        ctx.draw(Text("Origin").font(.caption2).foregroundStyle(Color.accentColor), at: CGPoint(x: o.x - 4, y: o.y + 14), anchor: .trailing)

        // Width dimension and labels.
        let dimY = front + 30
        var dim = Path()
        dim.move(to: CGPoint(x: vinyl.minX, y: dimY)); dim.addLine(to: CGPoint(x: vinyl.maxX, y: dimY))
        dim.move(to: CGPoint(x: vinyl.minX, y: dimY - 5)); dim.addLine(to: CGPoint(x: vinyl.minX, y: dimY + 5))
        dim.move(to: CGPoint(x: vinyl.maxX, y: dimY - 5)); dim.addLine(to: CGPoint(x: vinyl.maxX, y: dimY + 5))
        ctx.stroke(dim, with: .color(.secondary), lineWidth: 1)
        ctx.draw(Text(String(format: String(localized: "%.0f mm cutting width"), mediaWidth)).font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: vinyl.midX, y: dimY - 8))
        ctx.draw(Text("Front (you)").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: vinyl.midX, y: dimY + 12))
        let info = String(format: String(localized: "%.0f mm from the right · %.0f mm from the start"), settings.marginX, settings.marginY)
        ctx.draw(Text(info).font(.caption).foregroundStyle(.secondary), at: CGPoint(x: vinyl.maxX - 8, y: vinyl.minY + 14), anchor: .trailing)
        ctx.draw(Text("Seen from above, standing at the front. The design comes out top edge first.").font(.caption2).foregroundStyle(.secondary),
                 at: CGPoint(x: vinyl.maxX - 8, y: vinyl.minY + 30), anchor: .trailing)
    }

    // MARK: Helpers

    private static func drawTravel(_ toolpaths: [Polyline], start: Point, in ctx: GraphicsContext, _ map: (Point) -> CGPoint) {
        var travel = Path()
        var last: Point? = start
        for poly in toolpaths {
            guard let first = poly.points.first else { continue }
            if let last { travel.move(to: map(last)); travel.addLine(to: map(first)) }
            last = poly.isClosed ? first : poly.points.last
        }
        ctx.stroke(travel, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    static func decode(_ object: DesignObject) -> NSImage? {
        if case .image(let spec) = object.kind { return NSImage(data: spec.data) }
        return nil
    }
}

extension Path {
    mutating func addPolyline(_ poly: Polyline, _ map: (Point) -> CGPoint) {
        guard let first = poly.points.first else { return }
        move(to: map(first))
        for p in poly.points.dropFirst() { addLine(to: map(p)) }
        if poly.isClosed { closeSubpath() }
    }
}
