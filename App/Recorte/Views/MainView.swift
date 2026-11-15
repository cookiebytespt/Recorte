import CutterCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Binding var document: DesignFileDocument
    @Environment(\.undoManager) private var undoManager
    @Environment(CutterController.self) private var cutter
    @State private var editor = EditorState()

    var body: some View {
        HSplitView {
            CanvasView(editor: editor)
                .frame(minWidth: 500)
                .layoutPriority(1)
            SidebarView(editor: editor)
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 380)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tool", selection: $editor.tool) {
                    ForEach(Tool.allCases) { tool in
                        Image(systemName: tool.symbol).help(tool.title).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editor.showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down.on.square") }
                    .help("Add an SVG, PDF, Illustrator or DXF file as cut lines")
                Button { editor.showImagePlacer = true } label: { Label("Place artwork…", systemImage: "photo.badge.plus") }
                    .help("Add a PDF, Illustrator, PNG or JPEG file to be printed (Print & Cut)")
                Button { editor.showCutSheet = true } label: {
                    if document.design.printAndCut.isEnabled {
                        Label("Print & Cut…", systemImage: "printer")
                    } else {
                        Label("Cut…", systemImage: "scissors")
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Output settings, printing and cutting (⌘P)")
                .disabled(document.design.objects.isEmpty)
            }
        }
        .sheet(isPresented: $editor.showCutSheet) {
            OutputSheetView(editor: editor)
                .environment(cutter)
        }
        .sheet(isPresented: $editor.showContourSheet) {
            ContourSheetView(editor: editor)
        }
        .fileImporter(isPresented: $editor.showImporter, allowedContentTypes: [.svg, .pdf, .illustrator, .dxf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { editor.importFile(url) }
            }
        }
        .fileImporter(isPresented: $editor.showImagePlacer, allowedContentTypes: [.pdf, .illustrator, .png, .jpeg], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { editor.placeImage(url) }
        }
        .alert("Could not import", isPresented: Binding(get: { editor.importError != nil }, set: { if !$0 { editor.importError = nil } })) {
            Button("OK") { editor.importError = nil }
        } message: {
            Text(editor.importError ?? "")
        }
        .focusedSceneValue(\.editor, editor)
        .onAppear {
            editor.document = $document
            editor.design = document.design
            editor.undoManager = undoManager
        }
        .onChange(of: document.design) { _, new in
            // Revert, reload or external edits: keep the editor in sync.
            if editor.design != new { editor.design = new }
        }
        .onChange(of: undoManager) { _, new in editor.undoManager = new }
    }
}

/// Menu commands that act on the focused window's editor.
struct EditorCommands: Commands {
    @FocusedValue(\.editor) private var editor

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import Artwork…") { editor?.showImporter = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Place Artwork…") { editor?.showImagePlacer = true }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button(editor?.design.printAndCut.isEnabled == true ? "Print & Cut…" : "Cut…") { editor?.showCutSheet = true }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(editor == nil || editor?.design.objects.isEmpty == true)
        }
        CommandMenu("Object") {
            Button("Duplicate") { editor?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: [.command])
            Button("Delete") { editor?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
            Divider()
            Button("Bring to Front") { editor?.bringToFront() }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Send to Back") { editor?.sendToBack() }
                .keyboardShortcut("[", modifiers: [.command])
            Divider()
            Button("Select All Objects") { editor?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Create Cut Contour…") { editor?.showContourSheet = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(editor?.hasPrintedImages != true)
            Divider()
            ForEach(Tool.allCases) { tool in
                Button { editor?.tool = tool } label: { Label(tool.title, systemImage: tool.symbol) }
            }
        }
    }
}

/// Plain-text document used for the “Save HPGL…” exporter.
struct HPGLFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

#if DEBUG
@MainActor
private func sampleDocument() -> DesignFileDocument {
    var design = DesignDocument(name: "Sample", canvasSize: Size(300, 200))
    design.objects = [
        DesignObject(name: "Rectangle", kind: .rectangle(cornerRadius: 6), frame: Rect(minX: 20, minY: 20, maxX: 120, maxY: 90)),
        DesignObject(name: "Star", kind: .star(points: 5, innerRatio: 0.5), frame: Rect(minX: 150, minY: 20, maxX: 230, maxY: 100), rotation: 15),
        DesignObject(name: "Text", kind: .text(TextSpec(text: "Bonança 2026", fontSize: 48)),
                     frame: Rect(origin: Point(20, 120), size: DesignObject.naturalTextSize(TextSpec(text: "Bonança 2026", fontSize: 48)))),
    ]
    return DesignFileDocument(design: design)
}

#Preview("Editor") {
    @Previewable @State var document = sampleDocument()
    MainView(document: $document)
        .environment(CutterController())
        .frame(width: 1100, height: 700)
}
#endif

#if DEBUG
@MainActor
private func printAndCutSample() -> DesignFileDocument {
    var design = DesignDocument(name: "Stickers", canvasSize: Size(210, 297))
    design.printAndCut = PrintAndCutSettings(isEnabled: true)
    // A generated bitmap stands in for the designer's print file.
    let image = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { rect in
        NSGradient(colors: [NSColor.systemOrange, NSColor.systemPink, NSColor.systemPurple])?.draw(in: rect, angle: 30)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 120, dy: 60)).fill()
        return true
    }
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    // Centred so the marks (20.5 mm left and right of the artwork) stay on the A4 page.
    let art = Rect(minX: 40, minY: 70, maxX: 170, maxY: 160)
    design.objects = [
        DesignObject(name: "Print file", kind: .image(ImageSpec(sourceName: "stickers.png", data: png, format: "png")), frame: art),
        DesignObject(name: "Contour", kind: .rectangle(cornerRadius: 8), frame: art),
        DesignObject(name: "Inner", kind: .ellipse, frame: Rect(minX: 65, minY: 85, maxX: 145, maxY: 145)),
    ]
    return DesignFileDocument(design: design)
}

#Preview("Print & Cut editor") {
    @Previewable @State var document = printAndCutSample()
    MainView(document: $document)
        .environment(CutterController())
        .frame(width: 1100, height: 760)
}

@MainActor
private func sampleEditor(_ document: DesignFileDocument) -> EditorState {
    let editor = EditorState()
    editor.design = document.design
    return editor
}

#Preview("Print & Cut dialog") {
    OutputSheetView(editor: sampleEditor(printAndCutSample()))
        .environment(CutterController())
        .frame(width: 1040, height: 720)
}

#Preview("Cut only dialog") {
    OutputSheetView(editor: sampleEditor(sampleDocument()))
        .environment(CutterController())
        .frame(width: 1040, height: 720)
}

#Preview("Cut only – blade settings") {
    let session = CutSession(design: sampleDocument().design)
    session.settings.sendSpeedAndForce = true
    return OutputSettingsForm(session: session, showBlade: true)
        .environment(CutterController())
        .frame(width: 400, height: 900)
}

#Preview("Cut wizard – load sheet") {
    CutWizardView(session: CutSession(design: printAndCutSample().design), onBack: {}, onPrintAnother: {}, onClose: {})
        .environment(CutterController())
}

#Preview("Cut wizard – load vinyl") {
    CutWizardView(session: CutSession(design: sampleDocument().design), onBack: {}, onPrintAnother: {}, onClose: {})
        .environment(CutterController())
}

#Preview("Create Cut Contour") {
    ContourSheetView(editor: sampleEditor(printAndCutSample()))
        .frame(width: 1000, height: 680)
}
#endif
