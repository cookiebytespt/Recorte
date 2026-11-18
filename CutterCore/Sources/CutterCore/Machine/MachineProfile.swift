import Foundation

public enum FlowControl: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case hardware
    case software
}

public enum ConnectionKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// The cutter's own USB interface, found by vendor/product ID (the Liyu).
    case usb
    /// USB-serial adapter (shows up as /dev/cu.usbserial-… or similar), for other HPGL cutters.
    case serial
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
    /// Cutting speed in mm/s (sent as `VS`).
    public var defaultSpeed: Int
    /// Cutting pressure in grams (sent as `HS`).
    public var defaultForce: Int
    public var bladeOffsetMM: Double
    public var overcutMM: Double
    /// Off by default, like SignMaster: the machine's own panel settings apply.
    public var sendsSpeedAndForce: Bool
    /// USB identity when the machine enumerates as a USB printer (Liyu: STM32 0483:5750).
    public var usbVendorID: Int?
    public var usbProductID: Int?
    /// SignMaster "mark size" value sent in the TB command (25 → Ø5 mm printed circles).
    public var registrationMarkSize: Int

    public init(id: String, name: String, mediaWidthMM: Double, cutWidthMM: Double, stepsPerMM: Double = 40,
                baudRate: Int = 9600, flowControl: FlowControl = .hardware, defaultSpeed: Int = 200,
                defaultForce: Int = 70, bladeOffsetMM: Double = 0.25, overcutMM: Double = 1.0, sendsSpeedAndForce: Bool = false,
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

    /// Liyu GF-1261: 1260 mm media, roughly 1200 mm cutting width. Connects over USB (printer class, no driver).
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
    /// mm/s (SignMaster's units; was cm/s before 2026-11-15, values ×10).
    public var speed: Int
    /// grams
    public var force: Int

    public init(id: String, nameKey: String, speed: Int, force: Int) {
        self.id = id
        self.nameKey = nameKey
        self.speed = speed
        self.force = force
    }

    public static let standardVinyl = MaterialPreset(id: "vinyl", nameKey: "material.vinyl", speed: 300, force: 80)
    public static let thickVinyl = MaterialPreset(id: "thick-vinyl", nameKey: "material.thickVinyl", speed: 200, force: 120)
    public static let heatTransfer = MaterialPreset(id: "htv", nameKey: "material.heatTransfer", speed: 250, force: 90)
    public static let flock = MaterialPreset(id: "flock", nameKey: "material.flock", speed: 150, force: 150)
    public static let cardstock = MaterialPreset(id: "cardstock", nameKey: "material.cardstock", speed: 150, force: 140)
    public static let reflective = MaterialPreset(id: "reflective", nameKey: "material.reflective", speed: 150, force: 160)
    public static let custom = MaterialPreset(id: "custom", nameKey: "material.custom", speed: 300, force: 80)

    public static let all: [MaterialPreset] = [.standardVinyl, .thickVinyl, .heatTransfer, .flock, .cardstock, .reflective, .custom]
}
