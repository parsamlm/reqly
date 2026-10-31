import Capture
import CertificateAuthority
import Foundation
import ReqlyModel

/// Reqly's certificate for HTTPS decryption, and the hosts to decrypt, as the Mac app's HTTPS
/// model keeps them. Reqly decrypts only while the system trusts the certificate, and only the
/// hosts on the list; everything else passes through untouched.
actor HTTPSHost {
    private let store: any RootStore
    private let capture: CaptureSession
    private var root: RootIdentity?
    private var authority: CertificateAuthority?
    private var hosts = DecryptedHosts()
    private var status = HTTPSState.Status.notSetUp

    init(store: any RootStore, capture: CaptureSession) {
        self.store = store
        self.capture = capture
    }

    func load() async {
        let store = self.store
        root = await offThread { try? store.load() }
        await refresh()
    }

    /// Reads the certificate and whether it's trusted again, as ``load()`` does as the session
    /// opens, after the app changed them in the store itself.
    func reload() async -> HTTPSState {
        await load()
        return state
    }

    /// Makes the certificate if there isn't one, then asks the system to trust it, which asks you
    /// to confirm on Windows, and for an administrator's password on Linux, for the computer's
    /// list. Saying no isn't a failure: the status says it isn't trusted.
    func setUp() async throws(Problem) -> HTTPSState {
        let store = self.store
        let existing = root
        let result = await offThread { () -> Result<RootIdentity, any Error> in
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
            root = await offThread { try? store.load() }
        case .failure(let error):
            root = await offThread { try? store.load() }
            await refresh()
            throw Problem(.failed, "Reqly couldn't set up HTTPS. \(Self.explain(error))")
        }
        await refresh()
        return state
    }

    /// Removes the certificate, its key and the system's trust in it, which asks you to confirm
    /// on Windows, and for an administrator's password on Linux, for the computer's list.
    func remove() async throws(Problem) -> HTTPSState {
        guard let root else { return state }
        let store = self.store
        let result = await offThread { Result { try store.remove(root) } }
        switch result {
        case .success:
            self.root = nil
        case .failure(let error) where (error as? CertificateStoreError) == .cancelled:
            break
        case .failure(let error):
            await refresh()
            throw Problem(.failed, "Reqly couldn't remove its certificate. \(Self.explain(error))")
        }
        await refresh()
        return state
    }

    /// Changes the hosts to decrypt. Reqly decrypts by the new list from the next connection on.
    func changeHosts(_ change: @Sendable (inout DecryptedHosts) -> Void) -> HTTPSState {
        change(&hosts)
        apply()
        return state
    }

    func addHost(_ text: String) throws(Problem) -> HTTPSState {
        if let problem = hosts.add(text) {
            throw Problem(.badRequest, problem.message)
        }
        apply()
        return state
    }

    func decrypts(_ host: String) -> Bool {
        hosts.decrypts(host)
    }

    var state: HTTPSState {
        HTTPSState(
            status: status, certificateName: root?.name, created: root?.created,
            certificate: status == .trusted ? (try? root?.certificateDER).map { Data($0) } : nil, hosts: hosts)
    }

    /// Reads whether the system trusts the certificate, and decrypts only if it does. On Linux
    /// that runs certutil, so it's read on a thread of its own.
    private func refresh() async {
        guard let root else {
            status = .notSetUp
            authority = nil
            apply()
            return
        }
        let store = self.store
        let trusted = await offThread { store.isTrusted(root) }
        // The certificate changed meanwhile, and the refresh that came with it reads it.
        guard let current = self.root, (try? current.certificateDER) == (try? root.certificateDER) else { return }
        status = trusted ? .trusted : .notTrusted
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
}

/// Runs work that may wait a long time, such as for you to answer the system's question or unlock
/// your keyring, on a thread of its own, so none of Swift's shared threads waits with it.
func offThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.start()
    }
}

/// HTTPS as the app shows it: whether Reqly's certificate is set up and trusted, and the hosts
/// to decrypt.
public struct HTTPSState: Sendable, Equatable {
    public enum Status: String, Sendable {
        /// No certificate yet.
        case notSetUp
        /// The certificate exists, but the system doesn't trust it, so nothing is decrypted.
        case notTrusted
        case trusted
    }

    public var status: Status
    public var certificateName: String?
    /// When the certificate was made.
    public var created: Date?
    /// The certificate in DER, for devices to install. It's there only while the system trusts
    /// it, since only then does Reqly decrypt.
    public var certificate: Data?
    public var hosts: DecryptedHosts

    public init(
        status: Status, certificateName: String? = nil, created: Date? = nil, certificate: Data? = nil,
        hosts: DecryptedHosts
    ) {
        self.status = status
        self.certificateName = certificateName
        self.created = created
        self.certificate = certificate
        self.hosts = hosts
    }
}
