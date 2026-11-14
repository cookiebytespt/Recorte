import Foundation

public enum VectorFormat: String, CaseIterable, Sendable {
    case svg
    case pdf
    case illustrator
    case dxf

    public init?(filenameExtension ext: String) {
        switch ext.lowercased() {
        case "svg", "svgz": self = .svg
        case "pdf": self = .pdf
        case "ai": self = .illustrator
        case "dxf": self = .dxf
        default: return nil
        }
    }

    public static let supportedExtensions = ["svg", "pdf", "ai", "dxf"]
}

public struct ImportOptions: Sendable, Hashable {
    /// Maximum deviation when flattening curves, in millimetres.
    public var tolerance: Double
    /// DPI used for SVG files that give sizes without units (Illustrator exports are 72, the SVG spec says 96).
    public var unitlessDPI: Double
    /// Zero-based page (PDF) or artboard (AI) index to import.
    public var pageIndex: Int

    public init(tolerance: Double = 0.1, unitlessDPI: Double = 96, pageIndex: Int = 0) {
        self.tolerance = tolerance
        self.unitlessDPI = unitlessDPI
        self.pageIndex = pageIndex
    }
}

public enum ImportError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat(String)
    case unreadable
    case encrypted
    case illustratorNotPDFCompatible
    case noVectorPaths
    case parseFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return String(localized: "Files of type “\(ext)” are not supported. Use SVG, PDF, AI or DXF.", bundle: .module)
        case .unreadable:
            return String(localized: "The file could not be read.", bundle: .module)
        case .encrypted:
            return String(localized: "The file is password protected. Remove the password and try again.", bundle: .module)
        case .illustratorNotPDFCompatible:
            return String(localized: "This Illustrator file was saved without “Create PDF Compatible File”. In Illustrator, choose File ▸ Save As, and enable that option.", bundle: .module)
        case .noVectorPaths:
            return String(localized: "No cut lines were found in the file. Make sure the design contains vector paths and that text is converted to outlines.", bundle: .module)
        case .parseFailure(let detail):
            return String(localized: "The file could not be understood (\(detail)).", bundle: .module)
        }
    }
}

/// Entry point: picks the importer from the file name extension.
public enum DocumentLoader {
    public static func load(data: Data, filename: String, options: ImportOptions = ImportOptions()) throws -> CutDocument {
        let ext = (filename as NSString).pathExtension
        guard let format = VectorFormat(filenameExtension: ext) else {
            throw ImportError.unsupportedFormat(ext.isEmpty ? "?" : ext)
        }
        let name = (filename as NSString).deletingPathExtension
        let document: CutDocument
        switch format {
        case .svg:
            document = try SVGImporter().importDocument(data: data, name: name, options: options)
        case .pdf, .illustrator:
            document = try PDFImporter().importDocument(data: data, name: name, isIllustrator: format == .illustrator, options: options)
        case .dxf:
            document = try DXFImporter().importDocument(data: data, name: name, options: options)
        }
        let cleaned = document.cleaned()
        guard !cleaned.isEmpty else { throw ImportError.noVectorPaths }
        return cleaned
    }

    public static func load(url: URL, options: ImportOptions = ImportOptions()) throws -> CutDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable
        }
        return try load(data: data, filename: url.lastPathComponent, options: options)
    }
}
