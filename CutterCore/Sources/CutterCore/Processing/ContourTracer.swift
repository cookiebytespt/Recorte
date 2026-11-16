import CoreGraphics
import Foundation
import ImageIO

/// One click of the colour pick (like Preview's Instant Alpha): the connected area around `point` whose colour is
/// within `tolerance` of the clicked colour becomes background (or, with `keep`, artwork again).
public struct ColorPick: Sendable, Hashable, Codable {
    /// Where the image was clicked, normalised to the image frame (0…1), so it holds at any size and resolution.
    public var point: Point
    /// Largest colour difference (CIE ΔE, 0…100) still taken.
    public var tolerance: Double
    /// Puts the area back as artwork instead of removing it (⌥-click).
    public var keep: Bool

    public init(point: Point, tolerance: Double, keep: Bool = false) {
        self.point = point
        self.tolerance = tolerance
        self.keep = keep
    }
}

/// Settings for Create Cut Contour (SignMaster's Build Contours / Build Boxes).
public struct ContourOptions: Sendable, Hashable, Codable {
    public enum Shape: String, Sendable, Hashable, Codable, CaseIterable {
        /// Follow the edge of the artwork.
        case follow
        /// One rectangle around each image.
        case rectangle
        /// One rounded rectangle around each image.
        case rounded
    }

    public enum Corners: String, Sendable, Hashable, Codable, CaseIterable {
        case round, sharp
    }

    public var shape: Shape
    /// Distance between the artwork edge and the cut line, in mm.
    public var distanceMM: Double
    public var corners: Corners
    /// Also cut transparent areas inside the artwork.
    public var cutHoles: Bool
    /// Treat (near-)white pixels as background, for images without transparency.
    /// Only white that reaches the edge of the image counts, so white letters and highlights
    /// inside the artwork stay part of it (unless `cutEnclosedWhite` is set).
    public var whiteIsBackground: Bool
    /// With `whiteIsBackground`: also treat white areas enclosed by the artwork (e.g. white letters)
    /// as background, so they become holes when `cutHoles` is on.
    public var cutEnclosedWhite: Bool
    /// Ignore opaque specks and small holes below this size, in mm.
    public var minimumSpeckMM: Double
    /// Tracing resolution in pixels per mm (10 ≈ 254 dpi).
    public var pixelsPerMM: Double
    /// Fit smooth Bézier curves to the traced outline (fewer nodes, smoother cuts; follow mode only).
    public var smoothCurves: Bool
    /// Colour picks applied in order on top of the transparency / white rules.
    public var picks: [ColorPick]

    public init(shape: Shape = .follow, distanceMM: Double = 2, corners: Corners = .round, cutHoles: Bool = true,
                whiteIsBackground: Bool = false, cutEnclosedWhite: Bool = false, minimumSpeckMM: Double = 1,
                pixelsPerMM: Double = 10, smoothCurves: Bool = true, picks: [ColorPick] = []) {
        self.shape = shape
        self.distanceMM = distanceMM
        self.corners = corners
        self.cutHoles = cutHoles
        self.whiteIsBackground = whiteIsBackground
        self.cutEnclosedWhite = cutEnclosedWhite
        self.minimumSpeckMM = minimumSpeckMM
        self.pixelsPerMM = pixelsPerMM
        self.smoothCurves = smoothCurves
        self.picks = picks
    }

    public static let `default` = ContourOptions()
}

/// A binary image: `true` where there is artwork. Row 0 is the top.
public struct BitMask: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public var bits: [Bool]

    public init(width: Int, height: Int, bits: [Bool]? = nil) {
        self.width = width
        self.height = height
        self.bits = bits ?? Array(repeating: false, count: width * height)
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Bool {
        get { x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] }
        set { bits[y * width + x] = newValue }
    }

    public var isEmpty: Bool { !bits.contains(true) }

    /// Pixel bounds of the set pixels, or `nil` when empty.
    public var occupiedBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where bits[row + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }
}

/// Traces cut lines around printed artwork.
///
/// Pipeline: rasterise → mask (alpha, optionally white = background) → drop specks / fill holes →
/// grow by the distance (round: Euclidean) → trace the outlines → simplify → (sharp: mitred offset).
public enum ContourTracer {
    // MARK: Entry points

    /// Cut lines for a placed image object, in document space (mm). Empty for non-image objects.
    public static func contours(for object: DesignObject, options: ContourOptions) -> [Polyline] {
        guard case .image(let spec) = object.kind else { return [] }
        let size = object.frame.size
        guard size.width > 0, size.height > 0 else { return [] }
        let local: [Polyline]
        switch options.shape {
        case .follow:
            local = traceImage(spec, size: size, options: options)
        case .rectangle, .rounded:
            guard let box = artworkBox(spec, size: size, options: options) else { return [] }
            local = [boxOutline(box, options: options)]
        }
        return local.transformed(object.localToDocument)
    }

    /// Largest distance between the traced outline and the fitted curves, in mm.
    public static let smoothingToleranceMM = 0.1

    /// Cut lines as Bézier curves in document space: smooth curves fitted to the trace when
    /// `smoothCurves` is set (follow mode), otherwise the traced lines as straight segments.
    public static func contourCurves(for object: DesignObject, options: ContourOptions) -> [BezierPath] {
        let lines = contours(for: object, options: options)
        guard options.smoothCurves, options.shape == .follow else { return lines.map(BezierPath.init) }
        return lines.map { line in
            // Sharp corners: also keep gentler corners (e.g. obtuse corners of letters) as corners.
            let fitted = BezierPath.fitted(to: line, tolerance: smoothingToleranceMM,
                                           cornerAngle: options.corners == .sharp ? 35 : 60)
            return fitted.isUsable ? fitted : BezierPath(line)
        }
    }

    /// Bounding box of the visible artwork in frame-local mm (after removing specks).
    public static func artworkBox(_ spec: ImageSpec, size: Size, options: ContourOptions) -> Rect? {
        let ppm = effectiveResolution(size: size, options: options, pad: 0)
        guard var mask = rasterMask(spec, size: size, pixelsPerMM: ppm, pad: 0, whiteIsBackground: options.whiteIsBackground,
                                        cutEnclosedWhite: options.cutEnclosedWhite, picks: options.picks) else { return nil }
        removeSpecks(&mask, minimumPixels: options.minimumSpeckMM * ppm, fillHoles: false)
        guard let b = mask.occupiedBounds else { return nil }
        return Rect(minX: Double(b.minX) / ppm, minY: Double(b.minY) / ppm,
                    maxX: Double(b.maxX + 1) / ppm, maxY: Double(b.maxY + 1) / ppm)
    }

    /// Rectangle (or rounded rectangle) around `box`, grown by the distance. Frame-local mm.
    public static func boxOutline(_ box: Rect, options: ContourOptions) -> Polyline {
        let r = box.insetBy(-max(options.distanceMM, 0))
        let radius = options.shape == .rounded ? min(3 + max(options.distanceMM, 0), min(r.width, r.height) / 2) : 0
        let object = DesignObject(name: "", kind: .rectangle(cornerRadius: radius), frame: r)
        return object.outlines(tolerance: 0.05).first ?? Polyline(points: [], isClosed: true)
    }

    /// Follow-the-artwork contours for an image, frame-local mm.
    public static func traceImage(_ spec: ImageSpec, size: Size, options: ContourOptions) -> [Polyline] {
        let distance = max(options.distanceMM, 0)
        let padMM = distance + 1
        let ppm = effectiveResolution(size: size, options: options, pad: padMM)
        let pad = Int((padMM * ppm).rounded(.up))
        guard let mask = rasterMask(spec, size: size, pixelsPerMM: ppm, pad: pad, whiteIsBackground: options.whiteIsBackground,
                                        cutEnclosedWhite: options.cutEnclosedWhite, picks: options.picks) else { return [] }
        let loops = trace(mask: mask, pixelsPerMM: ppm, options: options)
        let offset = Point(Double(pad) / ppm, Double(pad) / ppm)
        return loops.transformed(.translation(-offset.x, -offset.y))
    }

    /// Core of the follow mode: works on a ready mask; output in mm relative to the mask's top-left pixel corner.
    public static func trace(mask input: BitMask, pixelsPerMM ppm: Double, options: ContourOptions) -> [Polyline] {
        var mask = input
        let speckPx = max(options.minimumSpeckMM, 0) * ppm
        removeSpecks(&mask, minimumPixels: speckPx, fillHoles: !options.cutHoles)
        guard !mask.isEmpty else { return [] }
        let distancePx = max(options.distanceMM, 0) * ppm

        let simplifyPx = 0.6
        var loops: [Polyline]
        if options.corners == .round || distancePx < 0.5 {
            if distancePx >= 0.5 { mask = dilateEuclidean(mask, radius: distancePx) }
            loops = traceLoops(mask).map { simplify($0, tolerance: simplifyPx) }
        } else {
            // Sharp: grow the artwork by a strip along every edge of its (lightly simplified) outline plus a
            // mitred wedge at every corner, painted onto the mask. The union is traced again, so noisy edges
            // and inside corners can't produce spikes, crossings or loose pieces.
            let outline = traceLoops(mask).map { simplify($0, tolerance: max(1.0, ppm * 0.15)) }
            mask = mitredGrow(mask, outlines: outline, distance: distancePx)
            loops = traceLoops(mask).map { simplify($0, tolerance: simplifyPx) }
        }
        let minSize = max(speckPx, 1.5)
        return loops
            .filter { $0.points.count >= 3 && max($0.bounds.width, $0.bounds.height) >= minSize }
            .map { $0.transformed(.scaling(1 / ppm, 1 / ppm)) }
    }

    // MARK: Rasterising

    static func effectiveResolution(size: Size, options: ContourOptions, pad: Double) -> Double {
        let maxPixels = 3000.0
        let longest = max(size.width, size.height) + pad * 2
        return max(2, min(options.pixelsPerMM, maxPixels / max(longest, 1)))
    }

    /// Draws the image into its frame (stretched like the canvas; PDFs keep their aspect ratio like the print)
    /// and returns the artwork mask with `pad` empty pixels around it.
    public static func rasterMask(_ spec: ImageSpec, size: Size, pixelsPerMM ppm: Double, pad: Int,
                                  whiteIsBackground: Bool, cutEnclosedWhite: Bool = false,
                                  picks: [ColorPick] = []) -> BitMask? {
        guard let r = rasterPixels(spec, size: size, pixelsPerMM: ppm, pad: pad) else { return nil }
        let (pixels, width, height, w, h) = (r.pixels, r.width, r.height, r.w, r.h)
        var opaque = BitMask(width: width, height: height)
        var white = BitMask(width: width, height: height)
        for i in 0..<(width * height) {
            let a = Int(pixels[i * 4 + 3])
            guard a >= 128 else { continue }
            opaque.bits[i] = true
            if whiteIsBackground {
                // Un-premultiply and compare against near-white.
                let r = Int(pixels[i * 4]) * 255 / a, g = Int(pixels[i * 4 + 1]) * 255 / a, b = Int(pixels[i * 4 + 2]) * 255 / a
                if r >= 240 && g >= 240 && b >= 240 { white.bits[i] = true }
            }
        }
        var mask = whiteIsBackground ? artworkMask(opaque: opaque, white: white, cutEnclosedWhite: cutEnclosedWhite) : opaque
        if !picks.isEmpty {
            let lab = labPixels(pixels, count: width * height)
            applyPicks(picks, to: &mask, lab: lab, width: width, image: (x: pad, y: pad, width: w, height: h))
        }
        return mask
    }

    /// The image drawn into its frame at `pixelsPerMM` with `pad` empty pixels around it: premultiplied RGBA, row 0 on top.
    static func rasterPixels(_ spec: ImageSpec, size: Size, pixelsPerMM ppm: Double, pad: Int)
        -> (pixels: [UInt8], width: Int, height: Int, w: Int, h: Int)? {
        let w = max(1, Int((size.width * ppm).rounded()))
        let h = max(1, Int((size.height * ppm).rounded()))
        let width = w + pad * 2, height = h + pad * 2
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            // The padding is symmetric, so the Y-up target rect is the same as a Y-down one.
            let target = CGRect(x: pad, y: pad, width: w, height: h)
            if spec.format == "pdf" {
                guard let provider = CGDataProvider(data: spec.data as CFData), let pdf = CGPDFDocument(provider),
                      let page = pdf.page(at: 1) else { return false }
                ctx.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(page)
            } else {
                guard let source = CGImageSourceCreateWithData(spec.data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
                ctx.draw(image, in: target)
            }
            return true
        }
        guard drawn else { return nil }
        return (pixels, width, height, w, h)
    }

    /// CIE L*a*b* of every pixel (3 floats each); NaN lightness marks transparent pixels.
    static func labPixels(_ pixels: [UInt8], count: Int) -> [Float] {
        var lab = [Float](repeating: .nan, count: count * 3)
        for i in 0..<count {
            let a = Int(pixels[i * 4 + 3])
            guard a >= 128 else { continue }
            let r = min(Int(pixels[i * 4]) * 255 / a, 255), g = min(Int(pixels[i * 4 + 1]) * 255 / a, 255), b = min(Int(pixels[i * 4 + 2]) * 255 / a, 255)
            let c = ColorLab.lab(r: r, g: g, b: b)
            lab[i * 3] = Float(c.0); lab[i * 3 + 1] = Float(c.1); lab[i * 3 + 2] = Float(c.2)
        }
        return lab
    }

    /// The artwork mask of an image object at `pixelsPerMM` (no padding, no speck removal): what the
    /// options count as artwork, pixel by pixel over the image frame. Used to show the picked areas.
    public static func artworkMask(for object: DesignObject, options: ContourOptions, pixelsPerMM: Double) -> BitMask? {
        guard case .image(let spec) = object.kind, object.frame.width > 0, object.frame.height > 0 else { return nil }
        let ppm = effectiveResolution(size: object.frame.size, options: ContourOptions(pixelsPerMM: pixelsPerMM), pad: 0)
        return rasterMask(spec, size: object.frame.size, pixelsPerMM: ppm, pad: 0, whiteIsBackground: options.whiteIsBackground,
                          cutEnclosedWhite: options.cutEnclosedWhite, picks: options.picks)
    }

    /// Applies colour picks in order: each removes (or with `keep`, restores) the pixels `pickRegion` finds.
    static func applyPicks(_ picks: [ColorPick], to mask: inout BitMask, lab: [Float], width: Int,
                           image: (x: Int, y: Int, width: Int, height: Int)) {
        var region = [Bool](repeating: false, count: mask.width * mask.height)
        for pick in picks {
            pickRegion(pick, lab: lab, width: width, height: mask.height, image: image, into: &region)
            for i in region.indices where region[i] { mask.bits[i] = pick.keep }
        }
    }

    /// The pixels one pick takes: a 4-connected flood fill from the clicked pixel over opaque pixels whose colour
    /// is within the pick's tolerance (CIE ΔE76) of the clicked colour. `region` is overwritten.
    static func pickRegion(_ pick: ColorPick, lab: [Float], width: Int, height: Int,
                           image: (x: Int, y: Int, width: Int, height: Int), into region: inout [Bool]) {
        for i in region.indices { region[i] = false }
        let sx = image.x + min(max(Int(pick.point.x * Double(image.width)), 0), image.width - 1)
        let sy = image.y + min(max(Int(pick.point.y * Double(image.height)), 0), image.height - 1)
        let seed = sy * width + sx
        guard !lab[seed * 3].isNaN else { return }
        let tL = lab[seed * 3], tA = lab[seed * 3 + 1], tB = lab[seed * 3 + 2]
        let tol2 = Float(pick.tolerance * pick.tolerance)
        var stack = [seed]
        region[seed] = true
        let minX = image.x, minY = image.y, maxX = image.x + image.width - 1, maxY = image.y + image.height - 1
        lab.withUnsafeBufferPointer { lab in
            func visit(_ j: Int) {
                guard !region[j] else { return }
                let l = lab[j * 3]
                guard !l.isNaN else { return }
                let dl = l - tL, da = lab[j * 3 + 1] - tA, db = lab[j * 3 + 2] - tB
                if dl * dl + da * da + db * db <= tol2 {
                    region[j] = true
                    stack.append(j)
                }
            }
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                if x > minX { visit(i - 1) }
                if x < maxX { visit(i + 1) }
                if y > minY { visit(i - width) }
                if y < maxY { visit(i + width) }
            }
        }
    }

    /// Combines the opacity and white masks. Transparent pixels are always background. White pixels are
    /// background when `cutEnclosedWhite` is set, otherwise only when they connect to the image's edge
    /// (through white or transparent pixels), so white shapes inside the artwork stay artwork.
    public static func artworkMask(opaque: BitMask, white: BitMask, cutEnclosedWhite: Bool) -> BitMask {
        let w = opaque.width, h = opaque.height
        var mask = BitMask(width: w, height: h)
        if cutEnclosedWhite {
            for i in 0..<(w * h) { mask.bits[i] = opaque.bits[i] && !white.bits[i] }
            return mask
        }
        // Flood fill the background from the border through transparent and white pixels.
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if !outside[i] && (!opaque.bits[i] || white.bits[i]) { outside[i] = true; stack.append(i) }
        }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        for i in 0..<(w * h) {
            // Enclosed white counts as artwork; transparent pixels never do.
            mask.bits[i] = opaque.bits[i] && !(white.bits[i] && outside[i])
        }
        return mask
    }

    // MARK: Mask clean-up

    /// Removes artwork specks whose size is below `minimumPixels`; fills holes below that size
    /// (or every enclosed hole when `fillHoles` is set).
    public static func removeSpecks(_ mask: inout BitMask, minimumPixels: Double, fillHoles: Bool) {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0 else { return }
        var label = [Int32](repeating: -1, count: w * h)
        var stack: [Int] = []
        var next: Int32 = 0
        for start in 0..<(w * h) where label[start] < 0 {
            let value = mask.bits[start]
            var minX = w, minY = h, maxX = -1, maxY = -1
            var touchesBorder = false
            var members: [Int] = []
            func visit(_ j: Int) {
                if label[j] < 0 && mask.bits[j] == value { label[j] = next; stack.append(j) }
            }
            label[start] = next
            stack.append(start)
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                if x > 0 { visit(i - 1) }
                if x < w - 1 { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y < h - 1 { visit(i + w) }
            }
            next += 1
            let size = Double(max(maxX - minX + 1, maxY - minY + 1))
            if value {
                if size < minimumPixels { for i in members { mask.bits[i] = false } }
            } else if !touchesBorder && (fillHoles || size < minimumPixels) {
                for i in members { mask.bits[i] = true }
            }
        }
    }

    /// Grows the artwork by `radius` pixels with round corners (exact Euclidean distance transform).
    public static func dilateEuclidean(_ mask: BitMask, radius: Double) -> BitMask {
        let w = mask.width, h = mask.height
        let inf = 1e20
        var f = [Double](repeating: inf, count: w * h)
        for i in 0..<(w * h) where mask.bits[i] { f[i] = 0 }
        // Columns, then rows (Felzenszwalb & Huttenlocher).
        var column = [Double](repeating: 0, count: h)
        for x in 0..<w {
            for y in 0..<h { column[y] = f[y * w + x] }
            let d = distance1D(column)
            for y in 0..<h { f[y * w + x] = d[y] }
        }
        var row = [Double](repeating: 0, count: w)
        let r2 = radius * radius
        var out = BitMask(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w { row[x] = f[y * w + x] }
            let d = distance1D(row)
            for x in 0..<w where d[x] <= r2 { out.bits[y * w + x] = true }
        }
        return out
    }

    /// 1-D squared distance transform of a sampled function.
    static func distance1D(_ f: [Double]) -> [Double] {
        let n = f.count
        guard n > 0 else { return [] }
        var d = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        let inf = Double.infinity
        z[0] = -inf; z[1] = inf
        for q in 1..<max(n, 1) {
            var s: Double
            repeat {
                let p = v[k]
                s = ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
                if s <= z[k] { k -= 1 } else { break }
            } while k >= 0
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = inf
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let p = v[k]
            d[q] = Double((q - p) * (q - p)) + f[p]
        }
        return d
    }

    // MARK: Tracing

    private struct Vertex: Hashable { var x: Int32; var y: Int32 }

    /// Closed outlines of the mask in pixel units (y down). Every loop keeps the artwork on the same side,
    /// so holes and outer edges are both oriented consistently. Vertices sit on pixel-edge midpoints
    /// (marching squares), which gives 45° steps instead of staircases.
    /// With `midpoints: false` the loops follow the pixel edges exactly (staircases), which keeps real corners.
    public static func traceLoops(_ mask: BitMask, midpoints: Bool = true) -> [Polyline] {
        let w = mask.width, h = mask.height
        // Directed boundary edges between an artwork pixel and an empty one.
        var outgoing: [Vertex: [Vertex]] = [:]
        func add(_ a: Vertex, _ b: Vertex) { outgoing[a, default: []].append(b) }
        for y in 0..<h {
            for x in 0..<w where mask[x, y] {
                let x0 = Int32(x), y0 = Int32(y), x1 = Int32(x + 1), y1 = Int32(y + 1)
                if !mask[x, y - 1] { add(Vertex(x: x1, y: y0), Vertex(x: x0, y: y0)) }   // top, leftwards
                if !mask[x - 1, y] { add(Vertex(x: x0, y: y0), Vertex(x: x0, y: y1)) }   // left, downwards
                if !mask[x, y + 1] { add(Vertex(x: x0, y: y1), Vertex(x: x1, y: y1)) }   // bottom, rightwards
                if !mask[x + 1, y] { add(Vertex(x: x1, y: y1), Vertex(x: x1, y: y0)) }   // right, upwards
            }
        }
        var loops: [Polyline] = []
        while let entry = outgoing.first, let first = entry.value.first {
            let start = entry.key
            var chain: [Vertex] = [start]
            var current = start
            var nextVertex = first
            remove(&outgoing, current, nextVertex)
            var guardCount = 0
            while nextVertex != start, guardCount < 10_000_000 {
                guardCount += 1
                let incoming = (nextVertex.x - current.x, nextVertex.y - current.y)
                current = nextVertex
                chain.append(current)
                guard let options = outgoing[current], !options.isEmpty else { break }
                // At a saddle (two artwork pixels touching at a corner) keep them apart: take the sharpest turn
                // towards the artwork side.
                var pick = options[0]
                if options.count > 1 {
                    pick = options.max { a, b in
                        turn(incoming, (a.x - current.x, a.y - current.y)) < turn(incoming, (b.x - current.x, b.y - current.y))
                    } ?? options[0]
                }
                remove(&outgoing, current, pick)
                nextVertex = pick
            }
            guard chain.count >= 4 else { continue }
            var pts: [Point] = []
            pts.reserveCapacity(chain.count)
            for i in 0..<chain.count {
                let a = chain[i]
                if midpoints {
                    // Midpoints of consecutive edges.
                    let b = chain[(i + 1) % chain.count]
                    pts.append(Point(Double(a.x + b.x) / 2, Double(a.y + b.y) / 2))
                } else {
                    pts.append(Point(Double(a.x), Double(a.y)))
                }
            }
            loops.append(Polyline(points: removeCollinear(pts), isClosed: true))
        }
        return loops
    }

    private static func remove(_ map: inout [Vertex: [Vertex]], _ a: Vertex, _ b: Vertex) {
        guard var list = map[a], let i = list.firstIndex(of: b) else { return }
        list.remove(at: i)
        map[a] = list.isEmpty ? nil : list
    }

    /// Positive for a turn towards the artwork side (left of the walking direction in y-down coordinates).
    private static func turn(_ a: (Int32, Int32), _ b: (Int32, Int32)) -> Int32 {
        // Artwork is on the side of the normal (-dy, dx) reversed; in y-down screen space that is a
        // counter-clockwise turn, i.e. negative cross product.
        -(a.0 * b.1 - a.1 * b.0)
    }

    private static func removeCollinear(_ pts: [Point]) -> [Point] {
        guard pts.count > 3 else { return pts }
        var out: [Point] = []
        let n = pts.count
        for i in 0..<n {
            let p = pts[(i + n - 1) % n], c = pts[i], q = pts[(i + 1) % n]
            if abs((c - p).cross(q - c)) > 1e-9 { out.append(c) }
        }
        return out.count >= 3 ? out : pts
    }

    // MARK: Simplify and offset

    /// Douglas–Peucker for a closed loop.
    public static func simplify(_ loop: Polyline, tolerance: Double) -> Polyline {
        let pts = loop.points
        guard pts.count > 4 else { return loop }
        // Split at the point farthest from the first one so both halves are open chains.
        var far = 0, best = -1.0
        for (i, p) in pts.enumerated() {
            let d = p.distance(to: pts[0])
            if d > best { best = d; far = i }
        }
        let a = Array(pts[0...far]), b = Array(pts[far...]) + [pts[0]]
        let sa = douglasPeucker(a, tolerance), sb = douglasPeucker(b, tolerance)
        let merged = Array(sa.dropLast()) + Array(sb.dropLast())
        return merged.count >= 3 ? Polyline(points: merged, isClosed: true) : loop
    }

    static func douglasPeucker(_ pts: [Point], _ tolerance: Double) -> [Point] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var index = -1, maxD = 0.0
            for i in (s + 1)..<e {
                let d = DesignObject.distance(from: pts[i], toSegment: pts[s], pts[e])
                if d > maxD { maxD = d; index = i }
            }
            if maxD > tolerance, index > 0 {
                keep[index] = true
                stack.append((s, index)); stack.append((index, e))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// The artwork grown by `distance` pixels with mitred (sharp) corners: the mask plus, for every outline edge,
    /// the strip swept by moving it outwards, and for every vertex the wedge up to the mitre point (bevelled past
    /// 2× the distance). Outline vertices are in pixel units (y down), oriented like `traceLoops`.
    static func mitredGrow(_ mask: BitMask, outlines: [Polyline], distance d: Double) -> BitMask {
        let w = mask.width, h = mask.height
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where mask.bits[i] { gray[i] = 255 }
        gray.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldAntialias(false)
            ctx.setFillColor(gray: 1, alpha: 1)
            func cg(_ p: Point) -> CGPoint { CGPoint(x: p.x, y: Double(h) - p.y) }
            func fill(_ pts: [Point]) {
                ctx.beginPath()
                ctx.addLines(between: pts.map(cg))
                ctx.closePath()
                ctx.fillPath()
            }
            for loop in outlines {
                let pts = loop.points
                let n = pts.count
                guard n >= 2 else { continue }
                for i in 0..<n {
                    let p = pts[(i + n - 1) % n], c = pts[i], q = pts[(i + 1) % n]
                    let d2 = (q - c).normalized
                    guard d2.length > 0.5 else { continue }
                    let n2 = Point(-d2.y, d2.x)   // away from the artwork
                    // Strip along the edge c → q.
                    fill([c, q, q + n2 * d, c + n2 * d])
                    // Wedge at c between the previous edge's offset and this one's.
                    let d1 = (c - p).normalized
                    guard d1.length > 0.5 else { continue }
                    let n1 = Point(-d1.y, d1.x)
                    let sum = n1 + n2
                    if sum.length < 1e-9 { continue }
                    let m = sum.normalized
                    let cosHalf = max(m.dot(n1), 1e-6)
                    if 1 / cosHalf > 2 {
                        fill([c, c + n1 * d, c + m * d, c + n2 * d])   // bevel
                    } else {
                        fill([c, c + n1 * d, c + m * (d / cosHalf), c + n2 * d])
                    }
                }
            }
        }
        var out = BitMask(width: w, height: h)
        for i in 0..<(w * h) { out.bits[i] = gray[i] >= 128 }
        return out
    }

    /// Moves every edge `distance` away from the artwork, joining edges with mitres (bevelled past 2× distance).
    public static func offsetMitred(_ loop: Polyline, distance: Double) -> Polyline {
        let pts = loop.points
        let n = pts.count
        guard n >= 3, distance > 0 else { return loop }
        var out: [Point] = []
        for i in 0..<n {
            let p = pts[(i + n - 1) % n], c = pts[i], q = pts[(i + 1) % n]
            let d1 = (c - p).normalized, d2 = (q - c).normalized
            // Outward normal (away from the artwork) for this edge orientation.
            let n1 = Point(-d1.y, d1.x), n2 = Point(-d2.y, d2.x)
            let sum = n1 + n2
            if sum.length < 1e-9 { out.append(c + n1 * distance); continue }
            let m = sum.normalized
            let cosHalf = max(m.dot(n1), 1e-6)
            if 1 / cosHalf > 2 {
                out.append(c + n1 * distance)
                out.append(c + n2 * distance)
            } else {
                out.append(c + m * (distance / cosHalf))
            }
        }
        return Polyline(points: out, isClosed: true)
    }
}

// MARK: - Offsetting lines

extension ContourTracer {
    /// Grows (positive `distanceMM`) or shrinks (negative) the area enclosed by closed lines, with round corners,
    /// and returns the new outlines as smooth curves. Lines inside other lines are holes (even-odd), and
    /// overlapping results merge. Works on a raster of `pixelsPerMM` (lowered for large shapes), so the result
    /// is accurate to about one pixel. Open lines are ignored.
    public static func offset(_ curves: [BezierPath], distanceMM: Double, pixelsPerMM: Double = 10) -> [BezierPath] {
        let closed = curves.filter(\.isClosed).map { $0.flattened(tolerance: 0.02) }.filter { $0.points.count >= 3 }
        let b = closed.bounds
        guard !b.isNull, b.width > 0 || b.height > 0 else { return [] }
        let padMM = Swift.abs(distanceMM) + 1
        let longest = max(b.width, b.height) + padMM * 2
        let ppm = max(2, min(pixelsPerMM, 3000 / max(longest, 1)))
        let width = Int(((b.width + padMM * 2) * ppm).rounded(.up))
        let height = Int(((b.height + padMM * 2) * ppm).rounded(.up))
        guard width > 0, height > 0 else { return [] }

        // Rasterise the even-odd fill: memory row 0 is the top, local y grows downwards.
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setShouldAntialias(false)
            ctx.setFillColor(gray: 1, alpha: 1)
            let path = CGMutablePath()
            for line in closed {
                let pts = line.points.map { p in
                    CGPoint(x: (p.x - b.minX + padMM) * ppm, y: Double(height) - (p.y - b.minY + padMM) * ppm)
                }
                path.addLines(between: pts)
                path.closeSubpath()
            }
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        guard drawn else { return [] }
        var mask = BitMask(width: width, height: height)
        for i in 0..<(width * height) { mask.bits[i] = pixels[i] >= 128 }

        let radius = Swift.abs(distanceMM) * ppm
        if distanceMM > 0 {
            mask = dilateEuclidean(mask, radius: radius)
        } else if distanceMM < 0 {
            var outside = mask
            for i in outside.bits.indices { outside.bits[i].toggle() }
            outside = dilateEuclidean(outside, radius: radius)
            for i in mask.bits.indices { mask.bits[i] = !outside.bits[i] }
        }
        let toLocal = AffineTransform.translation(b.minX - padMM, b.minY - padMM).concatenating(.scaling(1 / ppm, 1 / ppm))
        let tolerance = max(smoothingToleranceMM, 1 / ppm)
        return traceLoops(mask)
            .map { simplify($0, tolerance: 0.6) }
            .filter { $0.points.count >= 3 && max($0.bounds.width, $0.bounds.height) >= 2 }
            .map { loop in
                let line = loop.transformed(toLocal)
                let fitted = BezierPath.fitted(to: line, tolerance: tolerance)
                return fitted.isUsable ? fitted : BezierPath(line)
            }
    }
}

/// sRGB (0…255) → CIE L*a*b* (D65), for colour differences that match what people see.
enum ColorLab {
    private static let linear: [Double] = (0..<256).map { v in
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func lab(r: Int, g: Int, b: Int) -> (Double, Double, Double) {
        let rl = linear[r], gl = linear[g], bl = linear[b]
        let x = (0.4124 * rl + 0.3576 * gl + 0.1805 * bl) / 0.95047
        let y = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
        let z = (0.0193 * rl + 0.1192 * gl + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}

/// An image prepared for interactive colour picking: its colours are decoded once, so each drag
/// step only runs the flood fill. Frame-sized, no padding; pixel (0, 0) is the top-left of the frame.
public struct PickRaster: Sendable {
    public let width: Int
    public let height: Int
    /// What counts as artwork before any pick (transparency rule).
    public let base: BitMask
    let lab: [Float]

    public init?(object: DesignObject, pixelsPerMM: Double) {
        guard case .image(let spec) = object.kind, object.frame.width > 0, object.frame.height > 0 else { return nil }
        let ppm = ContourTracer.effectiveResolution(size: object.frame.size, options: ContourOptions(pixelsPerMM: pixelsPerMM), pad: 0)
        guard let r = ContourTracer.rasterPixels(spec, size: object.frame.size, pixelsPerMM: ppm, pad: 0) else { return nil }
        width = r.width
        height = r.height
        lab = ContourTracer.labPixels(r.pixels, count: width * height)
        var mask = BitMask(width: width, height: height)
        for i in 0..<(width * height) { mask.bits[i] = !lab[i * 3].isNaN }
        base = mask
    }

    private var image: (x: Int, y: Int, width: Int, height: Int) { (0, 0, width, height) }

    /// Artwork after applying `picks` (true = artwork).
    public func mask(picks: [ColorPick]) -> BitMask {
        var m = base
        ContourTracer.applyPicks(picks, to: &m, lab: lab, width: width, image: image)
        return m
    }

    /// The pixels a single pick takes (true = taken), to highlight the pick being dragged.
    public func region(_ pick: ColorPick) -> BitMask {
        var region = [Bool](repeating: false, count: width * height)
        ContourTracer.pickRegion(pick, lab: lab, width: width, height: height, image: image, into: &region)
        return BitMask(width: width, height: height, bits: region)
    }
}
