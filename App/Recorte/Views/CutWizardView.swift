import CutterCore
import SwiftUI

/// Step-by-step cutting, shown on the Output sheet after printing (SignMaster: Re-print / Cut / Done).
///
/// Print & Cut: Load the sheet → Sending → How did it go? (Cut finished / Marks not found) → Done.
/// Cut only: Load the vinyl → Cutting → Done.
/// Recorte sends one job; the machine reads the marks and cuts on its own, so "marks found?" is asked
/// after the job rather than before cutting.
struct CutWizardView: View {
    enum Step: Equatable {
        case load, sending, result, notFound, done
        case failed(String)
    }

    let session: CutSession
    var onBack: () -> Void
    var onPrintAnother: () -> Void
    var onClose: () -> Void

    @Environment(CutterController.self) private var cutter
    @State private var step: Step = .load
    /// Print & Cut: which sheet of `session.copies` is being cut (1-based).
    @State private var sheetNumber = 1

    private var printAndCut: Bool { session.isPrintAndCut }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .frame(height: 52)
            Divider()
            content
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
                .padding(.horizontal, 16)
                .frame(height: 52)
        }
        .frame(width: 680, height: 600)
        .onChange(of: cutter.status) { _, status in
            guard step == .sending else { return }
            switch status {
            case .finished:
                cutter.dismissStatus()
                step = printAndCut ? .result : .done
            case .failed(let message):
                cutter.dismissStatus()
                step = .failed(message)
            default:
                break
            }
        }
    }

    // MARK: Header

    private var stepIndicator: some View {
        let labels: [LocalizedStringKey] = printAndCut ? ["Print", "Load", "Cut", "Done"] : ["Load", "Cut", "Done"]
        let current: Int = {
            switch step {
            case .load: return printAndCut ? 1 : 0
            case .sending, .result, .notFound, .failed: return printAndCut ? 2 : 1
            case .done: return printAndCut ? 3 : 2
            }
        }()
        return HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(index == current ? Color.accentColor : (index < current ? Color.secondary.opacity(0.25) : Color.clear))
                        Circle().strokeBorder(index > current ? Color.secondary.opacity(0.5) : .clear)
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        } else {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index == current ? .white : .secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(label)
                        .fontWeight(index == current ? .semibold : .regular)
                        .foregroundStyle(index == current ? .primary : .secondary)
                    if index < labels.count - 1 {
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 28, height: 1).padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .load:
            VStack(alignment: .leading, spacing: 14) {
                MachineIllustration(kind: printAndCut ? .sheet(title: session.design.name) : .vinyl(width: session.job.sizeMM.width, height: session.job.sizeMM.height))
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if printAndCut { loadSheetSteps } else { loadVinylSteps }
                Form { OutputIssues(session: session, showsJobIssues: false) }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(maxHeight: cutter.hasDevice ? 0 : 130)
                    .opacity(cutter.hasDevice ? 0 : 1)
            }
        case .sending:
            sending
        case .result:
            result
        case .notFound:
            notFound
        case .done:
            done
        case .failed(let message):
            centred {
                Image(systemName: "xmark.octagon.fill").font(.system(size: 40)).foregroundStyle(.red)
                Text("Could not send to the machine").font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
    }

    private var loadSheetSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if session.copies > 1 { Text("Load printed sheet \(sheetNumber) of \(session.copies)") } else { Text("Load the printed sheet") }
            }
            .font(.title3.weight(.semibold))
            numbered(1, "Put the sheet in printed side up, **turned round so the arrow mark is at the front, on the right**.")
            numbered(2, "Lower the pinch rollers and press **Pause** on the machine.")
            numbered(3, "With the arrows on the panel, move the blade over **the arrow mark** (front right), then press **Origin**.")
            numbered(4, "Press **Next**. The machine finds the four marks, then cuts.")
        }
    }

    private var loadVinylSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Load the vinyl").font(.title3.weight(.semibold))
            numbered(1, "Load the vinyl so **its front edge is just past the blade**, then lower the pinch rollers.")
            numbered(2, "Move the blade to **the front right corner of the vinyl**, where the cut starts.")
            numbered(3, "Press **Origin** on the machine.")
            numbered(4, "Press **Cut**.")
        }
    }

    private func numbered(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sending: some View {
        centred {
            SheetGlyph(marks: printAndCut)
                .frame(width: 150, height: 190)
            Text(printAndCut ? "Reading the marks and cutting" : "Cutting").font(.title3.weight(.semibold))
            Text(printAndCut ? "The machine visits the four marks, then cuts. Keep your hands clear while it moves."
                             : "Keep your hands clear while the machine moves.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            VStack(spacing: 6) {
                ProgressView(value: progress)
                Text("Sending to the machine… \(Int(progress * 100)) %").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 320)
        }
    }

    private var progress: Double {
        if case .sending(let p) = cutter.status { return p }
        return 0
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("Sent to the machine").font(.title3.weight(.semibold))
                Text("Watch the head: it visits the four marks, then cuts. If it stops or beeps before cutting, it didn't find the marks.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("How did it go?").fontWeight(.semibold)
            HStack(spacing: 12) {
                choiceButton("Cut finished", "Unload the sheet", symbol: "checkmark.circle.fill", tint: .green) { step = .done }
                choiceButton("Marks not found", "Fix it and try again, no reprint", symbol: "exclamationmark.triangle.fill", tint: .orange) { step = .notFound }
            }
            Spacer()
        }
    }

    private func choiceButton(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, symbol: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var notFound: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The machine didn't find the marks").font(.title3.weight(.semibold))
                    Text("Nothing was cut. Check these, then try again with the same sheet.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                checkRow(1, "**The sheet is straight**, printed side up, the arrow mark at the front right.")
                Divider()
                checkRow(2, "**The blade was on the arrow mark** (front right) when you pressed Origin.")
                Divider()
                checkRow(3, "**The marks are solid black**, not faded, and not under a pinch roller or tape.")
                Divider()
                checkRow(4, "**The sheet was printed at 100 %** with mark size \(session.design.printAndCut.layout.markSizeParameter) (Ø \(Int(session.design.printAndCut.layout.markDiameterMM.rounded())) mm).")
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }

    private func checkRow(_ n: Int, _ text: LocalizedStringKey) -> some View {
        numbered(n, text).padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var done: some View {
        centred {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(.green)
            Text("Cut finished").font(.title3.weight(.semibold))
            Text(printAndCut ? "Unload the sheet." : "Unload the vinyl.").foregroundStyle(.secondary)
            if printAndCut {
                if session.copies > 1 {
                    Text("Sheet \(sheetNumber) of \(session.copies) done.").foregroundStyle(.secondary)
                }
                Text("To cut the same design again, load another printed sheet and choose Cut another copy. Recorte sends the same job.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 420)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.background))
            }
        }
    }

    private func centred<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 14) { content() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Text(footNote).font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch step {
            case .load:
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Back", action: onBack)
                Button(printAndCut ? "Next" : "Cut", action: send)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!cutter.hasDevice || cutter.isSending || session.hasBlockingIssue)
            case .sending:
                Button("Stop", role: .destructive) { cutter.cancel(); step = .load }
            case .result:
                Button("Close", action: onClose)
            case .notFound:
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Reprint sheet…", action: onPrintAnother)
                Button("Try again") { step = .load }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .done:
                if printAndCut {
                    Button("Print another sheet…", action: onPrintAnother)
                    if sheetNumber < session.copies {
                        Button("Done", action: onClose)
                        Button("Next sheet") { sheetNumber += 1; step = .load }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cut another copy") { sheetNumber += 1; step = .load }
                        Button("Done", action: onClose)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Cut again") { step = .load }
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .failed:
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Back") { step = .load }
                Button("Try again", action: send).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var footNote: String {
        switch step {
        case .load:
            if printAndCut {
                let layout = session.design.printAndCut.layout
                return String(format: String(localized: "Mark size %d · Ø %.0f mm"), layout.markSizeParameter, layout.markDiameterMM)
            }
            return String(format: String(localized: "Needs %.0f mm of the %.0f mm cutting width"),
                          session.job.bounds.width + session.settings.marginX, session.machine.cutWidthMM)
        case .result: return String(localized: "Try again resends the same job.")
        case .notFound: return String(localized: "Reprint only if the marks are damaged.")
        case .done:
            let length = String(format: "%.1f m", session.job.cutLength / 1000)
            return String(localized: "\(session.job.cutPaths.count) shapes · \(length)")
        case .sending, .failed: return ""
        }
    }

    private func send() {
        guard cutter.hasDevice, !cutter.isSending else { return }
        step = .sending
        cutter.send(hpgl: session.job.hpgl)
    }
}

// MARK: - Illustrations

/// Top view of the Liyu with the sheet (or vinyl) loaded, user at the front.
/// Blade carriage and screen on the right; the origin is the front right, by the blade.
struct MachineIllustration: View {
    enum Kind {
        case sheet(title: String)
        case vinyl(width: Double, height: Double)
    }

    let kind: Kind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { ctx, size in
            // Drawn in a 600 × 190 space, scaled to fit.
            let k = min(size.width / 600, size.height / 190)
            ctx.translateBy(x: (size.width - 600 * k) / 2, y: (size.height - 190 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            let accent = Color.accentColor
            let well = colorScheme == .dark ? Color(white: 0.11) : Color(white: 0.88)
            ctx.fill(Path(CGRect(x: -400, y: -100, width: 1400, height: 400)), with: .color(well))

            // Media behind the beam.
            switch kind {
            case .sheet(let title):
                let paper = CGRect(x: 170, y: -10, width: 260, height: 130)
                ctx.fill(Path(paper), with: .color(.white))
                ctx.stroke(Path(paper), with: .color(Color(white: 0.73)), lineWidth: 1)
                for (x, c) in [(245.0, Color(red: 0.96, green: 0.79, blue: 0.72)), (355.0, Color(red: 0.75, green: 0.89, blue: 0.86))] {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 22, y: 10, width: 44, height: 44)), with: .color(c))
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - 25, y: 7, width: 50, height: 50)), with: .color(accent), lineWidth: 1.2)
                }
                // The job name reads upside down: the sheet is turned round.
                var t = ctx
                t.translateBy(x: 300, y: 113)
                t.rotate(by: .degrees(180))
                t.draw(Text(title).font(.system(size: 8)).foregroundStyle(.black), at: .zero)
            case .vinyl(let w, let h):
                let vinyl = CGRect(x: 80, y: -10, width: 440, height: 122)
                ctx.fill(Path(vinyl), with: .color(Color(red: 0.96, green: 0.95, blue: 0.93)))
                ctx.stroke(Path(vinyl), with: .color(Color(white: 0.73)), lineWidth: 1)
                let design = CGRect(x: 352, y: 8, width: 120, height: 48)
                ctx.stroke(Path(roundedRect: design, cornerRadius: 8), with: .color(accent), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                ctx.draw(Text(String(format: String(localized: "Design: %.0f × %.0f mm"), w, h)).font(.system(size: 11)).foregroundStyle(Color(white: 0.37)),
                         at: CGPoint(x: 340, y: 32), anchor: .trailing)
            }

            // Machine: beam, end caps, screen and buttons on the right.
            ctx.fill(Path(roundedRect: CGRect(x: 20, y: 64, width: 560, height: 32), cornerRadius: 8), with: .color(Color(white: 0.23)))
            ctx.fill(Path(roundedRect: CGRect(x: 20, y: 56, width: 44, height: 48), cornerRadius: 8), with: .color(Color(white: 0.17)))
            ctx.fill(Path(roundedRect: CGRect(x: 500, y: 52, width: 80, height: 56), cornerRadius: 8), with: .color(Color(white: 0.17)))
            ctx.fill(Path(roundedRect: CGRect(x: 512, y: 60, width: 56, height: 22), cornerRadius: 3), with: .color(Color(red: 0.44, green: 0.72, blue: 0.85)))
            for x in [520.0, 534, 548, 562] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 90, width: 8, height: 8)), with: .color(Color(white: 0.56)))
            }
            ctx.draw(Text(verbatim: "LIYU GF-1261").font(.system(size: 12)).tracking(2).foregroundStyle(Color(white: 0.79)), at: CGPoint(x: 270, y: 80))
            ctx.draw(Text("Screen").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: 540, y: 124))
            ctx.draw(Text("Front (you)").font(.system(size: 11)).foregroundStyle(.secondary), at: CGPoint(x: 300, y: 180))

            let bladeX: Double
            let label: Text
            switch kind {
            case .sheet:
                bladeX = 418
                label = Text("Blade on this mark")
                // Front marks of the sheet; the arrow mark is the right one.
                for x in [182.0, 418] {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: 100, width: 8, height: 8)), with: .color(.black))
                }
                var arrow = Path()
                arrow.move(to: CGPoint(x: 402, y: 100)); arrow.addLine(to: CGPoint(x: 406, y: 107)); arrow.addLine(to: CGPoint(x: 410, y: 100))
                ctx.stroke(arrow, with: .color(.black), lineWidth: 1.2)
                for x in [164.0, 424] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 92, width: 12, height: 9), cornerRadius: 2), with: .color(Color(white: 0.11)))
                }
            case .vinyl:
                bladeX = 480
                label = Text("Origin")
                for x in [74.0, 474] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 92, width: 12, height: 9), cornerRadius: 2), with: .color(Color(white: 0.11)))
                }
            }

            // Blade carriage over the origin, with a callout.
            let carriage = CGRect(x: bladeX - 16, y: 74, width: 32, height: 40)
            ctx.fill(Path(roundedRect: carriage, cornerRadius: 5), with: .color(Color(white: 0.95).opacity(0.9)))
            ctx.stroke(Path(roundedRect: carriage, cornerRadius: 5), with: .color(Color(white: 0.43)), lineWidth: 1)
            var cross = Path()
            cross.move(to: CGPoint(x: bladeX - 6, y: 104)); cross.addLine(to: CGPoint(x: bladeX + 6, y: 104))
            cross.move(to: CGPoint(x: bladeX, y: 98)); cross.addLine(to: CGPoint(x: bladeX, y: 110))
            ctx.stroke(cross, with: .color(accent), lineWidth: 1.5)
            ctx.stroke(Path(ellipseIn: CGRect(x: bladeX - 13, y: 91, width: 26, height: 26)), with: .color(accent), lineWidth: 2.5)
            let pillCenter = CGPoint(x: bladeX - 90, y: 147)
            var leader = Path()
            leader.move(to: CGPoint(x: bladeX - 6, y: 116)); leader.addLine(to: CGPoint(x: pillCenter.x + 30, y: 138))
            ctx.stroke(leader, with: .color(accent), lineWidth: 1.5)
            let resolved = ctx.resolve(label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
            let textSize = resolved.measure(in: CGSize(width: 300, height: 40))
            let pill = CGRect(x: pillCenter.x - textSize.width / 2 - 12, y: pillCenter.y - 11, width: textSize.width + 24, height: 22)
            ctx.fill(Path(roundedRect: pill, cornerRadius: 11), with: .color(accent))
            ctx.draw(resolved, at: pillCenter)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch kind {
        case .sheet:
            Text("Top view of the machine, you at the front. The printed sheet is turned round so the top of the artwork faces you and its front edge sits just past the blade. The arrow mark is at the front right, under the blade, next to the screen.")
        case .vinyl:
            Text("Top view of the machine with vinyl loaded; its front edge sits just past the blade, at the front right next to the screen, which marks the origin. The design is cut from there, behind and to the left.")
        }
    }
}

/// Small sheet with the four marks, shown while sending.
struct SheetGlyph: View {
    let marks: Bool

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 150, size.height / 190)
            ctx.scaleBy(x: k, y: k)
            let paper = CGRect(x: 5, y: 5, width: 140, height: 180)
            ctx.fill(Path(paper), with: .color(.white))
            ctx.stroke(Path(paper), with: .color(Color(white: 0.73)), lineWidth: 1)
            if marks {
                var frame = Path(CGRect(x: 17, y: 20, width: 116, height: 150))
                frame = frame.strokedPath(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                ctx.fill(frame, with: .color(.accentColor))
                for p in [CGPoint(x: 17, y: 20), CGPoint(x: 133, y: 20), CGPoint(x: 17, y: 170), CGPoint(x: 133, y: 170)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.black))
                }
            }
            for c in [CGPoint(x: 52, y: 70), CGPoint(x: 98, y: 120)] {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44)), with: .color(Color(white: 0.6)), lineWidth: 1.2)
            }
        }
        .accessibilityHidden(true)
    }
}
