import BodyKit
import Foundation
import Presentation
import ReqlyModel
import TrafficStore

/// The version of the messages below. The app checks it when it opens a session, and it goes
/// up whenever a message changes in a way an older app wouldn't understand.
public let interfaceVersion = 1

/// What opening a session takes.
public struct OpenOptions: Codable, Sendable {
    /// The folder that holds each session's folder.
    public var sessionsFolder: String
    /// A saved session to open, instead of starting a new, live one.
    public var file: String?
    /// Whether capturing points your user's proxy setting at Reqly, on Windows. Your own
    /// settings are kept in `proxyRestoreFile` meanwhile, and put back after.
    public var setsSystemProxy: Bool?
    public var proxyRestoreFile: String?
    /// For test runs: a JSON file that stands in for Windows' proxy settings, so the switch runs
    /// without changing the computer's.
    public var proxySettingsStandIn: String?
    /// Whether to find which app on this computer sent each request, on Windows.
    public var findsApps: Bool?
    /// Where Windows' certificate store keeps Reqly's certificate and key, encrypted for your
    /// user. Without it, or `rootStandIn`, a session has no HTTPS decryption.
    public var rootFile: String?
    /// For test runs: a plain file for a certificate that counts as trusted, so the session
    /// decrypts while the computer never trusts it.
    public var rootStandIn: String?
    /// For test runs: more root certificates, in base64 DER, to trust when checking servers,
    /// such as a local test server's.
    public var extraTrustedRoots: [String]?

    public init(
        sessionsFolder: String, file: String? = nil, setsSystemProxy: Bool? = nil, proxyRestoreFile: String? = nil,
        proxySettingsStandIn: String? = nil, findsApps: Bool? = nil, rootFile: String? = nil,
        rootStandIn: String? = nil, extraTrustedRoots: [String]? = nil
    ) {
        self.sessionsFolder = sessionsFolder
        self.file = file
        self.setsSystemProxy = setsSystemProxy
        self.proxyRestoreFile = proxyRestoreFile
        self.proxySettingsStandIn = proxySettingsStandIn
        self.findsApps = findsApps
        self.rootFile = rootFile
        self.rootStandIn = rootStandIn
        self.extraTrustedRoots = extraTrustedRoots
    }
}

/// A request from the app, such as `{"call": "startCapturing", "port": 9090}`.
public enum Call: Sendable, Equatable {
    case version
    /// Starts the proxy on a port; 0 picks a free one.
    case startCapturing(port: Int)
    case stopCapturing
    /// Every row's exchange, in order, as of a version of the rows.
    case rowIDs
    /// The rows for some exchanges, as the list shows them.
    case rows(ids: [UInt64])
    /// The whole session at a glance, whatever the list shows: how many exchanges, what they
    /// sent and received, and the newest one, as the panel in the notification area shows them.
    case trafficSummary
    /// Narrows the list to exchanges with the text in their address, headers, body, app,
    /// device or comment. Empty text shows them all again.
    case setSearch(text: String)
    /// An exchange's details, without its bodies.
    case details(id: UInt64)
    /// A body made ready to show.
    case presentBody(id: UInt64, part: BodyPart)
    /// Whether HTTPS is set up, and the hosts to decrypt.
    case https
    /// Makes Reqly's certificate if there isn't one, and asks the system to trust it.
    case setUpHTTPS
    /// Removes the certificate, its key and the system's trust in it.
    case removeHTTPS
    /// The hosts to decrypt, as the app saved them.
    case setDecryptedHosts(DecryptedHosts)
    /// Decrypts a host from now on: switches its entry on, or adds one.
    case decryptHost(String)
    /// Stops decrypting a host. It stays on the list, switched off.
    case stopDecryptingHost(String)
    /// Adds a host or a wildcard, such as `*.example.com`, to the list, or says why it can't.
    case addDecryptedHost(text: String)
    case removeDecryptedHosts([HostPattern])
    case setHostDecrypted(HostPattern, isOn: Bool)
    case setDecryptsEveryHost(Bool)
    /// Whether Reqly decrypts a host now.
    case decryptsHost(String)
    /// Narrows the list to a sidebar row's exchanges, by the row's key from the latest
    /// `sidebar` event.
    case setScope(key: String)
    /// Narrows the list to the exchanges a filter lets through.
    case setFilter(WireFilter)
    /// Pins an exchange or not, marks it with a color, and comments on it. What's left out stays.
    case annotate(id: UInt64, isPinned: Bool?, color: Change<MarkColor>?, comment: Change<String>?)
    case unpinAll
    /// Clears the session's traffic. Pinned exchanges stay.
    case clear
    /// Saves the session as a file that Reqly opens on the Mac and on Windows alike.
    case saveSession(path: String, hidesSecrets: Bool)
    /// Exports exchanges to a HAR file: these, or with no `ids`, the list as it shows, in order.
    case exportHAR(path: String, ids: [UInt64]?, includesResponseBodies: Bool, hidesSecrets: Bool, version: String)
    /// The rules, as the rules file keeps them: the same JSON on the Mac and on Windows.
    case setRules(RuleSet)
    /// Opens the rules file and gives the session its rules. Each change after is saved to it.
    case openRules(path: String)
    /// The rules, as the Rules window lists them.
    case rules
    /// Switches a kind of rule on or off, such as breakpoints. A rule acts only while its kind is on.
    case setRuleKindOn(RuleKind, isOn: Bool)
    case setRuleOn(UUID, isOn: Bool)
    case removeRules([UUID])
    /// Moves a rule to another place among the rules of its kind.
    case moveRule(UUID, to: Int)
    /// Adds a copy of a rule, last among the rules of its kind.
    case duplicateRule(UUID)
    /// A new rule to edit, filled in from an exchange when there is one.
    case newRuleDraft(kind: RuleKind, id: UInt64?)
    /// A saved rule, to edit.
    case ruleDraft(UUID)
    /// What to fix in a draft, the name it gets, and how many requests captured so far it matches.
    case checkRuleDraft(WireRuleDraft)
    /// Saves a draft's rule. A new rule's kind comes on with it, so the rule acts.
    case saveRuleDraft(WireRuleDraft)
    /// What Slow Network slows down, and how much.
    case setNetwork(NetworkConditions)
    /// Slow Network's profiles to choose from: 3G, LTE and a lossy network.
    case networkPresets
    /// Scripts to start from, for the script editor's Examples menu.
    case scriptExamples
    /// Opens the connection settings and gives the session its upstream proxy, reverse proxies
    /// and client certificates; each change after is saved. The proxy's password and the
    /// certificates' keys go in the secrets file, which Windows encrypts for your user unless
    /// `protectsSecrets` is false, as for a test run.
    case openConnections(path: String, secretsPath: String, protectsSecrets: Bool)
    /// The connection settings, with why each reverse proxy that's on isn't listening.
    case connections
    /// What's wrong with the upstream proxy as you edit it. `proxyPort` is the one Reqly listens on.
    case checkUpstreamProxy(WireUpstreamProxy, proxyPort: Int)
    /// Applies the upstream proxy, which reconnects what goes another way now.
    case setUpstreamProxy(WireUpstreamProxy, proxyPort: Int)
    /// A new reverse proxy to edit, on a port none uses yet.
    case newReverseProxy(proxyPort: Int)
    /// What's wrong with a reverse proxy as you edit it, or where it sends requests.
    case checkReverseProxy(WireReverseProxy, proxyPort: Int)
    /// Adds a reverse proxy, or changes the one with the same ID.
    case saveReverseProxy(WireReverseProxy, proxyPort: Int)
    case removeReverseProxy(UUID)
    case setReverseProxyOn(UUID, isOn: Bool)
    /// What's wrong with hosts as typed, such as `api.example.com, *.example.com`, and how many there are.
    case checkHosts(text: String)
    /// Reads a certificate and its private key from files, and presents them to the hosts from now on.
    case addClientCertificate(files: [String], password: String, hosts: String)
    case setClientCertificateHosts(UUID, hosts: String)
    case setClientCertificateOn(UUID, isOn: Bool)
    case removeClientCertificate(UUID)
    /// Opens the list of `.proto` files and reads them, so protobuf bodies show their fields' names.
    case openProtobuf(path: String)
    /// The `.proto` files and what they hold.
    case protobuf
    case addProtobufSources(paths: [String])
    case removeProtobufSource(path: String)
    /// Reads the files again, as after they changed.
    case reloadProtobuf
    /// Reads bodies like this one, the same part of requests to the same host and path, as a
    /// message type from now on; or with none, as Reqly works out.
    case chooseMessageType(id: UInt64, part: BodyPart, type: String?)
    /// Opens the devices you let in, and asks the app about each new one from then on, with a
    /// `deviceWaiting` event. While devices are allowed, the proxy listens on the network.
    case openDevices(path: String, allowsNetworkDevices: Bool)
    /// The devices you let in, the ones waiting, and this computer's addresses for them.
    case devices
    /// Lets phones and tablets on the network connect, once you let each one in, or only this
    /// computer. Turning it off closes their connections and turns away the ones waiting.
    case setAllowsNetworkDevices(Bool)
    /// Lets a waiting device in, with the name you gave it, or turns it away until Reqly quits.
    case decideDevice(id: String, allow: Bool, name: String?)
    /// Stops letting a device in. It's asked about again the next time it connects.
    case forgetDevice(id: String)
    /// Names a device's traffic, from now on and in the list already.
    case renameDevice(id: String, name: String)
    /// A QR code for a short text, such as the setup page's address, as rows of dark (1) and light (0) modules.
    case qrCode(text: String)
    /// The Android emulators that run, and whether each sends its traffic through Reqly on `port`.
    case emulators(port: Int)
    /// Points an emulator's traffic at Reqly on `port`, or back to a direct connection.
    case setEmulatorUsesReqly(serial: String, isOn: Bool, port: Int)
    /// Copies Reqly's certificate, DER in base64, into an emulator's Downloads, and opens its
    /// security settings, where you install it.
    case copyCertificateToEmulator(serial: String, certificate: String)
    /// Lets a request or a response held at a breakpoint go on, as you edited it, or stops it.
    case decide(id: UInt64, edit: WirePausedEdit?)
    /// Lets every request and response held at a breakpoint go on as it was.
    case continueAllPaused
    /// What's wrong with a script, or nothing when it reads.
    case checkScript(code: String)
    /// A script's syntax, to color it as you type: its keywords, strings, numbers, literals and
    /// comments, as `[location, length, kind]` in UTF-16 code units.
    case highlightScript(code: String)
    /// Runs a script on a captured exchange, as it would run on traffic, and says what it would do.
    case tryScript(code: String, id: UInt64)
    /// Sends a request you wrote, straight to its server, and records it like any other.
    case send(WireOutgoing)
    /// Sends a request again, as the app sent it.
    case resend(id: UInt64)
    /// A request to write, filled in from an exchange, for Edit and Resend.
    case draft(id: UInt64)
    /// A cURL command that sends the request again.
    case curl(id: UInt64)
    /// The response body as Copy Response Body copies it: unpacked, as text when it's text, as an
    /// image when it's an image, and otherwise as hex.
    case copyableBody(id: UInt64)
    /// The request and the response as text, the way HTTP/1.1 writes them, with or without
    /// secrets such as cookies.
    case raw(id: UInt64, showsSecrets: Bool)
    /// A tree node's path, such as `hourly[0].time`, and its value to copy.
    case bodyNode(id: UInt64, part: BodyPart, node: Int)
    /// An exchange's WebSocket messages, from the one numbered `from` on.
    case messages(id: UInt64, from: Int)
    /// A WebSocket message made ready to show, as a body is.
    case presentMessage(id: UInt64, number: Int)

    /// A value to set, or `nil` to remove it, in a call that changes only what it names.
    public enum Change<Value: Sendable & Equatable>: Sendable, Equatable {
        case set(Value)
        case remove
    }

    private enum Keys: String, CodingKey {
        case call, port, ids, text, id, part, hosts, host, patterns, pattern, isOn, filter, isPinned, color, comment,
            key, showsSecrets, node, from, number, path, hidesSecrets, includesResponseBodies, version, request,
            rules, edit, code, kind, rule, ruleIDs, to, draft, network, secretsPath, protectsSecrets, proxy, proxyPort,
            reverseProxy, certificate, files, password, paths, type, allowsNetworkDevices, device, allow, name, serial
    }

    /// Reads a request, or says what's wrong with it.
    public init(json: Data) throws(Problem) {
        let container: KeyedDecodingContainer<Keys>
        let name: String
        do {
            container = try JSONDecoder().decode(Envelope.self, from: json).container
            name = try container.decode(String.self, forKey: .call)
        } catch {
            throw Problem(.badRequest, "The request isn't JSON with a \"call\".")
        }
        do {
            switch name {
            case "version": self = .version
            case "startCapturing": self = .startCapturing(port: try container.decode(Int.self, forKey: .port))
            case "stopCapturing": self = .stopCapturing
            case "rowIDs": self = .rowIDs
            case "rows": self = .rows(ids: try container.decode([UInt64].self, forKey: .ids))
            case "trafficSummary": self = .trafficSummary
            case "setSearch": self = .setSearch(text: try container.decode(String.self, forKey: .text))
            case "details": self = .details(id: try container.decode(UInt64.self, forKey: .id))
            case "presentBody":
                self = .presentBody(
                    id: try container.decode(UInt64.self, forKey: .id), part: try Self.part(in: container))
            case "raw":
                self = .raw(
                    id: try container.decode(UInt64.self, forKey: .id),
                    showsSecrets: try container.decodeIfPresent(Bool.self, forKey: .showsSecrets) ?? false)
            case "bodyNode":
                self = .bodyNode(
                    id: try container.decode(UInt64.self, forKey: .id), part: try Self.part(in: container),
                    node: try container.decode(Int.self, forKey: .node))
            case "messages":
                self = .messages(
                    id: try container.decode(UInt64.self, forKey: .id),
                    from: try container.decodeIfPresent(Int.self, forKey: .from) ?? 0)
            case "presentMessage":
                self = .presentMessage(
                    id: try container.decode(UInt64.self, forKey: .id),
                    number: try container.decode(Int.self, forKey: .number))
            case "https": self = .https
            case "setUpHTTPS": self = .setUpHTTPS
            case "removeHTTPS": self = .removeHTTPS
            case "setDecryptedHosts":
                self = .setDecryptedHosts(try container.decode(SavedHosts.self, forKey: .hosts).hosts)
            case "decryptHost": self = .decryptHost(try container.decode(String.self, forKey: .host))
            case "stopDecryptingHost": self = .stopDecryptingHost(try container.decode(String.self, forKey: .host))
            case "addDecryptedHost": self = .addDecryptedHost(text: try container.decode(String.self, forKey: .text))
            case "removeDecryptedHosts":
                self = .removeDecryptedHosts(try container.decode([HostPattern].self, forKey: .patterns))
            case "setHostDecrypted":
                self = .setHostDecrypted(
                    try container.decode(HostPattern.self, forKey: .pattern),
                    isOn: try container.decode(Bool.self, forKey: .isOn))
            case "setDecryptsEveryHost": self = .setDecryptsEveryHost(try container.decode(Bool.self, forKey: .isOn))
            case "decryptsHost": self = .decryptsHost(try container.decode(String.self, forKey: .host))
            case "setScope": self = .setScope(key: try container.decode(String.self, forKey: .key))
            case "setFilter": self = .setFilter(try container.decode(WireFilter.self, forKey: .filter))
            case "annotate":
                self = .annotate(
                    id: try container.decode(UInt64.self, forKey: .id),
                    isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned),
                    color: try Self.change(MarkColor.self, .color, in: container),
                    comment: try Self.change(String.self, .comment, in: container))
            case "unpinAll": self = .unpinAll
            case "clear": self = .clear
            case "saveSession":
                self = .saveSession(
                    path: try container.decode(String.self, forKey: .path),
                    hidesSecrets: try container.decodeIfPresent(Bool.self, forKey: .hidesSecrets) ?? false)
            case "exportHAR":
                self = .exportHAR(
                    path: try container.decode(String.self, forKey: .path),
                    ids: try container.decodeIfPresent([UInt64].self, forKey: .ids),
                    includesResponseBodies: try container.decodeIfPresent(Bool.self, forKey: .includesResponseBodies)
                        ?? true,
                    hidesSecrets: try container.decodeIfPresent(Bool.self, forKey: .hidesSecrets) ?? true,
                    version: try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0")
            case "setRules": self = .setRules(try container.decode(RuleSet.self, forKey: .rules))
            case "openRules": self = .openRules(path: try container.decode(String.self, forKey: .path))
            case "rules": self = .rules
            case "setRuleKindOn":
                self = .setRuleKindOn(
                    try container.decode(RuleKind.self, forKey: .kind),
                    isOn: try container.decode(Bool.self, forKey: .isOn))
            case "setRuleOn":
                self = .setRuleOn(
                    try container.decode(UUID.self, forKey: .rule), isOn: try container.decode(Bool.self, forKey: .isOn)
                )
            case "removeRules": self = .removeRules(try container.decode([UUID].self, forKey: .ruleIDs))
            case "moveRule":
                self = .moveRule(
                    try container.decode(UUID.self, forKey: .rule), to: try container.decode(Int.self, forKey: .to))
            case "duplicateRule": self = .duplicateRule(try container.decode(UUID.self, forKey: .rule))
            case "newRuleDraft":
                self = .newRuleDraft(
                    kind: try container.decode(RuleKind.self, forKey: .kind),
                    id: try container.decodeIfPresent(UInt64.self, forKey: .id))
            case "ruleDraft": self = .ruleDraft(try container.decode(UUID.self, forKey: .rule))
            case "checkRuleDraft": self = .checkRuleDraft(try container.decode(WireRuleDraft.self, forKey: .draft))
            case "saveRuleDraft": self = .saveRuleDraft(try container.decode(WireRuleDraft.self, forKey: .draft))
            case "setNetwork": self = .setNetwork(try container.decode(NetworkConditions.self, forKey: .network))
            case "networkPresets": self = .networkPresets
            case "scriptExamples": self = .scriptExamples
            case "openConnections":
                self = .openConnections(
                    path: try container.decode(String.self, forKey: .path),
                    secretsPath: try container.decode(String.self, forKey: .secretsPath),
                    protectsSecrets: try container.decodeIfPresent(Bool.self, forKey: .protectsSecrets) ?? true)
            case "connections": self = .connections
            case "checkUpstreamProxy":
                self = .checkUpstreamProxy(
                    try container.decode(WireUpstreamProxy.self, forKey: .proxy),
                    proxyPort: try container.decode(Int.self, forKey: .proxyPort))
            case "setUpstreamProxy":
                self = .setUpstreamProxy(
                    try container.decode(WireUpstreamProxy.self, forKey: .proxy),
                    proxyPort: try container.decode(Int.self, forKey: .proxyPort))
            case "newReverseProxy":
                self = .newReverseProxy(proxyPort: try container.decode(Int.self, forKey: .proxyPort))
            case "checkReverseProxy":
                self = .checkReverseProxy(
                    try container.decode(WireReverseProxy.self, forKey: .proxy),
                    proxyPort: try container.decode(Int.self, forKey: .proxyPort))
            case "saveReverseProxy":
                self = .saveReverseProxy(
                    try container.decode(WireReverseProxy.self, forKey: .proxy),
                    proxyPort: try container.decode(Int.self, forKey: .proxyPort))
            case "removeReverseProxy":
                self = .removeReverseProxy(try container.decode(UUID.self, forKey: .reverseProxy))
            case "setReverseProxyOn":
                self = .setReverseProxyOn(
                    try container.decode(UUID.self, forKey: .reverseProxy),
                    isOn: try container.decode(Bool.self, forKey: .isOn))
            case "checkHosts": self = .checkHosts(text: try container.decode(String.self, forKey: .text))
            case "addClientCertificate":
                self = .addClientCertificate(
                    files: try container.decode([String].self, forKey: .files),
                    password: try container.decodeIfPresent(String.self, forKey: .password) ?? "",
                    hosts: try container.decode(String.self, forKey: .hosts))
            case "setClientCertificateHosts":
                self = .setClientCertificateHosts(
                    try container.decode(UUID.self, forKey: .certificate),
                    hosts: try container.decode(String.self, forKey: .hosts))
            case "setClientCertificateOn":
                self = .setClientCertificateOn(
                    try container.decode(UUID.self, forKey: .certificate),
                    isOn: try container.decode(Bool.self, forKey: .isOn))
            case "removeClientCertificate":
                self = .removeClientCertificate(try container.decode(UUID.self, forKey: .certificate))
            case "openProtobuf": self = .openProtobuf(path: try container.decode(String.self, forKey: .path))
            case "protobuf": self = .protobuf
            case "addProtobufSources":
                self = .addProtobufSources(paths: try container.decode([String].self, forKey: .paths))
            case "removeProtobufSource":
                self = .removeProtobufSource(path: try container.decode(String.self, forKey: .path))
            case "reloadProtobuf": self = .reloadProtobuf
            case "openDevices":
                self = .openDevices(
                    path: try container.decode(String.self, forKey: .path),
                    allowsNetworkDevices: try container.decodeIfPresent(Bool.self, forKey: .allowsNetworkDevices)
                        ?? false)
            case "devices": self = .devices
            case "setAllowsNetworkDevices":
                self = .setAllowsNetworkDevices(try container.decode(Bool.self, forKey: .isOn))
            case "decideDevice":
                self = .decideDevice(
                    id: try container.decode(String.self, forKey: .device),
                    allow: try container.decode(Bool.self, forKey: .allow),
                    name: try container.decodeIfPresent(String.self, forKey: .name))
            case "forgetDevice": self = .forgetDevice(id: try container.decode(String.self, forKey: .device))
            case "renameDevice":
                self = .renameDevice(
                    id: try container.decode(String.self, forKey: .device),
                    name: try container.decode(String.self, forKey: .name))
            case "qrCode": self = .qrCode(text: try container.decode(String.self, forKey: .text))
            case "emulators": self = .emulators(port: try container.decode(Int.self, forKey: .port))
            case "setEmulatorUsesReqly":
                self = .setEmulatorUsesReqly(
                    serial: try container.decode(String.self, forKey: .serial),
                    isOn: try container.decode(Bool.self, forKey: .isOn),
                    port: try container.decode(Int.self, forKey: .port))
            case "copyCertificateToEmulator":
                self = .copyCertificateToEmulator(
                    serial: try container.decode(String.self, forKey: .serial),
                    certificate: try container.decode(String.self, forKey: .certificate))
            case "chooseMessageType":
                self = .chooseMessageType(
                    id: try container.decode(UInt64.self, forKey: .id), part: try Self.part(in: container),
                    type: try container.decodeIfPresent(String.self, forKey: .type))
            case "decide":
                self = .decide(
                    id: try container.decode(UInt64.self, forKey: .id),
                    edit: try container.decodeIfPresent(WirePausedEdit.self, forKey: .edit))
            case "continueAllPaused": self = .continueAllPaused
            case "checkScript": self = .checkScript(code: try container.decode(String.self, forKey: .code))
            case "highlightScript": self = .highlightScript(code: try container.decode(String.self, forKey: .code))
            case "tryScript":
                self = .tryScript(
                    code: try container.decode(String.self, forKey: .code),
                    id: try container.decode(UInt64.self, forKey: .id))
            case "send": self = .send(try container.decode(WireOutgoing.self, forKey: .request))
            case "resend": self = .resend(id: try container.decode(UInt64.self, forKey: .id))
            case "draft": self = .draft(id: try container.decode(UInt64.self, forKey: .id))
            case "curl": self = .curl(id: try container.decode(UInt64.self, forKey: .id))
            case "copyableBody": self = .copyableBody(id: try container.decode(UInt64.self, forKey: .id))
            default:
                throw Problem(.unknownCall, "There's no call \"\(name)\".")
            }
        } catch let problem as Problem {
            throw problem
        } catch {
            throw Problem(.badRequest, "The \"\(name)\" call is missing something: \(error)")
        }
    }

    private static func part(in container: KeyedDecodingContainer<Keys>) throws -> BodyPart {
        switch try container.decode(String.self, forKey: .part) {
        case "request": .request
        case "response": .response
        default: throw Problem(.badRequest, "\"part\" is \"request\" or \"response\".")
        }
    }

    /// A field left out changes nothing, `null` removes the value, and anything else sets it.
    private static func change<Value: Decodable & Sendable & Equatable>(
        _ type: Value.Type, _ key: Keys, in container: KeyedDecodingContainer<Keys>
    ) throws -> Change<Value>? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return .remove }
        return .set(try container.decode(Value.self, forKey: key))
    }

    /// The hosts as the app saved them. Entries that aren't hosts, such as from a settings file
    /// edited by hand, are left out, so the rest still count, as the Mac app reads its own.
    private struct SavedHosts: Decodable {
        struct Entry: Decodable {
            var pattern: String
            var isOn: Bool
        }

        var entries: [Entry]
        var includesEveryHost: Bool

        var hosts: DecryptedHosts {
            let valid = entries.compactMap { entry in
                HostPattern(rawValue: entry.pattern).map { DecryptedHosts.Entry($0, isOn: entry.isOn) }
            }
            return DecryptedHosts(entries: valid, includesEveryHost: includesEveryHost)
        }
    }

    /// Hands the decoder's container over, so each call reads only its own fields.
    private struct Envelope: Decodable {
        let container: KeyedDecodingContainer<Keys>
        init(from decoder: any Decoder) throws {
            container = try decoder.container(keyedBy: Keys.self)
        }
    }
}

/// Why a call failed: a code for the app to act on, and a message to show.
public struct Problem: Error, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case badRequest, unknownCall, portInUse, notFound, failed, notAvailable
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// A reply: `{"result": …}` or `{"problem": {"code": …, "message": …}}`.
enum Reply {
    static func result(_ value: some Encodable) -> Data {
        encode(["result": AnyEncodable(value)])
    }

    static func problem(_ problem: Problem) -> Data {
        encode(["problem": AnyEncodable(problem)])
    }

    static func encode(_ value: some Encodable) -> Data {
        // Every message is plain data, so encoding can't fail.
        (try? Wire.encoder.encode(value)) ?? Data(#"{"problem":{"code":"failed","message":"?"}}"#.utf8)
    }
}

enum Wire {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Times go as seconds since 1970, which every language reads.
    static func seconds(_ date: Date?) -> Double? {
        date?.timeIntervalSince1970
    }
}

struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

struct Empty: Codable {}

// MARK: - What the replies and events carry

/// Every exchange in a session at a glance, as the Mac's menu-bar panel shows them.
public struct WireTrafficSummary: Codable, Sendable, Equatable {
    public var total: Int
    /// What every exchange sent and received.
    public var bytes: Int64
    public var newest: WireRow?

    init(_ all: ExchangeList) {
        total = all.count
        bytes = all.reduce(0) { $0 + $1.bytesSent + $1.bytesReceived }
        newest = all.last.map(WireRow.init)
    }
}

/// A row of the request list.
public struct WireRow: Codable, Sendable, Equatable {
    public var id: UInt64
    /// `http`, or `tunnel` for an encrypted connection that passes through untouched.
    public var kind: String
    public var method: String
    public var scheme: String
    public var host: String
    public var port: Int
    public var target: String
    public var status: Int?
    /// `sending`, `waiting`, `receiving`, `open`, `paused`, `completed` or `failed`.
    public var state: String
    public var started: Double
    public var duration: Double?
    public var bytesSent: Int64
    public var bytesReceived: Int64
    public var contentType: String?
    public var app: String?
    /// The app's program, for its icon.
    public var appPath: String?
    public var device: String?
    public var isPinned: Bool
    public var color: String?
    public var comment: String?
    public var messageCount: Int
    public var grpcStatus: Int?
    /// `informational`, `success`, `redirection`, `clientError` or `serverError`, for the status
    /// dot's color. A gRPC call's status decides it when its HTTP status is 2xx.
    public var statusClass: String?
    /// What a gRPC status that isn't OK means, such as "Not found", for the status's tooltip.
    public var grpcTitle: String?

    init(_ summary: ExchangeSummary) {
        id = summary.id.rawValue
        kind = WireKind.name(summary.kind)
        method = summary.method
        scheme = summary.scheme
        host = summary.host
        port = summary.port
        target = summary.target
        status = summary.status
        state = WireState(summary.state).name
        started = summary.started.timeIntervalSince1970
        duration = summary.duration
        bytesSent = summary.bytesSent
        bytesReceived = summary.bytesReceived
        contentType = summary.contentType
        app = summary.source?.name
        appPath = summary.source?.path
        device = summary.device?.name
        isPinned = summary.annotation.isPinned
        color = summary.annotation.color?.rawValue
        comment = summary.annotation.comment
        messageCount = summary.messageCount
        grpcStatus = summary.grpcStatus
        statusClass = summary.statusClass.map(Self.name)
        grpcTitle = summary.grpcStatus.flatMap { $0 == 0 ? nil : GRPCStatus(code: $0).title }
    }

    static func name(_ statusClass: StatusClass) -> String {
        switch statusClass {
        case .informational: "informational"
        case .success: "success"
        case .redirection: "redirection"
        case .clientError: "clientError"
        case .serverError: "serverError"
        }
    }
}

enum WireKind {
    static func name(_ kind: ExchangeKind) -> String {
        switch kind {
        case .http: "http"
        case .tunnel: "tunnel"
        }
    }
}

struct WireState {
    var name: String
    var failure: String?

    init(_ state: ExchangeState) {
        switch state {
        case .sending: name = "sending"
        case .waiting: name = "waiting"
        case .receiving: name = "receiving"
        case .open: name = "open"
        case .paused: name = "paused"
        case .completed: name = "completed"
        case .failed(let failure):
            name = "failed"
            self.failure = failure.message
        }
    }
}

public struct WireHeader: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    /// Credentials or cookies, which the details show as dots until you choose to see them.
    public var isSecret: Bool

    public init(name: String, value: String, isSecret: Bool = false) {
        self.name = name
        self.value = value
        self.isSecret = isSecret
    }

    init(_ field: HeaderField) {
        self.init(name: field.name, value: field.value, isSecret: field.isSecret)
    }
}

/// An exchange's details. Its bodies come separately, as bytes or made ready to show.
public struct WireDetails: Codable, Sendable, Equatable {
    public var id: UInt64
    /// `http` or `tunnel`, as in ``WireRow``.
    public var kind: String
    public var method: String
    /// The full URL, when one can be formed.
    public var url: String?
    public var scheme: String
    public var host: String
    public var port: Int
    public var target: String
    /// The target without its query.
    public var path: String
    /// The query's names and values, decoded, in order.
    public var query: [WireHeader]
    public var version: String
    public var requestHeaders: [WireHeader]
    public var requestBodySize: Int
    public var status: Int?
    public var reason: String?
    public var responseVersion: String?
    public var responseHeaders: [WireHeader]?
    public var responseBodySize: Int
    public var state: String
    /// Why the exchange failed, in plain words.
    public var failure: String?
    public var started: Double
    public var ended: Double?
    public var remoteAddress: String?
    public var tlsVersion: String?
    public var serverProtocol: String?
    public var reusedConnection: Bool
    public var upstreamProxy: String?
    public var reverseProxy: String?
    public var clientCertificate: String?
    public var sentByReqly: Bool
    /// `plain`, `encryptedTunnel`, `decrypted` or `certificateRejected`: what the details say
    /// about decryption, and the action that fits.
    public var decryption: String
    public var app: String?
    public var device: String?
    public var isPinned: Bool
    public var color: String?
    public var comment: String?
    public var bytesSent: Int64
    public var bytesReceived: Int64
    /// Whether the connection switched to WebSocket, and how many messages it carried.
    public var isWebSocket: Bool
    public var messageCount: Int
    public var grpc: WireGRPC?
    public var responseTrailers: [WireHeader]?
    /// The steps of the exchange, for the Timing tab's waterfall.
    public var phases: [WirePhase]
    /// When Reqly started on a connection to the server, which a reused connection skips.
    public var connectStarted: Double?
    /// The rules that changed the exchange, one line per rule.
    public var appliedRules: [WireRule]
    public var scriptOutput: [WireScriptOutput]
    public var source: Source?
    public var deviceInfo: WireDeviceInfo?
    /// `request` or `response`, while a breakpoint holds the exchange.
    public var pausedPart: String?
    public var requestCookies: [WireCookie]
    public var responseCookies: [WireCookie]

    init(_ exchange: Exchange) {
        let state = WireState(exchange.state)
        id = exchange.id.rawValue
        kind = WireKind.name(exchange.kind)
        method = exchange.request.method
        url = exchange.request.url?.absoluteString
        scheme = exchange.request.scheme
        host = exchange.request.host
        port = exchange.request.port
        target = exchange.request.target
        path = exchange.request.path
        query =
            (exchange.request.query).map {
                QueryParameters.parse($0).map { WireHeader(name: $0.name, value: $0.value) }
            } ?? []
        version = exchange.request.version
        requestHeaders = exchange.request.headers.map(WireHeader.init)
        requestBodySize = exchange.requestBody.count
        status = exchange.response?.status
        reason = exchange.response?.reason
        responseVersion = exchange.response?.version
        responseHeaders = exchange.response?.headers.map(WireHeader.init)
        responseBodySize = exchange.responseBody.count
        self.state = state.name
        failure = state.failure
        started = exchange.timing.started.timeIntervalSince1970
        ended = Wire.seconds(exchange.timing.ended)
        remoteAddress = exchange.remoteAddress
        tlsVersion = exchange.tlsVersion
        serverProtocol = exchange.serverProtocol
        reusedConnection = exchange.reusedConnection
        upstreamProxy = exchange.upstreamProxy
        reverseProxy = exchange.reverseProxy
        clientCertificate = exchange.clientCertificate
        sentByReqly = exchange.sentByReqly
        decryption =
            switch DecryptionSituation(exchange) {
            case .plain: "plain"
            case .encryptedTunnel: "encryptedTunnel"
            case .decrypted: "decrypted"
            case .certificateRejected: "certificateRejected"
            }
        app = exchange.source?.name
        device = exchange.device?.name
        isPinned = exchange.annotation.isPinned
        color = exchange.annotation.color?.rawValue
        comment = exchange.annotation.comment
        bytesSent = exchange.bytesSent
        bytesReceived = exchange.bytesReceived
        messageCount = exchange.messageCount
        isWebSocket = exchange.messageCount > 0 || exchange.response?.status == 101
        grpc = exchange.grpcStatus.map(WireGRPC.init)
        responseTrailers = exchange.responseTrailers.map { $0.map(WireHeader.init) }
        phases = exchange.timingPhases.map(WirePhase.init)
        connectStarted = Wire.seconds(exchange.timing.connectStarted)
        appliedRules = WireRule.joined(exchange.appliedRules)
        scriptOutput = exchange.scriptOutput.map {
            WireScriptOutput(rule: $0.rule, part: $0.part.rawValue, lines: $0.lines)
        }
        source = exchange.source
        deviceInfo = exchange.device.map(WireDeviceInfo.init)
        if case .paused(let part) = exchange.state {
            pausedPart = part.rawValue
        }
        requestCookies = exchange.request.headers.requestCookies.map { WireCookie(name: $0.name, value: $0.value) }
        responseCookies = (exchange.response?.headers.responseCookies ?? []).map(WireCookie.init)
    }
}

/// A body made ready to show: what it is, the ways to view it, and its text in each.
public struct WireBody: Encodable, Sendable, Equatable {
    /// Such as "JSON" or "PNG".
    public var kind: String
    /// `formatted`, `tree`, `raw`, `preview`, `form` or `hex`, the best first.
    public var modes: [String]
    /// Why the body shows differently than its type suggests.
    public var note: String?
    public var formatted: WireCode?
    public var raw: WireCode?
    /// The keys and values, or the fields of protobuf messages, for the Tree view. Left out for
    /// a tree too big to send, which `treeIsTooBig` says.
    public var tree: WireTree?
    public var treeIsTooBig: Bool
    /// A form's fields, or a multipart body's parts.
    public var fields: [WireFormField]?
    /// Whether it's an image, for the Preview view.
    public var isImage: Bool
    /// The body's size as it came, and unpacked.
    public var wireSize: Int
    public var size: Int
    public var unpackedFrom: String?
    public var isTruncated: Bool
    public var readsAsProtobuf: Bool
    public var messageCount: Int?
    public var protobufType: String?
    /// The message type chosen for bodies like this one, if one was.
    public var chosenType: String?
    /// Whether the `.proto` files have message types to choose from.
    public var hasMessageTypes = false
    /// The status a gRPC body ended with, for its footnote.
    public var grpc: WireGRPC?
    public var details: [String]

    /// More nodes than this, and the Tree view isn't offered.
    static let treeLimit = 50_000

    init(_ body: BodyPresentation) {
        kind = body.kind.name
        let treeIsTooBig = (body.tree?.count ?? 0) > Self.treeLimit
        modes = body.modes.filter { !(treeIsTooBig && $0 == .tree) }.map(Self.name)
        note = body.note
        formatted = body.formatted.map { WireCode(text: $0.text, tokens: $0.tokens, isCode: $0.isCode) }
        raw = body.raw.map { WireCode(text: $0.text, tokens: $0.tokens, isCode: $0.isCode) }
        tree = treeIsTooBig ? nil : body.tree.map(WireTree.init)
        self.treeIsTooBig = treeIsTooBig
        if let fields = body.fields {
            self.fields = fields.map { WireFormField(name: $0.name, value: $0.value, isFile: false) }
        } else if let parts = body.parts {
            fields = parts.map(WireFormField.init)
        }
        if case .image = body.kind {
            isImage = true
        } else {
            isImage = false
        }
        wireSize = body.wireSize
        size = body.content.count
        unpackedFrom = body.unpackedFrom
        isTruncated = body.isTruncated
        readsAsProtobuf = body.readsAsProtobuf
        messageCount = body.messageCount
        protobufType = body.protobufType
        grpc = body.grpcStatus.map(WireGRPC.init)
        details = body.details
    }

    static func name(_ mode: BodyMode) -> String {
        switch mode {
        case .formatted: "formatted"
        case .tree: "tree"
        case .raw: "raw"
        case .preview: "preview"
        case .form: "form"
        case .hex: "hex"
        }
    }
}

/// The list's filters, as the filter bar sets them. An exchange shows when it passes every filter
/// that's set, and one that's left out lets everything through.
public struct WireFilter: Codable, Sendable, Equatable {
    /// `success`, `redirection`, `clientError`, `serverError` or `failed`. An exchange needs to
    /// match just one.
    public var statuses: [String]?
    /// `json`, `xml`, `html`, `javascript`, `css`, `image`, `media` or `other`.
    public var contents: [String]?
    public var host: String?
    public var method: String?
    public var source: Source?
    /// This computer's own traffic, as `""`, or a device's, by its ID.
    public var device: String?

    public init(
        statuses: [String]? = nil, contents: [String]? = nil, host: String? = nil, method: String? = nil,
        source: Source? = nil, device: String? = nil
    ) {
        self.statuses = statuses
        self.contents = contents
        self.host = host
        self.method = method
        self.source = source
        self.device = device
    }

    static let statusNames: [String: StatusFilter] = [
        "success": .success, "redirection": .redirection, "clientError": .clientError,
        "serverError": .serverError, "failed": .failed,
    ]
    static let contentNames: [String: ContentGroup] = [
        "json": .json, "xml": .xml, "html": .html, "javascript": .javascript, "css": .css, "image": .image,
        "media": .media, "other": .other,
    ]

    /// The filter, or what's wrong with it.
    func filter() throws(Problem) -> TrafficFilter {
        var filter = TrafficFilter()
        for name in statuses ?? [] {
            guard let status = Self.statusNames[name] else {
                throw Problem(.badRequest, "There's no status \"\(name)\".")
            }
            filter.statuses.insert(status)
        }
        for name in contents ?? [] {
            guard let content = Self.contentNames[name] else {
                throw Problem(.badRequest, "There's no kind of content \"\(name)\".")
            }
            filter.contents.insert(content)
        }
        filter.host = host
        filter.method = method
        filter.source = source
        filter.device = device.map(WireDevice.choice)
        return filter
    }
}

/// This computer, as `""`, or a device, by its ID. IDs are never empty.
enum WireDevice {
    static func choice(_ name: String) -> DeviceChoice {
        name.isEmpty ? .thisMac : .device(name)
    }

    static func name(_ choice: DeviceChoice) -> String {
        switch choice {
        case .thisMac: ""
        case .device(let id): id
        }
    }
}

/// The sidebar's rows, as the list engine keeps them for the Mac's sidebar. Each row has a key,
/// which `setScope` takes to narrow the list to it, and its count.
public struct WireSidebar: Encodable, Sendable, Equatable {
    public struct Row: Encodable, Sendable, Equatable {
        public var key: String
        public var name: String
        public var count: Int
        /// An app's program, for its icon.
        public var path: String?
    }

    public struct DeviceRow: Encodable, Sendable, Equatable {
        public var key: String
        /// This computer, as `""`, or the device's ID, as filters name it.
        public var id: String
        /// `nil` for this computer.
        public var name: String?
        /// `network`, `simulator` or `emulator`; `nil` for this computer.
        public var kind: String?
        public var count: Int
        public var apps: [Row]
        /// The hosts its traffic from no known app went to.
        public var otherHosts: [Row]
    }

    public var total: Int
    public var pinned: Int
    /// This computer's apps, by name.
    public var apps: [Row]
    /// Every host, in the order people expect: h2 before h10.
    public var hosts: [Row]
    /// This computer, then each device, by name. Empty while all traffic comes from this computer.
    public var devices: [DeviceRow]
    /// The methods the requests used, the common ones first, for the filters.
    public var methods: [String]
    /// Every app on any device, by name, for the filters.
    public var sources: [Source]
}

/// How the rows changed, in order, as the list should change its own. Rows are counted from 0.
/// `inserted` names each new row's exchange, so the app needs no other call to keep its list of
/// rows; it asks for the rows it shows with `rows`.
public enum RowStep: Codable, Sendable, Equatable {
    /// Rows taken out, at their places before.
    case removed([Int])
    /// Rows put in, each at its place after, with its exchange.
    case inserted([InsertedRow])
    /// Exchanges whose rows stay but show something new.
    case changed([UInt64])
    /// Every row, when so many changed that listing the changes would take longer.
    case reset([UInt64])

    public struct InsertedRow: Codable, Sendable, Equatable {
        public var row: Int
        public var id: UInt64
    }

    private enum Keys: String, CodingKey {
        case removed, inserted, changed, reset
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .removed(let rows): try container.encode(rows, forKey: .removed)
        case .inserted(let rows): try container.encode(rows, forKey: .inserted)
        case .changed(let ids): try container.encode(ids, forKey: .changed)
        case .reset(let ids): try container.encode(ids, forKey: .reset)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let rows = try container.decodeIfPresent([Int].self, forKey: .removed) {
            self = .removed(rows)
        } else if let rows = try container.decodeIfPresent([InsertedRow].self, forKey: .inserted) {
            self = .inserted(rows)
        } else if let ids = try container.decodeIfPresent([UInt64].self, forKey: .changed) {
            self = .changed(ids)
        } else {
            self = .reset(try container.decode([UInt64].self, forKey: .reset))
        }
    }
}

/// Something that happened in a session, sent to the app as it happens.
public enum Event: Sendable, Equatable {
    /// The rows changed. `version` goes up by one each time.
    case rows(version: Int, total: Int, shown: Int, steps: [RowStep])
    /// Saving traffic failed, with a message to show; or it works again, with `nil`.
    case storageProblem(String?)
    /// The sidebar's rows, when apps, hosts or devices came or went.
    case sidebar(WireSidebar)
    /// The sidebar's counts that changed, by row key, when no row came or went.
    case counts(total: Int, pinned: Int, counts: [String: Int])
    /// How far a HAR export got.
    case exportProgress(done: Int, total: Int)
    /// A breakpoint holds a request or a response, ready to edit, until `decide` answers.
    case paused(WirePaused)
    /// A held exchange went on or went away, as when its app gave up.
    case resumed(id: UInt64)
    /// A device on the network wants to send its traffic through Reqly, and waits for
    /// `decideDevice`. `waiting` counts it with the others that wait.
    case deviceWaiting(id: String, address: String, waiting: Int)

    var json: Data {
        switch self {
        case .rows(let version, let total, let shown, let steps):
            Reply.encode(RowsEvent(version: version, total: total, shown: shown, steps: steps))
        case .storageProblem(let message):
            Reply.encode(StorageProblemEvent(message: message))
        case .sidebar(let sidebar):
            Reply.encode(SidebarEvent(sidebar: sidebar))
        case .counts(let total, let pinned, let counts):
            Reply.encode(CountsEvent(total: total, pinned: pinned, counts: counts))
        case .exportProgress(let done, let total):
            Reply.encode(ExportProgressEvent(done: done, total: total))
        case .paused(let paused):
            Reply.encode(PausedEvent(paused: paused))
        case .resumed(let id):
            Reply.encode(ResumedEvent(id: id))
        case .deviceWaiting(let id, let address, let waiting):
            Reply.encode(DeviceWaitingEvent(id: id, address: address, waiting: waiting))
        }
    }

    private struct DeviceWaitingEvent: Encodable {
        var event = "deviceWaiting"
        var id: String
        var address: String
        var waiting: Int
    }

    private struct PausedEvent: Encodable {
        var event = "paused"
        var paused: WirePaused
    }

    private struct ResumedEvent: Encodable {
        var event = "resumed"
        var id: UInt64
    }

    private struct ExportProgressEvent: Encodable {
        var event = "exportProgress"
        var done: Int
        var total: Int
    }

    private struct SidebarEvent: Encodable {
        var event = "sidebar"
        var sidebar: WireSidebar

        func encode(to encoder: any Encoder) throws {
            try sidebar.encode(to: encoder)
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(event, forKey: .event)
        }

        private enum Keys: String, CodingKey {
            case event
        }
    }

    private struct CountsEvent: Encodable {
        var event = "counts"
        var total: Int
        var pinned: Int
        var counts: [String: Int]
    }

    private struct RowsEvent: Encodable {
        var event = "rows"
        var version: Int
        var total: Int
        var shown: Int
        var steps: [RowStep]
    }

    private struct StorageProblemEvent: Encodable {
        var event = "storageProblem"
        var message: String?
    }
}
