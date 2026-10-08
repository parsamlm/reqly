import Capture
import Foundation
import Observation
import SystemProxy

/// Starts and stops capturing, and says what state capturing is in.
@Observable
final class CaptureModel {
    enum Status: Equatable {
        case stopped
        case starting
        /// Waiting for the user to allow Reqly's helper in System Settings.
        case waitingForApproval
        case capturing(port: Int)
        case stopping
        case failed(String)
    }

    private(set) var status = Status.stopped
    /// A problem that doesn't stop capturing, such as proxy settings that couldn't be put back.
    private(set) var warning: String?
    /// Whether Reqly points the Mac's proxy at itself while capturing. Builds that aren't signed
    /// by a team can't, and `-setsSystemProxy NO` turns it off.
    let setsSystemProxy: Bool

    private let session: CaptureSession
    private let systemProxy: SystemProxyController?
    private var approvalWatch: Task<Void, Never>?

    init(session: CaptureSession, systemProxy: SystemProxyController?) {
        self.session = session
        self.systemProxy = systemProxy
        self.setsSystemProxy = systemProxy != nil
        let saved = UserDefaults.standard.integer(forKey: DefaultsKey.proxyPort)
        port = Self.ports.contains(saved) ? saved : Self.defaultPort
    }

    static let defaultPort = 9090
    /// The ports Reqly can listen on: the ones that need no administrator.
    static let ports = 1024...65535

    /// The port from Settings, or 9090. Capturing uses it the next time it starts.
    private(set) var port: Int

    func setPort(_ port: Int) {
        guard Self.ports.contains(port), port != self.port else { return }
        self.port = port
        UserDefaults.standard.set(port, forKey: DefaultsKey.proxyPort)
    }

    /// Whether Reqly captures on another port than the one in Settings, until it starts again.
    var isOnOldPort: Bool {
        if case .capturing(let listening) = status { listening != port } else { false }
    }

    /// Stops and starts capturing again, such as to listen on a new port.
    func restart() async {
        guard isCapturing else { return }
        await stop()
        if status == .stopped {
            await start()
        }
    }

    var isCapturing: Bool {
        if case .capturing = status { true } else { false }
    }

    /// Starting, stopping or waiting, when the capture switch shouldn't be pressed again.
    var isBusy: Bool {
        status == .starting || status == .stopping || status == .waitingForApproval
    }

    func toggle() {
        Task {
            if isCapturing {
                await stop()
            } else {
                await start()
            }
        }
    }

    func start() async {
        guard !isCapturing, status != .starting, status != .stopping else { return }
        status = .starting
        warning = nil
        do {
            let port = try await session.start(port: port)
            status = .capturing(port: port)
        } catch SystemProxyError.needsApproval {
            status = .waitingForApproval
            waitForApproval()
        } catch {
            status = .failed(Self.explain(error, port: port))
        }
    }

    func stop() async {
        guard case .capturing(let port) = status else { return }
        status = .stopping
        do {
            try await session.stop()
            status = .stopped
            warning = nil
        } catch {
            // The proxy keeps running, so apps still reach the internet through Reqly.
            status = .capturing(port: port)
            warning = "Reqly couldn't put your proxy settings back. Quit Reqly, and its helper will put them back."
        }
    }

    /// Stops waiting for approval, for example when the user cancels.
    func cancelApproval() {
        approvalWatch?.cancel()
        approvalWatch = nil
        if status == .waitingForApproval {
            status = .stopped
        }
    }

    @MainActor
    func openApprovalSettings() {
        SystemProxyController.openApprovalSettings()
    }

    /// What removing the helper did, in words for an alert.
    enum HelperRemovalOutcome {
        case removed, wasNotInstalled, notNow
        case failed(String)
    }

    /// Removes Reqly's helper from macOS, for example to troubleshoot. Only while not capturing.
    func removeHelper() async -> HelperRemovalOutcome {
        guard let systemProxy, !isCapturing, !isBusy else { return .notNow }
        do {
            let removal = try await systemProxy.removeHelper()
            status = .stopped
            return removal == .removed ? .removed : .wasNotInstalled
        } catch {
            let reason = (error as? SystemProxyError).map(Self.reason) ?? error.localizedDescription
            return .failed(reason)
        }
    }

    private static func reason(_ error: SystemProxyError) -> String {
        switch error {
        case .failed(let reason), .unreachable(let reason): reason
        case .needsApproval: "macOS is waiting for you to allow it in System Settings."
        case .helperMissing: "The helper is missing from the app."
        }
    }

    /// Checks every second whether the user has allowed the helper, then starts capturing.
    private func waitForApproval() {
        approvalWatch?.cancel()
        approvalWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, status == .waitingForApproval else { return }
                if systemProxy?.isApproved == true {
                    status = .stopped
                    await start()
                    return
                }
            }
        }
    }

    private static func explain(_ error: any Error, port: Int) -> String {
        switch error {
        case CaptureError.portInUse(let port):
            "Port \(port) is in use by another app. Choose a different port in Settings, then try again."
        case SystemProxyError.helperMissing:
            "Reqly's helper is missing from the app. Reinstall Reqly, then try again."
        case SystemProxyError.failed(let reason):
            "Reqly couldn't set your Mac's proxy. \(reason)"
        case SystemProxyError.unreachable:
            "Reqly couldn't reach its helper. Try again, or remove the helper in Settings › General and start capturing again."
        default:
            "Reqly couldn't start capturing. \(error.localizedDescription)"
        }
    }
}
