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
    /// The USB cutter (machine profile's VID/PID) currently plugged in, if any.
    private(set) var usbCutter: USBRegistryDevice?
    private var sendTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    var machine: MachineProfile { Preferences.machineProfile() }

    var connectionKind: ConnectionKind {
        get { ConnectionKind(rawValue: UserDefaults.standard.string(forKey: Preferences.connectionKind) ?? "") ?? .usb }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Preferences.connectionKind) }
    }

    var serialPortPath: String {
        get { UserDefaults.standard.string(forKey: Preferences.serialPortPath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Preferences.serialPortPath) }
    }

    var isSending: Bool {
        if case .sending = status { return true }
        return false
    }

    /// `true` when the machine for the current connection kind is there to send to.
    var hasDevice: Bool {
        switch connectionKind {
        case .usb: return usbCutter != nil
        case .serial: return !serialPortPath.isEmpty
        }
    }

    var deviceDescription: String {
        switch connectionKind {
        case .usb: return usbCutter?.productName ?? ""
        case .serial: return SerialPortInfo(path: serialPortPath).displayName
        }
    }

    init() {
        Preferences.registerDefaults()
        Preferences.migrateLegacyConnection()
        refreshDevices()
        // Notice the cutter being plugged in or switched on/off. The registry query is cheap.
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshUSB()
            }
        }
    }

    func refreshDevices() {
        refreshUSB()
        let ports = SerialPortScanner.availablePorts()
        availablePorts = ports
        // Auto-pick the only plausible port if nothing is selected yet.
        if serialPortPath.isEmpty || !ports.contains(where: { $0.path == serialPortPath }) {
            let candidates = ports.filter(\.isLikelyCutter)
            if candidates.count == 1 { serialPortPath = candidates[0].path }
        }
    }

    private func refreshUSB() {
        let m = machine
        guard let vid = m.usbVendorID, let pid = m.usbProductID else { usbCutter = nil; return }
        let found = USBRegistry.devices().first { $0.vendorID == vid && $0.productID == pid }
        if found?.registryID != usbCutter?.registryID { usbCutter = found }
    }

    private func makeTransport() throws -> any CutterTransport {
        let m = machine
        switch connectionKind {
        case .usb:
            guard let vid = m.usbVendorID, let pid = m.usbProductID else { throw TransportError.noDevice }
            return USBDirectTransport(vendorID: vid, productID: pid)
        case .serial:
            guard !serialPortPath.isEmpty else { throw TransportError.noDevice }
            return SerialPortTransport(path: serialPortPath, baudRate: m.baudRate, flowControl: m.flowControl)
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
