import CutterCore
import SwiftUI

@main
struct RecorteApp: App {
    @State private var cutter = CutterController()

    init() {
        // Start with an empty canvas instead of the Open panel.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        Preferences.registerDefaults()
    }

    var body: some Scene {
        DocumentGroup(newDocument: DesignFileDocument()) { file in
            MainView(document: file.$document)
                .environment(cutter)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            EditorCommands()
        }

        Settings {
            SettingsView()
                .environment(cutter)
        }
    }
}
