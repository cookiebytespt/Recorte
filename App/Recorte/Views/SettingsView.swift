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
                .help("The Liyu connects as a printer queue. USB / serial port is for other machines that show up as a serial device.")
                if connectionKind == ConnectionKind.serial.rawValue {
                    Picker("Port", selection: $serialPortPath) {
                        Text("None").tag("")
                        ForEach(cutter.availablePorts) { port in
                            Text(port.displayName).tag(port.path)
                        }
                    }
                    .help("The serial port the machine is connected to.")
                    Picker("Speed (baud)", selection: $baudRate) {
                        ForEach(MachineProfile.supportedBaudRates, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .help("Must match the speed set on the machine. See its manual.")
                    Picker("Flow control", selection: $flowControl) {
                        Text("Hardware (RTS/CTS)").tag(FlowControl.hardware.rawValue)
                        Text("Software (XON/XOFF)").tag(FlowControl.software.rawValue)
                        Text("None").tag(FlowControl.none.rawValue)
                    }
                    .help("How the machine tells the Mac to wait while it cuts. Must match the machine's setting.")
                } else {
                    Picker("Queue", selection: $printerQueue) {
                        Text("None").tag("")
                        ForEach(cutter.availableQueues, id: \.self) { Text($0).tag($0) }
                    }
                    .help("The printer queue that sends jobs to the machine. Recorte names it Recorte_Liyu when it sets the machine up.")
                    if let device = cutter.cutterNeedingQueue, cutter.availableQueues.isEmpty || printerQueue.isEmpty {
                        LabeledContent("Found on USB", value: device.description)
                        Button("Set up the cutter") { cutter.createQueue(for: device) }
                            .help(HelpText.setUpMachine)
                        Text("Creates a raw print queue for the cutter. No driver is needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error = cutter.setupError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                Button("Refresh") { cutter.refreshDevices() }
                    .help("Looks again for connected machines, ports and queues.")
            }
            Section("Machine") {
                LabeledContent("Model", value: MachineProfile.liyuGF1261.name)
                TextField("Cutting width (mm)", value: $cutWidthMM, format: .number)
                    .help("The widest the machine can cut. Recorte warns when a design is wider.")
                TextField("Steps per mm", value: $stepsPerMM, format: .number)
                    .help("Machine units per millimetre. Leave it at 40 for the Liyu; a wrong value cuts everything at the wrong size.")
                TextField("Default blade offset (mm)", value: $bladeOffsetMM, format: .number.precision(.fractionLength(2)))
                    .help(HelpText.bladeOffset)
                TextField("Default overcut (mm)", value: $overcutMM, format: .number.precision(.fractionLength(1)))
                    .help(HelpText.overcut)
                Text("Check the blade offset and pressure with a test cut (in the Output sheet) when you change the blade or the material.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Stepper(value: $markSize, in: 5...100, step: 5) {
                    LabeledContent("Mark size (cutter setting)", value: "\(markSize) = Ø \(String(format: "%.1f", Double(markSize) * 0.2)) mm")
                }
                .help(HelpText.machineMarkSize)
                Toggle("Send speed and pressure to the cutter", isOn: $sendSpeedAndForce)
                    .help("The starting value for new Output sessions. You can still change it for each job.")
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
                .help("Some SVG files give sizes without units. This decides how big they come in.")
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
                .help("How closely imported curves are followed. Fine is more exact but has more points; Coarse cuts faster.")
            }
            Text("Changes apply to files opened from now on.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
