import Foundation

public struct HPGLOptions: Sendable, Hashable, Codable {
    /// Plotter resolution. Liyu cutters use 40 steps/mm (1016 per inch).
    public var stepsPerMM: Double
    /// `VS` speed command, in cm/s. `nil` leaves the cutter's own setting.
    public var speed: Int?
    /// `FS` force command, in grams. `nil` leaves the cutter's own setting.
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
    public var lineTerminator: String

    public init(stepsPerMM: Double = 40, speed: Int? = nil, force: Int? = nil, swapAxes: Bool = true,
                mirrorX: Bool = false, flipY: Bool = false, originOffset: Point = .zero,
                pointsPerCommand: Int = 50, lineTerminator: String = "\n") {
        self.stepsPerMM = stepsPerMM
        self.speed = speed
        self.force = force
        self.swapAxes = swapAxes
        self.mirrorX = mirrorX
        self.flipY = flipY
        self.originOffset = originOffset
        self.pointsPerCommand = max(1, pointsPerCommand)
        self.lineTerminator = lineTerminator
    }
}

/// Generates HPGL for Liyu and other HPGL vinyl cutters.
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
        out += "PU0,0;" + options.lineTerminator
        out += "SP0;" + options.lineTerminator
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

    func header(options: HPGLOptions) -> String {
        var out = "IN;" + options.lineTerminator
        out += "SP1;" + options.lineTerminator
        if let s = options.speed { out += "VS\(s);" + options.lineTerminator }
        if let f = options.force { out += "FS\(f);" + options.lineTerminator }
        return out
    }

    func body(_ paths: [Polyline], options: HPGLOptions, map: (Point) -> (x: Int, y: Int)) -> String {
        var out = ""
        for path in paths where !path.isEmpty {
            var pts = path.points
            if path.isClosed, let first = pts.first { pts.append(first) }
            let coords = pts.map(map)
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
