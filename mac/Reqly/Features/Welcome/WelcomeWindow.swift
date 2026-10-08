import AppKit
import SwiftUI

/// The first-run guide: what capturing does, then setting up the certificate and choosing the
/// hosts to decrypt. It opens once, the first time Reqly does, and from the Help menu after.
struct WelcomeWindow: View {
    @Environment(CaptureModel.self) private var capture
    @Environment(HTTPSModel.self) private var https
    @Environment(SettingsNavigation.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
                Text("Welcome to Reqly")
                    .font(.title.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("See what your Mac apps send and receive.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 24)

            VStack(spacing: 0) {
                captureStep
                Divider()
                certificateStep
                Divider()
                hostsStep
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .padding(.horizontal, 44)

            Spacer(minLength: 20)
            Divider()
            HStack {
                Text("You can change all of this later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if isFinished {
                    Button("Get Started") { dismissWindow(id: "welcome") }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip for Now") { dismissWindow(id: "welcome") }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 720, height: 530)
    }

    private var isFinished: Bool {
        currentStep == nil
    }

    private var hasHosts: Bool {
        https.hosts.includesEveryHost || https.hosts.onCount > 0
    }

    /// The first step that isn't done, which the guide points at: capturing, then the
    /// certificate, then the hosts. `nil` once everything is done.
    private var currentStep: Int? {
        if !capture.isCapturing { return 1 }
        if !https.isTrusted { return 2 }
        if !hasHosts { return 3 }
        return nil
    }

    /// The current step, or one that's still to come.
    private func pending(_ number: Int) -> StepState {
        currentStep == number ? .current : .upcoming
    }

    /// A step's button: prominent on the step the guide points at, plain on the others, so
    /// they can be done in any order.
    @ViewBuilder
    private func stepButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) {
                Text(title).readableOnAccent()
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(title, action: action)
        }
    }

    @ViewBuilder
    private var captureStep: some View {
        let title = "Capture your Mac's traffic"
        let detail =
            capture.setsSystemProxy
            ? "While capturing, Reqly is your Mac's proxy. Your network settings come back when you stop."
            : "This copy of Reqly captures the apps you point at 127.0.0.1, port \(String(capture.port))."
        switch capture.status {
        case .capturing:
            WelcomeStep(number: 1, state: .done, title: title, detail: detail) {
                StepTag("Capturing")
            }
        case .starting, .stopping:
            WelcomeStep(number: 1, state: pending(1), title: title, detail: detail) {
                ProgressView().controlSize(.small)
            }
        case .waitingForApproval:
            WelcomeStep(
                number: 1, state: pending(1), title: title, detail: detail,
                problem:
                    "Allow Reqly's helper in System Settings, under Login Items & Extensions, and capturing starts."
            ) {
                stepButton("Open System Settings", prominent: true) { capture.openApprovalSettings() }
            }
        case .failed(let problem):
            WelcomeStep(number: 1, state: pending(1), title: title, detail: detail, problem: problem) {
                stepButton("Try Again", prominent: true) { capture.toggle() }
            }
        case .stopped:
            WelcomeStep(number: 1, state: pending(1), title: title, detail: detail) {
                stepButton("Start Capturing", prominent: currentStep == 1) { capture.toggle() }
            }
        }
    }

    @ViewBuilder
    private var certificateStep: some View {
        let title = "Install the Reqly certificate"
        let detail =
            "To read HTTPS traffic, your Mac needs to trust a certificate that Reqly creates just for you. It never leaves this Mac."
        switch https.status {
        case .trusted:
            WelcomeStep(number: 2, state: .done, title: title, detail: detail) {
                StepTag("Installed")
            }
        case .checking, .working:
            WelcomeStep(number: 2, state: pending(2), title: title, detail: detail) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if case .working(let step) = https.status {
                        Text(step).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        case .failed(let problem):
            WelcomeStep(number: 2, state: pending(2), title: title, detail: detail, problem: problem) {
                stepButton("Try Again", prominent: currentStep == 2) { Task { await https.setUp() } }
            }
        case .notSetUp, .notTrusted:
            WelcomeStep(number: 2, state: pending(2), title: title, detail: detail + " macOS asks for your password.") {
                stepButton(
                    https.status == .notTrusted ? "Trust Certificate…" : "Install Certificate…",
                    prominent: currentStep == 2
                ) {
                    Task { await https.setUp() }
                }
            }
        }
    }

    @ViewBuilder
    private var hostsStep: some View {
        let title = "Choose hosts to decrypt"
        let detail = "Decrypt only the hosts you care about. Everything else stays encrypted."
        if !https.isTrusted {
            // Hosts are decrypted only with the certificate, so this waits for step 2.
            WelcomeStep(number: 3, state: .upcoming, title: title, detail: detail) {
                EmptyView()
            }
        } else if hasHosts {
            WelcomeStep(number: 3, state: .done, title: title, detail: detail) {
                Button(hostCount) { settings.open(.https, with: openSettings) }
                    .buttonStyle(.link)
                    .help("Shows the hosts in Settings")
            }
        } else {
            WelcomeStep(number: 3, state: pending(3), title: title, detail: detail) {
                stepButton("Choose Hosts…", prominent: currentStep == 3) { settings.open(.https, with: openSettings) }
            }
        }
    }

    private var hostCount: String {
        if https.hosts.includesEveryHost { return "All hosts" }
        return https.hosts.onCount == 1 ? "1 host" : "\(https.hosts.onCount) hosts"
    }
}

/// Where a step of the guide stands.
private enum StepState {
    case done, current, upcoming
}

/// One step of the guide: its number, or a check once it's done, what it's about, and its action.
private struct WelcomeStep<Action: View>: View {
    let number: Int
    let state: StepState
    let title: String
    let detail: String
    var problem: String?
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 14) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle)
            action
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(state == .current ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(.clear))
    }

    private var accessibilityTitle: String {
        let progress =
            switch state {
            case .done: "Done"
            case .current: "Next"
            case .upcoming: "Later"
            }
        return "Step \(number), \(progress): \(title). \(detail)\(problem.map { " \($0)" } ?? "")"
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.tint, in: .circle)
                .accessibilityHidden(true)
        case .current:
            Text(String(number))
                .font(.caption.weight(.semibold))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.tint, lineWidth: 2))
                .accessibilityHidden(true)
        case .upcoming:
            Text(String(number))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.tertiary, lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }
}

/// A short word for a step that's done, such as "Ready".
private struct StepTag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
    }
}
