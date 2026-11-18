import AppKit
import CutterCore
import Observation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// Help ▸ Cutter Troubleshooting… — always in Debug builds; in release builds only after
// Settings ▸ Cutter ▸ Troubleshooting is switched on.
// Tests the USB connection to the cutter and logs everything: to the window, to the Xcode
// console / Console.app (subsystem pt.cookiebytes.recorte, category CutterDebug) and to a file
// (debug-logs/ in the repo when run from Xcode, otherwise ~/Library/Logs/Recorte).
// The window itself is a support tool and stays in English.

enum DebugWindowID {
    static let cutter = "cutter-troubleshooting"
}

struct CutterTroubleshootingCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.showTroubleshooting) private var showTroubleshooting = false

    private var isVisible: Bool {
        #if DEBUG
        true
        #else
        showTroubleshooting
        #endif
    }

    var body: some Commands {
        CommandGroup(after: .help) {
            if isVisible {
                Divider()
                Button("Cutter Troubleshooting…") { openWindow(id: DebugWindowID.cutter) }
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            }
        }
    }
}

// MARK: - Log sink

/// Thread-safe: diagnostics call `write` from background tasks.
final class CutterDebugLogSink: @unchecked Sendable {
    let fileURL: URL
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private let handle: FileHandle?
    private let formatter: DateFormatter
    private let logger = Logger(subsystem: "pt.cookiebytes.recorte", category: "CutterDebug")

    init() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = Self.logDirectory().appendingPathComponent("cutter-\(stamp.string(from: Date())).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        (stream, continuation) = AsyncStream<String>.makeStream()
    }

    deinit {
        continuation.finish()
        try? handle?.close()
    }

    func write(_ line: String) {
        lock.lock()
        let stamped = formatter.string(from: Date()) + "  " + line
        handle?.write(Data((stamped + "\n").utf8))
        lock.unlock()
        logger.log("\(line, privacy: .public)")
        continuation.yield(stamped)
    }

    /// `<repo>/debug-logs` when running from the source tree, otherwise ~/Library/Logs/Recorte.
    static func logDirectory() -> URL {
        let fm = FileManager.default
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Debug
            .deletingLastPathComponent() // Recorte
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // repo root
        let inRepo = repo.appendingPathComponent("debug-logs")
        if fm.fileExists(atPath: repo.appendingPathComponent("project.yml").path),
           (try? fm.createDirectory(at: inRepo, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: inRepo.path) {
            return inRepo
        }
        #endif
        let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Recorte")
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var repoCapturesFolder: URL? {
        #if DEBUG
        let folder = logDirectory().deletingLastPathComponent().appendingPathComponent("docs/debugging/captures/signmaster/plt")
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Model

@MainActor
@Observable
final class CutterDebugModel {
    enum Payload: String, CaseIterable, Identifiable {
        case moveOnly = "Move head 20 mm, knife up (no cut)"
        case recorteTestSquare = "Recorte test square + circle (cuts)"
        case signMasterRectangle = "SignMaster rectangle 104×86 mm, byte-exact (cuts)"
        case file = "PLT file…"
        var id: String { rawValue }
    }

    var payload: Payload = .moveOnly
    var payloadFile: URL?
    var vendorIDText = "0483"
    var productIDText = "5750"
    /// Empty: let the code pick the printer-class interface.
    var interfaceText = ""
    var chunkSize = 2048
    var seize = false
    var softResetFirst = false
    var readBackSeconds = 2.0
    private(set) var logText = ""
    private(set) var isBusy = false
    private(set) var currentStep = ""

    let sink = CutterDebugLogSink()
    private var task: Task<Void, Never>?

    init() {
        let stream = sink.stream
        Task { [weak self] in
            for await line in stream {
                guard let self else { return }
                self.logText += line + "\n"
                if self.logText.count > 400_000 { self.logText = String(self.logText.suffix(300_000)) }
            }
        }
        sink.write("Cutter troubleshooting session. Log file: \(sink.fileURL.path)")
    }

    var vendorID: Int { Int(vendorIDText, radix: 16) ?? 0x0483 }
    var productID: Int { Int(productIDText, radix: 16) ?? 0x5750 }

    var usbOptions: CutterDiagnostics.USBOptions {
        CutterDiagnostics.USBOptions(vendorID: vendorID, productID: productID,
                                     interfaceNumber: Int(interfaceText), chunkSize: chunkSize, seize: seize,
                                     softResetFirst: softResetFirst, readBackSeconds: readBackSeconds)
    }

    // MARK: Payloads

    /// Knife up the whole time: the head and the vinyl move, nothing gets cut.
    static let moveOnlyJob = "IN;SP1;PU0,0;PU800,0;PU800,800;PU0,800;PU0,0;\r\n"

    /// docs/debugging/captures/signmaster/plt/plain-black-passes1.plt, byte for byte.
    static let signMasterRectangleJob =
        "IN;SP1;SP1;VS120;HS70;PU81,93;PD81,173;PU81,113;PD81,4272;PD91,4267;PD94,4259;PD3541,4259;PD3536,4249;PD3528,4246;PD3528,68;PD3519,72;PD3515,81;PD68,81;PD72,90;PD81,94;PD81,113;PD81,153;PU3527,0;PG;\r\n"

    func payloadData(machine: MachineProfile) -> Data? {
        switch payload {
        case .moveOnly:
            return Data(Self.moveOnlyJob.utf8)
        case .recorteTestSquare:
            let options = HPGLOptions(stepsPerMM: machine.stepsPerMM,
                                      speed: machine.sendsSpeedAndForce ? machine.defaultSpeed : nil,
                                      force: machine.sendsSpeedAndForce ? machine.defaultForce : nil,
                                      originOffset: Point(5, 5))
            return Data(HPGLGenerator().testSquare(options: options).utf8)
        case .signMasterRectangle:
            return Data(Self.signMasterRectangleJob.utf8)
        case .file:
            guard let payloadFile else { return nil }
            return try? Data(contentsOf: payloadFile)
        }
    }

    // MARK: Actions

    private func run(_ step: String, _ work: @escaping @Sendable (@escaping CutterDiagnostics.Log) async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        currentStep = step
        let sink = self.sink
        let log: CutterDiagnostics.Log = { sink.write($0) }
        task = Task.detached { [weak self] in
            await work(log)
            log("— \(step): done")
            await self?.finished()
        }
    }

    private func finished() {
        isBusy = false
        currentStep = ""
        task = nil
    }

    func cancel() {
        task?.cancel()
        sink.write("Cancel requested.")
    }

    /// System scan, then open the USB interface without sending anything.
    func fullCheck() {
        let vid = vendorID, pid = productID, options = usbOptions
        run("Full check") { log in
            CutterDiagnostics.environmentReport(vendorID: vid, productID: pid, log: log)
            var probe = options
            probe.readBackSeconds = 1
            await CutterDiagnostics.usbSession(probe, send: nil, log: log)
        }
    }

    func probeUSB() {
        let options = usbOptions
        run("Probe USB") { log in
            await CutterDiagnostics.usbSession(options, send: nil, log: log)
        }
    }

    func send(machine: MachineProfile) {
        guard let data = payloadData(machine: machine) else {
            sink.write("!! No payload: pick a PLT file first.")
            return
        }
        // A Print & Cut job (starts with TB…) makes the machine hunt for printed marks; without
        // the printed sheet loaded at the right origin the head runs into its end stop.
        if data.starts(with: Data("TB".utf8)) {
            let alert = NSAlert()
            alert.messageText = "This is a Print & Cut job"
            alert.informativeText = "The machine will search for the printed registration marks. Only send it with the printed sheet loaded and the origin set on the first mark, or the head can hit its end stop."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let options = usbOptions, name = payload.rawValue
        run("Send") { log in
            log("Payload: \(name), \(data.count) bytes")
            await CutterDiagnostics.usbSession(options, send: data, log: log)
        }
    }

    func softReset() {
        var resetOptions = usbOptions
        resetOptions.softResetFirst = true
        resetOptions.readBackSeconds = 0
        let options = resetOptions
        run("Soft reset") { log in
            await CutterDiagnostics.usbSession(options, send: nil, log: log)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "plt") ?? .data, UTType(filenameExtension: "hpgl") ?? .data, .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Pick a PLT/HPGL file to send as-is"
        if let folder = CutterDebugLogSink.repoCapturesFolder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url {
            payloadFile = url
            payload = .file
            sink.write("Payload file: \(url.path)")
        }
    }

    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([sink.fileURL])
    }

    func clearView() { logText = "" }
}

// MARK: - View

struct CutterDebugView: View {
    @Environment(CutterController.self) private var cutter
    @State private var model = CutterDebugModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            Divider()
            log
        }
        .padding(12)
        .frame(minWidth: 860, minHeight: 600)
    }

    private var controls: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                label("Device")
                HStack {
                    Text(verbatim: "VID").foregroundStyle(.secondary)
                    TextField(text: $model.vendorIDText) { Text(verbatim: "VID") }.frame(width: 60)
                    Text(verbatim: "PID").foregroundStyle(.secondary)
                    TextField(text: $model.productIDText) { Text(verbatim: "PID") }.frame(width: 60)
                    Text(verbatim: "Interface").foregroundStyle(.secondary)
                    TextField(text: $model.interfaceText, prompt: Text(verbatim: "auto")) { Text(verbatim: "Interface") }.frame(width: 50)
                    Text(verbatim: cutter.usbCutter.map { "Found: \($0.productName)" } ?? "Not plugged in")
                        .foregroundStyle(cutter.usbCutter == nil ? Color.secondary : Color.green)
                }
            }
            GridRow {
                label("Checks")
                HStack {
                    button("Full check (safe)", action: model.fullCheck)
                    button("Probe USB", action: model.probeUSB)
                    button("Soft reset", action: model.softReset)
                }
            }
            GridRow {
                label("USB options")
                HStack {
                    Picker(selection: $model.chunkSize) {
                        ForEach([64, 512, 1024, 2048, 4096, 0], id: \.self) { size in
                            Text(verbatim: size == 0 ? "all at once" : "\(size) B").tag(size)
                        }
                    } label: { Text(verbatim: "Chunk") }
                    .frame(width: 170)
                    Toggle(isOn: $model.seize) { Text(verbatim: "Seize from other owner") }
                    Toggle(isOn: $model.softResetFirst) { Text(verbatim: "Soft reset first") }
                    Stepper(value: $model.readBackSeconds, in: 0...10, step: 1) {
                        Text(verbatim: "Read back \(Int(model.readBackSeconds)) s")
                    }
                }
            }
            GridRow {
                label("Send")
                HStack {
                    Picker(selection: $model.payload) {
                        ForEach(CutterDebugModel.Payload.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                    } label: { EmptyView() }
                    .labelsHidden()
                    .frame(width: 340)
                    if model.payload == .file {
                        button(model.payloadFile?.lastPathComponent ?? "Choose…", action: model.chooseFile)
                    }
                    Button { model.send(machine: cutter.machine) } label: { Text(verbatim: "Send") }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || cutter.isSending)
                }
            }
            GridRow {
                label("")
                HStack {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        Text(verbatim: model.currentStep + "…").foregroundStyle(.secondary)
                        Button(action: model.cancel) { Text(verbatim: "Cancel") }
                    }
                    Spacer()
                    button("Copy log", action: model.copyLog)
                    button("Show log file", action: model.revealLog)
                    button("Clear view", action: model.clearView)
                }
            }
        }
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: model.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.logText) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }.disabled(model.isBusy)
    }
}
