import CutterCore
import Foundation
import Observation

/// Owns the connection to the cutter and the job currently being sent.
@MainActor
@Observable
final class CutterController {
    enum Status: Equatable {
        case idle
        case sending(progress: Double)
        case finished
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var availablePorts: [SerialPortInfo] = []
    private(set) var availableQueues: [String] = []
    /// USB printer-class devices seen by CUPS (the Liyu shows up here) that may still need a queue.
    private(set) var attachedUSBPrinters: [USBPrinterDevice] = []
    private(set) var setupError: String?
    private var sendTask: Task<Void, Never>?

    var machine: MachineProfile { Preferences.machineProfile() }

    var connectionKind: ConnectionKind {
        get { ConnectionKind(rawValue: UserDefaults.standard.string(forKey: Preferences.connectionKind) ?? "") ?? .printerQueue }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Preferences.connectionKind) }
    }

    var serialPortPath: String {
        get { UserDefaults.standard.string(forKey: Preferences.serialPortPath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Preferences.serialPortPath) }
    }

    var printerQueue: String {
        get { UserDefaults.standard.string(forKey: Preferences.printerQueue) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Preferences.printerQueue) }
    }

    var isSending: Bool {
        if case .sending = status { return true }
        return false
    }

    /// `true` when a device has been chosen for the current connection kind.
    var hasDevice: Bool {
        switch connectionKind {
        case .serial: return !serialPortPath.isEmpty
        case .printerQueue: return !printerQueue.isEmpty
        }
    }

    var deviceDescription: String {
        switch connectionKind {
        case .serial: return SerialPortInfo(path: serialPortPath).displayName
        case .printerQueue: return printerQueue
        }
    }

    init() {
        Preferences.registerDefaults()
        refreshDevices()
    }

    func refreshDevices() {
        let ports = SerialPortScanner.availablePorts()
        availablePorts = ports
        // Auto-pick the only plausible port if nothing is selected yet.
        if serialPortPath.isEmpty || !ports.contains(where: { $0.path == serialPortPath }) {
            let candidates = ports.filter(\.isLikelyCutter)
            if candidates.count == 1 { serialPortPath = candidates[0].path }
        }
        Task {
            let queues = await PrinterQueueTransport.availableQueues()
            let printers = await PrinterQueueTransport.attachedUSBPrinters()
            availableQueues = queues
            attachedUSBPrinters = printers
            // Pick the cutter's queue automatically when there is an obvious one.
            if connectionKind == .printerQueue, printerQueue.isEmpty || !queues.contains(printerQueue) {
                // Never guess: a wrong queue would send HPGL to a real printer.
                if let match = queues.first(where: { let n = $0.lowercased(); return n.contains("liyu") || n.contains("recorte") || n.contains("cookiecut") || n.contains("cutter") || n.contains("plotter") }) {
                    printerQueue = match
                } else {
                    printerQueue = ""
                }
            }
        }
    }

    /// The attached cutter that has no queue yet, if any.
    var cutterNeedingQueue: USBPrinterDevice? {
        guard connectionKind == .printerQueue else { return nil }
        return attachedUSBPrinters.first(where: \.isLikelyCutter)
    }

    /// Creates a raw CUPS queue for the attached cutter and selects it.
    func createQueue(for device: USBPrinterDevice) {
        Task {
            do {
                try await PrinterQueueTransport.createRawQueue(named: "Recorte_Liyu", for: device)
                printerQueue = "Recorte_Liyu"
                setupError = nil
            } catch {
                setupError = error.localizedDescription
            }
            refreshDevices()
        }
    }

    private func makeTransport() throws -> any CutterTransport {
        let m = machine
        switch connectionKind {
        case .serial:
            guard !serialPortPath.isEmpty else { throw TransportError.noDevice }
            return SerialPortTransport(path: serialPortPath, baudRate: m.baudRate, flowControl: m.flowControl)
        case .printerQueue:
            guard !printerQueue.isEmpty else { throw TransportError.noDevice }
            return PrinterQueueTransport(queueName: printerQueue)
        }
    }

    func send(hpgl: String) {
        guard !isSending else { return }
        status = .sending(progress: 0)
        let data = Data(hpgl.utf8)
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try makeTransport()
                try await transport.send(data) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.isSending else { return }
                        self.status = .sending(progress: value)
                    }
                }
                status = .finished
            } catch is CancellationError {
                status = .idle
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func sendTestCut() {
        let m = machine
        let options = HPGLOptions(
            stepsPerMM: m.stepsPerMM,
            speed: m.sendsSpeedAndForce ? m.defaultSpeed : nil,
            force: m.sendsSpeedAndForce ? m.defaultForce : nil,
            originOffset: Point(5, 5)
        )
        send(hpgl: HPGLGenerator().testSquare(options: options))
    }

    func cancel() {
        sendTask?.cancel()
        sendTask = nil
        status = .idle
    }

    func dismissStatus() {
        if !isSending { status = .idle }
    }
}
