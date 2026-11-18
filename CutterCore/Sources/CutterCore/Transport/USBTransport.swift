import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

// Talks to the cutter over USB: find the device in the IOKit registry, open its interface with
// IOUSBHost and write the job to the bulk OUT endpoint. No driver and no print queue: macOS no
// longer allows raw CUPS queues ("Raw queues are no longer supported on macOS", tried 2026-11-18).
// The Liyu GF-1261 (STM32, 0483:5750) has one printer-class interface: bulk OUT 0x03, bulk IN
// 0x81, interrupt IN 0x82, 64-byte packets. It ignores the printer-class status requests
// (GET_DEVICE_ID / GET_PORT_STATUS) and never answers on bulk IN; jobs are one-way.

// MARK: - Registry snapshot (read-only, never opens the device)

public enum USBClassNames {
    public static func name(_ c: Int) -> String {
        switch c {
        case 0x00: return "defined per interface"
        case 0x01: return "audio"
        case 0x02: return "CDC (serial / modem)"
        case 0x03: return "HID"
        case 0x07: return "printer"
        case 0x08: return "mass storage"
        case 0x09: return "hub"
        case 0x0A: return "CDC data"
        case 0xEF: return "miscellaneous"
        case 0xFE: return "application specific"
        case 0xFF: return "vendor specific"
        default: return String(format: "0x%02X", c)
        }
    }
}

public struct USBRegistryInterface: Sendable, Hashable {
    public var number: Int
    public var alternateSetting: Int
    public var interfaceClass: Int
    public var interfaceSubClass: Int
    public var interfaceProtocol: Int
    /// IOKit classes attached under this interface (drivers, user clients). Empty: nobody claims it.
    public var attachedClasses: [String]
    /// IOKit records which process has the interface open exclusively, when one does.
    public var exclusiveOwner: String?

    public var summary: String {
        var s = "interface \(number) alt \(alternateSetting): class \(USBClassNames.name(interfaceClass))"
        s += String(format: " (%02X/%02X/%02X)", interfaceClass, interfaceSubClass, interfaceProtocol)
        s += attachedClasses.isEmpty ? ", no driver attached" : ", attached: \(attachedClasses.joined(separator: ", "))"
        if let exclusiveOwner { s += ", OPEN EXCLUSIVELY BY \(exclusiveOwner)" }
        return s
    }
}

public struct USBRegistryDevice: Sendable, Hashable, Identifiable {
    public var registryID: UInt64
    public var vendorID: Int
    public var productID: Int
    public var productName: String
    public var vendorName: String
    public var serialNumber: String
    public var locationID: Int
    public var deviceClass: Int
    public var speed: Int?
    public var exclusiveOwner: String?
    public var interfaces: [USBRegistryInterface]

    public var id: UInt64 { registryID }
    public var vidpid: String { String(format: "%04X:%04X", vendorID, productID) }

    public var summary: String {
        var s = "\(vidpid) \"\(productName)\" by \"\(vendorName)\""
        if !serialNumber.isEmpty { s += " serial \"\(serialNumber)\"" }
        s += String(format: " location 0x%08X device class %@", locationID, USBClassNames.name(deviceClass))
        if let exclusiveOwner { s += " OPEN EXCLUSIVELY BY \(exclusiveOwner)" }
        return s
    }
}

public enum USBRegistry {
    /// Every USB device IOKit knows about, with its interfaces and whatever is attached to them.
    public static func devices() -> [USBRegistryDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [USBRegistryDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let p = properties(of: service)
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            result.append(USBRegistryDevice(
                registryID: entryID,
                vendorID: int(p["idVendor"]),
                productID: int(p["idProduct"]),
                productName: string(p["kUSBProductString"]) ?? string(p["USB Product Name"]) ?? registryName(service),
                vendorName: string(p["kUSBVendorString"]) ?? string(p["USB Vendor Name"]) ?? "",
                serialNumber: string(p["kUSBSerialNumberString"]) ?? string(p["USB Serial Number"]) ?? "",
                locationID: int(p["locationID"]),
                deviceClass: int(p["bDeviceClass"]),
                speed: p["Device Speed"].map { int($0) },
                exclusiveOwner: string(p["UsbExclusiveOwner"]),
                interfaces: interfaces(of: service)
            ))
        }
        return result
    }

    static func interfaces(of device: io_service_t) -> [USBRegistryInterface] {
        children(of: device).compactMap { child -> USBRegistryInterface? in
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { return nil }
            let p = properties(of: child)
            let attached = children(of: child).map { grandChild -> String in
                defer { IOObjectRelease(grandChild) }
                return className(grandChild)
            }
            return USBRegistryInterface(
                number: int(p["bInterfaceNumber"]),
                alternateSetting: int(p["bAlternateSetting"]),
                interfaceClass: int(p["bInterfaceClass"]),
                interfaceSubClass: int(p["bInterfaceSubClass"]),
                interfaceProtocol: int(p["bInterfaceProtocol"]),
                attachedClasses: attached,
                exclusiveOwner: string(p["UsbExclusiveOwner"])
            )
        }.sorted { $0.number < $1.number }
    }

    /// Children in the IOService plane. The caller releases each one.
    static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [io_registry_entry_t] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            out.append(child)
        }
        return out
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return [:] }
        return dict
    }

    static func className(_ object: io_object_t) -> String {
        (IOObjectCopyClass(object)?.takeRetainedValue() as String?) ?? "?"
    }

    static func registryName(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? -1 }
    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// Interface services of the device with this VID/PID. The caller releases each one.
    /// Walks from the device: on recent macOS the interface nubs don't carry idVendor/idProduct.
    static func interfaceServices(vendorID: Int, productID: Int) -> [(service: io_service_t, info: USBRegistryInterface)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(io_service_t, USBRegistryInterface)] = []
        while true {
            let device = IOIteratorNext(iterator)
            guard device != 0 else { break }
            defer { IOObjectRelease(device) }
            let dp = properties(of: device)
            guard int(dp["idVendor"]) == vendorID, int(dp["idProduct"]) == productID else { continue }
            for child in children(of: device) {
                guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { IOObjectRelease(child); continue }
                let p = properties(of: child)
                out.append((child, USBRegistryInterface(
                    number: int(p["bInterfaceNumber"]),
                    alternateSetting: int(p["bAlternateSetting"]),
                    interfaceClass: int(p["bInterfaceClass"]),
                    interfaceSubClass: int(p["bInterfaceSubClass"]),
                    interfaceProtocol: int(p["bInterfaceProtocol"]),
                    attachedClasses: [],
                    exclusiveOwner: string(p["UsbExclusiveOwner"])
                )))
            }
        }
        return out
    }
}

// MARK: - Direct session

public struct USBEndpointInfo: Sendable, Hashable, CustomStringConvertible {
    public var address: UInt8
    public var attributes: UInt8
    public var maxPacketSize: Int
    public var interval: UInt8

    public var isIn: Bool { address & 0x80 != 0 }
    public var transferType: String { ["control", "isochronous", "bulk", "interrupt"][Int(attributes & 0x03)] }
    public var description: String {
        String(format: "endpoint 0x%02X %@ %@, max packet %d, interval %d", address, isIn ? "IN " : "OUT", transferType, maxPacketSize, interval)
    }
}

public enum USBDirectError: Error, LocalizedError, Sendable {
    case deviceNotFound(vendorID: Int, productID: Int)
    case openFailed(String)
    case noBulkOut
    case noBulkIn
    case transferFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return String(localized: "The cutter was not found. Check that it is switched on and the USB cable is plugged in.", bundle: .module)
        case .openFailed(let detail):
            return String(localized: "The cutter could not be opened. Another app may be using it. (\(detail))", bundle: .module)
        case .noBulkOut, .noBulkIn:
            return String(localized: "This USB device doesn't look like a cutter.", bundle: .module)
        case .transferFailed(let detail):
            return String(localized: "Sending to the cutter failed (\(detail)).", bundle: .module)
        }
    }

    /// Technical detail for logs (the localized text hides the IDs).
    public var debugDescription: String {
        switch self {
        case .deviceNotFound(let v, let p): return String(format: "no USB device %04X:%04X", v, p)
        case .openFailed(let detail): return "open failed: \(detail)"
        case .noBulkOut: return "no bulk OUT endpoint"
        case .noBulkIn: return "no bulk IN endpoint"
        case .transferFailed(let detail): return "transfer failed: \(detail)"
        }
    }
}

/// An open USB interface. Blocking calls; create, use and close it on one thread.
public final class USBInterfaceSession {
    public let info: USBRegistryInterface
    public private(set) var endpoints: [USBEndpointInfo] = []
    /// The whole configuration descriptor (all interfaces), for the log.
    public private(set) var configurationDescriptor = Data()

    private let service: io_service_t
    private let interface: IOUSBHostInterface
    private var closed = false

    /// Opens an interface of the device. With no `interfaceNumber`, prefers the printer-class one,
    /// then a vendor-specific one, then the first. `seize` takes it from whoever holds it (e.g. CUPS).
    public static func open(vendorID: Int, productID: Int, interfaceNumber: Int? = nil, seize: Bool = false) throws -> USBInterfaceSession {
        var candidates = USBRegistry.interfaceServices(vendorID: vendorID, productID: productID)
        guard !candidates.isEmpty else { throw USBDirectError.deviceNotFound(vendorID: vendorID, productID: productID) }
        let rank: (USBRegistryInterface) -> Int = { $0.interfaceClass == 0x07 ? 0 : ($0.interfaceClass == 0xFF ? 1 : 2) }
        candidates.sort { (rank($0.info), $0.info.number) < (rank($1.info), $1.info.number) }
        let chosenIndex = interfaceNumber.flatMap { n in candidates.firstIndex { $0.info.number == n } } ?? 0
        for (i, candidate) in candidates.enumerated() where i != chosenIndex { IOObjectRelease(candidate.service) }
        let chosen = candidates[chosenIndex]
        if let interfaceNumber, chosen.info.number != interfaceNumber {
            IOObjectRelease(chosen.service)
            throw USBDirectError.openFailed("the device has no interface \(interfaceNumber)")
        }
        do {
            return try USBInterfaceSession(service: chosen.service, info: chosen.info, seize: seize)
        } catch {
            IOObjectRelease(chosen.service)
            throw error
        }
    }

    private init(service: io_service_t, info: USBRegistryInterface, seize: Bool) throws {
        self.service = service
        self.info = info
        let options: IOUSBHostObjectInitOptions = seize ? [.deviceSeize] : []
        do {
            interface = try IOUSBHostInterface(__ioService: service, options: options, queue: nil, interestHandler: nil)
        } catch {
            throw USBDirectError.openFailed(Self.describe(error))
        }
        readDescriptors()
    }

    deinit { close() }

    public func close() {
        guard !closed else { return }
        closed = true
        interface.destroy()
        IOObjectRelease(service)
    }

    private func readDescriptors() {
        let configuration = interface.configurationDescriptor
        let interfaceDescriptor = interface.interfaceDescriptor
        let configRaw = UnsafeRawPointer(configuration)
        let total = Int(configRaw.load(fromByteOffset: 2, as: UInt8.self)) | Int(configRaw.load(fromByteOffset: 3, as: UInt8.self)) << 8
        configurationDescriptor = Data(bytes: configRaw, count: max(0, min(total, 4096)))

        var current = UnsafeRawPointer(interfaceDescriptor).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        var found: [USBEndpointInfo] = []
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, interfaceDescriptor, current) {
            let raw = UnsafeRawPointer(endpoint)
            found.append(USBEndpointInfo(
                address: raw.load(fromByteOffset: 2, as: UInt8.self),
                attributes: raw.load(fromByteOffset: 3, as: UInt8.self),
                maxPacketSize: Int(raw.load(fromByteOffset: 4, as: UInt8.self)) | Int(raw.load(fromByteOffset: 5, as: UInt8.self) & 0x07) << 8,
                interval: raw.load(fromByteOffset: 6, as: UInt8.self)
            ))
            current = raw.assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        endpoints = found
    }

    public var bulkOut: USBEndpointInfo? { endpoints.first { !$0.isIn && $0.transferType == "bulk" } }
    public var bulkIn: USBEndpointInfo? { endpoints.first { $0.isIn && $0.transferType == "bulk" } }

    // MARK: Control requests

    public func controlIn(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: Int, timeout: TimeInterval = 2) throws -> Data {
        let buffer = NSMutableData(length: length) ?? NSMutableData()
        var transferred = 0
        let setup = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: request, wValue: value, wIndex: index, wLength: UInt16(length))
        do {
            try interface.__send(setup, data: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw USBDirectError.transferFailed(Self.describe(error))
        }
        return Data(buffer.prefix(transferred))
    }

    public func controlOut(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, timeout: TimeInterval = 2) throws {
        var transferred = 0
        let setup = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: request, wValue: value, wIndex: index, wLength: 0)
        do {
            try interface.__send(setup, data: nil, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw USBDirectError.transferFailed(Self.describe(error))
        }
    }

    /// USB printer class GET_DEVICE_ID (IEEE 1284 ID string, e.g. "MFG:…;MDL:…;CMD:HPGL;").
    public func printerDeviceID() throws -> String {
        let index = UInt16(info.number) << 8 | UInt16(max(0, info.alternateSetting))
        let data = try controlIn(requestType: 0xA1, request: 0, value: 0, index: index, length: 1023)
        guard data.count > 2 else { return "" }
        return String(decoding: data.dropFirst(2), as: UTF8.self)
    }

    /// USB printer class GET_PORT_STATUS. Bit 3 = no error, bit 4 = selected, bit 5 = paper empty.
    public func printerPortStatus() throws -> UInt8 {
        let data = try controlIn(requestType: 0xA1, request: 1, value: 0, index: UInt16(info.number), length: 1)
        return data.first ?? 0
    }

    public static func describePortStatus(_ status: UInt8) -> String {
        let bits = [
            status & 0x08 != 0 ? "no error" : "ERROR",
            status & 0x10 != 0 ? "selected/online" : "NOT selected",
            status & 0x20 != 0 ? "PAPER EMPTY" : "paper ok",
        ]
        return String(format: "0x%02X (", status) + bits.joined(separator: ", ") + ")"
    }

    /// USB printer class SOFT_RESET: flushes the device's buffers.
    public func printerSoftReset() throws {
        try controlOut(requestType: 0x21, request: 2, value: 0, index: UInt16(info.number))
    }

    // MARK: Bulk transfers

    /// Writes `data` to the bulk OUT endpoint in chunks. `progress` gets the bytes written so far.
    @discardableResult
    public func write(_ data: Data, chunkSize: Int, timeout: TimeInterval = 30,
                      progress: (_ written: Int, _ chunkBytes: Int, _ seconds: Double) throws -> Void = { _, _, _ in }) throws -> Int {
        guard let endpoint = bulkOut else { throw USBDirectError.noBulkOut }
        let pipe: IOUSBHostPipe
        do { pipe = try interface.copyPipe(withAddress: Int(endpoint.address)) } catch { throw USBDirectError.transferFailed("copyPipe: \(Self.describe(error))") }
        let size = chunkSize > 0 ? chunkSize : max(data.count, 1)
        var offset = 0
        while offset < data.count {
            let end = min(offset + size, data.count)
            let chunk = NSMutableData(data: data.subdata(in: offset..<end))
            var transferred = 0
            let start = Date()
            do {
                try pipe.__sendIORequest(with: chunk, bytesTransferred: &transferred, completionTimeout: timeout)
            } catch {
                throw USBDirectError.transferFailed("bulk OUT at byte \(offset) after \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(Self.describe(error))")
            }
            offset += transferred
            try progress(offset, transferred, Date().timeIntervalSince(start))
            if transferred == 0 { throw USBDirectError.transferFailed("bulk OUT accepted 0 bytes at byte \(offset)") }
        }
        return offset
    }

    /// One read from the bulk IN endpoint. Returns empty data on timeout.
    public func read(maxLength: Int = 512, timeout: TimeInterval = 1) throws -> Data {
        guard let endpoint = bulkIn else { throw USBDirectError.noBulkIn }
        let pipe: IOUSBHostPipe
        do { pipe = try interface.copyPipe(withAddress: Int(endpoint.address)) } catch { throw USBDirectError.transferFailed("copyPipe: \(Self.describe(error))") }
        let buffer = NSMutableData(length: maxLength) ?? NSMutableData()
        var transferred = 0
        do {
            try pipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            let ns = error as NSError
            let code = Int32(truncatingIfNeeded: ns.code)
            if code == kIOReturnTimeout || code == Self.usbTransactionTimeout { return Data() }
            throw USBDirectError.transferFailed("bulk IN: \(Self.describe(error))")
        }
        return Data(buffer.prefix(transferred))
    }

    // iokit_usb_err(0x4F) / iokit_usb_err(0x51); the C macros aren't imported into Swift.
    static let usbPipeStalled = Int32(bitPattern: 0xE000_404F)
    static let usbTransactionTimeout = Int32(bitPattern: 0xE000_4051)

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let code = Int32(truncatingIfNeeded: ns.code)
        var name = ""
        switch code {
        case kIOReturnExclusiveAccess: name = "kIOReturnExclusiveAccess — another process has it open (CUPS backend? the vendor app?)"
        case kIOReturnNotPermitted: name = "kIOReturnNotPermitted"
        case kIOReturnNotPrivileged: name = "kIOReturnNotPrivileged"
        case kIOReturnTimeout: name = "kIOReturnTimeout"
        case kIOReturnNoDevice: name = "kIOReturnNoDevice"
        case kIOReturnNotResponding: name = "kIOReturnNotResponding"
        case kIOReturnAborted: name = "kIOReturnAborted"
        case Self.usbPipeStalled: name = "kIOUSBPipeStalled — the device refused the request"
        case Self.usbTransactionTimeout: name = "kIOUSBTransactionTimeout"
        default: break
        }
        return String(format: "%@ (domain %@, code 0x%08X%@)", ns.localizedDescription, ns.domain, UInt32(bitPattern: code), name.isEmpty ? "" : " " + name)
    }
}

/// Sends a job straight to the cutter's USB interface.
public struct USBDirectTransport: CutterTransport {
    public var vendorID: Int
    public var productID: Int
    public var interfaceNumber: Int?
    public var chunkSize: Int
    public var seize: Bool

    public init(vendorID: Int, productID: Int, interfaceNumber: Int? = nil, chunkSize: Int = 2048, seize: Bool = false) {
        self.vendorID = vendorID
        self.productID = productID
        self.interfaceNumber = interfaceNumber
        self.chunkSize = chunkSize
        self.seize = seize
    }

    public func send(_ data: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = try USBInterfaceSession.open(vendorID: vendorID, productID: productID, interfaceNumber: interfaceNumber, seize: seize)
        defer { session.close() }
        progress(0)
        let total = Double(max(data.count, 1))
        try session.write(data, chunkSize: chunkSize) { written, _, _ in
            try Task.checkCancellation()
            progress(Double(written) / total)
        }
        progress(1)
    }
}

// MARK: - Helpers

public enum HexDump {
    public static func lines(_ data: Data, limit: Int = 512) -> [String] {
        let bytes = [UInt8](data.prefix(limit))
        var out: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let row = bytes[start..<min(start + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            out.append(String(format: "%04X  ", start) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii)
        }
        if data.count > limit { out.append("… \(data.count - limit) more bytes") }
        return out
    }
}
