import AppKit
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers

/// Which dropped or opened files are documents of their own.
enum DocumentFiles {
    static let projectExtensions: Set<String> = ["recorte", "cookiecut"]
    static let artworkExtensions: Set<String> = ["svg", "pdf", "ai", "dxf"]

    static func isProject(_ url: URL) -> Bool { projectExtensions.contains(url.pathExtension.lowercased()) }

    /// Files that open in their own window rather than being placed on the canvas.
    static func opensAsDocument(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return projectExtensions.contains(ext) || artworkExtensions.contains(ext)
    }
}

/// How Recorte documents save:
///
/// - macOS autosave-in-place, Versions and drafts are off: classic Save / Save As…, and a prompt for
///   unsaved changes on close. SwiftUI's `DocumentGroup` turns them on and has no setting for it, so the class
///   getters of its (private, runtime-created) document class are replaced at run time.
/// - A window opened from an SVG, PDF, AI or DXF becomes a new, untitled project: it's detached from the source
///   file, so saving can never write a Recorte project over someone's PDF or AI file.
@MainActor
enum DocumentSavingPolicy {
    private static var patched = Set<ObjectIdentifier>()

    /// Call from `App.init`. SwiftUI creates its document classes while the app finishes launching.
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { patchDocumentClasses() }
        }
    }

    static func patchDocumentClasses() {
        let controller = NSDocumentController.shared
        for type in DesignFileDocument.readableContentTypes {
            if let cls = controller.documentClass(forType: type.identifier) { apply(to: cls) }
        }
        for document in controller.documents { apply(to: type(of: document)) }
    }

    static func apply(to cls: AnyClass) {
        guard patched.insert(ObjectIdentifier(cls)).inserted, let meta = object_getClass(cls) else { return }
        let alwaysNo: @convention(block) (AnyObject) -> Bool = { _ in false }
        let imp = imp_implementationWithBlock(alwaysNo)
        let selectors = [
            #selector(getter: NSDocument.autosavesInPlace),
            #selector(getter: NSDocument.preservesVersions),
            #selector(getter: NSDocument.autosavesDrafts),
        ]
        for selector in selectors {
            guard let method = class_getClassMethod(cls, selector) else { continue }
            class_replaceMethod(meta, selector, imp, method_getTypeEncoding(method))
        }
    }

    /// Called once the document's window exists.
    static func documentWindowAppeared(_ window: NSWindow) {
        guard let document = NSDocumentController.shared.document(for: window) else { return }
        apply(to: type(of: document))
        guard let url = document.fileURL, !DocumentFiles.isProject(url) else { return }
        // Imported artwork: make it an untitled Recorte project named after the source file.
        let name = url.deletingPathExtension().lastPathComponent
        document.fileURL = nil
        document.fileType = UTType.recorte.identifier
        document.displayName = name
        document.updateChangeCount(.changeDone)
    }
}

/// Reports the window a view is placed in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // The document is attached to the window controller right after the window is shown.
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}
