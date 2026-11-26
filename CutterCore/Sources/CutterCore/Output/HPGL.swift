import Foundation

public struct HPGLOptions: Sendable, Hashable, Codable {
    /// Plotter resolution. Liyu cutters use 40 steps/mm (1016 per inch).
    public var stepsPerMM: Double
    /// Cutting speed in **mm/s**, sent as `VS<mm/s>;` (SignMaster's units). `nil` leaves the machine's panel setting.
    public var speed: Int?
    /// Cutting pressure in **grams**, sent as `HS<g>;` (not `FS`). `nil` leaves the machine's panel setting.
    public var force: Int?
    /// Liyu convention (verified from a SignMaster capture): plotter X runs along the media feed,
    /// plotter Y across the media. Document X (across) therefore becomes plotter Y and document Y
    /// (down the design = into the machine) becomes plotter X.
    public var swapAxes: Bool
    /// Mirror the design across the media (needed for heat-transfer vinyl).
    public var mirrorX: Bool
    /// Flip the feed direction.
    public var flipY: Bool
    /// Offset from the plotter origin, in document millimetres (x across, y along the feed).
    public var originOffset: Point
    public var pointsPerCommand: Int
    /// Written after every command. SignMaster writes jobs as one line, so the Liyu default is empty.
    public var lineTerminator: String
    /// Plain cuts: finish with `PU<job length>,0;PG;` so the machine feeds the vinyl past the job
    /// (SignMaster's *Advance After Plot*, on by default). Off: return to the origin with `PU0,0;SP0;`.
    public var advanceAfterCut: Bool
    /// How far to advance, in mm along the feed from the origin. `nil`: the far edge of the paths sent.
    /// The planner sets it to the design's far edge, so blade-offset loops don't count (as in SignMaster).
    public var advanceFeedMM: Double?
    /// Written once at the very end of a plain job (SignMaster ends its PLT files with CRLF).
    public var jobTerminator: String

    public init(stepsPerMM: Double = 40, speed: Int? = nil, force: Int? = nil, swapAxes: Bool = true,
                mirrorX: Bool = false, flipY: Bool = false, originOffset: Point = .zero,
                pointsPerCommand: Int = 1, lineTerminator: String = "", advanceAfterCut: Bool = true,
                advanceFeedMM: Double? = nil, jobTerminator: String = "\r\n") {
        self.stepsPerMM = stepsPerMM
        self.speed = speed
        self.force = force
        self.swapAxes = swapAxes
        self.mirrorX = mirrorX
        self.flipY = flipY
        self.originOffset = originOffset
        self.pointsPerCommand = max(1, pointsPerCommand)
        self.lineTerminator = lineTerminator
        self.advanceAfterCut = advanceAfterCut
        self.advanceFeedMM = advanceFeedMM
        self.jobTerminator = jobTerminator
    }
}

/// Generates HPGL for Liyu and other HPGL vinyl cutters, in the byte format SignMaster sends to the Liyu
/// (`docs/debugging/captures/signmaster/plt/`):
///
///     IN;SP1;[SP1;VS<mm/s>;HS<g>;]PU…;PD…;PD…; … PU<job length>,0;PG;\r\n
public struct HPGLGenerator: Sendable {
    public init() {}

    public func generate(_ paths: [Polyline], options: HPGLOptions) -> String {
        let bounds = paths.bounds
        var out = ""
        out.reserveCapacity(paths.reduce(0) { $0 + $1.points.count * 12 } + 64)
        out += header(options: options)
        out += body(paths, options: options) { p in
            Self.plotterCoordinate(p, bounds: bounds, options: options)
        }
        out += trailer(bounds: bounds, options: options)
        out += options.jobTerminator
        return out
    }

    /// A small square for checking blade depth, force and speed.
    public func testSquare(sizeMM: Double = 20, options: HPGLOptions) -> String {
        let square = Polyline(points: [Point(0, 0), Point(sizeMM, 0), Point(sizeMM, sizeMM), Point(0, sizeMM)], isClosed: true)
        let circle = Polyline(points: (0..<36).map { i in
            let a = Double(i) / 36 * 2 * .pi
            return Point(sizeMM / 2 + sizeMM * 0.3 * cos(a), sizeMM / 2 + sizeMM * 0.3 * sin(a))
        }, isClosed: true)
        return generate([circle, square], options: options)
    }

    /// `SP1;VS<mm/s>;HS<g>;` — SignMaster always sends the pen select again before speed and pressure.
    /// Empty when neither is set (the machine's panel settings apply).
    public static func speedAndPressure(speed: Int?, force: Int?, terminator: String = "") -> String {
        guard speed != nil || force != nil else { return "" }
        var out = "SP1;" + terminator
        if let s = speed { out += "VS\(s);" + terminator }
        if let f = force { out += "HS\(f);" + terminator }
        return out
    }

    func header(options: HPGLOptions) -> String {
        var out = "IN;" + options.lineTerminator
        out += "SP1;" + options.lineTerminator
        out += Self.speedAndPressure(speed: options.speed, force: options.force, terminator: options.lineTerminator)
        return out
    }

    func body(_ paths: [Polyline], options: HPGLOptions, map: (Point) -> (x: Int, y: Int)) -> String {
        var out = ""
        for path in paths where !path.isEmpty {
            var pts = path.points
            if path.isClosed, let first = pts.first { pts.append(first) }
            // Points closer than one machine step map to the same coordinate; send each position once.
            var coords: [(x: Int, y: Int)] = []
            coords.reserveCapacity(pts.count)
            for c in pts.map(map) where coords.last.map({ $0.x != c.x || $0.y != c.y }) ?? true { coords.append(c) }
            out += "PU\(coords[0].x),\(coords[0].y);" + options.lineTerminator
            var i = 1
            while i < coords.count {
                let chunk = coords[i..<min(i + options.pointsPerCommand, coords.count)]
                out += "PD" + chunk.map { "\($0.x),\($0.y)" }.joined(separator: ",") + ";" + options.lineTerminator
                i += chunk.count
            }
        }
        return out
    }

    /// Advance After Plot: lift and move to the far end of the job along the feed, then page-feed.
    func trailer(bounds: Rect, options: HPGLOptions) -> String {
        guard options.advanceAfterCut else {
            return "PU0,0;" + options.lineTerminator + "SP0;" + options.lineTerminator
        }
        let feedMM = options.advanceFeedMM ?? (bounds.isNull ? 0 : bounds.height + options.originOffset.y)
        let end = Self.steps(across: 0, feed: feedMM, options: options)
        return "PU\(end.x),\(end.y);" + options.lineTerminator + "PG;" + options.lineTerminator
    }

    /// Maps a document point (mm) to plotter steps, placing the design's bounding box at `originOffset`.
    static func plotterCoordinate(_ p: Point, bounds: Rect, options: HPGLOptions) -> (x: Int, y: Int) {
        let across = (options.mirrorX ? bounds.maxX - p.x : p.x - bounds.minX) + options.originOffset.x
        let feed = (options.flipY ? bounds.maxY - p.y : p.y - bounds.minY) + options.originOffset.y
        return steps(across: across, feed: feed, options: options)
    }

    static func steps(across: Double, feed: Double, options: HPGLOptions) -> (x: Int, y: Int) {
        let a = Int((across * options.stepsPerMM).rounded())
        let f = Int((feed * options.stepsPerMM).rounded())
        return options.swapAxes ? (f, a) : (a, f)
    }
}
