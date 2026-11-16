import AppKit
import CutterCore
import SwiftUI

/// Create Cut Contour (⇧⌘K): makes cut lines around placed (printed) images, like SignMaster's
/// Create Cut Contour. Results go on the “Cut contour” layer as normal, editable shapes.
struct ContourSheetView: View {
    enum Layers: String { case both, artwork, cut }
    /// How the edge of the artwork is found.
    enum EdgeMode: String { case transparency, white, pick }

    @Environment(\.dismiss) private var dismiss
    @Bindable var editor: EditorState
    @State private var options = ContourOptions.default
    @State private var layers: Layers = .both
    @State private var replaceExisting = true
    @State private var preview: [UUID: [BezierPath]] = [:]
    @State private var isTracing = false
    @State private var isCreating = false
    @State private var edgeMode: EdgeMode = .transparency
    /// Colour picks per image (Pick colour mode), like Preview's Instant Alpha.
    @State private var picks: [UUID: [ColorPick]] = [:]
    /// Tinted overlay of the background areas per image, for Pick colour mode.
    @State private var overlays: [UUID: CGImage] = [:]
    /// The pick being dragged: its image, its index, and where the drag started.
    @State private var dragPick: (id: UUID, index: Int)?
    /// Images in the order they were picked, for Undo Last Pick.
    @State private var pickHistory: [UUID] = []
    /// Decoded images for picking at preview resolution, so dragging only runs the colour fill.
    @State private var rasters: [UUID: PickRaster] = [:]
    /// The area the pick being dragged takes, highlighted live.
    @State private var liveRegion: (id: UUID, image: CGImage)?
    /// The artwork mask before the pick being dragged, so each drag step only fills that one pick.
    @State private var dragBase: BitMask?

    /// Selected printed images, or every printed image when none is selected.
    private var targets: [DesignObject] {
        let images = editor.design.objects.filter { $0.isVisible && $0.kind.isImage }
        let selected = images.filter { editor.selection.contains($0.id) }
        return selected.isEmpty ? images : selected
    }

    /// Fixed sheet size: the document window's content area less 10 pt on each side, taken once when the sheet
    /// opens and kept in state, so nothing that happens inside the sheet can resize it.
    @State private var sheetSize: CGSize = ContourSheetView.openingSize()

    private static func openingSize() -> CGSize {
        // The document window is the main window (the sheet becomes the key window once it is shown).
        guard let window = NSApp.mainWindow else { return CGSize(width: 1100, height: 720) }
        let content = window.contentLayoutRect.size
        return CGSize(width: max(content.width - 20, 760), height: max(content.height - 20, 520))
    }

    private static let settingsWidth: CGFloat = SettingsMetrics.columnWidth
    private static let rowInnerWidth: CGFloat = SettingsMetrics.rowInnerWidth
    private static let valueWidth: CGFloat = 60
    private static let valueSpacing: CGFloat = 8

    /// Largest distance the slider offers, in mm (also the room kept around the artwork in the preview).
    private static let maxDistanceMM = 10.0

    private var follow: Bool { options.shape == .follow }
    private var previewLines: [Polyline] { preview.values.flatMap { $0 }.map { $0.flattened(tolerance: 0.1) } }
    private var previewNodeCount: Int { preview.values.flatMap { $0 }.reduce(0) { $0 + $1.nodes.count } }
    private var pickCount: Int { picks.values.reduce(0) { $0 + $1.count } }

    /// The settings for one image: the shared options plus the edge mode and that image's picks.
    private func options(for object: DesignObject) -> ContourOptions {
        var o = options
        o.whiteIsBackground = edgeMode == .white
        o.cutEnclosedWhite = edgeMode == .white && options.cutEnclosedWhite
        o.picks = edgeMode == .pick ? picks[object.id] ?? [] : []
        return o
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Cut Contour").font(.headline)
                    Text("\(targets.count) printed images selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            // An overlay, so the spinner appearing never changes the layout.
            .overlay(alignment: .trailing) {
                ProgressView().controlSize(.small).padding(.trailing, 16).opacity(isTracing ? 1 : 0)
            }
            Divider()
            HStack(spacing: 0) {
                previewPane
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                // A fixed 440 pt column. The form sits in it as an overlay, which cannot change the column's size
                // (forms recompute their width while controls update, e.g. during a slider drag), and is clipped to it.
                Color.clear
                    .frame(width: Self.settingsWidth)
                    .frame(maxHeight: .infinity)
                    .overlay { settingsForm.frame(width: Self.settingsWidth).scrollIndicators(.never) }
                    .clipped()
            }
            Divider()
            HStack {
                Button("Reset") {
                    options = .default; replaceExisting = true; layers = .both
                    edgeMode = .transparency; picks = [:]; pickHistory = []; overlays = [:]
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Contour", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty || isCreating)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        // The window owns the size: it opens at the document window's size (less 10 pt each side), the user can
        // resize it, and the layout always follows the window's actual size, so SwiftUI never resizes it itself.
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(ResizableSheet(minSize: CGSize(width: 760, height: 520), size: $sheetSize))
        .task(id: PreviewKey(options: options, targets: targets.map(\.id), edgeMode: edgeMode, picks: picks,
                             dragging: dragPick != nil)) {
            // While a pick is dragged only the highlight updates; the cut line is traced when it is let go.
            guard dragPick == nil else { return }
            // Debounce slider drags, then trace at preview resolution off the main thread.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            isTracing = true
            let perObject = Dictionary(uniqueKeysWithValues: targets.map { object -> (UUID, ContourOptions) in
                var o = options(for: object)
                o.pixelsPerMM = 4
                return (object.id, o)
            })
            let result = await Self.trace(targets, options: perObject)
            guard !Task.isCancelled else { return }
            preview = result
            isTracing = false
        }
        .task(id: RasterKey(targets: targets.map { [$0.id.uuidString, "\($0.frame.width)", "\($0.frame.height)"] }, picking: edgeMode == .pick)) {
            guard edgeMode == .pick else { rasters = [:]; overlays = [:]; return }
            let objects = targets
            rasters = await Task.detached(priority: .userInitiated) {
                var out: [UUID: PickRaster] = [:]
                for object in objects { out[object.id] = PickRaster(object: object, pixelsPerMM: 4) }
                return out
            }.value
            for object in objects { refreshOverlay(object.id) }
        }
    }

    private struct RasterKey: Hashable {
        var targets: [[String]]
        var picking: Bool
    }

    private struct PreviewKey: Hashable {
        var options: ContourOptions
        var targets: [UUID]
        var edgeMode: EdgeMode
        var picks: [UUID: [ColorPick]]
        var dragging: Bool
    }

    private static func trace(_ objects: [DesignObject], options: [UUID: ContourOptions]) async -> [UUID: [BezierPath]] {
        await Task.detached(priority: .userInitiated) {
            var out: [UUID: [BezierPath]] = [:]
            for object in objects {
                if Task.isCancelled { break }
                guard let o = options[object.id] else { continue }
                out[object.id] = ContourTracer.contourCurves(for: object, options: o)
            }
            return out
        }.value
    }

    /// A tint over the pixels of `mask` equal to `value`, in premultiplied RGBA `color`; other pixels clear.
    private static func tint(_ mask: BitMask, where value: Bool, color: (UInt8, UInt8, UInt8, UInt8)) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for i in 0..<(mask.width * mask.height) where mask.bits[i] == value {
            rgba[i * 4] = color.0; rgba[i * 4 + 1] = color.1; rgba[i * 4 + 2] = color.2; rgba[i * 4 + 3] = color.3
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: mask.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Background (everything the picks removed) in a soft blue-violet.
    private func refreshOverlay(_ id: UUID) {
        guard let raster = rasters[id] else { overlays[id] = nil; return }
        overlays[id] = Self.tint(raster.mask(picks: picks[id] ?? []), where: false, color: (50, 33, 121, 140))
    }

    // MARK: Colour pick

    /// Starts a pick at `point` (document mm) on the image under it; ⌥ puts the area back instead.
    private func beginPick(at point: Point) {
        for object in targets.reversed() {
            guard let inv = object.localToDocument.inverted() else { continue }
            let local = inv.apply(point)
            guard local.x >= 0, local.y >= 0, local.x <= object.frame.width, local.y <= object.frame.height else { continue }
            let keep = NSEvent.modifierFlags.contains(.option)
            let pick = ColorPick(point: Point(local.x / object.frame.width, local.y / object.frame.height),
                                 tolerance: Self.startTolerance, keep: keep)
            dragBase = rasters[object.id]?.mask(picks: picks[object.id] ?? [])
            picks[object.id, default: []].append(pick)
            dragPick = (object.id, picks[object.id]!.count - 1)
            pickHistory.append(object.id)
            refreshLive()
            return
        }
    }

    /// Dragging further takes more similar colours, like Preview: slow and precise at first, faster further out.
    private func updatePick(distance: CGFloat) {
        guard let d = dragPick, var list = picks[d.id], list.indices.contains(d.index) else { return }
        let tolerance = Self.tolerance(forDrag: Double(distance))
        guard list[d.index].tolerance != tolerance else { return }
        list[d.index].tolerance = tolerance
        picks[d.id] = list
        refreshLive()
    }

    /// A plain click takes the clicked colour (plus compression noise); 300 pt of drag reaches the maximum.
    static func tolerance(forDrag distance: Double) -> Double {
        let t = min(max(distance, 0) / 300, 1)
        return (max(Self.startTolerance, 100 * pow(t, 1.6)) * 2).rounded() / 2
    }

    private static let startTolerance = 2.0

    /// Updates the background tint and the highlight of the pick being dragged.
    private func refreshLive() {
        guard let d = dragPick, let raster = rasters[d.id], let pick = picks[d.id]?[d.index] else { return }
        let region = raster.region(pick)
        var mask = dragBase ?? raster.mask(picks: Array(picks[d.id]?.dropLast() ?? []))
        for i in region.bits.indices where region.bits[i] { mask.bits[i] = pick.keep }
        overlays[d.id] = Self.tint(mask, where: false, color: (50, 33, 121, 140))
        let color: (UInt8, UInt8, UInt8, UInt8) = pick.keep ? (30, 140, 60, 150) : (180, 30, 70, 150)
        liveRegion = Self.tint(region, where: true, color: color).map { (d.id, $0) }
    }

    private func endPick() {
        dragPick = nil
        liveRegion = nil
        dragBase = nil
    }

    private var currentTolerance: Double? {
        guard let d = dragPick, let list = picks[d.id], list.indices.contains(d.index) else { return nil }
        return list[d.index].tolerance
    }

    /// Removes the most recent pick (over all images).
    private func undoLastPick() {
        guard let id = pickHistory.popLast() else { return }
        picks[id]?.removeLast()
        if picks[id]?.isEmpty == true { picks[id] = nil }
        refreshOverlay(id)
    }

    // MARK: Preview

    private var previewPane: some View {
        GeometryReader { geo in
            // Fixed framing: the images plus room for the largest distance, so changing the distance only moves
            // the cut line and never re-zooms the artwork.
            let area = targets.reduce(Rect.null) { $0.union($1.documentBounds) }
                .insetBy(-(Self.maxDistanceMM + 6))
            let scale = area.isNull ? 1 : min((geo.size.width - 60) / area.width, (geo.size.height - 100) / area.height)
            let origin = CGPoint(x: (geo.size.width - area.width * scale) / 2, y: (geo.size.height - area.height * scale) / 2 - 16)
            let pt: (Point) -> CGPoint = { p in CGPoint(x: origin.x + (p.x - area.minX) * scale, y: origin.y + (p.y - area.minY) * scale) }
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Canvas { ctx, _ in
                    guard !area.isNull else { return }
                    let paper = CGRect(origin: origin, size: CGSize(width: area.width * scale, height: area.height * scale))
                    ctx.fill(Path(paper), with: .color(.white))
                    if layers != .cut {
                        for object in targets {
                            guard let image = editor.image(for: object) else { continue }
                            let c = pt(object.center)
                            let w = object.frame.width * scale, h = object.frame.height * scale
                            ctx.drawLayer { layer in
                                layer.translateBy(x: c.x, y: c.y)
                                layer.rotate(by: .degrees(object.rotation))
                                layer.draw(Image(nsImage: image), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                                if edgeMode == .pick, let tint = overlays[object.id] {
                                    layer.draw(Image(decorative: tint, scale: 1), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                                }
                                if edgeMode == .pick, let live = liveRegion, live.id == object.id {
                                    layer.draw(Image(decorative: live.image, scale: 1), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                                }
                            }
                        }
                    }
                    if layers != .artwork {
                        var path = Path()
                        for poly in previewLines { path.addPolyline(poly, pt) }
                        ctx.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
                    }
                }
                if targets.isEmpty {
                    Text("Place a printed image first (File ▸ Place Artwork…).").foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragPick == nil {
                            let v = value.startLocation
                            beginPick(at: Point(area.minX + Double(v.x - origin.x) / scale, area.minY + Double(v.y - origin.y) / scale))
                        }
                        updatePick(distance: hypot(value.translation.width, value.translation.height))
                    }
                    .onEnded { _ in endPick() },
                including: edgeMode == .pick && !area.isNull ? .all : .subviews
            )
            .onHover { inside in
                guard edgeMode == .pick else { return }
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Picker("Show", selection: $layers) {
                    Text("Both").tag(Layers.both)
                    Text("Artwork").tag(Layers.artwork)
                    Text("Cut line").tag(Layers.cut)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let tolerance = currentTolerance {
                    Text("Tolerance \(Int(tolerance.rounded()))").monospacedDigit()
                } else if edgeMode == .pick, pickCount == 0 {
                    Text("Click the background and drag to take more similar colours").foregroundStyle(.secondary)
                }
                Text(summary).foregroundStyle(.secondary)
            }
            .font(.caption)
            .controlSize(.small)
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
    }

    private var summary: String {
        let lines = previewLines
        let length = String(format: "%.2f m", lines.totalLength / 1000)
        return String(localized: "\(lines.count) cut lines · \(length)") + " · " + String(localized: "\(previewNodeCount) points")
    }

    // MARK: Settings

    /// The settings, laid out by hand (not a grouped Form): a macOS Form is a table underneath that re-measures its
    /// width whenever a row changes, which made the whole panel breathe while the distance slider moved.
    private var settingsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSection("Cut line") {
                    // Label above, control across the whole row, so the three choices get the full width.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shape")
                        // Drawn in SwiftUI: the system segmented control re-spaced its segments on every
                        // slider step (its frame stayed put, the segments moved inside it).
                        SegmentedChoice(selection: $options.shape, width: Self.rowInnerWidth, choices: [
                            (.follow, "Follow the artwork"), (.rectangle, "Rectangle"), (.rounded, "Rounded"),
                        ])
                    }
                    .settingsRowPadding()
                    .help("Build Contours / Build Boxes in SignMaster")
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Distance from the artwork")
                        Text("Leave 1–2 mm so the knife misses the print edge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // Every width explicit, adding up to the row's inner width, so nothing is re-measured
                        // while the slider is dragged: slider + 8 pt + 60 pt value label.
                        HStack(spacing: Self.valueSpacing) {
                            Slider(value: $options.distanceMM, in: 0...Self.maxDistanceMM, step: 0.5)
                                .labelsHidden()
                                .frame(width: Self.rowInnerWidth - Self.valueSpacing - Self.valueWidth)
                            Text(String(format: "%.1f mm", options.distanceMM))
                                .monospacedDigit()
                                .lineLimit(1)
                                .frame(width: Self.valueWidth, alignment: .trailing)
                        }
                        .frame(width: Self.rowInnerWidth, alignment: .leading)
                        .padding(.top, 2)
                    }
                    // The row's own width is fixed too: without it the stack took its width from its children,
                    // which alternated by 18.5 pt during a slider drag and re-centred the whole row (logged).
                    .frame(width: Self.rowInnerWidth, alignment: .leading)
                    .settingsRowPadding()
                    .help("Called Outline offset in SignMaster")
                    SettingsDivider()
                    SettingRow("Corners") {
                        SegmentedChoice(selection: $options.corners, width: 150, choices: [
                            (.round, "Round"), (.sharp, "Sharp"),
                        ])
                    }
                    .disabled(!follow)
                    SettingsDivider()
                    SettingRow("Cut out holes", subtitle: "Also cut transparent areas inside an image") {
                        SettingSwitch(isOn: $options.cutHoles)
                    }
                    .disabled(!follow)
                    .help("Called Keep Holes in SignMaster")
                    SettingsDivider()
                    SettingRow("Smooth curves", subtitle: "Fewer points and smoother cuts; the points stay editable") {
                        SettingSwitch(isOn: $options.smoothCurves)
                    }
                    .disabled(!follow)
                }

                SettingsSection("Finding the edge") {
                    SettingRow("Edge of the image") {
                        Picker("Edge of the image", selection: $edgeMode) {
                            Text("Transparency").tag(EdgeMode.transparency)
                            Text("White background").tag(EdgeMode.white)
                            Text("Pick colour").tag(EdgeMode.pick)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .help("Pick colour works like Instant Alpha in Preview")
                    SettingsDivider()
                    switch edgeMode {
                    case .transparency:
                        Text("Transparent pixels are the background. For JPEG and other images without transparency, use White background or Pick colour.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: Self.rowInnerWidth, alignment: .leading)
                            .settingsRowPadding()
                    case .white:
                        SettingRow("Also cut white areas inside", subtitle: "For example white letters on a coloured background") {
                            SettingSwitch(isOn: $options.cutEnclosedWhite)
                        }
                        .disabled(!options.cutHoles || !follow)
                        .help("Off: only white that touches the edge of the image is background")
                    case .pick:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Click the background in the preview and drag to take more similar colours. Click again to remove more; ⌥-click puts an area back.")
                                .font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                Text("\(pickCount) picks").monospacedDigit()
                                Spacer()
                                Button("Undo Last Pick", action: undoLastPick).disabled(pickHistory.isEmpty)
                                Button("Clear") {
                                    picks = [:]; pickHistory = []
                                    for id in rasters.keys { refreshOverlay(id) }
                                }
                                .disabled(pickCount == 0)
                            }
                        }
                        .settingsRowPadding()
                    }
                    SettingsDivider()
                    SettingRow("Ignore specks smaller than") {
                        HStack(spacing: 4) {
                            TextField("Ignore specks smaller than", value: $options.minimumSpeckMM, format: .number.precision(.fractionLength(1)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 52)
                            Text("mm").foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsSection("Result") {
                    SettingRow("Put the cut lines on") {
                        Text("New layer “Cut contour”").foregroundStyle(.secondary)
                    }
                    SettingsDivider()
                    SettingRow("Replace existing cut contours") {
                        SettingSwitch(isOn: $replaceExisting)
                    }
                }
            }
            // Exactly the column's width (less the padding). If the content were wider than the scroll view,
            // dragging a control (the distance slider) would auto-scroll it sideways and back.
            .frame(width: Self.settingsWidth - 32)
            .padding(16)
        }
        .scrollIndicators(.never)
    }

    // MARK: Create

    private func create() {
        let objects = targets
        let options = self.options
        let perObject = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, self.options(for: $0)) })
        let replace = replaceExisting
        isCreating = true
        Task {
            let traced = await Self.trace(objects, options: perObject)
            var created: [DesignObject] = []
            for image in objects {
                let name = String(localized: "Cut contour – \(image.name)")
                switch options.shape {
                case .follow:
                    let curves = traced[image.id] ?? []
                    let b = curves.bounds
                    guard !b.isNull, b.width > 0, b.height > 0 else { continue }
                    let normalized = curves.transformed(AffineTransform.scaling(1 / b.width, 1 / b.height).concatenating(.translation(-b.minX, -b.minY)))
                    created.append(DesignObject(name: name, kind: .artwork(ArtworkSpec(sourceName: String(localized: "Cut contour"), curves: normalized)),
                                                frame: b, contourSourceID: image.id))
                case .rectangle, .rounded:
                    // Keep boxes as real rectangles so the corner radius stays editable.
                    guard case .image(let spec) = image.kind,
                          let box = ContourTracer.artworkBox(spec, size: image.frame.size, options: perObject[image.id] ?? options) else { continue }
                    let r = box.insetBy(-max(options.distanceMM, 0))
                    let radius = options.shape == .rounded ? min(3 + options.distanceMM, min(r.width, r.height) / 2) : 0
                    let center = image.localToDocument.apply(r.center)
                    let frame = Rect(origin: Point(center.x - r.width / 2, center.y - r.height / 2), size: r.size)
                    created.append(DesignObject(name: name, kind: .rectangle(cornerRadius: radius), frame: frame,
                                                rotation: image.rotation, contourSourceID: image.id))
                }
            }
            let sources = Set(objects.map(\.id))
            editor.change { doc in
                if replace { doc.objects.removeAll { $0.contourSourceID.map(sources.contains) ?? false } }
                doc.objects.append(contentsOf: created)
            }
            editor.selection = Set(created.map(\.id))
            isCreating = false
            dismiss()
        }
    }
}

// MARK: - Settings layout

/// A titled group of rows on a rounded background, like a grouped Form section but with a fixed layout.
private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10)
            // Exactly the content width: a stack takes its widest child's width, so a flexible frame here let one
            // row's changing measurement re-centre the whole section during a slider drag (logged).
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

/// A row: title (and optional subtitle) on the left, the control on the right.
private struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let control: Control

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .settingsRowPadding()
    }
}

private struct SettingSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 10) }
}

/// Fixed widths for the settings column, so no row or section is ever measured from its contents.
enum SettingsMetrics {
    static let columnWidth: CGFloat = 440
    /// The column less 16 pt padding each side.
    static let contentWidth: CGFloat = columnWidth - 32
    /// A row less its 10 pt padding each side.
    static let rowInnerWidth: CGFloat = contentWidth - 20
}

private extension View {
    /// Every row is exactly the row width (plus padding), whatever its contents report.
    func settingsRowPadding() -> some View {
        frame(width: SettingsMetrics.rowInnerWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

/// Makes the sheet window resizable and reports its size as it changes, so the SwiftUI layout always matches
/// the window instead of asking AppKit for a different size.
private struct ResizableSheet: NSViewRepresentable {
    let minSize: CGSize
    @Binding var size: CGSize

    func makeNSView(context: Context) -> NSView {
        Probe(minSize: minSize) { newSize in
            if abs(newSize.width - size.width) > 0.5 || abs(newSize.height - size.height) > 0.5 { size = newSize }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let minSize: CGSize
        let onResize: (CGSize) -> Void
        private var observer: NSObjectProtocol?

        init(minSize: CGSize, onResize: @escaping (CGSize) -> Void) {
            self.minSize = minSize
            self.onResize = onResize
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = minSize
            // Only user resizes change the size; they arrive while the user drags the sheet's edge.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.inLiveResize else { return }
                    self.onResize(window.contentLayoutRect.size)
                }
            }
        }
    }
}

/// A segmented control drawn entirely in SwiftUI with equal, fixed-width segments, so nothing re-spaces it
/// when the surrounding view updates (the system control did during slider drags).
private struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let width: CGFloat
    let choices: [(Value, LocalizedStringKey)]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let segment = width / CGFloat(max(choices.count, 1))
        HStack(spacing: 0) {
            ForEach(choices.indices, id: \.self) { i in
                let (value, title) = choices[i]
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(width: segment - 4, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(width: segment, height: 24)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
        .opacity(isEnabled ? 1 : 0.5)
    }
}

