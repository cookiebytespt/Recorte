import SwiftUI

enum HelpLinks {
    /// The README is the help page until there is one on cookiebytes.pt.
    static let readme = URL(string: "https://github.com/cookiebytespt/Recorte#readme")!
    static let newIssue = URL(string: "https://github.com/cookiebytespt/Recorte/issues/new")!
}

enum HelpWindowID {
    static let gettingStarted = "getting-started"
    static let shortcuts = "keyboard-shortcuts"
}

/// Welcome window: opens by itself on the first launch, and from Help ▸ Getting Started.
struct GettingStartedView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let steps: [Step] = [
        Step(id: 1, symbol: "cable.connector", title: "Connect the machine",
             text: "Plug the cutter in with the USB cable and switch it on. The first time, Recorte offers to set it up; this is only needed once."),
        Step(id: 2, symbol: "pencil.and.outline", title: "Draw or bring in your design",
             text: "Draw shapes and write text on the canvas, import cut lines (SVG, PDF, Illustrator, DXF), or place artwork to print."),
        Step(id: 3, symbol: "printer", title: "Choose Cut or Print & Cut",
             text: "Cut only cuts shapes out of plain vinyl. Print & Cut prints your artwork with registration marks, then cuts around it. Press ⌘P when you're ready."),
        Step(id: 4, symbol: "scissors", title: "Load the machine and cut",
             text: "Recorte shows how to load the vinyl or the printed sheet and where to put the blade. With a new material, make a test cut first."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Recorte").font(.title2).fontWeight(.semibold)
                    Text("From design to cut sticker in four steps.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.15))
                            Image(systemName: step.symbol).foregroundStyle(Color.accentColor)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).fontWeight(.semibold)
                            Text(step.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Hover over any setting to see what it does, or click ⓘ for more. Open this window again from Help ▸ Getting Started.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Recorte Help") { openURL(HelpLinks.readme) }
                    .help("Opens the Recorte guide in your browser.")
                Spacer()
                Button("Start") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// Help ▸ Keyboard Shortcuts.
struct ShortcutsView: View {
    private let groups: [(LocalizedStringKey, [(String, LocalizedStringKey)])] = [
        ("Tools", [
            ("V", "Select"), ("H", "Pan"), ("R", "Rectangle"), ("E", "Ellipse"), ("L", "Line"),
            ("G", "Polygon"), ("S", "Star"), ("P", "Freehand"), ("T", "Text"),
            ("⇧", "While drawing: keep proportions"), ("Esc", "Back to the Select tool"),
        ]),
        ("Objects", [
            ("⌘D", "Duplicate"), ("⌫", "Delete"), ("← → ↑ ↓", "Move 1 mm"), ("⌘]", "Bring to Front"),
            ("⌘[", "Send to Back"), ("⇧⌘A", "Select All Objects"), ("⌘Z / ⇧⌘Z", "Undo / Redo"),
            ("↩", "Edit points of the selected lines"), ("Esc", "Stop editing points"),
        ]),
        ("Files and output", [
            ("⇧⌘I", "Import Artwork…"), ("⌥⌘I", "Place Artwork…"), ("⇧⌘K", "Create Cut Contour…"), ("⌘P", "Cut… / Print & Cut…"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups.indices, id: \.self) { index in
                    let group = groups[index]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.0).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                            ForEach(group.1.indices, id: \.self) { row in
                                GridRow {
                                    Text(verbatim: group.1[row].0)
                                        .font(.body.monospaced())
                                        .frame(minWidth: 90, alignment: .leading)
                                    Text(group.1[row].1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 560)
    }
}

/// The Help menu.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Recorte Help") { openURL(HelpLinks.readme) }
                .keyboardShortcut("?", modifiers: [.command])
            Button("Getting Started") { openWindow(id: HelpWindowID.gettingStarted) }
            Button("Keyboard Shortcuts") { openWindow(id: HelpWindowID.shortcuts) }
            Divider()
            Button("Show Tips Again") { RecorteTips.showAgain() }
            Divider()
            Button("Report a Problem…") { openURL(HelpLinks.newIssue) }
        }
    }
}

#Preview("Getting Started") { GettingStartedView() }
#Preview("Keyboard Shortcuts") { ShortcutsView() }
