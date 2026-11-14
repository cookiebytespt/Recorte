import Foundation

/// Everything the user can change about how a design is cut.
public struct JobSettings: Sendable, Hashable, Codable {
    public var scale: Double
    /// Mirror horizontally (needed for heat-transfer vinyl, which is cut from the back).
    public var mirror: Bool
    public var rotate90: Bool
    /// Distance from the cutter origin, in millimetres.
    public var marginX: Double
    public var marginY: Double
    public var bladeOffsetMM: Double
    public var overcutMM: Double
    public var optimizeOrder: Bool
    public var innerFirst: Bool
    public var speed: Int
    public var force: Int
    public var sendSpeedAndForce: Bool

    public init(scale: Double = 1, mirror: Bool = false, rotate90: Bool = false, marginX: Double = 5, marginY: Double = 5,
                bladeOffsetMM: Double = 0.25, overcutMM: Double = 1, optimizeOrder: Bool = true, innerFirst: Bool = true,
                speed: Int = 30, force: Int = 80, sendSpeedAndForce: Bool = true) {
        self.scale = scale
        self.mirror = mirror
        self.rotate90 = rotate90
        self.marginX = marginX
        self.marginY = marginY
        self.bladeOffsetMM = bladeOffsetMM
        self.overcutMM = overcutMM
        self.optimizeOrder = optimizeOrder
        self.innerFirst = innerFirst
        self.speed = speed
        self.force = force
        self.sendSpeedAndForce = sendSpeedAndForce
    }

    public static func defaults(for machine: MachineProfile) -> JobSettings {
        JobSettings(bladeOffsetMM: machine.bladeOffsetMM, overcutMM: machine.overcutMM,
                    speed: machine.defaultSpeed, force: machine.defaultForce, sendSpeedAndForce: machine.sendsSpeedAndForce)
    }
}

/// A planned job: what will be cut (for preview) and the HPGL to send.
public struct CutJob: Sendable, Hashable {
    /// Design outlines after scale/mirror/rotate, positioned at the origin (mm).
    public var cutPaths: [Polyline]
    /// Carriage paths after ordering and blade-offset compensation (mm).
    public var toolpaths: [Polyline]
    public var bounds: Rect
    public var cutLength: Double
    public var hpgl: String
    public var fitsMachine: Bool
    /// Set for Print & Cut jobs: the sheet size and mark layout the paths are referenced to.
    public var printSheet: (page: Size, layout: RegistrationMarkLayout)?

    public var isPrintAndCut: Bool { printSheet != nil }
    public var sizeMM: Size { bounds.size }

    public static func == (l: CutJob, r: CutJob) -> Bool { l.hpgl == r.hpgl && l.cutPaths == r.cutPaths }
    public func hash(into hasher: inout Hasher) { hasher.combine(hpgl) }
}

public enum JobPlanner {
    /// Print & Cut: paths stay where they are on the sheet; only ordering and blade compensation apply.
    public static func planPrintAndCut(document: CutDocument, page: Size, layout: RegistrationMarkLayout,
                                       settings: JobSettings, machine: MachineProfile) -> CutJob {
        let cutPaths = document.paths
        var ordered = cutPaths
        if settings.optimizeOrder {
            ordered = PathOptimizer(innerFirst: settings.innerFirst).optimize(cutPaths, startingAt: layout.markFrame(for: page).origin)
        }
        let compensated = BladeOffsetCompensator(offset: settings.bladeOffsetMM, overcut: settings.overcutMM).apply(ordered)
        let hpgl = PrintAndCutHPGL.generate(
            paths: compensated, page: page, layout: layout, stepsPerMM: machine.stepsPerMM,
            speed: settings.sendSpeedAndForce ? settings.speed : nil,
            force: settings.sendSpeedAndForce ? settings.force : nil)
        let safe = layout.safeArea(for: page)
        let bounds = cutPaths.bounds
        let inside = bounds.isNull || safe.contains(bounds)
        return CutJob(cutPaths: cutPaths, toolpaths: compensated, bounds: bounds, cutLength: cutPaths.totalLength,
                      hpgl: hpgl, fitsMachine: page.width <= machine.cutWidthMM && inside,
                      printSheet: (page, layout))
    }

    public static func plan(document: CutDocument, settings: JobSettings, machine: MachineProfile) -> CutJob {
        var t = AffineTransform.scaling(settings.scale, settings.scale)
        if settings.mirror { t = AffineTransform.scaling(-1, 1).concatenating(t) }
        if settings.rotate90 { t = AffineTransform.rotation(radians: .pi / 2).concatenating(t) }

        let positioned = document.normalized().transformed(t).normalized()
        let cutPaths = positioned.paths
        let bounds = cutPaths.bounds

        var ordered = cutPaths
        if settings.optimizeOrder {
            ordered = PathOptimizer(innerFirst: settings.innerFirst).optimize(cutPaths, startingAt: .zero)
        }
        let compensated = BladeOffsetCompensator(offset: settings.bladeOffsetMM, overcut: settings.overcutMM).apply(ordered)

        let options = HPGLOptions(
            stepsPerMM: machine.stepsPerMM,
            speed: settings.sendSpeedAndForce ? settings.speed : nil,
            force: settings.sendSpeedAndForce ? settings.force : nil,
            originOffset: Point(settings.marginX, settings.marginY)
        )
        let hpgl = HPGLGenerator().generate(compensated, options: options)
        let widthAcross = bounds.width + settings.marginX
        return CutJob(
            cutPaths: cutPaths,
            toolpaths: compensated,
            bounds: bounds,
            cutLength: cutPaths.totalLength,
            hpgl: hpgl,
            fitsMachine: widthAcross <= machine.cutWidthMM,
            printSheet: nil
        )
    }
}
