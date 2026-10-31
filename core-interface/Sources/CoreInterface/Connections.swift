import Capture
import Foundation
import Presentation
import ProxyEngine
import ReqlyModel

/// How Reqly's own connections go, as Settings edit them: through an upstream proxy, from reverse
/// proxies, and with client certificates. They're kept in the same file the Mac keeps them in,
/// with the proxy's password and the certificates' private keys in a file only your user can read.
struct ConnectionsBook {
    private(set) var contents = ConnectionsFile.Contents()
    /// Certificates whose private keys are gone from the secrets file.
    private(set) var missing: Set<UUID> = []
    /// Why the settings couldn't be read or saved, if they couldn't.
    private(set) var problem: String?
    private var identities: [UUID: ClientIdentity] = [:]
    private var file: URL?
    private var secretFile: (any SecretStorage)?
    private var secrets: [String: Data] = [:]

    static let passwordName = "Reqly Upstream Proxy/password"

    static func keyName(_ id: UUID) -> String {
        "Reqly Client Certificate/\(id.uuidString)"
    }

    mutating func open(_ url: URL, secrets secretFile: any SecretStorage) {
        file = url
        self.secretFile = secretFile
        let loaded = ConnectionsFile.load(from: url)
        contents = loaded.contents
        problem = loaded.problem
        do {
            secrets = try secretFile.load()
        } catch {
            secrets = [:]
            problem = "Reqly couldn't read the passwords and keys it keeps. \(error.localizedDescription)"
        }
        if var proxy = contents.upstreamProxy, proxy.username != nil, let password = secrets[Self.passwordName] {
            proxy.password = String(decoding: password, as: UTF8.self)
            contents.upstreamProxy = proxy
        }
        for certificate in contents.clientCertificates {
            guard let data = secrets[Self.keyName(certificate.id)],
                let identity = try? ClientIdentity(serialized: data, hosts: certificate.hosts)
            else {
                missing.insert(certificate.id)
                continue
            }
            identities[certificate.id] = identity
        }
    }

    /// The proxy traffic goes through now, if any.
    var activeUpstreamProxy: UpstreamProxy? {
        contents.usesUpstreamProxy ? contents.upstreamProxy : nil
    }

    /// The certificates to present, in the order of the list: the first one for a host is the one presented.
    var activeIdentities: [ClientIdentity] {
        contents.clientCertificates.filter(\.isOn).compactMap { identities[$0.id] }
    }

    // MARK: The upstream proxy

    mutating func setUpstreamProxy(_ proxy: UpstreamProxy?, isOn: Bool) {
        contents.upstreamProxy = proxy
        contents.usesUpstreamProxy = isOn && proxy != nil
        if let password = proxy?.password, proxy?.username != nil, !password.isEmpty {
            secrets[Self.passwordName] = Data(password.utf8)
        } else {
            secrets[Self.passwordName] = nil
        }
        save()
        // After the settings, so that a password that couldn't be kept is the problem that shows.
        saveSecrets(failure: "Reqly couldn't keep the proxy's password.")
    }

    // MARK: Reverse proxies

    /// Adds a reverse proxy, or changes the one with the same ID.
    mutating func saveReverseProxy(_ proxy: ReverseProxy) {
        if let index = contents.reverseProxies.firstIndex(where: { $0.id == proxy.id }) {
            contents.reverseProxies[index] = proxy
        } else {
            contents.reverseProxies.append(proxy)
        }
        save()
    }

    mutating func removeReverseProxy(_ id: UUID) {
        contents.reverseProxies.removeAll { $0.id == id }
        save()
    }

    mutating func setReverseProxy(_ id: UUID, isOn: Bool) {
        guard let index = contents.reverseProxies.firstIndex(where: { $0.id == id }) else { return }
        contents.reverseProxies[index].isOn = isOn
        save()
    }

    // MARK: Client certificates

    /// Keeps a certificate and its private key, and adds it, switched on, last in the list.
    mutating func addClientCertificate(_ identity: ClientIdentity) {
        let certificate = ClientCertificate(
            hosts: identity.hosts, name: identity.name, issuer: identity.issuer, expires: identity.expires)
        let name = Self.keyName(certificate.id)
        do {
            secrets[name] = try identity.serialized
        } catch {
            problem = "Reqly couldn't keep the certificate. \(error.localizedDescription)"
            return
        }
        guard saveSecrets(failure: "Reqly couldn't keep the certificate.") else {
            secrets[name] = nil
            return
        }
        identities[certificate.id] = identity
        contents.clientCertificates.append(certificate)
        save()
    }

    mutating func setHosts(_ hosts: [HostPattern], of id: UUID) {
        guard let index = contents.clientCertificates.firstIndex(where: { $0.id == id }) else { return }
        contents.clientCertificates[index].hosts = hosts
        identities[id]?.hosts = hosts
        save()
    }

    mutating func setClientCertificate(_ id: UUID, isOn: Bool) {
        guard let index = contents.clientCertificates.firstIndex(where: { $0.id == id }) else { return }
        contents.clientCertificates[index].isOn = isOn
        save()
    }

    mutating func removeClientCertificate(_ id: UUID) {
        contents.clientCertificates.removeAll { $0.id == id }
        identities[id] = nil
        missing.remove(id)
        secrets[Self.keyName(id)] = nil
        save()
        saveSecrets(failure: "Reqly couldn't remove the certificate's key.")
    }

    // MARK: Saving

    private mutating func save() {
        guard let file else { return }
        var saved = contents
        saved.upstreamProxy?.password = nil
        do {
            try ConnectionsFile.save(saved, to: file)
            problem = nil
        } catch {
            problem = ConnectionsFile.saveProblem(error)
        }
    }

    @discardableResult
    private mutating func saveSecrets(failure: String) -> Bool {
        guard let secretFile else { return true }
        do {
            try secretFile.save(secrets)
            return true
        } catch {
            problem = "\(failure) \(error.localizedDescription)"
            return false
        }
    }

    /// The settings as Settings show them, with why each reverse proxy that's on isn't listening.
    func state(reverseProxyProblems: [UUID: String]) -> ConnectionsState {
        ConnectionsState(
            upstreamProxy: UpstreamProxyDraft(contents.upstreamProxy, isOn: contents.usesUpstreamProxy),
            activeUpstreamProxy: activeUpstreamProxy,
            reverseProxies: contents.reverseProxies.map {
                ConnectionsState.ReverseProxyRow(proxy: $0, problem: $0.isOn ? reverseProxyProblems[$0.id] : nil)
            },
            clientCertificates: contents.clientCertificates.map {
                ConnectionsState.ClientCertificateRow(certificate: $0, isMissing: missing.contains($0.id))
            },
            problem: problem)
    }
}

/// How Reqly's own connections go, as Settings show them.
public struct ConnectionsState: Sendable, Equatable {
    /// A reverse proxy in the list.
    public struct ReverseProxyRow: Sendable, Equatable {
        public var proxy: ReverseProxy
        /// Why it isn't listening, while Reqly captures.
        public var problem: String?

        public init(proxy: ReverseProxy, problem: String? = nil) {
            self.proxy = proxy
            self.problem = problem
        }
    }

    /// A client certificate in the list. Its private key stays in the core.
    public struct ClientCertificateRow: Sendable, Equatable {
        public var certificate: ClientCertificate
        /// Its private key is gone, so it can't be presented.
        public var isMissing: Bool

        public init(certificate: ClientCertificate, isMissing: Bool) {
            self.certificate = certificate
            self.isMissing = isMissing
        }
    }

    /// The upstream proxy as it's saved, whether or not it's in use.
    public var upstreamProxy: UpstreamProxyDraft
    /// The proxy traffic goes through now.
    public var activeUpstreamProxy: UpstreamProxy?
    public var reverseProxies: [ReverseProxyRow]
    /// In the order they're tried: the first one for a host is the one presented.
    public var clientCertificates: [ClientCertificateRow]
    public var problem: String?

    public init(
        upstreamProxy: UpstreamProxyDraft, activeUpstreamProxy: UpstreamProxy? = nil, reverseProxies: [ReverseProxyRow],
        clientCertificates: [ClientCertificateRow], problem: String? = nil
    ) {
        self.upstreamProxy = upstreamProxy
        self.activeUpstreamProxy = activeUpstreamProxy
        self.reverseProxies = reverseProxies
        self.clientCertificates = clientCertificates
        self.problem = problem
    }
}

/// A reverse proxy as its editor edits it, with its port as typed.
public struct ReverseProxyDraft: Sendable, Equatable {
    public var id: UUID
    public var isOn: Bool
    public var port: String
    public var serverURL: String
    public var rewritesRedirects: Bool

    public init(id: UUID, isOn: Bool, port: String, serverURL: String, rewritesRedirects: Bool) {
        self.id = id
        self.isOn = isOn
        self.port = port
        self.serverURL = serverURL
        self.rewritesRedirects = rewritesRedirects
    }

    public init(_ proxy: ReverseProxy) {
        self.init(
            id: proxy.id, isOn: proxy.isOn, port: String(proxy.localPort), serverURL: proxy.serverURL,
            rewritesRedirects: proxy.rewritesRedirects)
    }

    /// The proxy to save, with the port it has while the one typed isn't a number.
    func proxy(keeping old: ReverseProxy?) -> ReverseProxy {
        ReverseProxy(
            id: id, isOn: isOn, localPort: Int(port.trimmingCharacters(in: .whitespaces)) ?? old?.localPort ?? 0,
            serverURL: serverURL, rewritesRedirects: rewritesRedirects)
    }
}
