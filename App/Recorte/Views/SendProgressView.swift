import SwiftUI

struct SendProgressView: View {
    @Environment(CutterController.self) private var cutter

    var body: some View {
        VStack(spacing: 16) {
            switch cutter.status {
            case .sending(let progress):
                Image(systemName: "scissors")
                    .font(.system(size: 36))
                    .symbolEffect(.pulse)
                Text("Cutting…")
                    .font(.title2)
                ProgressView(value: progress)
                    .frame(width: 260)
                Text("Keep the machine clear while it moves.")
                    .foregroundStyle(.secondary)
                Button("Stop", role: .destructive) { cutter.cancel() }
                    .help("Stops sending. The machine may still finish what it has already received.")
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text("Sent to the cutter")
                    .font(.title2)
                Text("The machine will finish on its own.")
                    .foregroundStyle(.secondary)
                Button("Done") { cutter.dismissStatus() }
                    .keyboardShortcut(.defaultAction)
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("Could not send")
                    .font(.title2)
                Text(message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("OK") { cutter.dismissStatus() }
                    .keyboardShortcut(.defaultAction)
            case .idle:
                EmptyView()
            }
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}
