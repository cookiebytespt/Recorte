import Foundation

/// Checks for working out why a job doesn't reach the cutter (Help ▸ Cutter Troubleshooting). Every step writes plain-text lines
/// to `log`; nothing here is shown to end users, so the text is not localised.
public enum CutterDiagnostics {
    public typealias Log = @Sendable (String) -> Void

    public struct CommandResult: Sendable {
        public var status: Int32
        public var output: String
        public var timedOut: Bool
    }

    // MARK: - Running tools

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        var data: Data {
            get { lock.lock(); defer { lock.unlock() }; return _data }
            set { lock.lock(); _data = newValue; lock.unlock() }
        }
    }

    /// Runs a tool, stdout and stderr together, killing it after `timeout`.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return CommandResult(status: -1, output: "could not launch \(executable): \(error.localizedDescription)", timedOut: false)
        }
        let box = OutputBox()
        let handle = pipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.data = handle.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return CommandResult(status: -1, output: String(decoding: box.data, as: UTF8.self), timedOut: true)
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: box.data, as: UTF8.self), timedOut: false)
    }

    public static func shell(_ command: String, timeout: TimeInterval = 20) -> CommandResult {
        run("/bin/sh", ["-c", command], timeout: timeout)
    }

    /// Runs and logs a command with its output indented.
    @discardableResult
    static func logged(_ log: Log, _ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> CommandResult {
        log("$ " + ([executable] + arguments).map(quote).joined(separator: " "))
        let r = run(executable, arguments, timeout: timeout)
        dump(r, to: log)
        return r
    }

    @discardableResult
    static func loggedShell(_ log: Log, _ command: String, timeout: TimeInterval = 20) -> CommandResult {
        log("$ " + command)
        let r = shell(command, timeout: timeout)
        dump(r, to: log)
        return r
    }

    private static func dump(_ r: CommandResult, to log: Log) {
        let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { log("    (no output)") }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) { log("    " + line) }
        if r.timedOut { log("    !! timed out") } else if r.status != 0 { log("    !! exit status \(r.status)") }
    }

    static func quote(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }

    static func describe(_ error: Error) -> String {
        (error as? USBDirectError)?.debugDescription ?? error.localizedDescription
    }

    static func section(_ log: Log, _ title: String) {
        log("")
        log("=== \(title) ===")
    }

    // MARK: - Environment

    /// How macOS sees the cutter: USB registry (and who owns each interface), serial ports,
    /// third-party drivers that could claim it.
    public static func environmentReport(vendorID: Int, productID: Int, log: Log) {
        section(log, "System")
        log("Date: \(ISO8601DateFormatter().string(from: Date()))")
        log("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let info = Bundle.main.infoDictionary ?? [:]
        log("App: \(Bundle.main.bundleIdentifier ?? "?") \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) pid \(ProcessInfo.processInfo.processIdentifier)")

        section(log, "USB devices (IOKit registry)")
        let devices = USBRegistry.devices()
        if devices.isEmpty { log("No USB devices found at all (unexpected; sandboxed?).") }
        var cutterFound = false
        for d in devices {
            let isCutter = d.vendorID == vendorID && d.productID == productID
            cutterFound = cutterFound || isCutter
            log((isCutter ? ">> " : "   ") + d.summary)
            if isCutter || d.vendorID == vendorID {
                for i in d.interfaces { log("       " + i.summary) }
            }
        }
        if !cutterFound {
            log(String(format: "!! No device %04X:%04X. Cutter off, cable unplugged, or it enumerates with a different ID (check the list above).", vendorID, productID))
        }

        section(log, "Serial ports")
        let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.usb") }.sorted()
        log(ports.isEmpty ? "(none)" : ports.map { "/dev/" + $0 }.joined(separator: "\n"))

        section(log, "Third-party drivers")
        loggedShell(log, "systemextensionsctl list 2>&1")
        loggedShell(log, "kmutil showloaded --list-only 2>/dev/null | grep -v com.apple")
    }

    // MARK: - Direct USB

    public struct USBOptions: Sendable, Hashable {
        public var vendorID: Int
        public var productID: Int
        /// nil: pick the printer-class interface.
        public var interfaceNumber: Int?
        /// Bytes per bulk transfer; 0 sends everything in one transfer.
        public var chunkSize: Int
        public var seize: Bool
        public var softResetFirst: Bool
        /// Seconds to keep reading the bulk IN endpoint after sending.
        public var readBackSeconds: Double
        public var transferTimeout: TimeInterval

        public init(vendorID: Int, productID: Int, interfaceNumber: Int? = nil, chunkSize: Int = 2048, seize: Bool = false,
                    softResetFirst: Bool = false, readBackSeconds: Double = 2, transferTimeout: TimeInterval = 30) {
            self.vendorID = vendorID
            self.productID = productID
            self.interfaceNumber = interfaceNumber
            self.chunkSize = chunkSize
            self.seize = seize
            self.softResetFirst = softResetFirst
            self.readBackSeconds = readBackSeconds
            self.transferTimeout = transferTimeout
        }
    }

    /// Opens the interface, logs descriptors and printer-class status, and optionally sends `data`.
    public static func usbSession(_ options: USBOptions, send data: Data?, log: Log) async {
        section(log, data == nil ? "Probe USB (no data sent)" : "Send directly over USB (\(data!.count) bytes)")
        log("Options: \(options)")
        let session: USBInterfaceSession
        do {
            session = try USBInterfaceSession.open(vendorID: options.vendorID, productID: options.productID,
                                                   interfaceNumber: options.interfaceNumber, seize: options.seize)
        } catch {
            log("!! \(describe(error))")
            log("   If this is kIOReturnExclusiveAccess: quit the other app using the cutter, or try with Seize on.")
            return
        }
        defer {
            session.close()
            log("Interface closed.")
        }
        log("Opened " + session.info.summary)
        for e in session.endpoints { log("    " + e.description) }
        log("Configuration descriptor (\(session.configurationDescriptor.count) bytes):")
        for line in HexDump.lines(session.configurationDescriptor) { log("    " + line) }

        if session.info.interfaceClass == 0x07 {
            do { log("GET_DEVICE_ID: \"\(try session.printerDeviceID())\"") } catch { log("GET_DEVICE_ID failed: \(describe(error))") }
            do { log("GET_PORT_STATUS: " + USBInterfaceSession.describePortStatus(try session.printerPortStatus())) } catch { log("GET_PORT_STATUS failed: \(describe(error))") }
        } else {
            log("Not a printer-class interface; skipping printer status requests.")
        }

        if options.softResetFirst {
            do { try session.printerSoftReset(); log("SOFT_RESET sent.") } catch { log("SOFT_RESET failed: \(describe(error))") }
        }

        if let data {
            log("Payload starts with:")
            for line in HexDump.lines(data, limit: 128) { log("    " + line) }
            let chunks = options.chunkSize > 0 ? (data.count + options.chunkSize - 1) / options.chunkSize : 1
            let every = max(1, chunks / 20)
            var index = 0
            let start = Date()
            do {
                let sent = try session.write(data, chunkSize: options.chunkSize, timeout: options.transferTimeout) { written, bytes, seconds in
                    index += 1
                    if index % every == 0 || written == data.count || seconds > 1 {
                        log(String(format: "    transfer %d/%d: %d bytes in %.3f s (total %d)", index, chunks, bytes, seconds, written))
                    }
                    try Task.checkCancellation()
                }
                log(String(format: "Sent %d of %d bytes in %.2f s.", sent, data.count, Date().timeIntervalSince(start)))
            } catch is CancellationError {
                log("Cancelled.")
            } catch {
                log("!! \(describe(error))")
            }
        }

        if options.readBackSeconds > 0 {
            if session.bulkIn == nil {
                log("No bulk IN endpoint: the cutter can't reply on this interface.")
            } else {
                log("Reading bulk IN for \(options.readBackSeconds) s…")
                let until = Date().addingTimeInterval(options.readBackSeconds)
                var got = 0
                while Date() < until {
                    do {
                        let reply = try session.read(maxLength: 512, timeout: 0.5)
                        if !reply.isEmpty {
                            got += reply.count
                            for line in HexDump.lines(reply) { log("    IN " + line) }
                        }
                    } catch {
                        log("!! \(describe(error))")
                        break
                    }
                }
                log(got == 0 ? "Nothing came back." : "Received \(got) bytes.")
            }
        }

        if session.info.interfaceClass == 0x07 {
            do { log("GET_PORT_STATUS after: " + USBInterfaceSession.describePortStatus(try session.printerPortStatus())) } catch { log("GET_PORT_STATUS failed: \(describe(error))") }
        }
    }
}
