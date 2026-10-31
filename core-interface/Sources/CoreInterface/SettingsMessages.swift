import BodyKit
import Foundation
import Presentation
import ReqlyModel

// What the replies about HTTPS, rules, connections, devices and Protobuf files carry to the
// Windows app, made from the values SessionHost and its neighbors give.

/// HTTPS as the app shows it.
struct WireHTTPS: Encodable {
    /// `notSetUp`, `notTrusted` or `trusted`.
    var status: String
    var certificateName: String?
    /// When the certificate was made, in seconds since 1970.
    var created: Double?
    /// The certificate in DER, base64, for devices to install. It's there only while the system
    /// trusts it, since only then does Reqly decrypt.
    var certificate: String?
    var hosts: DecryptedHosts

    init(_ state: HTTPSState) {
        status = state.status.rawValue
        certificateName = state.certificateName
        created = Wire.seconds(state.created)
        certificate = state.certificate?.base64EncodedString()
        hosts = state.hosts
    }
}

// MARK: - Rules

/// The rules as the Rules window lists them.
struct WireRules: Encodable {
    struct Row: Encodable {
        var id: UUID
        var kind: RuleKind
        var name: String
        var isOn: Bool
        /// Such as `GET · api.weatherly.dev/v2/forecast*`.
        var match: String
        /// What the rule does, in a word or two, such as `Response` or `403`.
        var tag: String
    }

    /// The kinds that are on, in the order the Rules window lists them.
    var kindsOn: [RuleKind]
    var rules: [Row]
    /// What Slow Network slows down, and how much.
    var network: NetworkConditions
    var problem: String?

    init(_ state: RulesState) {
        kindsOn = RuleKind.allCases.filter(state.set.kindsOn.contains)
        rules = state.set.rules.map {
            Row(id: $0.id, kind: $0.kind, name: $0.name, isOn: $0.isOn, match: $0.match.description, tag: $0.tag)
        }
        network = state.set.network
        problem = state.problem
    }
}

/// A rule as the app's editor edits it: a ``RuleDraft``, field for field.
public struct WireRuleDraft: Codable, Sendable, Equatable {
    public struct Change: Codable, Sendable, Equatable {
        public var change: RewriteDraft.Change
        public var part: MessagePart
        /// The header or parameter, or the text to find.
        public var name: String
        /// The value to set, or the text to replace with.
        public var value: String
        public var status: Int
    }

    public var id: UUID
    public var isNew: Bool
    public var kind: RuleKind
    public var isOn: Bool
    public var name: String
    public var host: String
    public var path: String
    /// Empty for any method.
    public var method: String
    public var phase: BreakpointPhase
    public var file: String
    public var status: Int
    /// Empty to take the type from the file's extension.
    public var contentType: String
    public var destination: String
    public var changes: [Change]
    public var closesConnection: Bool
    public var blockStatus: Int
    public var code: String
    /// The exchange the rule was made from, for saving its response as Map Local's file.
    public var exchange: UInt64?

    init(_ draft: RuleDraft) {
        id = draft.id
        isNew = draft.isNew
        kind = draft.kind
        isOn = draft.isOn
        name = draft.name
        host = draft.host
        path = draft.path
        method = draft.method
        phase = draft.phase
        file = draft.file
        status = draft.status
        contentType = draft.contentType
        destination = draft.destination
        changes = draft.changes.map {
            Change(change: $0.change, part: $0.part, name: $0.name, value: $0.value, status: $0.status)
        }
        closesConnection = draft.closesConnection
        blockStatus = draft.blockStatus
        code = draft.code
        exchange = draft.exchange?.rawValue
    }

    var draft: RuleDraft {
        var draft = RuleDraft(id: id, isNew: isNew, kind: kind)
        draft.isOn = isOn
        draft.name = name
        draft.host = host
        draft.path = path
        draft.method = method
        draft.phase = phase
        draft.file = file
        draft.status = status
        draft.contentType = contentType
        draft.destination = destination
        draft.changes = changes.map {
            var change = RewriteDraft()
            change.change = $0.change
            change.part = $0.part
            change.name = $0.name
            change.value = $0.value
            change.status = $0.status
            return change
        }
        draft.closesConnection = closesConnection
        draft.blockStatus = blockStatus
        draft.code = code
        draft.exchange = exchange.map(ExchangeID.init(rawValue:))
        return draft
    }
}

/// What the editor shows under a draft as you edit it.
struct WireRuleCheck: Encodable {
    struct Request: Encodable {
        var id: UInt64
        /// Such as `GET api.weatherly.dev/v2/forecast · 200`.
        var description: String
    }

    /// What to fix before the rule can be saved, if anything.
    var problem: String?
    /// The name the rule gets when you don't give it one.
    var defaultName: String
    /// How many requests captured so far the rule would act on.
    var matchCount: Int
    /// For a script: the requests captured so far to try it on, newest first.
    var matching: [Request]?

    init(_ check: RuleCheck) {
        problem = check.problem
        defaultName = check.defaultName
        matchCount = check.matchCount
        matching = check.matching?.map { Request(id: $0.id.rawValue, description: RuleDraft.describe($0)) }
    }
}

// MARK: - Connections

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

    init(_ state: ConnectionsState) {
        upstreamProxy = WireUpstreamProxy(state.upstreamProxy)
        activeUpstreamProxy = state.activeUpstreamProxy?.address
        reverseProxies = state.reverseProxies.map(WireReverseProxyRow.init)
        clientCertificates = state.clientCertificates.map(WireClientCertificate.init)
        problem = state.problem
    }
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

    init(_ row: ConnectionsState.ReverseProxyRow) {
        let proxy = row.proxy
        id = proxy.id
        isOn = proxy.isOn
        localPort = proxy.localPort
        serverURL = proxy.serverURL
        rewritesRedirects = proxy.rewritesRedirects
        localAddress = proxy.localAddress
        server = proxy.server?.url ?? proxy.serverURL
        problem = row.problem
    }
}

/// A reverse proxy as its editor edits it, field for field as ``ReverseProxyDraft``.
public struct WireReverseProxy: Codable, Sendable, Equatable {
    public var id: UUID
    public var isOn: Bool
    public var port: String
    public var serverURL: String
    public var rewritesRedirects: Bool

    init(_ draft: ReverseProxyDraft) {
        id = draft.id
        isOn = draft.isOn
        port = draft.port
        serverURL = draft.serverURL
        rewritesRedirects = draft.rewritesRedirects
    }

    var draft: ReverseProxyDraft {
        ReverseProxyDraft(id: id, isOn: isOn, port: port, serverURL: serverURL, rewritesRedirects: rewritesRedirects)
    }
}

/// What's wrong with something as you edit it, or a note on what it does once nothing is.
struct WireCheck: Encodable {
    var problem: String?
    var note: String?

    init(_ check: CheckResult) {
        problem = check.problem
        note = check.note
    }
}

/// What's wrong with hosts as typed, and how many there are.
struct WireHostsCheck: Encodable {
    var problem: String?
    var count: Int

    init(_ list: HostList) {
        problem = list.problem
        count = list.patterns.count
    }
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

    init(_ row: ConnectionsState.ClientCertificateRow) {
        let certificate = row.certificate
        id = certificate.id
        isOn = certificate.isOn
        name = certificate.name
        issuer = certificate.issuer
        hosts = HostList.text(certificate.hosts)
        expires = Wire.seconds(certificate.expires)
        hasExpired = certificate.hasExpired()
        isMissing = row.isMissing
    }
}

// MARK: - Devices

/// The Android emulators that run, as the Devices window shows them.
struct WireEmulators: Encodable {
    struct Emulator: Encodable {
        /// adb's serial, such as `emulator-5554`.
        var id: String
        /// Such as "Pixel 10 Pro XL".
        var name: String
        /// The proxy it sends its traffic to, such as `10.0.2.2:9090`.
        var proxy: String?
        /// Still starting up, or not answering adb.
        var isReady: Bool
        /// Its proxy is Reqly, on the port asked about.
        var usesReqly: Bool
    }

    /// Whether Reqly found adb.
    var hasAdb: Bool
    var emulators: [Emulator]
    var problem: String?

    init(_ emulators: Emulators) {
        hasAdb = emulators.hasAdb
        self.emulators = emulators.emulators.map {
            Emulator(
                id: $0.emulator.id, name: $0.emulator.name, proxy: $0.emulator.proxy, isReady: $0.emulator.isReady,
                usesReqly: $0.usesReqly)
        }
        problem = emulators.problem
    }
}

/// Phones and tablets on the network, as the Devices window shows them.
struct WireDevices: Encodable {
    struct Known: Encodable {
        var id: String
        /// The name you gave it, if you gave it one.
        var name: String?
        /// The address it last connected from.
        var address: String
        /// Such as `aa:bb:cc:dd:ee:ff`, when its ID is that.
        var hardwareAddress: String?
    }

    struct Waiting: Encodable {
        var id: String
        var address: String
    }

    struct Address: Encodable {
        /// Such as "Wi-Fi".
        var interface: String
        var address: String
    }

    var allowsNetworkDevices: Bool
    var known: [Known]
    /// Devices waiting for you to decide, in the order they asked.
    var waiting: [Waiting]
    /// This computer's addresses on the networks devices can reach, the likeliest first.
    var addresses: [Address]
    var problem: String?

    init(_ state: DevicesState) {
        allowsNetworkDevices = state.allowsNetworkDevices
        known = state.known.map {
            Known(id: $0.id, name: $0.name, address: $0.address, hardwareAddress: $0.hardwareAddress)
        }
        waiting = state.waiting.map { Waiting(id: $0.id, address: $0.address) }
        addresses = state.addresses.map { Address(interface: $0.interface, address: $0.address) }
        problem = state.problem
    }
}

// MARK: - Protobuf files

/// The `.proto` files, as Settings list them, and the message types they hold.
struct WireProtobuf: Encodable, Sendable {
    struct Source: Encodable, Sendable {
        var path: String
        var isFolder: Bool
        /// The file's or the folder's name.
        var name: String
        /// How many `.proto` files it holds, or none when it's missing or has none.
        var count: Int?
    }

    struct Problem: Encodable, Sendable {
        var file: String
        /// 0 when the problem is with the whole file.
        var line: Int
        var message: String
    }

    var sources: [Source]
    /// Such as "14 message types and 2 services."
    var summary: String
    /// At most 200, in the order of the sources.
    var problems: [Problem]
    var saveProblem: String?
    /// Every message type, by its full name, for a body's message type menu.
    var types: [String]
    var version: Int

    init(_ state: ProtobufState) {
        sources = state.sources.map { Source(path: $0.path, isFolder: $0.isFolder, name: $0.name, count: $0.count) }
        summary = state.summary
        problems = state.problems.prefix(200).map { Problem(file: $0.file, line: $0.line, message: $0.message) }
        saveProblem = state.saveProblem
        types = state.types
        version = state.version
    }
}
