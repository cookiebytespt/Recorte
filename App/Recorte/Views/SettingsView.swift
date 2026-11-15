import CutterCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            CutterSettingsView()
                .tabItem { Label("Cutter", systemImage: "scissors") }
            ImportSettingsView()
                .tabItem { Label("Files", systemImage: "doc") }
        }
        .frame(width: 480)
        .padding()
    }
}

struct CutterSettingsView: View {
    @Environment(CutterController.self) private var cutter
    @AppStorage(Preferences.connectionKind) private var connectionKind = ConnectionKind.serial.rawValue
    @AppStorage(Preferences.serialPortPath) private var serialPortPath = ""
    @AppStorage(Preferences.printerQueue) private var printerQueue = ""
    @AppStorage(Preferences.baudRate) private var baudRate = MachineProfile.liyuGF1261.baudRate
    @AppStorage(Preferences.flowControl) private var flowControl = MachineProfile.liyuGF1261.flowControl.rawValue
    @AppStorage(Preferences.stepsPerMM) private var stepsPerMM = MachineProfile.liyuGF1261.stepsPerMM
    @AppStorage(Preferences.cutWidthMM) private var cutWidthMM = MachineProfile.liyuGF1261.cutWidthMM
    @AppStorage(Preferences.bladeOffsetMM) private var bladeOffsetMM = MachineProfile.liyuGF1261.bladeOffsetMM
    @AppStorage(Preferences.overcutMM) private var overcutMM = MachineProfile.liyuGF1261.overcutMM
    @AppStorage(Preferences.sendSpeedAndForce) private var sendSpeedAndForce = false
    @AppStorage(Preferences.markSize) private var markSize = MachineProfile.liyuGF1261.registrationMarkSize

    var body: some View {
        Form {
            Section("Connection") {
                Picker("Connected as", selection: $connectionKind) {
                    Text("USB / serial port").tag(ConnectionKind.serial.rawValue)
                    Text("Printer queue").tag(ConnectionKind.printerQueue.rawValue)
                }
                if connectionKind == ConnectionKind.serial.rawValue {
                    Picker("Port", selection: $serialPortPath) {
                        Text("None").tag("")
                        ForEach(cutter.availablePorts) { port in
                            Text(port.displayName).tag(port.path)
                        }
                    }
                    Picker("Speed (baud)", selection: $baudRate) {
                        ForEach(MachineProfile.supportedBaudRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Flow control", selection: $flowControl) {
                        Text("Hardware (RTS/CTS)").tag(FlowControl.hardware.rawValue)
                        Text("Software (XON/XOFF)").tag(FlowControl.software.rawValue)
                        Text("None").tag(FlowControl.none.rawValue)
                    }
                } else {
                    Picker("Queue", selection: $printerQueue) {
                        Text("None").tag("")
                        ForEach(cutter.availableQueues, id: \.self) { Text($0).tag($0) }
                    }
                    if let device = cutter.cutterNeedingQueue, cutter.availableQueues.isEmpty || printerQueue.isEmpty {
                        LabeledContent("Found on USB", value: device.description)
                        Button("Set up the cutter") { cutter.createQueue(for: device) }
                        Text("Creates a raw print queue for the cutter. No driver is needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error = cutter.setupError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Button("Refresh") { cutter.refreshDevices() }
            }
            Section("Machine") {
                LabeledContent("Model", value: MachineProfile.liyuGF1261.name)
                TextField("Cutting width (mm)", value: $cutWidthMM, format: .number)
                TextField("Steps per mm", value: $stepsPerMM, format: .number)
                TextField("Default blade offset (mm)", value: $bladeOffsetMM, format: .number.precision(.fractionLength(2)))
                TextField("Default overcut (mm)", value: $overcutMM, format: .number.precision(.fractionLength(1)))
                Stepper(value: $markSize, in: 5...100, step: 5) {
                    LabeledContent("Mark size (cutter setting)", value: "\(markSize) = Ø \(String(format: "%.1f", Double(markSize) * 0.2)) mm")
                }
                Toggle("Send speed and pressure to the cutter", isOn: $sendSpeedAndForce)
                Text("Off (default): the machine uses the speed and pressure set on its panel. On: each job sends the values chosen in Output, like SignMaster with Cutting Speed and Cutting Force ticked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ImportSettingsView: View {
    @AppStorage(Preferences.unitlessDPI) private var unitlessDPI = 72.0
    @AppStorage(Preferences.curveTolerance) private var curveTolerance = 0.1

    var body: some View {
        Form {
            Section("SVG files") {
                Picker("Size of SVG files without units", selection: $unitlessDPI) {
                    Text("Illustrator (72 per inch)").tag(72.0)
                    Text("Web standard (96 per inch)").tag(96.0)
                }
                Text("Illustrator and most design apps export at 72. If an SVG comes in too large or too small, try the other option.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Curves") {
                Picker("Curve smoothness", selection: $curveTolerance) {
                    Text("Fine").tag(0.05)
                    Text("Normal").tag(0.1)
                    Text("Coarse").tag(0.25)
                }
            }
            Text("Changes apply to files opened from now on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
