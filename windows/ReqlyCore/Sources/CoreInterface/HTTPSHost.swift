import Capture
import CertificateAuthority
import Foundation
import ReqlyModel

/// Reqly's certificate for HTTPS decryption, and the hosts to decrypt, as the Mac app's HTTPS
/// model keeps them. Reqly decrypts only while the system trusts the certificate, and only the
/// hosts on the list; everything else passes through untouched.
actor HTTPSHost {
    enum Status: String, Codable {
        /// No certificate yet.
        case notSetUp
        /// The certificate exists, but the system doesn't trust it, so nothing is decrypted.
        case notTrusted
        case trusted
    }

    private let store: any RootStore
    private let capture: CaptureSession
    private var root: RootIdentity?
    private var authority: CertificateAuthority?
    private var hosts = DecryptedHosts()
    private var status = Status.notSetUp

    init(store: any RootStore, capture: CaptureSession) {
        self.store = store
        self.capture = capture
    }

    func load() async {
        let store = self.store
        root = await Self.offThread { try? store.load() }
        refresh()
    }

    /// Makes the certificate if there isn't one, then asks the system to trust it, which on
    /// Windows asks you to confirm. Saying no isn't a failure: the status says it isn't trusted.
    func setUp() async throws(Problem) -> WireHTTPS {
        let store = self.store
        let existing = root
        let result = await Self.offThread { () -> Result<RootIdentity, any Error> in
            Result {
                let root = try existing ?? store.load() ?? RootIdentity.create()
                try store.save(root)
                try store.trust(root)
                return root
            }
        }
        switch result {
        case .success(let made):
            root = made
        case .failure(let error) where (error as? CertificateStoreError) == .cancelled:
            root = await Self.offThread { try? store.load() }
        case .failure(let error):
            root = await Self.offThread { try? store.load() }
            refresh()
            throw Problem(.failed, "Reqly couldn't set up HTTPS. \(Self.explain(error))")
        }
        refresh()
        return wire
    }

    /// Removes the certificate, its key and the system's trust in it, which on Windows asks you
    /// to confirm.
    func remove() async throws(Problem) -> WireHTTPS {
        guard let root else { return wire }
        let store = self.store
        let result = await Self.offThread { Result { try store.remove(root) } }
        switch result {
        case .success:
            self.root = nil
        case .failure(let error) where (error as? CertificateStoreError) == .cancelled:
            break
        case .failure(let error):
            refresh()
            throw Problem(.failed, "Reqly couldn't remove its certificate. \(Self.explain(error))")
        }
        refresh()
        return wire
    }

    /// Changes the hosts to decrypt. Reqly decrypts by the new list from the next connection on.
    func changeHosts(_ change: @Sendable (inout DecryptedHosts) -> Void) -> WireHTTPS {
        change(&hosts)
        apply()
        return wire
    }

    func addHost(_ text: String) throws(Problem) -> WireHTTPS {
        if let problem = hosts.add(text) {
            throw Problem(.badRequest, problem.message)
        }
        apply()
        return wire
    }

    func decrypts(_ host: String) -> Bool {
        hosts.decrypts(host)
    }

    var wire: WireHTTPS {
        WireHTTPS(
            status: status, certificateName: root?.name, created: root.map { $0.created.timeIntervalSince1970 },
            certificate: status == .trusted
                ? (try? root?.certificateDER).flatMap { Data($0).base64EncodedString() } : nil,
            hosts: hosts)
    }

    /// Reads whether the system trusts the certificate, and decrypts only if it does.
    private func refresh() {
        guard let root else {
            status = .notSetUp
            authority = nil
            apply()
            return
        }
        status = store.isTrusted(root) ? .trusted : .notTrusted
        if status == .trusted, authority == nil {
            authority = try? CertificateAuthority(root: root)
        } else if status != .trusted {
            authority = nil
        }
        apply()
    }

    private func apply() {
        capture.setDecryption(authority: authority, hosts: hosts)
    }

    private static func explain(_ error: any Error) -> String {
        if case CertificateStoreError.failed(let message) = error { return message }
        return error.localizedDescription
    }

    /// Runs work that may wait a long time, such as for you to answer the system's question, on a
    /// thread of its own, so none of Swift's shared threads waits with it.
    private static func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.start()
        }
    }
}

/// HTTPS as the app shows it.
public struct WireHTTPS: Codable, Sendable, Equatable {
    var status: HTTPSHost.Status
    public var certificateName: String?
    /// When the certificate was made, in seconds since 1970.
    public var created: Double?
    /// The certificate in DER, base64, for devices to install. It's there only while the system
    /// trusts it, since only then does Reqly decrypt.
    public var certificate: String?
    public var hosts: DecryptedHosts

    public var statusName: String { status.rawValue }
}
