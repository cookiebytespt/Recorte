import Foundation

public enum FlowControl: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case hardware
    case software
}

public enum ConnectionKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// USB-serial adapter (shows up as /dev/cu.usbserial-… or similar).
    case serial
    /// USB printer-class device, driven through a raw CUPS queue.
    case printerQueue
}

public struct MachineProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Width of the media the machine accepts, in millimetres.
    public var mediaWidthMM: Double
    /// Usable cutting width, in millimetres.
    public var cutWidthMM: Double
    public var stepsPerMM: Double
    public var baudRate: Int
    public var flowControl: FlowControl
    public var defaultSpeed: Int
    public var defaultForce: Int
    public var bladeOffsetMM: Double
    public var overcutMM: Double
    public var sendsSpeedAndForce: Bool
    /// USB identity when the machine enumerates as a USB printer (Liyu: STM32 0483:5750).
    public var usbVendorID: Int?
    public var usbProductID: Int?
    /// SignMaster "mark size" value sent in the TB command (25 → Ø5 mm printed circles).
    public var registrationMarkSize: Int

    public init(id: String, name: String, mediaWidthMM: Double, cutWidthMM: Double, stepsPerMM: Double = 40,
                baudRate: Int = 9600, flowControl: FlowControl = .hardware, defaultSpeed: Int = 30,
                defaultForce: Int = 80, bladeOffsetMM: Double = 0.25, overcutMM: Double = 1.0, sendsSpeedAndForce: Bool = true,
                usbVendorID: Int? = nil, usbProductID: Int? = nil, registrationMarkSize: Int = 25) {
        self.id = id
        self.name = name
        self.mediaWidthMM = mediaWidthMM
        self.cutWidthMM = cutWidthMM
        self.stepsPerMM = stepsPerMM
        self.baudRate = baudRate
        self.flowControl = flowControl
        self.defaultSpeed = defaultSpeed
        self.defaultForce = defaultForce
        self.bladeOffsetMM = bladeOffsetMM
        self.overcutMM = overcutMM
        self.sendsSpeedAndForce = sendsSpeedAndForce
        self.usbVendorID = usbVendorID
        self.usbProductID = usbProductID
        self.registrationMarkSize = registrationMarkSize
    }

    /// Liyu GF-1261: 1260 mm media, roughly 1200 mm cutting width. Connects as a USB printer.
    public static let liyuGF1261 = MachineProfile(
        id: "liyu-gf-1261",
        name: "Liyu GF-1261",
        mediaWidthMM: 1260,
        cutWidthMM: 1200,
        usbVendorID: 0x0483,
        usbProductID: 0x5750
    )

    public static let presets: [MachineProfile] = [.liyuGF1261]
    public static let supportedBaudRates = [9600, 19200, 38400, 57600, 115200]
}

/// Speed/force presets so designers pick a material instead of numbers.
public struct MaterialPreset: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    /// Localization key for the display name.
    public var nameKey: String
    public var speed: Int
    public var force: Int

    public init(id: String, nameKey: String, speed: Int, force: Int) {
        self.id = id
        self.nameKey = nameKey
        self.speed = speed
        self.force = force
    }

    public static let standardVinyl = MaterialPreset(id: "vinyl", nameKey: "material.vinyl", speed: 30, force: 80)
    public static let thickVinyl = MaterialPreset(id: "thick-vinyl", nameKey: "material.thickVinyl", speed: 20, force: 120)
    public static let heatTransfer = MaterialPreset(id: "htv", nameKey: "material.heatTransfer", speed: 25, force: 90)
    public static let flock = MaterialPreset(id: "flock", nameKey: "material.flock", speed: 15, force: 150)
    public static let cardstock = MaterialPreset(id: "cardstock", nameKey: "material.cardstock", speed: 15, force: 140)
    public static let reflective = MaterialPreset(id: "reflective", nameKey: "material.reflective", speed: 15, force: 160)
    public static let custom = MaterialPreset(id: "custom", nameKey: "material.custom", speed: 30, force: 80)

    public static let all: [MaterialPreset] = [.standardVinyl, .thickVinyl, .heatTransfer, .flock, .cardstock, .reflective, .custom]
}
