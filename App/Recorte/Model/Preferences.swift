import CutterCore
import Foundation

/// Keys for `UserDefaults` / `@AppStorage`.
enum Preferences {
    static let connectionKind = "connectionKind"
    static let hasSeenGettingStarted = "hasSeenGettingStarted"
    static let serialPortPath = "serialPortPath"
    static let printerQueue = "printerQueue"
    static let baudRate = "baudRate"
    static let flowControl = "flowControl"
    static let stepsPerMM = "stepsPerMM"
    static let cutWidthMM = "cutWidthMM"
    static let bladeOffsetMM = "bladeOffsetMM"
    static let overcutMM = "overcutMM"
    static let sendSpeedAndForce = "sendSpeedAndForce"
    static let unitlessDPI = "unitlessDPI"
    static let curveTolerance = "curveTolerance"
    static let markSize = "registrationMarkSize"

    static func registerDefaults() {
        let m = MachineProfile.liyuGF1261
        UserDefaults.standard.register(defaults: [
            connectionKind: ConnectionKind.printerQueue.rawValue,
            baudRate: m.baudRate,
            flowControl: m.flowControl.rawValue,
            stepsPerMM: m.stepsPerMM,
            cutWidthMM: m.cutWidthMM,
            bladeOffsetMM: m.bladeOffsetMM,
            overcutMM: m.overcutMM,
            sendSpeedAndForce: m.sendsSpeedAndForce,
            markSize: m.registrationMarkSize,
            unitlessDPI: 72.0,
            curveTolerance: 0.1,
        ])
    }

    static func importOptions() -> ImportOptions {
        registerDefaults()
        let d = UserDefaults.standard
        return ImportOptions(tolerance: d.double(forKey: curveTolerance), unitlessDPI: d.double(forKey: unitlessDPI))
    }

    /// The machine profile as configured by the user.
    static func machineProfile() -> MachineProfile {
        registerDefaults()
        let d = UserDefaults.standard
        var m = MachineProfile.liyuGF1261
        m.baudRate = d.integer(forKey: baudRate)
        m.flowControl = FlowControl(rawValue: d.string(forKey: flowControl) ?? "") ?? m.flowControl
        m.stepsPerMM = d.double(forKey: stepsPerMM)
        m.cutWidthMM = d.double(forKey: cutWidthMM)
        m.bladeOffsetMM = d.double(forKey: bladeOffsetMM)
        m.overcutMM = d.double(forKey: overcutMM)
        m.sendsSpeedAndForce = d.bool(forKey: sendSpeedAndForce)
        m.registrationMarkSize = max(1, d.integer(forKey: markSize))
        return m
    }
}
