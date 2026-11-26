import CutterCore
import AppKit
import Foundation
import Observation
import SwiftUI
import TipKit
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case select, hand, rectangle, ellipse, line, polygon, star, freehand, text

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "arrow.up.left"
        case .hand: "hand.raised"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .polygon: "hexagon"
        case .star: "star"
        case .freehand: "pencil.and.outline"
        case .text: "textformat"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .select: "Select (V)"
        case .hand: "Pan (H)"
        case .rectangle: "Rectangle (R)"
        case .ellipse: "Ellipse (E)"
        case .line: "Line (L)"
        case .polygon: "Polygon (G)"
        case .star: "Star (S)"
        case .freehand: "Freehand (P)"
        case .text: "Text (T)"
        }
    }

    /// How to use the tool, shown in its help tag after the title.
    var hint: LocalizedStringKey {
        switch self {
        case .select: "Click to select, drag to move, Shift-click to add more. Double-click lines to edit their points."
        case .hand: "Drag to move around the canvas. Pinch to zoom."
        case .rectangle: "Drag to draw, or click for a 40 mm square. Hold Shift to keep it square."
        case .ellipse: "Drag to draw, or click for a 40 mm circle. Hold Shift to keep it round."
        case .line: "Drag to draw a straight line. Open lines are cut but don't make a separate piece."
        case .polygon: "Drag to draw. Change the number of sides in the sidebar."
        case .star: "Drag to draw. Change the points and inner radius in the sidebar."
        case .freehand: "Drag to draw freely. Turn on Closed shape in the sidebar to cut out a piece."
        case .text: "Click to add text in any installed font. It is turned into outlines for cutting."
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .hand: "h"
        case .rectangle: "r"
        case .ellipse: "e"
        case .line: "l"
        case .polygon: "g"
        case .star: "s"
        case .freehand: "p"
        case .text: "t"
        }
    }
}

/// Per-window editing state: tool, selection, view, and undoable changes to the document.
@MainActor
@Observable
final class EditorState {
    var tool: Tool = .select
    var selection: Set<UUID> = [] {
        didSet {
            if let edit = pathEdit, selection != [edit.objectID] { pathEdit = nil }
        }
    }
    /// Point editing of one artwork object (double-click it on the canvas).
    var pathEdit: PathEdit?
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var showCutSheet = false
    var showContourSheet = false
    var showImporter = false
    var showImagePlacer = false
    var importError: String?
    /// An offset is being computed (it can take a moment on large shapes).
    var isOffsetting = false
    /// Why the last offset did nothing, shown under the offset field.
    var offsetNote: String?

    /// Decoded images for the canvas, keyed by object id (not part of the document).
    @ObservationIgnored var imageCache: [UUID: NSImage] = [:]

    @ObservationIgnored var document: Binding<DesignFileDocument>?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var transactionSnapshot: DesignDocument?

    /// Observable mirror of the document's design; every write is pushed to the document binding.
    var design: DesignDocument = DesignDocument() {
        didSet {
            if let document, document.wrappedValue.design != design {
                document.wrappedValue.design = design
            }
        }
    }

    var selectedObjects: [DesignObject] { design.objects.filter { selection.contains($0.id) } }
    var singleSelection: DesignObject? { selection.count == 1 ? selectedObjects.first : nil }

    // MARK: Undo plumbing

    /// One discrete, undoable change.
    func change(_ body: (inout DesignDocument) -> Void) {
        let old = design
        var next = old
        body(&next)
        guard next != old else { return }
        design = next
        registerUndo(from: old)
    }

    /// Continuous edits (drags): call `beginTransaction`, then `changeLive` repeatedly, then `endTransaction`.
    func beginTransaction() { transactionSnapshot = design }

    func changeLive(_ body: (inout DesignDocument) -> Void) {
        var next = design
        body(&next)
        design = next
    }

    func endTransaction() {
        guard let old = transactionSnapshot else { return }
        transactionSnapshot = nil
        registerUndo(from: old)
    }

    private func registerUndo(from old: DesignDocument) {
        guard old != design, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                let current = editor.design
                editor.design = old
                editor.selection = editor.selection.filter { old.object($0) != nil }
                editor.registerUndo(from: current)
            }
        }
    }

    // MARK: Object operations

    @discardableResult
    func add(_ kind: ShapeKind, frame: Rect, name: String) -> UUID {
        let object = DesignObject(name: uniqueName(name), kind: kind, frame: frame)
        change { $0.objects.append(object) }
        selection = [object.id]
        return object.id
    }

    func update(_ id: UUID, _ body: (inout DesignObject) -> Void) {
        change { $0.update(id, body) }
    }

    /// Deletes what is selected: the selected point or line while editing points, otherwise the objects.
    func deleteSelection() {
        if pathEdit != nil { deleteInPathEdit(); return }
        deleteObjects()
    }

    /// Deletes the selected objects (also while editing points).
    func deleteObjects() {
        pathEdit = nil
        guard !selection.isEmpty else { return }
        let ids = selection
        change { $0.objects.removeAll { ids.contains($0.id) && !$0.isLocked } }
        selection = []
    }

    func duplicateSelection() {
        let copies = selectedObjects.map { original -> DesignObject in
            var copy = original
            copy.id = UUID()
            copy.name = uniqueName(original.name)
            copy.frame = Rect(origin: original.frame.origin + Point(5, 5), size: original.frame.size)
            return copy
        }
        guard !copies.isEmpty else { return }
        change { $0.objects.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
    }

    func selectAll() { selection = Set(design.objects.filter { !$0.isLocked }.map(\.id)) }

    func nudge(_ dx: Double, _ dy: Double) {
        if pathEdit != nil { nudgeInPathEdit(dx, dy); return }
        let ids = selection
        change { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) && !doc.objects[i].isLocked {
                let f = doc.objects[i].frame
                doc.objects[i].frame = Rect(origin: f.origin + Point(dx, dy), size: f.size)
            }
        }
    }

    func bringToFront() {
        let ids = selection
        change { doc in
            let moving = doc.objects.filter { ids.contains($0.id) }
            doc.objects.removeAll { ids.contains($0.id) }
            doc.objects.append(contentsOf: moving)
        }
    }

    func sendToBack() {
        let ids = selection
        change { doc in
            let moving = doc.objects.filter { ids.contains($0.id) }
            doc.objects.removeAll { ids.contains($0.id) }
            doc.objects.insert(contentsOf: moving, at: 0)
        }
    }

    func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try DocumentLoader.load(url: url, options: Preferences.importOptions())
            let wrapped = DesignDocument.fromImport(imported, sourceName: url.lastPathComponent)
            guard var object = wrapped.objects.first else { return }
            object.name = uniqueName((url.lastPathComponent as NSString).deletingPathExtension)
            change { $0.objects.append(object) }
            selection = [object.id]
        } catch {
            importError = error.localizedDescription
        }
    }

    /// A file dropped on the canvas: projects, SVG, PDF, AI and DXF open in their own window; images are
    /// placed as printed artwork where they were dropped.
    func handleDroppedFile(_ url: URL, at point: Point) {
        if DocumentFiles.opensAsDocument(url) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            placeImage(url, centeredAt: point)
        } else {
            importError = String(localized: "Recorte can’t use this kind of file. Drop an image to place it on the canvas, or a project, SVG, PDF, AI or DXF file to open it.")
        }
    }

    /// Adds a PDF/AI or bitmap image as printed artwork for Print & Cut.
    /// - Parameter center: where to put the artwork's centre (canvas mm), e.g. the drop point. Defaults to the
    ///   top-left of the printable area.
    func placeImage(_ url: URL, centeredAt center: Point? = nil) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            placeImage(data: data, sourceName: url.lastPathComponent, centeredAt: center)
        } catch {
            importError = error.localizedDescription
        }
    }

    /// Adds image data (a file's contents or an image dragged from another app) as printed artwork.
    func placeImage(data: Data, sourceName: String, centeredAt center: Point? = nil) {
        guard let (stored, format, natural) = Self.printableImage(data: data, sourceName: sourceName) else {
            importError = String(localized: "The file could not be opened as an image.")
            return
        }
        let area = printableArea
        let fit = min(1, area.width / natural.width, area.height / natural.height)
        let size = Size(natural.width * fit, natural.height * fit)
        var origin = area.origin
        if let center {
            // Centre on the drop point, but keep the artwork inside the printable area when it fits.
            let x = min(max(center.x - size.width / 2, area.minX), area.maxX - size.width)
            let y = min(max(center.y - size.height / 2, area.minY), area.maxY - size.height)
            origin = Point(x, y)
        }
        let object = DesignObject(
            name: uniqueName((sourceName as NSString).deletingPathExtension),
            kind: .image(ImageSpec(sourceName: sourceName, data: stored, format: format)),
            frame: Rect(origin: origin, size: size))
        change { $0.objects.insert(object, at: 0) }   // behind the cut lines
        selection = [object.id]
    }

    /// The data to store, its format ("pdf", "png" or "jpeg") and its natural size in mm.
    /// PDF/AI keep their vector data (points → mm). Bitmaps are sized at 300 dpi from their pixel size;
    /// formats other than PNG/JPEG (TIFF, HEIC, GIF, WebP…) are converted to PNG.
    static func printableImage(data: Data, sourceName: String) -> (Data, String, Size)? {
        let ext = (sourceName as NSString).pathExtension.lowercased()
        let isPDF = ext == "pdf" || ext == "ai" || data.starts(with: Array("%PDF".utf8))
        if isPDF {
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            let mm = 25.4 / 72
            return (data, "pdf", Size(image.size.width * mm, image.size.height * mm))
        }
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let mm = 25.4 / 300
        let size = Size(Double(rep.pixelsWide) * mm, Double(rep.pixelsHigh) * mm)
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if isJPEG { return (data, "jpeg", size) }
        if isPNG { return (data, "png", size) }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png", size)
    }

    /// Where printed artwork can go: inside the page-edge marks, or (marks around the artwork) far enough
    /// from the page edges that the marks still fit beside it.
    var printableArea: Rect {
        guard design.printAndCut.isEnabled else { return Rect(origin: .zero, size: design.canvasSize) }
        return design.printAndCut.layout.artworkArea(for: design.canvasSize)
    }

    /// Selected printed images, or all of them, for Create Cut Contour.
    var hasPrintedImages: Bool { design.objects.contains { $0.kind.isImage && $0.isVisible } }

    func image(for object: DesignObject) -> NSImage? {
        guard case .image(let spec) = object.kind else { return nil }
        if let cached = imageCache[object.id] { return cached }
        let image = NSImage(data: spec.data)
        imageCache[object.id] = image
        return image
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(design.objects.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - Point editing

/// Which line and node of an artwork object are selected while editing points.
struct PathEdit: Equatable {
    var objectID: UUID
    /// Selected line (index into the artwork's curves).
    var path: Int?
    /// Selected node on the selected line.
    var point: Int?
}

extension EditorState {
    /// The object being point-edited, when it still exists and can be edited.
    var pathEditObject: DesignObject? {
        guard let edit = pathEdit, let object = design.object(edit.objectID),
              object.isEditableArtwork, object.isVisible, !object.isLocked else { return nil }
        return object
    }

    /// The selection clamped to what the object currently has (undo can remove lines and nodes).
    var validPathEdit: PathEdit? {
        guard var edit = pathEdit, let curves = pathEditObject?.artworkLocalCurves else { return nil }
        if let p = edit.path, !curves.indices.contains(p) { edit.path = nil; edit.point = nil }
        if let p = edit.path, let k = edit.point, !curves[p].nodes.indices.contains(k) { edit.point = nil }
        if edit.path == nil { edit.point = nil }
        return edit
    }

    /// The selected node, while editing points.
    var selectedNode: BezierNode? {
        guard let edit = validPathEdit, let p = edit.path, let k = edit.point else { return nil }
        return pathEditObject?.artworkLocalCurves?[p].nodes[k]
    }

    var canEditPoints: Bool { singleSelection.map { $0.isEditableArtwork && !$0.isLocked } ?? false }

    func beginPathEdit(_ id: UUID) {
        guard let object = design.object(id), object.isEditableArtwork, !object.isLocked else { return }
        EditPointsTip().invalidate(reason: .actionPerformed)
        tool = .select
        selection = [id]
        let count = object.artworkLocalCurves?.count ?? 0
        pathEdit = PathEdit(objectID: id, path: count == 1 ? 0 : nil, point: nil)
    }

    func endPathEdit() { pathEdit = nil }

    /// Delete key while editing: the selected node, else the selected line. Removing the last line
    /// removes the object.
    func deleteInPathEdit() {
        guard let edit = validPathEdit, let object = pathEditObject else { endPathEdit(); return }
        guard let p = edit.path else { return }
        let result: DesignObject?
        if let k = edit.point {
            result = object.deletingArtworkPoint(path: p, point: k)
        } else {
            result = object.removingArtworkPaths([p])
        }
        if let result {
            change { $0.update(object.id) { $0 = result } }
            let curves = result.artworkLocalCurves ?? []
            if let k = edit.point, curves.count == object.artworkLocalCurves?.count, curves.indices.contains(p) {
                // Select the neighbouring node so ⌫ can be pressed repeatedly.
                let n = curves[p].nodes.count
                pathEdit = PathEdit(objectID: object.id, path: p, point: n > 0 ? min(k, n - 1) : nil)
            } else {
                pathEdit = PathEdit(objectID: object.id, path: curves.count == 1 ? 0 : nil, point: nil)
            }
        } else {
            let id = object.id
            pathEdit = nil
            change { $0.objects.removeAll { $0.id == id } }
            selection = []
        }
    }

    /// Arrow keys while editing: move the selected node or line by (dx, dy) mm on the page.
    func nudgeInPathEdit(_ dx: Double, _ dy: Double) {
        guard let edit = validPathEdit, let object = pathEditObject, let p = edit.path,
              let inv = object.localToDocument.inverted() else { return }
        let d = inv.applyVector(Point(dx, dy))
        change { doc in
            doc.update(object.id) { o in
                o.editArtworkCurves { curves in
                    if let k = edit.point { curves[p].nodes[k] = curves[p].nodes[k].moved(by: d) }
                    else { curves[p].nodes = curves[p].nodes.map { $0.moved(by: d) } }
                }
            }
        }
    }

    /// Makes the selected node smooth or a corner.
    func setSelectedPoint(smooth: Bool) {
        guard let edit = validPathEdit, let object = pathEditObject, let p = edit.path, let k = edit.point else { return }
        let result = object.settingArtworkPoint(path: p, point: k, smooth: smooth)
        change { $0.update(object.id) { $0 = result } }
    }

    /// Keeps only the outer lines of the selected artwork (drops holes and lines inside others).
    func keepOuterLines() {
        guard let object = singleSelection, object.isEditableArtwork, !object.isLocked else { return }
        let result = object.keepingOuterArtworkPaths()
        change { $0.update(object.id) { $0 = result } }
        if pathEdit != nil { beginPathEdit(object.id) }
    }

    /// Replaces the selected artwork with one object per line.
    func splitIntoLines() {
        guard let object = singleSelection, object.isEditableArtwork, !object.isLocked else { return }
        let parts = object.splitArtwork()
        guard parts.count > 1 else { return }
        pathEdit = nil
        change { doc in
            guard let i = doc.objects.firstIndex(where: { $0.id == object.id }) else { return }
            doc.objects.replaceSubrange(i...i, with: parts)
        }
        selection = Set(parts.map(\.id))
    }

    /// Grows (positive) or shrinks (negative) the selected line, or all lines of the selected artwork, by
    /// `distanceMM`. With `keepOriginal` the result becomes a new object; otherwise it replaces the lines.
    func offsetLines(distanceMM: Double, keepOriginal: Bool) async {
        guard distanceMM != 0, let object = singleSelection, object.isEditableArtwork, !object.isLocked else { return }
        let line = validPathEdit?.path
        isOffsetting = true
        offsetNote = nil
        defer { isOffsetting = false }
        let offset = await Task.detached(priority: .userInitiated) {
            object.offsetArtworkCurves(distanceMM: distanceMM, only: line)
        }.value
        guard let current = design.object(object.id), current == object else { return }   // changed meanwhile
        if offset.isEmpty {
            offsetNote = String(localized: "Nothing is left after shrinking by this distance.")
            return
        }
        if keepOriginal {
            let mm = distanceMM.formatted(.number.precision(.fractionLength(0...2)))
            guard let copy = object.offsetCopy(offset, name: String(localized: "\(object.name) – offset \(mm) mm")) else { return }
            pathEdit = nil
            change { doc in
                let i = doc.objects.firstIndex { $0.id == object.id }.map { $0 + 1 } ?? doc.objects.count
                doc.objects.insert(copy, at: i)
            }
            selection = [copy.id]
        } else if let result = object.replacingWithOffset(offset, only: line) {
            change { $0.update(object.id) { $0 = result } }
            if pathEdit != nil { beginPathEdit(object.id) }
        }
    }

    /// Turns the lines into smooth curves within `toleranceMM` (only the selected line while editing).
    func smoothIntoCurves(toleranceMM: Double) {
        guard let object = singleSelection, object.isEditableArtwork, !object.isLocked else { return }
        let line = validPathEdit?.path
        let result = object.smoothingArtwork(toleranceMM: toleranceMM, only: line)
        change { $0.update(object.id) { $0 = result } }
        if var edit = pathEdit { edit.point = nil; pathEdit = edit }
    }
}

struct EditorFocusedKey: FocusedValueKey {
    typealias Value = EditorState
}

extension FocusedValues {
    var editor: EditorState? {
        get { self[EditorFocusedKey.self] }
        set { self[EditorFocusedKey.self] = newValue }
    }
}
