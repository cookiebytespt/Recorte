import Foundation

public enum TransportError: Error, LocalizedError, Sendable {
    case cannotOpen(path: String, code: Int32)
    case configurationFailed(code: Int32)
    case writeFailed(code: Int32)
    case noDevice

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            return String(localized: "Could not open the cutter at \(path) (\(String(cString: strerror(code)))). Check the USB cable and that no other app is using it.", bundle: .module)
        case .configurationFailed:
            return String(localized: "The connection to the cutter could not be configured.", bundle: .module)
        case .writeFailed(let code):
            return String(localized: "Sending to the cutter failed (\(String(cString: strerror(code)))).", bundle: .module)
        case .noDevice:
            return String(localized: "No cutter selected. Choose one in Settings.", bundle: .module)
        }
    }
}

/// Anything that can carry bytes to the cutter.
public protocol CutterTransport: Sendable {
    /// Sends `data`, reporting progress from 0 to 1. Honours task cancellation.
    func send(_ data: Data, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Keeps the data in memory; used for previews and tests.
public actor RecordingTransport: CutterTransport {
    public private(set) var sent: [Data] = []

    public init() {}

    public func send(_ data: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        sent.append(data)
        progress(1)
    }
}
