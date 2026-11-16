import AppKit
import CutterCore
import SwiftUI
import TipKit

/// Right-hand panel: properties of the selection (or the canvas) plus the layers list.
struct SidebarView: View {
    @Bindable var editor: EditorState
    /// Share of the panel height used by the layers list; starts at about a fifth on launch.
    @State private var layersFraction: CGFloat = 0.22
    @State private var dragStartHeight: CGFloat?

    private let dividerHeight: CGFloat = 7
    private let minLayers: CGFloat = 100
    private let minProperties: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let layersHeight = min(max(total * layersFraction, minLayers), max(total - minProperties - dividerHeight, minLayers))
            VStack(spacing: 0) {
                Form {
                    if let object = editor.singleSelection {
                        ObjectSection(editor: editor, object: object)
                    } else if editor.selection.count > 1 {
                        Section {
                            Text("\(editor.selection.count) objects selected")
                            HStack {
                                Button("Duplicate") { editor.duplicateSelection() }
                                    .help("Makes a copy of the selection (⌘D).")
                                Button("Delete", role: .destructive) { editor.deleteObjects() }
                                    .help("Removes the selection, except locked objects. Undo with ⌘Z.")
                            }
                        }
                    } else {
                        CanvasSection(editor: editor)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                splitDivider(total: total, layersHeight: layersHeight)

                LayersList(editor: editor)
                    .frame(height: layersHeight)
            }
        }
    }

    /// Draggable divider between the properties and the layers list.
    private func splitDivider(total: CGFloat, layersHeight: CGFloat) -> some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(height: dividerHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? layersHeight
                    dragStartHeight = start
                    guard total > 0 else { return }
                    layersFraction = (start - value.translation.height) / total
                }
                .onEnded { _ in
                    guard total > 0 else { return }
                    layersFraction = min(max(layersFraction, minLayers / total), max(total - minProperties, minLayers) / total)
                    dragStartHeight = nil
                }
        )
    }
}

private struct CanvasSection: View {
    @Bindable var editor: EditorState
    private var mm: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...1)) }

    private static let pagePresets: [(String, Size)] = [
        ("A4", Size(210, 297)), ("A4 landscape", Size(297, 210)), ("A3", Size(297, 420)), ("A3 landscape", Size(420, 297)),
        ("SRA3", Size(320, 450)), ("SRA3 landscape", Size(450, 320)), ("Letter", Size(215.9, 279.4)), ("Tabloid", Size(279.4, 431.8)),
    ]

    var body: some View {
        Section("Canvas") {
            TextField("Width (mm)", value: Binding(
                get: { editor.design.canvasSize.width },
                set: { v in editor.change { $0.canvasSize.width = max(v, 10) } }), format: mm)
                .help("Size of the canvas. With Print & Cut on, it is the paper size.")
            TextField("Height (mm)", value: Binding(
                get: { editor.design.canvasSize.height },
                set: { v in editor.change { $0.canvasSize.height = max(v, 10) } }), format: mm)
                .help("Size of the canvas. With Print & Cut on, it is the paper size.")
            Menu("Page size") {
                ForEach(Self.pagePresets, id: \.0) { preset in
                    Button(preset.0) { editor.change { $0.canvasSize = preset.1 } }
                }
                Divider()
                Button("Match cutter width") {
                    let w = Preferences.machineProfile().cutWidthMM
                    editor.change { $0.canvasSize.width = w }
                }
                .help("Makes the canvas as wide as the machine can cut.")
            }
            .help("Sets the canvas to a paper size, or to the machine's cutting width.")
            LabeledContent("Objects", value: "\(editor.design.objects.count)")
        }

        Section {
            if !editor.design.printAndCut.isEnabled {
                TipView(PrintAndCutTip())
            }
            Toggle("Print & Cut", isOn: Binding(
                get: { editor.design.printAndCut.isEnabled },
                set: { v in
                    if v { PrintAndCutTip().invalidate(reason: .actionPerformed) }
                    editor.change {
                    $0.printAndCut.isEnabled = v
                    if v { $0.printAndCut.layout.markSizeParameter = Preferences.machineProfile().registrationMarkSize }
                } }))
                .help(HelpText.printAndCut)
            if editor.design.printAndCut.isEnabled {
                let layout = editor.design.printAndCut.layout
                let sheet = editor.design.printSheet
                Stepper(value: Binding(
                    get: { layout.markSizeParameter },
                    set: { v in editor.change { $0.printAndCut.layout.markSizeParameter = v } }), in: 5...100, step: 5) {
                    LabeledContent("Mark size", value: String(format: "%d · Ø %.0f mm", layout.markSizeParameter, layout.markDiameterMM))
                }
                .help(HelpText.markSize)
                Picker("Place the marks", selection: Binding(
                    get: { layout.placement },
                    set: { v in editor.change { $0.printAndCut.layout.placement = v } })) {
                    Text("Around the artwork").tag(MarkPlacement.aroundArtwork)
                    Text("At the page edges").tag(MarkPlacement.pageEdges)
                }
                .help(HelpText.placeMarks)
                if layout.placement == .aroundArtwork {
                    TextField("Distance from the artwork (mm)", value: Binding(
                        get: { layout.artworkDistanceMM },
                        set: { v in editor.change { $0.printAndCut.layout.artworkDistanceMM = max(v, layout.markDiameterMM) } }), format: mm)
                        .help(HelpText.markDistance)
                } else {
                    TextField("Side inset (mm)", value: Binding(
                        get: { layout.sideInsetMM },
                        set: { v in editor.change { $0.printAndCut.layout.sideInsetMM = max(v, layout.markDiameterMM / 2) } }), format: mm)
                        .help(HelpText.markInset)
                    TextField("Top inset (mm)", value: Binding(
                        get: { layout.topInsetMM },
                        set: { v in editor.change { $0.printAndCut.layout.topInsetMM = max(v, layout.markDiameterMM / 2) } }), format: mm)
                        .help(HelpText.markInset)
                    TextField("Bottom inset (mm)", value: Binding(
                        get: { layout.bottomInsetMM },
                        set: { v in editor.change { $0.printAndCut.layout.bottomInsetMM = max(v, layout.markDiameterMM / 2) } }), format: mm)
                        .help(HelpText.markInset)
                }
                if !sheet.marksFitPage {
                    Label("The marks don't fit on the page", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("Move the artwork away from the edges, use a bigger page or a smaller distance.")
                }
                if !editor.hasPrintedImages && editor.design.cutObjects.isEmpty {
                    Label("Next: place the artwork to print, then make a cut line around it.", systemImage: "lightbulb")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if editor.hasPrintedImages && editor.design.cutObjects.isEmpty {
                    Label("Next: make a cut line around the artwork with Create Cut Contour.", systemImage: "lightbulb")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Place artwork…") { editor.showImagePlacer = true }
                    .help(HelpText.placeArtwork)
                Button("Create Cut Contour…") { editor.showContourSheet = true }
                    .disabled(!editor.hasPrintedImages)
                    .help(editor.hasPrintedImages ? HelpText.createCutContour : "Place artwork to print first, then make a cut line around it.")
                Text("The canvas is the printed sheet. Placed images are printed; shapes, text and imported lines are cut after the machine reads the four marks. Keep everything inside the dashed area.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 4) { Text("Print & Cut"); InfoButton(topic: .registrationMarks) }
        }
        Section {
            Text("Pick a tool in the toolbar and drag on the canvas. Double-check sizes here before cutting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ObjectSection: View {
    @Bindable var editor: EditorState
    let object: DesignObject

    private var mm: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(0...2)) }

    private func frameBinding(_ get: @escaping (Rect) -> Double, _ set: @escaping (inout Rect, Double) -> Void) -> Binding<Double> {
        let id = object.id
        return Binding(get: { get(object.frame) }, set: { v in editor.update(id) { set(&$0.frame, v) } })
    }

    var body: some View {
        Section(object.name) {
            TextField("Name", text: Binding(get: { object.name }, set: { v in editor.update(object.id) { $0.name = v } }))
                .help("The name shown in the layers list.")
            HStack {
                TextField("X", value: frameBinding({ $0.minX }, { r, v in r = Rect(origin: Point(v, r.minY), size: r.size) }), format: mm)
                TextField("Y", value: frameBinding({ $0.minY }, { r, v in r = Rect(origin: Point(r.minX, v), size: r.size) }), format: mm)
            }
            .help("Position of the object's top-left corner, in mm from the top-left of the canvas.")
            HStack {
                TextField("W", value: frameBinding({ $0.width }, { r, v in r = Rect(origin: r.origin, size: Size(max(v, 0.1), r.height)) }), format: mm)
                TextField("H", value: frameBinding({ $0.height }, { r, v in r = Rect(origin: r.origin, size: Size(r.width, max(v, 0.1))) }), format: mm)
            }
            .help("Width and height in mm.")
            TextField("Rotation (°)", value: Binding(get: { object.rotation }, set: { v in editor.update(object.id) { $0.rotation = v } }), format: .number.precision(.fractionLength(0...1)))
                .help("Turns the object around its centre, in degrees.")
            Toggle("Visible", isOn: Binding(get: { object.isVisible }, set: { v in editor.update(object.id) { $0.isVisible = v } }))
                .help("Hidden objects are neither printed nor cut.")
            Toggle("Locked", isOn: Binding(get: { object.isLocked }, set: { v in editor.update(object.id) { $0.isLocked = v } }))
                .help("Locked objects can't be moved, resized or deleted. They are still printed and cut.")
        }

        kindSection

        Section {
            HStack {
                Button("Duplicate") { editor.duplicateSelection() }
                    .help("Makes a copy of the selection (⌘D).")
                Button("Delete", role: .destructive) { editor.deleteObjects() }
                    .help("Removes the selection, except locked objects. Undo with ⌘Z.")
            }
        }
    }

    @ViewBuilder
    private var kindSection: some View {
        switch object.kind {
        case .rectangle(let radius):
            Section("Rectangle") {
                TextField("Corner radius (mm)", value: Binding(get: { radius }, set: { v in editor.update(object.id) { $0.kind = .rectangle(cornerRadius: max(v, 0)) } }), format: mm)
                    .help("Rounds the corners. 0 gives sharp corners.")
            }
        case .polygon(let sides):
            Section("Polygon") {
                Stepper(value: Binding(get: { sides }, set: { v in editor.update(object.id) { $0.kind = .polygon(sides: v) } }), in: 3...24) {
                    LabeledContent("Sides", value: "\(sides)")
                }
                .help("Number of sides, from 3 to 24.")
            }
        case .star(let points, let ratio):
            Section("Star") {
                Stepper(value: Binding(get: { points }, set: { v in editor.update(object.id) { $0.kind = .star(points: v, innerRatio: ratio) } }), in: 3...24) {
                    LabeledContent("Points", value: "\(points)")
                }
                .help("Number of points, from 3 to 24.")
                Slider(value: Binding(get: { ratio }, set: { v in editor.update(object.id) { $0.kind = .star(points: points, innerRatio: v) } }), in: 0.1...0.9) {
                    Text("Inner radius")
                }
                .help("Lower values make thinner, sharper points.")
            }
        case .line(let reversed):
            Section("Line") {
                Toggle("Other diagonal", isOn: Binding(get: { reversed }, set: { v in editor.update(object.id) { $0.kind = .line(reversed: v) } }))
                    .help("Draws the line between the other two corners of its frame.")
            }
        case .freehand(let points, let closed):
            Section("Drawing") {
                Toggle("Closed shape", isOn: Binding(get: { closed }, set: { v in editor.update(object.id) { $0.kind = .freehand(points: points, closed: v) } }))
                    .help("Joins the end to the start, so the drawing is cut out as a piece.")
            }
        case .text(let spec):
            TextSection(editor: editor, object: object, spec: spec)
        case .artwork(let art):
            Section("Artwork") {
                LabeledContent("Source", value: art.sourceName)
                LabeledContent("Shapes", value: "\(art.curves.count)")
                LabeledContent("Points", value: "\(object.artworkPointCount)")
            }
            ArtworkLinesSection(editor: editor, object: object, lineCount: art.curves.count)
        case .image(let spec):
            Section("Printed image") {
                TipView(CreateContourTip())
                LabeledContent("Source", value: spec.sourceName)
                LabeledContent("Format", value: spec.format.uppercased())
                Button("Create Cut Contour…") {
                    editor.selection = [object.id]
                    editor.showContourSheet = true
                }
                .help("Makes a cut line around this image, a small distance away from it (⇧⌘K).")
                Button("Fit to sheet") {
                    let area = editor.printableArea
                    let f = object.frame
                    let k = min(area.width / f.width, area.height / f.height)
                    let size = Size(f.width * k, f.height * k)
                    editor.update(object.id) {
                        $0.frame = Rect(origin: Point(area.center.x - size.width / 2, area.center.y - size.height / 2), size: size)
                    }
                }
                .help("Makes the image as big as the printable area allows, keeping its proportions, and centres it.")
                Text("Printed on the Print & Cut sheet, never cut. Create a cut contour, or draw or import the cut lines on top of it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .ellipse:
            EmptyView()
        }
    }
}

private struct TextSection: View {
    @Bindable var editor: EditorState
    let object: DesignObject
    let spec: TextSpec

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    private func set(_ change: (inout TextSpec) -> Void, refit: Bool = true) {
        var s = spec
        change(&s)
        let id = object.id
        editor.update(id) { obj in
            obj.kind = .text(s)
            if refit {
                let size = DesignObject.naturalTextSize(s)
                obj.frame = Rect(origin: obj.frame.origin, size: size)
            }
        }
    }

    var body: some View {
        Section("Text") {
            TextEditor(text: Binding(get: { spec.text }, set: { v in set { $0.text = v } }))
                .font(.body)
                .frame(minHeight: 60)
            Picker("Font", selection: Binding(get: { spec.fontName }, set: { v in set { $0.fontName = v } })) {
                if !Self.families.contains(spec.fontName) { Text(spec.fontName).tag(spec.fontName) }
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
            .help("Any font installed on this Mac.")
            TextField("Size (pt)", value: Binding(get: { spec.fontSize }, set: { v in set { $0.fontSize = max(v, 1) } }), format: .number.precision(.fractionLength(0...1)))
                .help("Font size in points, as in Illustrator.")
            Button("Fit frame to text") { set({ _ in }, refit: true) }
                .help("Resizes the frame to fit the text exactly.")
            Text("Text is converted to outlines when cutting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LayersList: View {
    @Bindable var editor: EditorState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { editor.bringToFront() } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                    .help("Bring to front (⌘]). Objects on top are drawn over the ones below.")
                Button { editor.sendToBack() } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                    .help("Send to back (⌘[).")
            }
            .buttonStyle(.borderless)
            .disabled(editor.selection.isEmpty)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(selection: $editor.selection) {
                ForEach(editor.design.objects.reversed()) { object in
                    HStack(spacing: 8) {
                        Button {
                            editor.update(object.id) { $0.isVisible.toggle() }
                        } label: {
                            Image(systemName: object.isVisible ? "eye" : "eye.slash").foregroundStyle(object.isVisible ? .primary : .secondary)
                        }
                        .help("Show or hide. Hidden objects are neither printed nor cut.")
                        Image(systemName: object.isCutContour ? "scissors" : symbol(for: object.kind))
                            .foregroundStyle(object.isCutContour ? Color.accentColor : .secondary)
                            .frame(width: 16)
                            .help(object.isCutContour ? "Cut contour, made with Create Cut Contour" : "")
                        Text(object.name).lineLimit(1)
                        Spacer()
                        Button {
                            editor.update(object.id) { $0.isLocked.toggle() }
                        } label: {
                            Image(systemName: object.isLocked ? "lock.fill" : "lock.open").foregroundStyle(object.isLocked ? .primary : .tertiary)
                        }
                        .help("Lock or unlock. Locked objects can't be moved, resized or deleted.")
                    }
                    .buttonStyle(.borderless)
                    .tag(object.id)
                }
            }
            .listStyle(.inset)
            .overlay {
                if editor.design.objects.isEmpty {
                    Text("Nothing on the canvas yet").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func symbol(for kind: ShapeKind) -> String {
        switch kind {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .polygon: "hexagon"
        case .star: "star"
        case .freehand: "scribble"
        case .text: "textformat"
        case .artwork: "doc.richtext"
        case .image: "photo"
        }
    }
}

/// Editing the lines of artwork and cut contours: point editing, node types, removing inner lines,
/// splitting, and turning traced lines into smooth curves.
private struct ArtworkLinesSection: View {
    @Bindable var editor: EditorState
    let object: DesignObject
    let lineCount: Int
    @State private var toleranceMM = 0.1
    @State private var offsetMM = 2.0
    @State private var keepOriginal = true

    private var isEditing: Bool { editor.pathEdit?.objectID == object.id }
    private var selectedLine: Int? { isEditing ? editor.validPathEdit?.path : nil }
    private var selectedNode: BezierNode? { isEditing ? editor.selectedNode : nil }
    /// The selected line is open (offset only works on closed lines).
    private var selectedLineIsOpen: Bool {
        guard let p = selectedLine, let curves = object.artworkLocalCurves, curves.indices.contains(p) else { return false }
        return !curves[p].isClosed
    }
    private var hasClosedLines: Bool { object.artworkLocalCurves?.contains(where: \.isClosed) ?? false }

    private var outerCount: Int { object.artworkLocalCurves.map { DesignObject.outerPathIndices($0).count } ?? 0 }

    var body: some View {
        Section("Lines") {
            TipView(EditPointsTip())
            Button(isEditing ? LocalizedStringKey("Done Editing Points") : "Edit Points") {
                if isEditing { editor.endPathEdit() } else { editor.beginPathEdit(object.id) }
            }
            .help("Move, add or remove the points of the lines. You can also double-click the object on the canvas.")
            if isEditing {
                LabeledContent("Selected point") {
                    Picker("Selected point", selection: Binding(
                        get: { selectedNode?.hasHandles ?? false },
                        set: { editor.setSelectedPoint(smooth: $0) })) {
                        Text("Corner").tag(false)
                        Text("Smooth").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(selectedNode == nil)
                .help("Smooth points have curve handles; corner points join straight or independent segments. Double-click a point to switch.")
                Button("Delete Selected Line", role: .destructive) {
                    if var edit = editor.pathEdit { edit.point = nil; editor.pathEdit = edit }
                    editor.deleteInPathEdit()
                }
                .disabled(selectedLine == nil)
                .help("Removes the whole line that the selected point belongs to.")
            }
            Button("Keep Outer Lines Only") { editor.keepOuterLines() }
                .disabled(outerCount == lineCount)
                .help("Removes the lines inside other lines, such as holes in a cut contour")
            Button("Split into Separate Objects") { editor.splitIntoLines() }
                .disabled(lineCount < 2)
                .help("Makes each line its own object, to move, hide or delete them one by one.")
            LabeledContent {
                HStack {
                    TextField("Smooth into curves", value: $toleranceMM, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Text("mm").foregroundStyle(.secondary)
                    Button("Apply") { editor.smoothIntoCurves(toleranceMM: max(toleranceMM, 0.01)) }
                        .help("Replaces many small straight segments with fewer smooth curves. Good for traced or imported lines.")
                }
            } label: {
                Text("Smooth into curves")
                Text(selectedLine == nil ? LocalizedStringKey("Fits curves with fewer points; the line moves at most this distance")
                                         : "Only on the selected line")
            }
            LabeledContent {
                HStack {
                    TextField("Offset", value: $offsetMM, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Text("mm").foregroundStyle(.secondary)
                    if editor.isOffsetting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Apply") { Task { await editor.offsetLines(distanceMM: offsetMM, keepOriginal: keepOriginal) } }
                            .disabled(offsetMM == 0 || selectedLineIsOpen || !hasClosedLines)
                            .help(hasClosedLines ? "Moves the lines outwards (positive) or inwards (negative) by this distance." : "Only closed lines can be offset.")
                    }
                }
            } label: {
                Text("Offset")
                Text(selectedLineIsOpen ? LocalizedStringKey("Only closed lines can be offset")
                     : selectedLine == nil ? "Positive grows outwards, negative shrinks; round corners"
                     : "Only on the selected line")
            }
            if let note = editor.offsetNote {
                Text(note).font(.footnote).foregroundStyle(.orange)
            }
            Toggle("Keep the original line", isOn: $keepOriginal)
                .help("On: the offset becomes a new object. Off: it replaces the line.")
        }
        .disabled(object.isLocked)
    }
}
