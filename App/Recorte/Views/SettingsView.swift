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
    @AppStorage(Preferences.connectionKind) private var connectionKind = ConnectionKind.usb.rawValue
    @AppStorage(Preferences.serialPortPath) private var serialPortPath = ""
    @AppStorage(Preferences.showTroubleshooting) private var showTroubleshooting = false
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
                    Text("USB").tag(ConnectionKind.usb.rawValue)
                    Text("Serial port").tag(ConnectionKind.serial.rawValue)
                }
                .help("The Liyu connects over USB and needs no driver. Serial port is for other machines that show up as a serial device.")
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
                    LabeledContent("Machine") {
                        if let device = cutter.usbCutter {
                            Label(device.productName, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Text("Not found. Plug in the USB cable and switch the machine on.").foregroundStyle(.secondary)
                        }
                    }
                    .help("Recorte finds the machine on its own when it's plugged in and switched on.")
                }
                Button("Refresh") { cutter.refreshDevices() }
                    .help("Looks again for connected machines and ports.")
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
                Stepper(value: $markSize, in: RegistrationMarkLayout.minimumMarkSizeParameter...100, step: 5) {
                    LabeledContent("Mark size (cutter setting)", value: "\(markSize) = Ø \(String(format: "%.1f", Double(markSize) * 0.2)) mm")
                }
                .help(HelpText.machineMarkSize)
                Toggle("Send speed and pressure to the cutter", isOn: $sendSpeedAndForce)
                    .help("The starting value for new Output sessions. You can still change it for each job.")
                Text("Off (default): the machine uses the speed and pressure set on its panel. On: each job sends the values chosen in Output, like SignMaster with Cutting Speed and Cutting Force ticked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                Toggle("Show Cutter Troubleshooting in the Help menu", isOn: $showTroubleshooting)
                    .help("Adds tools that test the connection to the machine. Only needed if the machine doesn't respond, or when support asks for a log.")
                Text("Help ▸ Cutter Troubleshooting checks how the Mac sees the machine and can send small test jobs. It keeps a log you can send to support.")
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
