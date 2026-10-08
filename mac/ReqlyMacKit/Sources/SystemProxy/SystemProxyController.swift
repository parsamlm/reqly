import Foundation
import HelperProtocol
import ReqlyModel
import ServiceManagement
import Synchronization

public enum SystemProxyError: Error, Equatable {
    /// The helper is registered, but waits for the user to allow it in System Settings.
    case needsApproval
    /// The helper or its launchd property list is missing from the app.
    case helperMissing
    /// The helper couldn't be reached.
    case unreachable(String)
    /// The helper reported a problem.
    case failed(String)
}

/// What removing the helper did.
public enum HelperRemoval: Sendable, Equatable {
    case removed
    /// macOS had no helper registered for this copy of Reqly.
    case wasNotInstalled
}

/// Sets and restores the Mac's proxy through ReqlyHelper, the privileged helper inside the app.
public final class SystemProxyController: SystemProxySwitch {
    private let plistName: String
    private let machServiceName: String
    private let requirement: String
    /// How long Reqly waits for the helper's answer. macOS keeps a request to a helper it can't
    /// start, such as one a copy of Reqly signed another way registered, waiting forever.
    private static let answerTimeout: TimeInterval = 10

    /// `nil` when this build of Reqly isn't signed by a team, because the helper only accepts
    /// requests from a Reqly signed by the same team as itself.
    public init?() {
        guard let signing = CodeSigningInfo.current(), let team = signing.teamIdentifier else { return nil }
        machServiceName = HelperNames.helperIdentifier(forApp: signing.identifier)
        plistName = HelperNames.launchdPlistName(forApp: signing.identifier)
        requirement = CodeSigningInfo.requirement(identifier: machServiceName, team: team)
    }

    /// Whether the user has allowed the helper in System Settings.
    public var isApproved: Bool {
        SMAppService.daemon(plistName: plistName).status == .enabled
    }

    /// Opens System Settings › General › Login Items & Extensions, where the user allows the helper.
    @MainActor
    public static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func enable(port: Int) async throws {
        try register()
        do {
            try await send { helper, reply in helper.setProxy(port: port, reply: reply) }
        } catch SystemProxyError.unreachable(let problem) {
            // The helper may still be registered from another copy of Reqly that has since moved
            // or been deleted, so macOS won't start it. Register this copy's helper instead, and
            // try once more. macOS can refuse to register it again so soon; then the problem to
            // report is still the helper that didn't answer.
            try? await SMAppService.daemon(plistName: plistName).unregister()
            do {
                try register()
            } catch SystemProxyError.failed {
                throw SystemProxyError.unreachable(problem)
            }
            try await send { helper, reply in helper.setProxy(port: port, reply: reply) }
        }
    }

    public func disable() async throws {
        try await send { helper, reply in helper.restoreProxy(reply: reply) }
    }

    /// Removes the helper from macOS. Reqly registers it again the next time it's needed.
    /// Don't call this while capturing: the helper would stop guarding the proxy settings.
    @discardableResult
    public func removeHelper() async throws -> HelperRemoval {
        let service = SMAppService.daemon(plistName: plistName)
        switch service.status {
        case .notRegistered, .notFound:
            return .wasNotInstalled
        default:
            break
        }
        do {
            try await service.unregister()
        } catch {
            throw SystemProxyError.failed(error.localizedDescription)
        }
        return .removed
    }

    private func register() throws {
        let service = SMAppService.daemon(plistName: plistName)
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw SystemProxyError.needsApproval
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval { throw SystemProxyError.needsApproval }
            throw SystemProxyError.failed(error.localizedDescription)
        }
        switch service.status {
        case .enabled: return
        case .requiresApproval: throw SystemProxyError.needsApproval
        case .notFound: throw SystemProxyError.helperMissing
        default: throw SystemProxyError.failed("macOS didn't register Reqly's helper.")
        }
    }

    /// Sends one request to the helper and waits for its answer. A connection problem, or no
    /// answer in time, ends the wait with an error instead of leaving it hanging.
    private func send(
        _ request: @escaping @Sendable (any ReqlyHelperXPC, @escaping @Sendable (NSError?) -> Void) -> Void
    ) async throws {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ReqlyHelperXPC.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: SystemProxyError.unreachable(error.localizedDescription))
            }
            guard let helper = proxy as? any ReqlyHelperXPC else {
                once.resume(throwing: SystemProxyError.failed("Reqly's helper didn't answer as expected."))
                return
            }
            request(helper) { error in
                if let error {
                    once.resume(throwing: SystemProxyError.failed(error.localizedDescription))
                } else {
                    once.resume(throwing: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.answerTimeout) {
                once.resume(throwing: SystemProxyError.unreachable("Reqly's helper didn't answer."))
            }
        }
    }
}

/// Resumes a continuation once, whichever of the reply or the error handler comes first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, any Error>?>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(throwing error: (any Error)?) {
        guard let continuation = continuation.withLock({ $0.take() }) else { return }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
