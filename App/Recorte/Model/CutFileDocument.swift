import CutterCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let recorte = UTType(exportedAs: "pt.cookiebytes.recorte")
    /// Projects saved before the app was renamed from CookieCut.
    static let legacyCookieCut = UTType(importedAs: "pt.cookiebytes.cookiecut")
    static let illustrator = UTType(importedAs: "com.adobe.illustrator")
    static let dxf = UTType(importedAs: "pt.cookiebytes.dxf")
}

/// The project file. Opening an SVG/PDF/AI/DXF creates a project with the file as artwork.
struct DesignFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.recorte, .legacyCookieCut, .svg, .pdf, .illustrator, .dxf]
    static let writableContentTypes: [UTType] = [.recorte]

    var design: DesignDocument

    init(design: DesignDocument = DesignDocument(name: String(localized: "Untitled"))) {
        self.design = design
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = configuration.file.filename ?? "Untitled"
        let lower = name.lowercased()
        if configuration.contentType.conforms(to: .recorte) || configuration.contentType.conforms(to: .legacyCookieCut)
            || lower.hasSuffix(".recorte") || lower.hasSuffix(".cookiecut") {
            design = try DesignDocument.decode(data)
        } else {
            let imported = try DocumentLoader.load(data: data, filename: name, options: Preferences.importOptions())
            design = DesignDocument.fromImport(imported, sourceName: name)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try DesignDocument.encode(design))
    }
}
