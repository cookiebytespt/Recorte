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
    /// Cutting speed in mm/s (`VS`).
    public var speed: Int
    /// Cutting pressure in grams (`HS`).
    public var force: Int
    public var sendSpeedAndForce: Bool
    /// Plain cuts: feed the vinyl past the job when done (SignMaster's Advance After Plot).
    public var advanceAfterCut: Bool
    /// Plain cuts: how many copies to cut one after another along the vinyl.
    public var copies: Int
    /// Plain cuts: gap between copies along the feed, in mm.
    public var copyGapMM: Double

    public init(scale: Double = 1, mirror: Bool = false, rotate90: Bool = false, marginX: Double = 5, marginY: Double = 5,
                bladeOffsetMM: Double = 0.25, overcutMM: Double = 1, optimizeOrder: Bool = true, innerFirst: Bool = true,
                speed: Int = 200, force: Int = 70, sendSpeedAndForce: Bool = false,
                advanceAfterCut: Bool = true, copies: Int = 1, copyGapMM: Double = 5) {
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
        self.advanceAfterCut = advanceAfterCut
        self.copies = copies
        self.copyGapMM = copyGapMM
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
    /// Set for Print & Cut jobs: the sheet and marks the paths are referenced to.
    public var printSheet: PrintSheet?

    public var isPrintAndCut: Bool { printSheet != nil }
    public var sizeMM: Size { bounds.size }

    public static func == (l: CutJob, r: CutJob) -> Bool { l.hpgl == r.hpgl && l.cutPaths == r.cutPaths }
    public func hash(into hasher: inout Hasher) { hasher.combine(hpgl) }
}

public enum JobPlanner {
    /// Print & Cut: paths stay where they are on the sheet; only ordering and blade compensation apply.
    public static func planPrintAndCut(document: CutDocument, sheet: PrintSheet,
                                       settings: JobSettings, machine: MachineProfile) -> CutJob {
        let cutPaths = document.paths
        var ordered = cutPaths
        if settings.optimizeOrder {
            ordered = PathOptimizer(innerFirst: settings.innerFirst).optimize(cutPaths, startingAt: sheet.originMark)
        }
        let compensated = BladeOffsetCompensator(offset: settings.bladeOffsetMM, overcut: settings.overcutMM).apply(ordered)
        let hpgl = PrintAndCutHPGL.generate(
            paths: compensated, sheet: sheet, stepsPerMM: machine.stepsPerMM,
            speed: settings.sendSpeedAndForce ? settings.speed : nil,
            force: settings.sendSpeedAndForce ? settings.force : nil)
        let bounds = cutPaths.bounds
        let inside = bounds.isNull || sheet.safeArea.insetBy(-0.01).contains(bounds)
        return CutJob(cutPaths: cutPaths, toolpaths: compensated, bounds: bounds, cutLength: cutPaths.totalLength,
                      hpgl: hpgl, fitsMachine: sheet.markFrame.width <= machine.cutWidthMM && inside,
                      printSheet: sheet)
    }

    public static func planPrintAndCut(document: CutDocument, page: Size, layout: RegistrationMarkLayout,
                                       settings: JobSettings, machine: MachineProfile) -> CutJob {
        planPrintAndCut(document: document, sheet: PrintSheet(page: page, layout: layout, artwork: document.paths.bounds),
                        settings: settings, machine: machine)
    }

    public static func plan(document: CutDocument, settings: JobSettings, machine: MachineProfile) -> CutJob {
        var t = AffineTransform.scaling(settings.scale, settings.scale)
        if settings.mirror { t = AffineTransform.scaling(-1, 1).concatenating(t) }
        if settings.rotate90 { t = AffineTransform.rotation(radians: .pi / 2).concatenating(t) }

        let positioned = document.normalized().transformed(t).normalized()
        let single = positioned.paths
        let singleBounds = single.bounds
        // Copies follow each other along the feed (into the machine).
        var cutPaths = single
        if settings.copies > 1, !singleBounds.isNull {
            let step = singleBounds.height + max(settings.copyGapMM, 0)
            for i in 1..<settings.copies {
                cutPaths += single.transformed(.translation(0, step * Double(i)))
            }
        }
        let bounds = cutPaths.bounds

        var ordered = cutPaths
        if settings.optimizeOrder {
            ordered = PathOptimizer(innerFirst: settings.innerFirst).optimize(cutPaths, startingAt: .zero)
        }
        let compensated = BladeOffsetCompensator(offset: settings.bladeOffsetMM, overcut: settings.overcutMM).apply(ordered)

        let toolBounds = compensated.bounds
        let options = HPGLOptions(
            stepsPerMM: machine.stepsPerMM,
            speed: settings.sendSpeedAndForce ? settings.speed : nil,
            force: settings.sendSpeedAndForce ? settings.force : nil,
            // The design (not the blade-offset loops around it) sits at the position offset, like SignMaster.
            originOffset: Point(settings.marginX + (toolBounds.isNull || bounds.isNull ? 0 : toolBounds.minX - bounds.minX),
                                settings.marginY + (toolBounds.isNull || bounds.isNull ? 0 : toolBounds.minY - bounds.minY)),
            advanceAfterCut: settings.advanceAfterCut,
            advanceFeedMM: bounds.isNull ? nil : bounds.height + settings.marginY
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
