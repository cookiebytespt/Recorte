import SwiftUI

/// Help tags used by more than one view, so each sentence is written and translated once.
///
/// Writing rules (see the project's IN-APP-HELP plan): say what the control does, then when to change it,
/// and put the SignMaster name last ("In SignMaster: …"). Keep English under about 150 characters.
@MainActor
enum HelpText {
    // MARK: Files

    static let importFile: LocalizedStringKey = "Adds an SVG, PDF, Illustrator or DXF file as cut lines (⇧⌘I)."
    static let placeArtwork: LocalizedStringKey = "Adds a PDF, Illustrator, PNG or JPEG file to be printed on the Print & Cut sheet. Printed images are never cut (⌥⌘I)."

    // MARK: Print & Cut

    static let printAndCut: LocalizedStringKey = "Turns the canvas into the printed sheet. Recorte adds registration marks that the machine's camera finds, so the cut lines up with the print."
    static let createCutContour: LocalizedStringKey = "Makes a cut line around the printed images, a small distance away from them (⇧⌘K)."
    static let markSize: LocalizedStringKey = "Size of the printed circles the machine's camera looks for. Must match the mark size set on the machine: 25 prints Ø 5 mm circles. 25 is the smallest the machine can find."
    static let placeMarks: LocalizedStringKey = "Around the artwork uses less paper and vinyl. At the page edges keeps the marks in the same place on every sheet."
    static let markDistance: LocalizedStringKey = "Gap between the artwork and the marks to its left and right. 20.5 mm is SignMaster's Mark Position. A smaller gap fits more artwork, but the machine reads the marks best with nothing printed near them."
    static let markInset: LocalizedStringKey = "Distance from the edge of the page to the centre of the marks. Keep the marks inside the area your printer can print."
    static let printsMarks: LocalizedStringKey = "Turn off only if the sheet already has the marks printed on it."
    static let jobName: LocalizedStringKey = "Prints the project name above the marks, to tell the sheets apart. In SignMaster: Job Name."

    // MARK: Cutting

    static let sendSpeedAndPressure: LocalizedStringKey = "Off: the machine uses the speed and pressure set on its panel. On: Recorte sends the values below with each job. In SignMaster: Cutting Speed / Cutting Force ticked."
    static let speed: LocalizedStringKey = "How fast the knife moves, in millimetres per second. Go slower for small details and thick material."
    static let pressure: LocalizedStringKey = "How hard the knife presses, in grams. Too little leaves the vinyl uncut, too much cuts the backing. Check with a test cut."
    static let bladeOffset: LocalizedStringKey = "How far the blade tip trails behind the centre of the holder. Recorte adds small loops at corners so they come out sharp."
    static let overcut: LocalizedStringKey = "The knife carries on this far past the start of a closed shape, so the ends meet cleanly."
    static let material: LocalizedStringKey = "Sets a starting speed and pressure for the material. Fine-tune them with a test cut."
    static let testCut: LocalizedStringKey = "Cuts a small square and circle, to check the blade depth and pressure before the real job."
    static let machineMarkSize: LocalizedStringKey = "The mark size set on the machine. New Print & Cut projects start with it."
}
