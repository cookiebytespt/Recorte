import CutterCore
import Foundation
import Observation

/// State of the Output sheet: mode, cut settings, printing choice and the planned job.
@MainActor
@Observable
final class CutSession {
    enum Mode: String, CaseIterable, Identifiable {
        case cutOnly, printAndCut
        var id: String { rawValue }
    }

    enum PrintChoice: String, CaseIterable, Identifiable {
        case print, pdf, image, skip
        var id: String { rawValue }
    }

    enum PreviewLayers: String, CaseIterable, Identifiable {
        case both, print, cut
        var id: String { rawValue }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case canvas, selection
        var id: String { rawValue }
    }

    let machine: MachineProfile
    /// Objects selected in the editor when the sheet opened.
    let selection: Set<UUID>
    /// Pushes design changes made here (mode, marks) back to the editor as undoable edits.
    @ObservationIgnored private let commit: (DesignDocument) -> Void

    private(set) var design: DesignDocument
    private(set) var document: CutDocument
    private(set) var job: CutJob

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            updateDesign { $0.printAndCut.isEnabled = mode == .printAndCut }
        }
    }

    var scope: Scope = .canvas {
        didSet { if scope != oldValue { rebuild() } }
    }

    var settings: JobSettings {
        didSet { replan() }
    }

    /// Plain cuts: copies along the vinyl. Print & Cut: number of sheets to cut.
    var copies: Int = 1 {
        didSet { if copies != oldValue { replan() } }
    }

    var materialID: String = MaterialPreset.standardVinyl.id {
        didSet {
            guard let preset = MaterialPreset.all.first(where: { $0.id == materialID }), preset.id != MaterialPreset.custom.id else { return }
            settings.speed = preset.speed
            settings.force = preset.force
        }
    }

    var printChoice: PrintChoice = .print
    var imageFormat: PrintSheetRenderer.ImageFormat = .png
    var imageDPI: Int = 300
    var previewLayers: PreviewLayers = .both
    var showKnifeTravel = false

    var isPrintAndCut: Bool { mode == .printAndCut }
    var sheet: PrintSheet? { job.printSheet }
    var hasSelection: Bool { !selection.isEmpty }
    var isEmpty: Bool { document.isEmpty }

    /// Print & Cut jobs with printed images but nothing to cut: offer Create Cut Contour.
    var needsCutContour: Bool {
        isPrintAndCut && !design.imageObjects.isEmpty && design.cutObjects.isEmpty
    }

    init(design: DesignDocument, selection: Set<UUID> = [], commit: @escaping (DesignDocument) -> Void = { _ in }) {
        let machine = Preferences.machineProfile()
        self.machine = machine
        self.selection = selection
        self.commit = commit
        self.design = design
        self.mode = design.printAndCut.isEnabled ? .printAndCut : .cutOnly
        var s = JobSettings.defaults(for: machine)
        s.speed = MaterialPreset.standardVinyl.speed
        s.force = MaterialPreset.standardVinyl.force
        self.settings = s
        let doc = design.cutDocument(tolerance: Preferences.importOptions().tolerance)
        self.document = doc
        self.job = Self.plan(document: doc, design: design, printAndCut: design.printAndCut.isEnabled,
                             settings: s, copies: 1, machine: machine)
    }

    /// Changes the project (marks, mode) and sends the change back to the editor.
    func updateDesign(_ change: (inout DesignDocument) -> Void) {
        var next = design
        change(&next)
        guard next != design else { return }
        design = next
        commit(next)
        rebuild()
    }

    func updateLayout(_ change: (inout RegistrationMarkLayout) -> Void) {
        updateDesign { change(&$0.printAndCut.layout) }
    }

    /// The editor changed underneath (undo, edits in the sidebar).
    func designChanged(_ new: DesignDocument) {
        guard new != design else { return }
        design = new
        let wanted: Mode = new.printAndCut.isEnabled ? .printAndCut : .cutOnly
        if wanted != mode { mode = wanted }
        rebuild()
    }

    private func rebuild() {
        let ids = scope == .selection && !selection.isEmpty ? selection : nil
        document = design.cutDocument(tolerance: Preferences.importOptions().tolerance, only: ids)
        replan()
    }

    private func replan() {
        job = Self.plan(document: document, design: design, printAndCut: mode == .printAndCut,
                        settings: settings, copies: copies, machine: machine)
    }

    private static func plan(document: CutDocument, design: DesignDocument, printAndCut: Bool,
                             settings: JobSettings, copies: Int, machine: MachineProfile) -> CutJob {
        var s = settings
        if printAndCut {
            s.copies = 1
            return JobPlanner.planPrintAndCut(document: document, sheet: design.printSheet, settings: s, machine: machine)
        }
        s.copies = max(1, copies)
        return JobPlanner.plan(document: document, settings: s, machine: machine)
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
        let speedMMPerSecond = Double(max(settings.speed, 1))
        let travel = job.toolpaths.totalLength * 1.3
        return .seconds(travel / speedMMPerSecond + 3)
    }

    func markCustomMaterial() {
        if materialID != MaterialPreset.custom.id { materialID = MaterialPreset.custom.id }
    }

    // MARK: Problems with the job

    /// A warning only: the sheet can still be printed and cut.
    var marksOffPage: Bool { isPrintAndCut && !(sheet?.marksFitPage ?? true) }
    var outsideMarks: Bool { isPrintAndCut && !job.fitsMachine && !marksOffPage }
    var tooWide: Bool { !isPrintAndCut && !job.fitsMachine }
    /// Problems with the job itself that stop printing and cutting (machine problems are checked by the view).
    /// Marks off the page are only a warning.
    var hasBlockingIssue: Bool { isEmpty || outsideMarks || tooWide }
}
