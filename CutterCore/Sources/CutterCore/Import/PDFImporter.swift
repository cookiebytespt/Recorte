import CoreGraphics
import Foundation

/// Imports vector paths from PDF files and from Illustrator `.ai` files saved with
/// “Create PDF Compatible File” (the default in Illustrator).
///
/// Only one page/artboard is imported. Text and images are skipped and reported as warnings.
public struct PDFImporter: Sendable {
    public init() {}

    public func importDocument(data: Data, name: String, isIllustrator: Bool, options: ImportOptions) throws -> CutDocument {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else {
            throw isIllustrator ? ImportError.illustratorNotPDFCompatible : ImportError.unreadable
        }
        if pdf.isEncrypted, !pdf.isUnlocked { throw ImportError.encrypted }
        let pageCount = pdf.numberOfPages
        guard pageCount >= 1, let page = pdf.page(at: min(max(options.pageIndex, 0), pageCount - 1) + 1) else {
            throw ImportError.unreadable
        }

        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        let pageSizePt = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        let drawing = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSizePt), rotate: 0, preserveAspectRatio: true)

        let ptToMM = 25.4 / 72
        // PDF user space → page-space points (Y up) → millimetres with Y down.
        let toPage = AffineTransform(a: drawing.a, b: drawing.b, c: drawing.c, d: drawing.d, tx: drawing.tx, ty: drawing.ty)
        let toMM = AffineTransform(a: ptToMM, b: 0, c: 0, d: -ptToMM, tx: 0, ty: pageSizePt.height * ptToMM)
        let final = toMM.concatenating(toPage)

        let collector = PDFPathCollector(tolerance: options.tolerance / ptToMM, baseTransform: final)
        collector.scan(page: page)

        var warnings: [ImportWarning] = []
        if collector.textObjects > 0 { warnings.append(.textIgnored(count: collector.textObjects)) }
        if collector.imageObjects > 0 { warnings.append(.imagesIgnored(count: collector.imageObjects)) }
        if pageCount > 1 { warnings.append(.extraPagesIgnored(count: pageCount - 1)) }

        return CutDocument(
            name: name,
            paths: collector.paths,
            pageSize: Size(pageSizePt.width * ptToMM, pageSizePt.height * ptToMM),
            warnings: warnings
        )
    }
}

/// Walks a PDF content stream and collects painted paths. Clipping paths (`W n`) and
/// no-op paths (`n`) are discarded, which drops Illustrator's artboard clip rectangles.
final class PDFPathCollector {
    private(set) var paths: [Polyline] = []
    private(set) var textObjects = 0
    private(set) var imageObjects = 0

    private var ctm: AffineTransform
    private var stack: [AffineTransform] = []
    private var builder: PathBuilder
    private var pendingClip = false
    private var formDepth = 0
    private let table: CGPDFOperatorTableRef

    init(tolerance: Double, baseTransform: AffineTransform) {
        ctm = baseTransform
        builder = PathBuilder(tolerance: tolerance)
        table = CGPDFOperatorTableCreate()!
        Self.register(table)
    }

    deinit { CGPDFOperatorTableRelease(table) }

    func scan(page: CGPDFPage) {
        let cs = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(cs)
    }

    // MARK: Operator table

    private static func register(_ table: CGPDFOperatorTableRef) {
        func set(_ op: String, _ cb: @escaping CGPDFOperatorCallback) {
            CGPDFOperatorTableSetCallback(table, op, cb)
        }
        set("q") { _, info in PDFPathCollector.from(info).ops_q() }
        set("Q") { _, info in PDFPathCollector.from(info).ops_Q() }
        set("cm") { s, info in PDFPathCollector.from(info).ops_cm(s) }
        set("m") { s, info in PDFPathCollector.from(info).ops_m(s) }
        set("l") { s, info in PDFPathCollector.from(info).ops_l(s) }
        set("c") { s, info in PDFPathCollector.from(info).ops_c(s) }
        set("v") { s, info in PDFPathCollector.from(info).ops_v(s) }
        set("y") { s, info in PDFPathCollector.from(info).ops_y(s) }
        set("h") { _, info in PDFPathCollector.from(info).ops_h() }
        set("re") { s, info in PDFPathCollector.from(info).ops_re(s) }
        for op in ["S", "f", "F", "f*", "B", "B*"] {
            set(op) { _, info in PDFPathCollector.from(info).endPath(close: false, discard: false) }
        }
        for op in ["s", "b", "b*"] {
            set(op) { _, info in PDFPathCollector.from(info).endPath(close: true, discard: false) }
        }
        set("n") { _, info in PDFPathCollector.from(info).endPath(close: false, discard: true) }
        set("W") { _, info in PDFPathCollector.from(info).pendingClip = true }
        set("W*") { _, info in PDFPathCollector.from(info).pendingClip = true }
        set("BT") { _, info in PDFPathCollector.from(info).textObjects += 1 }
        set("BI") { _, info in PDFPathCollector.from(info).imageObjects += 1 }
        set("Do") { s, info in PDFPathCollector.from(info).ops_Do(s) }
    }

    private static func from(_ info: UnsafeMutableRawPointer?) -> PDFPathCollector {
        Unmanaged<PDFPathCollector>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func numbers(_ s: CGPDFScannerRef, _ n: Int) -> [Double]? {
        var out = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var v: CGPDFReal = 0
            guard CGPDFScannerPopNumber(s, &v) else { return nil }
            out[i] = Double(v)
        }
        return out
    }

    // MARK: Operators

    private func ops_q() { stack.append(ctm) }
    private func ops_Q() { ctm = stack.popLast() ?? ctm }

    private func ops_cm(_ s: CGPDFScannerRef) {
        guard let m = Self.numbers(s, 6) else { return }
        ctm = ctm.concatenating(AffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]))
    }

    private func ops_m(_ s: CGPDFScannerRef) {
        guard let v = Self.numbers(s, 2) else { return }
        builder.move(to: ctm.apply(Point(v[0], v[1])))
    }

    private func ops_l(_ s: CGPDFScannerRef) {
        guard let v = Self.numbers(s, 2) else { return }
        builder.line(to: ctm.apply(Point(v[0], v[1])))
    }

    private func ops_c(_ s: CGPDFScannerRef) {
        guard let v = Self.numbers(s, 6) else { return }
        builder.cubic(to: ctm.apply(Point(v[4], v[5])),
                      control1: ctm.apply(Point(v[0], v[1])),
                      control2: ctm.apply(Point(v[2], v[3])))
    }

    private func ops_v(_ s: CGPDFScannerRef) {
        guard let v = Self.numbers(s, 4) else { return }
        let c2 = ctm.apply(Point(v[0], v[1]))
        let p = ctm.apply(Point(v[2], v[3]))
        builder.cubic(to: p, control1: builder.currentPoint ?? c2, control2: c2)
    }

    private func ops_y(_ s: CGPDFScannerRef) {
        guard let v = Self.numbers(s, 4) else { return }
        let c1 = ctm.apply(Point(v[0], v[1]))
        let p = ctm.apply(Point(v[2], v[3]))
        builder.cubic(to: p, control1: c1, control2: p)
    }

    private func ops_h() { builder.close() }

    private func ops_re(_ s: CGPDFScannerRef) {
        guard let v = Self.numbers(s, 4) else { return }
        let x = v[0], y = v[1], w = v[2], h = v[3]
        builder.move(to: ctm.apply(Point(x, y)))
        builder.line(to: ctm.apply(Point(x + w, y)))
        builder.line(to: ctm.apply(Point(x + w, y + h)))
        builder.line(to: ctm.apply(Point(x, y + h)))
        builder.close()
    }

    private func endPath(close: Bool, discard: Bool) {
        if close { builder.close() }
        let polylines = builder.finish()
        let clip = pendingClip
        pendingClip = false
        if discard || clip { return }
        paths.append(contentsOf: polylines)
    }

    private func ops_Do(_ s: CGPDFScannerRef) {
        var namePtr: UnsafePointer<CChar>? = nil
        guard CGPDFScannerPopName(s, &namePtr), let namePtr else { return }
        let cs = CGPDFScannerGetContentStream(s)
        guard let object = CGPDFContentStreamGetResource(cs, "XObject", namePtr) else { return }
        var stream: CGPDFStreamRef? = nil
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
        guard let dict = CGPDFStreamGetDictionary(stream) else { return }

        var subtypePtr: UnsafePointer<CChar>? = nil
        if CGPDFDictionaryGetName(dict, "Subtype", &subtypePtr), let subtypePtr {
            let subtype = String(cString: subtypePtr)
            if subtype == "Image" { imageObjects += 1; return }
            if subtype != "Form" { return }
        }
        guard formDepth < 32 else { return }
        formDepth += 1
        defer { formDepth -= 1 }

        let savedCTM = ctm
        let savedStack = stack
        var matrix: CGPDFArrayRef? = nil
        if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
            var m = [Double](repeating: 0, count: 6)
            var ok = true
            for i in 0..<6 {
                var v: CGPDFReal = 0
                if CGPDFArrayGetNumber(matrix, i, &v) { m[i] = Double(v) } else { ok = false }
            }
            if ok { ctm = ctm.concatenating(AffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5])) }
        }

        let formCS = CGPDFContentStreamCreateWithStream(stream, dict, cs)
        let sub = CGPDFScannerCreate(formCS, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(sub)
        CGPDFScannerRelease(sub)
        CGPDFContentStreamRelease(formCS)

        ctm = savedCTM
        stack = savedStack
    }
}
