import SwiftUI

/// Ideas that need more than a help tag: a few sentences and a small drawing, opened from an ⓘ button.
enum InfoTopic: String, CaseIterable, Identifiable {
    case registrationMarks, markPlacement, bladeOffset, cutStart, speedAndPressure

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .registrationMarks: "Registration marks"
        case .markPlacement: "Where the marks go"
        case .bladeOffset: "Blade offset and overcut"
        case .cutStart: "Where the cut starts"
        case .speedAndPressure: "Speed and pressure"
        }
    }

    var text: LocalizedStringKey {
        switch self {
        case .registrationMarks:
            "Recorte prints four black circles around the artwork. The machine's camera finds them, so the knife knows exactly where the print is. Load the sheet with the arrow mark under the blade: the cut starts there. The mark size must match the setting on the machine."
        case .markPlacement:
            "Around the artwork: the marks sit beside the artwork (20.5 mm by default, like SignMaster), which uses less paper and vinyl. At the page edges: the marks stay in the corners of the page, wherever the artwork is."
        case .bladeOffset:
            "The tip of a drag knife trails a little behind the centre of the holder, which would round off the corners. Recorte adds a small loop at each corner to turn the blade. Overcut carries the cut a little past the start, so closed shapes come out cleanly. Find the right values with a test cut."
        case .cutStart:
            "The blade starts at the front-right corner of the vinyl, on the side of the machine's screen. From the right and From the start move the design away from that corner. Seen from the front, the design comes out upside down; it is not mirrored."
        case .speedAndPressure:
            "By default the machine uses the speed and pressure set on its own panel. Turn on Send speed and pressure to use the values here for each job instead. Start from a material, then check with a test cut: the knife should cut through the vinyl and only scratch the backing."
        }
    }
}

/// Small ⓘ button that opens a popover about a topic.
struct InfoButton: View {
    let topic: InfoTopic
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text("About: ") + Text(topic.title))
        .accessibilityLabel(Text(topic.title))
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            InfoPopover(topic: topic)
        }
    }
}

struct InfoPopover: View {
    let topic: InfoTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(topic.title).font(.headline)
            InfoDrawing(topic: topic)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            Text(topic.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Simple diagrams drawn in code, so only the text needs translating.
private struct InfoDrawing: View {
    let topic: InfoTopic

    var body: some View {
        switch topic {
        case .registrationMarks: sheet(marksAroundArtwork: true, showOrigin: true)
        case .markPlacement:
            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    sheet(marksAroundArtwork: true, showOrigin: false).frame(width: 90)
                    Text("Around the artwork").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    sheet(marksAroundArtwork: false, showOrigin: false).frame(width: 90)
                    Text("At the page edges").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        case .bladeOffset: bladeDrawing
        case .cutStart: cutStartDrawing
        case .speedAndPressure: speedDrawing
        }
    }

    /// A printed page with artwork, its cut line and the four marks.
    private func sheet(marksAroundArtwork: Bool, showOrigin: Bool) -> some View {
        Canvas { ctx, size in
            let page = CGRect(x: 0, y: 0, width: size.height * 0.75, height: size.height - 8)
                .offsetBy(dx: (size.width - size.height * 0.75) / 2, dy: 4)
            ctx.fill(Path(page), with: .color(.white))
            ctx.stroke(Path(page), with: .color(.gray.opacity(0.5)), lineWidth: 0.5)
            let art = page.insetBy(dx: page.width * 0.3, dy: page.height * 0.3)
            ctx.fill(Path(roundedRect: art, cornerRadius: 4), with: .color(.orange.opacity(0.8)))
            ctx.stroke(Path(roundedRect: art.insetBy(dx: -3, dy: -3), cornerRadius: 6), with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            let frame = marksAroundArtwork
                ? CGRect(x: art.minX - page.width * 0.16, y: art.minY, width: art.width + page.width * 0.32, height: art.height)
                : page.insetBy(dx: 7, dy: 9)
            let r: CGFloat = 3
            for corner in [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                           CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)] {
                ctx.fill(Path(ellipseIn: CGRect(x: corner.x - r, y: corner.y - r, width: r * 2, height: r * 2)), with: .color(.black))
            }
            if showOrigin {
                let o = CGPoint(x: frame.minX, y: frame.minY)
                ctx.stroke(Path(ellipseIn: CGRect(x: o.x - 7, y: o.y - 7, width: 14, height: 14)), with: .color(.red), lineWidth: 1.5)
                var arrow = Path()
                arrow.move(to: CGPoint(x: o.x, y: o.y + 9)); arrow.addLine(to: CGPoint(x: o.x, y: o.y + 22))
                arrow.move(to: CGPoint(x: o.x - 3, y: o.y + 18)); arrow.addLine(to: CGPoint(x: o.x, y: o.y + 22))
                arrow.addLine(to: CGPoint(x: o.x + 3, y: o.y + 18))
                ctx.stroke(arrow, with: .color(.black), lineWidth: 1)
            }
        }
    }

    /// A corner with the turning loop, the blade tip behind the holder centre and the overcut past the start.
    private var bladeDrawing: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width * 0.62, y: size.height * 0.3)
            var cut = Path()
            cut.move(to: CGPoint(x: size.width * 0.15, y: c.y))
            cut.addLine(to: c)
            cut.addLine(to: CGPoint(x: c.x, y: size.height * 0.88))
            ctx.stroke(cut, with: .color(.primary), lineWidth: 2)
            var loop = Path()
            loop.move(to: c)
            loop.addLine(to: CGPoint(x: c.x + 8, y: c.y))
            loop.addArc(center: CGPoint(x: c.x + 8, y: c.y + 8), radius: 8, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: false)
            ctx.stroke(loop, with: .color(.accentColor), lineWidth: 1.5)
            var over = Path()
            over.move(to: CGPoint(x: size.width * 0.15, y: c.y))
            over.addLine(to: CGPoint(x: size.width * 0.15 - 14, y: c.y))
            ctx.stroke(over, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            let holder = CGPoint(x: size.width * 0.35, y: c.y - 30)
            ctx.stroke(Path(ellipseIn: CGRect(x: holder.x - 12, y: holder.y - 12, width: 24, height: 24)), with: .color(.secondary), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: holder.x - 2, y: holder.y - 2, width: 4, height: 4)), with: .color(.secondary))
            ctx.fill(Path(ellipseIn: CGRect(x: holder.x - 9, y: holder.y - 2, width: 4, height: 4)), with: .color(.red))
            ctx.draw(Text("Corner loop").font(.caption2).foregroundStyle(Color.accentColor), at: CGPoint(x: c.x + 20, y: c.y + 26), anchor: .leading)
            ctx.draw(Text("Overcut").font(.caption2).foregroundStyle(.orange), at: CGPoint(x: size.width * 0.15 - 14, y: c.y + 12), anchor: .leading)
            ctx.draw(Text("Blade tip").font(.caption2).foregroundStyle(.red), at: CGPoint(x: holder.x + 16, y: holder.y), anchor: .leading)
        }
    }

    /// Top view of the vinyl in the machine: the origin at the front right and the two distances.
    private var cutStartDrawing: some View {
        Canvas { ctx, size in
            let vinyl = CGRect(x: size.width * 0.06, y: 6, width: size.width * 0.82, height: size.height - 30)
            ctx.fill(Path(vinyl), with: .color(.white))
            ctx.stroke(Path(vinyl), with: .color(.gray.opacity(0.5)), lineWidth: 0.5)
            let origin = CGPoint(x: vinyl.maxX, y: vinyl.maxY)
            let design = CGRect(x: origin.x - 100 - 50, y: origin.y - 50 - 30, width: 50, height: 30)
            ctx.stroke(Path(roundedRect: design, cornerRadius: 3), with: .color(.accentColor), lineWidth: 1.5)
            var cross = Path()
            cross.move(to: CGPoint(x: origin.x - 8, y: origin.y)); cross.addLine(to: CGPoint(x: origin.x + 8, y: origin.y))
            cross.move(to: CGPoint(x: origin.x, y: origin.y - 8)); cross.addLine(to: CGPoint(x: origin.x, y: origin.y + 8))
            ctx.stroke(cross, with: .color(.red), lineWidth: 1.5)
            let ink = Color.gray
            // From the right: across the vinyl, below the design.
            let rightY = design.maxY + 14
            var dims = Path()
            dims.move(to: CGPoint(x: design.maxX, y: rightY)); dims.addLine(to: CGPoint(x: origin.x, y: rightY))
            // From the start: along the feed, right of the design.
            let startX = design.maxX + 14
            dims.move(to: CGPoint(x: startX, y: design.maxY)); dims.addLine(to: CGPoint(x: startX, y: origin.y))
            ctx.stroke(dims, with: .color(ink), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            ctx.draw(Text("From the right").font(.caption2).foregroundStyle(ink), at: CGPoint(x: design.maxX - 4, y: rightY), anchor: .trailing)
            ctx.draw(Text("From the start").font(.caption2).foregroundStyle(ink), at: CGPoint(x: startX + 4, y: (rightY + origin.y) / 2 + 2), anchor: .leading)
            ctx.draw(Text("Front of the machine (you)").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height - 8))
        }
    }

    private var speedDrawing: some View {
        HStack(spacing: 18) {
            VStack(spacing: 4) {
                Image(systemName: "dial.medium").font(.system(size: 30))
                Text("Machine panel").font(.caption2)
            }
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Image(systemName: "macbook").font(.system(size: 30))
                Text("Sent by Recorte").font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
    }
}

#Preview("Info – registration marks") { InfoPopover(topic: .registrationMarks) }
#Preview("Info – mark placement") { InfoPopover(topic: .markPlacement) }
#Preview("Info – blade offset") { InfoPopover(topic: .bladeOffset) }
#Preview("Info – where the cut starts") { InfoPopover(topic: .cutStart) }
#Preview("Info – speed and pressure") { InfoPopover(topic: .speedAndPressure) }
