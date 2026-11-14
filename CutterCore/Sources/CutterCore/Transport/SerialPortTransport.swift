import Darwin
import Foundation

public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    /// Device path, e.g. `/dev/cu.usbserial-1410`.
    public var path: String
    public var id: String { path }

    public var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("cu.") ? String(name.dropFirst(3)) : name
    }

    /// Ports that are usually not a cutter (Bluetooth, debug consoles).
    public var isLikelyCutter: Bool {
        let n = path.lowercased()
        return !n.contains("bluetooth") && !n.contains("debug-console") && !n.contains("wlan")
    }

    public init(path: String) { self.path = path }
}

public enum SerialPortScanner {
    public static func availablePorts() -> [SerialPortInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .sorted()
            .map { SerialPortInfo(path: "/dev/" + $0) }
    }
}

/// Sends data to a USB-serial cutter using POSIX termios.
public actor SerialPortTransport: CutterTransport {
    public let path: String
    public let baudRate: Int
    public let flowControl: FlowControl
    public let chunkSize: Int

    public init(path: String, baudRate: Int = 9600, flowControl: FlowControl = .hardware, chunkSize: Int = 256) {
        self.path = path
        self.baudRate = baudRate
        self.flowControl = flowControl
        self.chunkSize = max(16, chunkSize)
    }

    public func send(_ data: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw TransportError.cannotOpen(path: path, code: errno) }
        defer { Darwin.close(fd) }

        // Back to blocking writes.
        guard fcntl(fd, F_SETFL, 0) != -1 else { throw TransportError.configurationFailed(code: errno) }

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else { throw TransportError.configurationFailed(code: errno) }
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(baudRate))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(CSIZE)
        tty.c_cflag |= tcflag_t(CS8)
        tty.c_cflag &= ~tcflag_t(PARENB | CSTOPB)
        tty.c_cflag &= ~tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        tty.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        switch flowControl {
        case .hardware: tty.c_cflag |= tcflag_t(CCTS_OFLOW | CRTS_IFLOW)
        case .software: tty.c_iflag |= tcflag_t(IXON | IXOFF)
        case .none: break
        }
        guard tcsetattr(fd, TCSANOW, &tty) == 0 else { throw TransportError.configurationFailed(code: errno) }

        let total = data.count
        var offset = 0
        progress(0)
        while offset < total {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, total)
            let written = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
                Darwin.write(fd, buf.baseAddress! + offset, end - offset)
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { await Task.yield(); continue }
                throw TransportError.writeFailed(code: errno)
            }
            offset += written
            progress(Double(offset) / Double(total))
            await Task.yield()
        }
        tcdrain(fd)
        progress(1)
    }
}
