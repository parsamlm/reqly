import Capture
import Foundation
import Observation
import ProxyEngine
import ReqlyModel

/// How Reqly's own connections go: through an upstream proxy, from reverse proxies, and with
/// client certificates. The settings are saved, and the passwords and private keys are kept
/// in the Keychain.
@Observable
final class ConnectionsModel {
    /// The upstream proxy's settings, with its password, whether or not it's in use.
    private(set) var upstreamProxy: UpstreamProxy?
    private(set) var usesUpstreamProxy = false
    private(set) var reverseProxies: [ReverseProxy] = []
    private(set) var clientCertificates: [ClientCertificate] = []
    /// Why reverse proxies that are on aren't listening, while capturing.
    private(set) var reverseProxyProblems: [ReverseProxy.ID: String] = [:]
    /// Certificates whose private keys the Keychain no longer has.
    private(set) var missingCertificates: Set<ClientCertificate.ID> = []
    /// Why the settings couldn't be read or saved, if they couldn't.
    private(set) var problem: String?

    private let session: CaptureSession
    private let secrets: any SecretStore
    private let url: URL
    private var identities: [ClientCertificate.ID: ClientIdentity] = [:]

    private static let proxyService = "Reqly Upstream Proxy"
    private static let certificateService = "Reqly Client Certificate"

    private struct Saved: Codable {
        var version = 1
        var upstreamProxy: UpstreamProxy?
        var usesUpstreamProxy = false
        var reverseProxies: [ReverseProxy] = []
        var clientCertificates: [ClientCertificate] = []
    }

    init(session: CaptureSession) {
        self.session = session
        secrets = SecretStores.standard
        url = Self.fileURL
        if let data = try? Data(contentsOf: url) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: data)
                upstreamProxy = saved.upstreamProxy
                usesUpstreamProxy = saved.usesUpstreamProxy
                reverseProxies = saved.reverseProxies
                clientCertificates = saved.clientCertificates
            } catch {
                problem = "Reqly couldn't read its connection settings, so it started without them."
            }
        }
        if var proxy = upstreamProxy, proxy.username != nil,
            let password = secrets.load(service: Self.proxyService, account: "password")
        {
            proxy.password = String(decoding: password, as: UTF8.self)
            upstreamProxy = proxy
        }
        for certificate in clientCertificates {
            loadIdentity(of: certificate)
        }
        applyUpstreamProxy()
        applyClientCertificates()
        let proxies = reverseProxies
        Task { await session.setReverseProxies(proxies) }
        #if DEBUG
            // `-importClientCertificate "path|password|host,host"` adds one, as the Add sheet does.
            if let spec = UserDefaults.standard.string(forKey: DefaultsKey.importClientCertificate) {
                let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3,
                    !clientCertificates.contains(where: { $0.hosts.map(\.rawValue).joined(separator: ",") == parts[2] })
                {
                    let hosts = parts[2].split(separator: ",").compactMap { HostPattern(rawValue: String($0)) }
                    try? addClientCertificate(from: [URL(filePath: parts[0])], password: parts[1], hosts: hosts)
                }
            }
        #endif
    }

    /// Where the settings are saved. A debug build takes another file from `-connectionsFile path`.
    private static var fileURL: URL {
        #if DEBUG
            if let path = UserDefaults.standard.string(forKey: DefaultsKey.connectionsFile) {
                return URL(filePath: path)
            }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Reqly/Connections.json")
    }

    // MARK: - Upstream proxy

    /// The proxy traffic goes through now, if any.
    var activeUpstreamProxy: UpstreamProxy? {
        usesUpstreamProxy ? upstreamProxy : nil
    }

    func setUpstreamProxy(_ proxy: UpstreamProxy?, isOn: Bool) {
        upstreamProxy = proxy
        usesUpstreamProxy = isOn && proxy != nil
        if let password = proxy?.password, proxy?.username != nil, !password.isEmpty {
            do {
                try secrets.save(
                    Data(password.utf8), service: Self.proxyService, account: "password",
                    label: "Reqly Upstream Proxy")
            } catch {
                problem = "Reqly couldn't keep the proxy's password in the Keychain: \(error.localizedDescription)"
            }
        } else {
            secrets.delete(service: Self.proxyService, account: "password")
        }
        save()
        applyUpstreamProxy()
    }

    private func applyUpstreamProxy() {
        session.setUpstreamProxy(activeUpstreamProxy)
    }

    // MARK: - Reverse proxies

    /// Adds a reverse proxy, or changes the one with the same ID.
    func saveReverseProxy(_ proxy: ReverseProxy) {
        if let index = reverseProxies.firstIndex(where: { $0.id == proxy.id }) {
            reverseProxies[index] = proxy
        } else {
            reverseProxies.append(proxy)
        }
        reverseProxiesChanged()
    }

    func removeReverseProxy(_ id: ReverseProxy.ID) {
        reverseProxies.removeAll { $0.id == id }
        reverseProxiesChanged()
    }

    func setReverseProxy(_ id: ReverseProxy.ID, on isOn: Bool) {
        guard let index = reverseProxies.firstIndex(where: { $0.id == id }) else { return }
        reverseProxies[index].isOn = isOn
        reverseProxiesChanged()
    }

    private func reverseProxiesChanged() {
        save()
        let proxies = reverseProxies
        Task {
            let problems = await session.setReverseProxies(proxies)
            reverseProxyProblems = problems.mapValues(\.message)
        }
    }

    /// Asks again why reverse proxies aren't listening, as after capturing starts or stops.
    func refreshReverseProxyProblems() async {
        reverseProxyProblems = await session.reverseProxyProblems.mapValues(\.message)
    }

    // MARK: - Client certificates

    /// Reads a certificate and its private key from files: a `.p12` or `.pfx` file, unlocked with
    /// `password`, or PEM files with the certificate and its key. Its key goes in the Keychain.
    func addClientCertificate(from files: [URL], password: String, hosts: [HostPattern]) throws(ClientIdentity.Problem)
    {
        let identity = try Self.identity(from: files, password: password, hosts: hosts)
        let certificate = ClientCertificate(
            hosts: hosts, name: identity.name, issuer: identity.issuer, expires: identity.expires)
        do {
            try secrets.save(
                try identity.serialized, service: Self.certificateService, account: certificate.id.uuidString,
                label: "Reqly Client Certificate: \(identity.name)")
        } catch {
            problem = "Reqly couldn't keep the certificate in the Keychain: \(error.localizedDescription)"
            return
        }
        identities[certificate.id] = identity
        clientCertificates.append(certificate)
        clientCertificatesChanged()
    }

    /// What a certificate's files hold, checked without keeping anything.
    static func identity(from files: [URL], password: String, hosts: [HostPattern]) throws(ClientIdentity.Problem)
        -> ClientIdentity
    {
        let contents = files.compactMap { try? Data(contentsOf: $0) }
        guard contents.count == files.count, !contents.isEmpty else { throw .unreadable }
        // A PKCS #12 file is binary; PEM files are text, which may come in two files.
        let isPKCS12 = files.contains { ["p12", "pfx"].contains($0.pathExtension.lowercased()) }
        if isPKCS12 || String(data: contents[0], encoding: .utf8) == nil {
            return try ClientIdentity(pkcs12: [UInt8](contents[0]), password: password, hosts: hosts)
        }
        let pem = contents.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        return try ClientIdentity(pem: pem, password: password.isEmpty ? nil : password, hosts: hosts)
    }

    func setHosts(_ hosts: [HostPattern], of id: ClientCertificate.ID) {
        guard let index = clientCertificates.firstIndex(where: { $0.id == id }) else { return }
        clientCertificates[index].hosts = hosts
        identities[id]?.hosts = hosts
        clientCertificatesChanged()
    }

    func setClientCertificate(_ id: ClientCertificate.ID, on isOn: Bool) {
        guard let index = clientCertificates.firstIndex(where: { $0.id == id }) else { return }
        clientCertificates[index].isOn = isOn
        clientCertificatesChanged()
    }

    func removeClientCertificate(_ id: ClientCertificate.ID) {
        clientCertificates.removeAll { $0.id == id }
        identities[id] = nil
        missingCertificates.remove(id)
        secrets.delete(service: Self.certificateService, account: id.uuidString)
        clientCertificatesChanged()
    }

    private func loadIdentity(of certificate: ClientCertificate) {
        guard let data = secrets.load(service: Self.certificateService, account: certificate.id.uuidString),
            let identity = try? ClientIdentity(serialized: data, hosts: certificate.hosts)
        else {
            missingCertificates.insert(certificate.id)
            return
        }
        identities[certificate.id] = identity
    }

    private func clientCertificatesChanged() {
        save()
        applyClientCertificates()
    }

    private func applyClientCertificates() {
        session.setClientIdentities(clientCertificates.filter(\.isOn).compactMap { identities[$0.id] })
    }

    // MARK: - Saving

    private func save() {
        var proxy = upstreamProxy
        proxy?.password = nil
        let saved = Saved(
            upstreamProxy: proxy, usesUpstreamProxy: usesUpstreamProxy, reverseProxies: reverseProxies,
            clientCertificates: clientCertificates)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(saved).write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = "Reqly couldn't save its connection settings: \(error.localizedDescription)"
        }
    }
}
