import Capture
import Foundation
import Presentation
import ProxyEngine
import ReqlyModel
import WindowsSystem

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
    private var secretFile: SecretFile?
    private var secrets: [String: Data] = [:]

    static let passwordName = "Reqly Upstream Proxy/password"

    static func keyName(_ id: UUID) -> String {
        "Reqly Client Certificate/\(id.uuidString)"
    }

    mutating func open(_ url: URL, secrets secretFile: SecretFile) {
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

    func wire(reverseProxyProblems: [UUID: String]) -> WireConnections {
        WireConnections(
            upstreamProxy: WireUpstreamProxy(
                UpstreamProxyDraft(contents.upstreamProxy, isOn: contents.usesUpstreamProxy)),
            activeUpstreamProxy: activeUpstreamProxy?.address,
            reverseProxies: contents.reverseProxies.map {
                WireReverseProxyRow(
                    id: $0.id, isOn: $0.isOn, localPort: $0.localPort, serverURL: $0.serverURL,
                    rewritesRedirects: $0.rewritesRedirects, localAddress: $0.localAddress,
                    server: $0.server?.url ?? $0.serverURL, problem: $0.isOn ? reverseProxyProblems[$0.id] : nil)
            },
            clientCertificates: contents.clientCertificates.map {
                WireClientCertificate(
                    id: $0.id, isOn: $0.isOn, name: $0.name, issuer: $0.issuer, hosts: HostList.text($0.hosts),
                    expires: Wire.seconds($0.expires), hasExpired: $0.hasExpired(), isMissing: missing.contains($0.id))
            },
            problem: problem)
    }
}

/// How Reqly's own connections go, as Settings show them.
struct WireConnections: Encodable {
    /// The upstream proxy as it's saved, whether or not it's in use.
    var upstreamProxy: WireUpstreamProxy
    /// The proxy traffic goes through now, such as `proxy.example.com:8080`.
    var activeUpstreamProxy: String?
    var reverseProxies: [WireReverseProxyRow]
    /// In the order they're tried: the first one for a host is the one presented.
    var clientCertificates: [WireClientCertificate]
    var problem: String?
}

/// The upstream proxy as Settings edit it, field for field as the core's ``UpstreamProxyDraft``.
public struct WireUpstreamProxy: Codable, Sendable, Equatable {
    public var isOn: Bool
    public var host: String
    public var port: String
    public var username: String
    public var password: String
    /// Hosts to reach directly, as typed.
    public var bypass: String
    public var bypassesLocalAddresses: Bool

    init(_ draft: UpstreamProxyDraft) {
        isOn = draft.isOn
        host = draft.host
        port = draft.port
        username = draft.username
        password = draft.password
        bypass = draft.bypass
        bypassesLocalAddresses = draft.bypassesLocalAddresses
    }

    var draft: UpstreamProxyDraft {
        var draft = UpstreamProxyDraft()
        draft.isOn = isOn
        draft.host = host
        draft.port = port
        draft.username = username
        draft.password = password
        draft.bypass = bypass
        draft.bypassesLocalAddresses = bypassesLocalAddresses
        return draft
    }
}

/// A reverse proxy in the list.
struct WireReverseProxyRow: Encodable {
    var id: UUID
    var isOn: Bool
    var localPort: Int
    var serverURL: String
    var rewritesRedirects: Bool
    /// Such as `localhost:8080`.
    var localAddress: String
    /// Where requests go, such as `https://api.weatherly.dev`, or the server as typed while it isn't an address.
    var server: String
    /// Why it isn't listening, while Reqly captures.
    var problem: String?
}

/// A reverse proxy as its editor edits it, with its port as typed.
public struct WireReverseProxy: Codable, Sendable, Equatable {
    public var id: UUID
    public var isOn: Bool
    public var port: String
    public var serverURL: String
    public var rewritesRedirects: Bool

    init(_ proxy: ReverseProxy) {
        id = proxy.id
        isOn = proxy.isOn
        port = String(proxy.localPort)
        serverURL = proxy.serverURL
        rewritesRedirects = proxy.rewritesRedirects
    }

    /// The proxy to save, with the port it has while the one typed isn't a number.
    func proxy(keeping old: ReverseProxy?) -> ReverseProxy {
        ReverseProxy(
            id: id, isOn: isOn, localPort: Int(port.trimmingCharacters(in: .whitespaces)) ?? old?.localPort ?? 0,
            serverURL: serverURL, rewritesRedirects: rewritesRedirects)
    }
}

/// What's wrong with something as you edit it, or a note on what it does once nothing is.
struct WireCheck: Encodable {
    var problem: String?
    var note: String?
}

/// What's wrong with hosts as typed, and how many there are.
struct WireHostsCheck: Encodable {
    var problem: String?
    var count: Int
}

/// A client certificate in the list. Its private key stays in the core.
struct WireClientCertificate: Encodable {
    var id: UUID
    var isOn: Bool
    /// Who the certificate names, such as "Weatherly Staging".
    var name: String
    var issuer: String
    /// The hosts it's for, as the field shows them: `api.bank.dev, *.bank.dev`.
    var hosts: String
    /// Seconds since 1970.
    var expires: Double?
    var hasExpired: Bool
    /// Its private key is gone, so it can't be presented.
    var isMissing: Bool
}
