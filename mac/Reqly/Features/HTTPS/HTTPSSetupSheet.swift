import SwiftUI

/// Sets up HTTPS decryption: Reqly creates its certificate, and macOS trusts it after asking
/// for the user's password.
struct HTTPSSetupSheet: View {
    @Environment(HTTPSModel.self) private var https

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up HTTPS")
                .font(.title2)
            Text(
                "To show what's inside HTTPS requests, Reqly creates its own certificate on your Mac, and macOS trusts it for your user account. Reqly decrypts only the hosts you choose. Everything else passes through untouched."
            )
            Text(
                "macOS asks for your password to trust the certificate. You can remove it at any time in Settings, under HTTPS."
            )
            .foregroundStyle(.secondary)
            switch https.status {
            case .working(let step):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(step)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            default:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    https.cancelSetup()
                }
                .keyboardShortcut(.cancelAction)
                Button(https.hasCertificate ? "Trust Certificate" : "Create and Trust Certificate") {
                    Task { await https.setUp() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(https.isWorking)
            }
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 480)
    }
}

/// What the detail pane says about decryption for the selected request, with the action that fits.
struct DecryptionCallout: View {
    @Environment(HTTPSModel.self) private var https
    @Environment(\.openWindow) private var openWindow
    let summary: ExchangeSummaryForCallout

    var body: some View {
        let host = summary.host
        // Says what happens to the host from now on, which may differ from what happened to this request.
        switch (summary.situation, https.isDecrypting(host)) {
        case (.plain, _):
            EmptyView()
        case (.encryptedTunnel, false):
            callout("This connection is encrypted, so Reqly can't show what's inside.", symbol: "lock") {
                Button("Decrypt \(host)") { https.decrypt(host) }
                    .buttonStyle(.borderedProminent)
            }
        case (.encryptedTunnel, true):
            callout("Reqly now decrypts \(host). Its next requests show up decrypted.", symbol: "lock.open") {
                Button("Stop Decrypting \(host)") { https.stopDecrypting(host) }
            }
        case (.decrypted, true):
            callout("Reqly decrypted this request.", symbol: "lock.open") {
                Button("Stop Decrypting \(host)") { https.stopDecrypting(host) }
            }
        case (.certificateRejected, true):
            if let device = summary.device {
                // A device keeps the certificate it was given, so a new one on the Mac needs installing there too.
                callout(
                    "\(device) may trust an earlier Reqly certificate. Install the current one on it, or stop decrypting \(host) to let its traffic through, encrypted.",
                    symbol: "exclamationmark.lock"
                ) {
                    HStack {
                        Button("Set Up Device…") { openWindow(id: "devices") }
                        Button("Stop Decrypting \(host)") { https.stopDecrypting(host) }
                    }
                }
            } else {
                callout(
                    "Stopping decryption for \(host) lets its traffic through again, encrypted.",
                    symbol: "exclamationmark.lock"
                ) {
                    Button("Stop Decrypting \(host)") { https.stopDecrypting(host) }
                }
            }
        case (.decrypted, false), (.certificateRejected, false):
            callout("Reqly no longer decrypts \(host). Its connections pass through encrypted.", symbol: "lock") {
                Button("Decrypt \(host)") { https.decrypt(host) }
            }
        }
    }

    private func callout(
        _ text: String, symbol: String, @ViewBuilder action: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(text, systemImage: symbol)
            action()
                .disabled(https.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// The few facts the decryption callout needs about a request.
struct ExchangeSummaryForCallout {
    enum Situation {
        case plain, encryptedTunnel, decrypted, certificateRejected
    }

    var host: String
    var situation: Situation
    /// The device the request came from, or `nil` for this Mac.
    var device: String? = nil
}
