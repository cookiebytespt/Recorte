import SwiftUI
import TipKit

/// One-time tips (TipKit). At most one new tip per hour, each dismissed for good once closed or once
/// the user does what it suggests. Help ▸ Show Tips Again brings them back on the next launch.
enum RecorteTips {
    private static let resetKey = "resetTipsOnNextLaunch"

    /// Call once at launch, before any tip is shown.
    static func configure() {
        if UserDefaults.standard.bool(forKey: resetKey) {
            try? Tips.resetDatastore()
            UserDefaults.standard.removeObject(forKey: resetKey)
        }
        try? Tips.configure([.displayFrequency(.hourly)])
        // Keep SwiftUI previews free of tips.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            Tips.hideAllTipsForTesting()
        }
    }

    /// TipKit can only reset its store before it is configured, so the reset happens on the next launch.
    @MainActor
    static func showAgain() {
        UserDefaults.standard.set(true, forKey: resetKey)
        UserDefaults.standard.set(false, forKey: Preferences.hasSeenGettingStarted)
        let alert = NSAlert()
        alert.messageText = String(localized: "Tips will show again")
        alert.informativeText = String(localized: "The tips and the Getting Started window come back the next time you open Recorte.")
        alert.runModal()
    }
}

/// Sidebar, Print & Cut toggle: after a couple of projects without trying Print & Cut.
struct PrintAndCutTip: Tip {
    static let projectOpened = Event(id: "projectOpened")

    var title: Text { Text("Try Print & Cut") }
    var message: Text? { Text("Print your artwork with registration marks on any printer, then let the machine cut around it.") }
    var image: Image? { Image(systemName: "printer") }

    var rules: [Rule] {
        #Rule(Self.projectOpened) { $0.donations.count >= 2 }
    }
}

/// Printed image inspector: the first time an image is selected.
struct CreateContourTip: Tip {
    var title: Text { Text("Let Recorte draw the cut line") }
    var message: Text? { Text("Create Cut Contour traces a cut line around the image, a small distance away from it.") }
    var image: Image? { Image(systemName: "scissors") }
}

/// Output sheet, Test cut button: until a test cut has been made.
struct TestCutTip: Tip {
    var title: Text { Text("Try a test cut first") }
    var message: Text? { Text("With a new material or blade, cut a small test to check the pressure before the real job.") }
    var image: Image? { Image(systemName: "checkmark.seal") }
}

/// Lines section of imported artwork and cut contours: until points have been edited once.
struct EditPointsTip: Tip {
    var title: Text { Text("Fix the lines here") }
    var message: Text? { Text("Edit Points lets you move, add or remove points, for example to tidy an imported or traced line.") }
    var image: Image? { Image(systemName: "point.topleft.down.to.point.bottomright.curvepath") }
}
