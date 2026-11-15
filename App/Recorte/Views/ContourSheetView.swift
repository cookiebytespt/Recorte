import AppKit
import CutterCore
import SwiftUI

/// Create Cut Contour (⇧⌘K): makes cut lines around placed (printed) images, like SignMaster's
/// Create Cut Contour. Results go on the “Cut contour” layer as normal, editable shapes.
struct ContourSheetView: View {
    enum Layers: String { case both, artwork, cut }

    @Environment(\.dismiss) private var dismiss
    @Bindable var editor: EditorState
    @State private var options = ContourOptions.default
    @State private var layers: Layers = .both
    @State private var replaceExisting = true
    @State private var preview: [UUID: [Polyline]] = [:]
    @State private var isTracing = false
    @State private var isCreating = false

    /// Selected printed images, or every printed image when none is selected.
    private var targets: [DesignObject] {
        let images = editor.design.objects.filter { $0.isVisible && $0.kind.isImage }
        let selected = images.filter { editor.selection.contains($0.id) }
        return selected.isEmpty ? images : selected
    }

    private var follow: Bool { options.shape == .follow }
    private var previewLines: [Polyline] { preview.values.flatMap { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Cut Contour").font(.headline)
                    Text("\(targets.count) printed images selected").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isTracing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            HStack(spacing: 0) {
                previewPane
                    .frame(minWidth: 460, idealWidth: 560)
                    .layoutPriority(1)
                Divider()
                settingsForm
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 420)
            }
            Divider()
            HStack {
                Button("Reset") { options = .default; replaceExisting = true; layers = .both }
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
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 600, idealHeight: 680)
        .task(id: PreviewKey(options: options, targets: targets.map(\.id))) {
            // Debounce slider drags, then trace at preview resolution off the main thread.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isTracing = true
            var previewOptions = options
            previewOptions.pixelsPerMM = 4
            let result = await Self.trace(targets, options: previewOptions)
            guard !Task.isCancelled else { return }
            preview = result
            isTracing = false
        }
    }

    private struct PreviewKey: Hashable {
        var options: ContourOptions
        var targets: [UUID]
    }

    private static func trace(_ objects: [DesignObject], options: ContourOptions) async -> [UUID: [Polyline]] {
        await Task.detached(priority: .userInitiated) {
            var out: [UUID: [Polyline]] = [:]
            for object in objects {
                if Task.isCancelled { break }
                out[object.id] = ContourTracer.contours(for: object, options: options)
            }
            return out
        }.value
    }

    // MARK: Preview

    private var previewPane: some View {
        GeometryReader { geo in
            let area = targets.reduce(Rect.null) { $0.union($1.documentBounds) }
                .union(previewLines.bounds)
                .insetBy(-6)
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
        return String(localized: "\(lines.count) cut lines · \(length)")
    }

    // MARK: Settings

    private var settingsForm: some View {
        Form {
            Section("Cut line") {
                Picker("Shape", selection: $options.shape) {
                    Text("Follow the artwork").tag(ContourOptions.Shape.follow)
                    Text("Rectangle").tag(ContourOptions.Shape.rectangle)
                    Text("Rounded").tag(ContourOptions.Shape.rounded)
                }
                .pickerStyle(.segmented)
                .help("Build Contours / Build Boxes in SignMaster")
                LabeledContent {
                    HStack {
                        Slider(value: $options.distanceMM, in: 0...10, step: 0.5)
                            .frame(width: 150)
                        Text(String(format: "%.1f mm", options.distanceMM)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                } label: {
                    Text("Distance from the artwork")
                    Text("Leave 1–2 mm so the knife misses the print edge")
                }
                .help("Called Outline offset in SignMaster")
                Picker("Corners", selection: $options.corners) {
                    Text("Round").tag(ContourOptions.Corners.round)
                    Text("Sharp").tag(ContourOptions.Corners.sharp)
                }
                .pickerStyle(.segmented)
                .disabled(!follow)
                Toggle(isOn: $options.cutHoles) {
                    Text("Cut out holes")
                    Text("Also cut transparent areas inside an image")
                }
                .disabled(!follow)
                .help("Called Keep Holes in SignMaster")
            }

            Section("Finding the edge") {
                LabeledContent("Edge of the image", value: String(localized: "Transparency"))
                Toggle(isOn: $options.whiteIsBackground) {
                    Text("Treat white as background")
                    Text("For JPEG and other images without transparency")
                }
                LabeledContent("Ignore specks smaller than") {
                    TextField("Ignore specks smaller than", value: $options.minimumSpeckMM, format: .number.precision(.fractionLength(1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                    Text("mm").foregroundStyle(.secondary)
                }
            }

            Section("Result") {
                LabeledContent("Put the cut lines on", value: String(localized: "New layer “Cut contour”"))
                Toggle("Replace existing cut contours", isOn: $replaceExisting)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Create

    private func create() {
        let objects = targets
        let options = self.options
        let replace = replaceExisting
        isCreating = true
        Task {
            let traced = await Self.trace(objects, options: options)
            var created: [DesignObject] = []
            for image in objects {
                let name = String(localized: "Cut contour – \(image.name)")
                switch options.shape {
                case .follow:
                    let paths = traced[image.id] ?? []
                    let b = paths.bounds
                    guard !b.isNull, b.width > 0, b.height > 0 else { continue }
                    let normalized = paths.transformed(AffineTransform.scaling(1 / b.width, 1 / b.height).concatenating(.translation(-b.minX, -b.minY)))
                    created.append(DesignObject(name: name, kind: .artwork(ArtworkSpec(sourceName: String(localized: "Cut contour"), paths: normalized)),
                                                frame: b, contourSourceID: image.id))
                case .rectangle, .rounded:
                    // Keep boxes as real rectangles so the corner radius stays editable.
                    guard case .image(let spec) = image.kind,
                          let box = ContourTracer.artworkBox(spec, size: image.frame.size, options: options) else { continue }
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
