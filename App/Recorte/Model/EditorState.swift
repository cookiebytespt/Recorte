import CutterCore
import AppKit
import Foundation
import Observation
import SwiftUI

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
    var selection: Set<UUID> = []
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var showCutSheet = false
    var showImporter = false
    var showImagePlacer = false
    var importError: String?

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

    func deleteSelection() {
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

    /// Adds a PDF/AI/PNG/JPEG as printed artwork for Print & Cut.
    func placeImage(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let format = (ext == "ai" || ext == "pdf") ? "pdf" : (ext == "jpg" || ext == "jpeg") ? "jpeg" : "png"
            guard let image = NSImage(data: data), image.size.width > 0 else {
                importError = String(localized: "The file could not be opened as an image.")
                return
            }
            // Natural size: PDF points → mm; bitmaps at 300 dpi.
            let scale = format == "pdf" ? 25.4 / 72 : 25.4 / 300
            var size = Size(image.size.width * scale, image.size.height * scale)
            let area = design.printAndCut.isEnabled ? design.printAndCut.layout.safeArea(for: design.canvasSize)
                : Rect(origin: .zero, size: design.canvasSize)
            let fit = min(1, area.width / size.width, area.height / size.height)
            size = Size(size.width * fit, size.height * fit)
            let object = DesignObject(
                name: uniqueName((url.lastPathComponent as NSString).deletingPathExtension),
                kind: .image(ImageSpec(sourceName: url.lastPathComponent, data: data, format: format)),
                frame: Rect(origin: area.origin, size: size))
            change { $0.objects.insert(object, at: 0) }   // behind the cut lines
            selection = [object.id]
        } catch {
            importError = error.localizedDescription
        }
    }

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

struct EditorFocusedKey: FocusedValueKey {
    typealias Value = EditorState
}

extension FocusedValues {
    var editor: EditorState? {
        get { self[EditorFocusedKey.self] }
        set { self[EditorFocusedKey.self] = newValue }
    }
}
