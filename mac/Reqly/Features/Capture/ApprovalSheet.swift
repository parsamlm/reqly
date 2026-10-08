import SwiftUI

/// Asks the user to allow Reqly's helper, the first time they start capturing. Capturing starts
/// by itself once they do.
struct ApprovalSheet: View {
    @Environment(CaptureModel.self) private var capture

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Allow Reqly to Set Your Proxy")
                .font(.title2)
            Text(
                "While capturing, Reqly points your Mac's proxy at itself, and puts your settings back when you stop, even if Reqly quits unexpectedly. A small helper does this, and macOS asks you to allow it once."
            )
            Text(
                "In System Settings, open General › Login Items & Extensions, then turn on Reqly under Allow in the Background."
            )
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Capturing starts as soon as you allow it.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    capture.cancelApproval()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    capture.openApprovalSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
    }
}
