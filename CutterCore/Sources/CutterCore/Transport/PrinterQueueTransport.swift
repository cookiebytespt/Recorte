import Foundation

/// A USB printer-class device CUPS can see but that has no queue yet.
public struct USBPrinterDevice: Hashable, Sendable, Identifiable {
    public var uri: String
    public var description: String
    public var id: String { uri }

    /// The Liyu identifies itself as a printer-class device named "LIYU CUTTING PLOTTER".
    public var isLikelyCutter: Bool {
        let s = (uri + " " + description).lowercased()
        return s.contains("liyu") || s.contains("cutting") || s.contains("plotter") || s.contains("cutter")
    }
}

/// Sends raw HPGL through a CUPS printer queue (`lp -o raw`). The Liyu GF-1261 enumerates as a
/// USB printer-class device (VID 0483 / PID 5750), so this needs no driver: just a raw queue.
public struct PrinterQueueTransport: CutterTransport {
    public let queueName: String

    public init(queueName: String) { self.queueName = queueName }

    /// USB printers attached right now (`lpinfo -v`), whether or not they have a queue.
    public static func attachedUSBPrinters() async -> [USBPrinterDevice] {
        let output = (try? await Self.run("/usr/sbin/lpinfo", ["-v"])) ?? ""
        return output.split(separator: "\n").compactMap { line -> USBPrinterDevice? in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0] == "direct", parts[1].hasPrefix("usb://") else { return nil }
            let uri = String(parts[1])
            let name = uri.dropFirst("usb://".count).split(separator: "?").first.map(String.init) ?? uri
            return USBPrinterDevice(uri: uri, description: name.removingPercentEncoding ?? name)
        }
    }

    /// Creates a raw queue for a USB device. Needs the user to be an administrator (member of `_lpadmin`).
    public static func createRawQueue(named name: String, for device: USBPrinterDevice) async throws {
        let safeName = name.replacingOccurrences(of: " ", with: "_").filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        _ = try await Self.run("/usr/sbin/lpadmin", ["-p", safeName, "-E", "-v", device.uri, "-m", "raw", "-D", device.description])
    }

    public static func availableQueues() async -> [String] {
        let output = (try? await Self.run("/usr/bin/lpstat", ["-p"])) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "printer" else { return nil }
            return String(parts[1])
        }
    }

    public func send(_ data: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorte-\(UUID().uuidString).plt")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        progress(0.1)
        do {
            _ = try await Self.run("/usr/bin/lp", ["-d", queueName, "-o", "raw", url.path])
        } catch let error as TransportError {
            throw error
        } catch {
            throw TransportError.printerQueueFailed(error.localizedDescription)
        }
        progress(1)
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { p in
                let stdout = String(decoding: (p.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data(), as: UTF8.self)
                let stderr = String(decoding: (p.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: TransportError.printerQueueFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: TransportError.printerQueueFailed(error.localizedDescription))
            }
        }
    }
}
