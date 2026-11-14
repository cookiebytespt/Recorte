import CutterCore
import Foundation
import Observation

/// Per-window state: the imported design plus the user's cut settings and the planned job.
@MainActor
@Observable
final class CutSession {
    let document: CutDocument
    let machine: MachineProfile
    /// Set when the design is a Print & Cut sheet.
    let printSheet: (page: Size, layout: RegistrationMarkLayout)?
    private(set) var job: CutJob

    var isPrintAndCut: Bool { printSheet != nil }

    var settings: JobSettings {
        didSet { replan() }
    }

    var materialID: String = MaterialPreset.standardVinyl.id {
        didSet {
            guard let preset = MaterialPreset.all.first(where: { $0.id == materialID }), preset.id != MaterialPreset.custom.id else { return }
            settings.speed = preset.speed
            settings.force = preset.force
        }
    }

    convenience init(document: CutDocument) {
        self.init(document: document, printSheet: nil)
    }

    convenience init(design: DesignDocument) {
        let cut = design.cutDocument(tolerance: Preferences.importOptions().tolerance)
        let sheet = design.printAndCut.isEnabled ? (design.canvasSize, design.printAndCut.layout) : nil
        self.init(document: cut, printSheet: sheet)
    }

    init(document: CutDocument, printSheet: (page: Size, layout: RegistrationMarkLayout)?) {
        let machine = Preferences.machineProfile()
        self.document = document
        self.machine = machine
        self.printSheet = printSheet
        var s = JobSettings.defaults(for: machine)
        s.speed = MaterialPreset.standardVinyl.speed
        s.force = MaterialPreset.standardVinyl.force
        self.settings = s
        self.job = Self.plan(document: document, printSheet: printSheet, settings: s, machine: machine)
    }

    private static func plan(document: CutDocument, printSheet: (page: Size, layout: RegistrationMarkLayout)?,
                             settings: JobSettings, machine: MachineProfile) -> CutJob {
        if let printSheet {
            return JobPlanner.planPrintAndCut(document: document, page: printSheet.page, layout: printSheet.layout,
                                              settings: settings, machine: machine)
        }
        return JobPlanner.plan(document: document, settings: settings, machine: machine)
    }

    private func replan() {
        job = Self.plan(document: document, printSheet: printSheet, settings: settings, machine: machine)
    }

    // MARK: Size helpers (millimetres, keep aspect ratio)

    private var baseSize: Size {
        let b = document.bounds
        return settings.rotate90 ? Size(b.height, b.width) : Size(b.width, b.height)
    }

    var widthMM: Double {
        get { baseSize.width * settings.scale }
        set { if baseSize.width > 0, newValue > 0 { settings.scale = newValue / baseSize.width } }
    }

    var heightMM: Double {
        get { baseSize.height * settings.scale }
        set { if baseSize.height > 0, newValue > 0 { settings.scale = newValue / baseSize.height } }
    }

    var scalePercent: Double {
        get { settings.scale * 100 }
        set { if newValue > 0 { settings.scale = newValue / 100 } }
    }

    /// Rough estimate from cut length and speed.
    var estimatedDuration: Duration {
        let speedMMPerSecond = Double(max(settings.speed, 1)) * 10
        let travel = job.toolpaths.totalLength * 1.3
        return .seconds(travel / speedMMPerSecond + 3)
    }

    func markCustomMaterial() {
        if materialID != MaterialPreset.custom.id { materialID = MaterialPreset.custom.id }
    }
}
