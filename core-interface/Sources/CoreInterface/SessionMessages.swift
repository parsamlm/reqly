import BodyKit
import Foundation
import Presentation
import ReqlyModel
import TrafficStore

// The JSON messages the Windows app sends SessionHost, and the replies and events it gets back:
// a thin layer over SessionHost's own methods, which reads each call, runs the method, and writes
// what it gave as the app reads it.

extension SessionHost {
    /// Opens a session, live or from a file, with the parts of the system it runs on, and starts
    /// sending its events to `send`, as JSON.
    public static func open(
        _ options: OpenOptions, system: SystemParts, protobuf: ProtobufLibrary = .shared,
        send: @escaping @Sendable (Data) -> Void
    ) async throws(Problem) -> SessionHost {
        try await open(options, system: system, protobuf: protobuf, events: { send($0.json) })
    }

    /// Answers a request with a reply, both JSON.
    public func reply(to request: Data) async -> Data {
        do {
            return try await handle(try Call(json: request))
        } catch {
            return Reply.problem(error)
        }
    }

    /// Part of a body as bytes, by the exchange's number, as `body(_:part:offset:limit:unpacked:)`
    /// gives it, for the C interface.
    public func body(_ id: UInt64, part: BodyPart, offset: Int, limit: Int, unpacked: Bool = false) async -> Data? {
        await body(ExchangeID(rawValue: id), part: part, offset: offset, limit: limit, unpacked: unpacked)
    }

    /// A body as Copy Response Body copies it, as the reply carries it.
    static func copyable(_ data: Data, headers: Headers) -> WireCopyableBody {
        WireCopyableBody(CopyableBody(data, headers: headers))
    }

    func handle(_ call: Call) async throws(Problem) -> Data {
        switch call {
        case .version:
            return Reply.result(["version": interfaceVersion])
        case .startCapturing(let port):
            return Reply.result(["port": try await startCapturing(port: port)])
        case .stopCapturing:
            try await stopCapturing()
            return Reply.result(Empty())
        case .rowIDs:
            let (version, ids) = rowIDs()
            return Reply.result(WireRowIDs(version: version, ids: ids.map(\.rawValue)))
        case .rows(let ids):
            return Reply.result(["rows": rows(ids.map(ExchangeID.init(rawValue:))).map(WireRow.init)])
        case .trafficSummary:
            return Reply.result(WireTrafficSummary(trafficSummary()))
        case .setSearch(let text):
            setSearch(text)
            return Reply.result(Empty())
        case .details(let id):
            return Reply.result(WireDetails(try await exchange(ExchangeID(rawValue: id))))
        case .presentBody(let id, let part):
            let presented = try await presentBody(ExchangeID(rawValue: id), part: part)
            var wire = WireBody(presented.body)
            wire.chosenType = presented.chosenType
            wire.hasMessageTypes = presented.hasMessageTypes
            return Reply.result(wire)
        case .bodyNode(let id, let part, let node):
            let found = try await bodyNode(ExchangeID(rawValue: id), part: part, node: node)
            return Reply.result(["path": found.path, "copy": found.copyText])
        case .raw(let id, let showsSecrets):
            return Reply.result(WireRaw(try await raw(ExchangeID(rawValue: id), showsSecrets: showsSecrets)))
        case .messages(let id, let from):
            let messages = await messages(ExchangeID(rawValue: id), from: from)
            return Reply.result([
                "messages": messages.enumerated().map { WireMessage(number: from + $0.offset, $0.element) }
            ])
        case .presentMessage(let id, let number):
            return Reply.result(WireBody(try await presentMessage(ExchangeID(rawValue: id), number: number)))
        case .https:
            return Reply.result(WireHTTPS(try await https()))
        case .setUpHTTPS:
            return Reply.result(WireHTTPS(try await setUpHTTPS()))
        case .removeHTTPS:
            return Reply.result(WireHTTPS(try await removeHTTPS()))
        case .setDecryptedHosts(let hosts):
            return Reply.result(WireHTTPS(try await setDecryptedHosts(hosts)))
        case .decryptHost(let host):
            return Reply.result(WireHTTPS(try await decryptHost(host)))
        case .stopDecryptingHost(let host):
            return Reply.result(WireHTTPS(try await stopDecryptingHost(host)))
        case .addDecryptedHost(let text):
            return Reply.result(WireHTTPS(try await addDecryptedHost(text)))
        case .removeDecryptedHosts(let patterns):
            return Reply.result(WireHTTPS(try await removeDecryptedHosts(patterns)))
        case .setHostDecrypted(let pattern, let isOn):
            return Reply.result(WireHTTPS(try await setHostDecrypted(pattern, isOn: isOn)))
        case .setDecryptsEveryHost(let isOn):
            return Reply.result(WireHTTPS(try await setDecryptsEveryHost(isOn)))
        case .decryptsHost(let host):
            return Reply.result(["decrypts": try await decryptsHost(host)])
        case .setScope(let key):
            try setScope(key)
            return Reply.result(Empty())
        case .setFilter(let wire):
            setFilter(try wire.filter())
            return Reply.result(Empty())
        case .annotate(let id, let isPinned, let color, let comment):
            try annotate(ExchangeID(rawValue: id), isPinned: isPinned, color: color, comment: comment)
            return Reply.result(Empty())
        case .unpinAll:
            unpinAll()
            return Reply.result(Empty())
        case .clear:
            await clear()
            return Reply.result(Empty())
        case .setRules(let set):
            setRules(set)
            return Reply.result(Empty())
        case .openRules(let path):
            return Reply.result(WireRules(openRules(URL(fileURLWithPath: path))))
        case .rules:
            return Reply.result(WireRules(rules()))
        case .setRuleKindOn(let kind, let isOn):
            return Reply.result(WireRules(setRuleKindOn(kind, isOn: isOn)))
        case .setRuleOn(let id, let isOn):
            return Reply.result(WireRules(setRuleOn(id, isOn: isOn)))
        case .removeRules(let ids):
            return Reply.result(WireRules(removeRules(ids)))
        case .moveRule(let id, let place):
            return Reply.result(WireRules(moveRule(id, to: place)))
        case .duplicateRule(let id):
            return Reply.result(WireRules(duplicateRule(id)))
        case .newRuleDraft(let kind, let id):
            return Reply.result(WireRuleDraft(try newRuleDraft(kind: kind, from: id.map(ExchangeID.init(rawValue:)))))
        case .ruleDraft(let id):
            return Reply.result(WireRuleDraft(try ruleDraft(id)))
        case .checkRuleDraft(let wire):
            return Reply.result(WireRuleCheck(checkRuleDraft(wire.draft)))
        case .saveRuleDraft(let wire):
            return Reply.result(WireRules(try saveRuleDraft(wire.draft)))
        case .setNetwork(let network):
            return Reply.result(WireRules(setNetwork(network)))
        case .networkPresets:
            return Reply.result(networkPresets())
        case .scriptExamples:
            return Reply.result(scriptExamples().map { ["id": $0.id, "code": $0.code] })
        case .openProtobuf(let path):
            return Reply.result(WireProtobuf(await protobuf.open(URL(fileURLWithPath: path))))
        case .protobuf:
            return Reply.result(WireProtobuf(await protobuf.state))
        case .addProtobufSources(let paths):
            return Reply.result(WireProtobuf(await protobuf.add(paths.map { URL(fileURLWithPath: $0) })))
        case .removeProtobufSource(let path):
            return Reply.result(WireProtobuf(await protobuf.remove(path)))
        case .reloadProtobuf:
            return Reply.result(WireProtobuf(await protobuf.reload()))
        case .openDevices(let path, let allows):
            let state = await openDevices(URL(fileURLWithPath: path), allowsNetworkDevices: allows)
            return Reply.result(WireDevices(state))
        case .devices:
            return Reply.result(WireDevices(devices()))
        case .setAllowsNetworkDevices(let allows):
            return Reply.result(WireDevices(await setAllowsNetworkDevices(allows)))
        case .decideDevice(let id, let allow, let name):
            return Reply.result(WireDevices(decideDevice(id, allow: allow, name: name)))
        case .forgetDevice(let id):
            return Reply.result(WireDevices(forgetDevice(id)))
        case .renameDevice(let id, let name):
            return Reply.result(WireDevices(try await renameDevice(id, to: name)))
        case .qrCode(let text):
            let code = try qrCode(text)
            return Reply.result(["rows": code.modules.map { row in row.map { $0 ? "1" : "0" }.joined() }])
        case .emulators(let port):
            return Reply.result(WireEmulators(await emulators(port: port)))
        case .setEmulatorUsesReqly(let serial, let isOn, let port):
            return Reply.result(WireCheck(try await setEmulatorUsesReqly(serial: serial, isOn: isOn, port: port)))
        case .copyCertificateToEmulator(let serial, let certificate):
            guard let der = Data(base64Encoded: certificate) else {
                // Without adb, that comes first, as it does for a certificate that reads.
                _ = try adb()
                throw Problem(.badRequest, "The certificate isn't base64.")
            }
            return Reply.result(WireCheck(try await copyCertificateToEmulator(serial: serial, certificate: der)))
        case .chooseMessageType(let id, let part, let type):
            try await chooseMessageType(type, for: ExchangeID(rawValue: id), part: part)
            return Reply.result(Empty())
        case .openConnections(let path, let secretsPath, let protectsSecrets):
            let secrets = URL(fileURLWithPath: secretsPath)
            let state = await openConnections(
                URL(fileURLWithPath: path), secrets: secrets, protectsSecrets: protectsSecrets)
            return Reply.result(WireConnections(state))
        case .connections:
            return Reply.result(WireConnections(await connections()))
        case .checkUpstreamProxy(let proxy, let port):
            return Reply.result(["problem": checkUpstreamProxy(proxy.draft, proxyPort: port)])
        case .setUpstreamProxy(let wire, let port):
            return Reply.result(WireConnections(try setUpstreamProxy(wire.draft, proxyPort: port)))
        case .newReverseProxy(let port):
            return Reply.result(WireReverseProxy(newReverseProxy(proxyPort: port)))
        case .checkReverseProxy(let wire, let port):
            return Reply.result(WireCheck(checkReverseProxy(wire.draft, proxyPort: port)))
        case .saveReverseProxy(let wire, let port):
            return Reply.result(WireConnections(try await saveReverseProxy(wire.draft, proxyPort: port)))
        case .removeReverseProxy(let id):
            return Reply.result(WireConnections(await removeReverseProxy(id)))
        case .setReverseProxyOn(let id, let isOn):
            return Reply.result(WireConnections(await setReverseProxyOn(id, isOn: isOn)))
        case .checkHosts(let text):
            return Reply.result(WireHostsCheck(checkHosts(text)))
        case .addClientCertificate(let files, let password, let hosts):
            let state = try addClientCertificate(
                files: files.map { URL(fileURLWithPath: $0) }, password: password, hosts: hosts)
            return Reply.result(WireConnections(state))
        case .setClientCertificateHosts(let id, let hosts):
            return Reply.result(WireConnections(try setClientCertificateHosts(id, hosts: hosts)))
        case .setClientCertificateOn(let id, let isOn):
            return Reply.result(WireConnections(setClientCertificateOn(id, isOn: isOn)))
        case .removeClientCertificate(let id):
            return Reply.result(WireConnections(removeClientCertificate(id)))
        case .decide(let id, let changes):
            // The changes go onto the held message as you're editing it. With none, it stops.
            let id = ExchangeID(rawValue: id)
            if let changes, var edit = pausedEdit(id) {
                changes.apply(to: &edit)
                try resumePaused(id, as: edit)
            } else {
                try stopPaused(id)
            }
            return Reply.result(Empty())
        case .continueAllPaused:
            continueAllPaused()
            return Reply.result(Empty())
        case .checkScript(let code):
            return Reply.result(["problem": await checkScript(code)])
        case .highlightScript(let code):
            return Reply.result(["tokens": WireCode.parts(highlightScript(code))])
        case .tryScript(let code, let id):
            let trials = await tryScript(code, on: ExchangeID(rawValue: id))
            return Reply.result(["trials": trials.map(WireScriptTrial.init)])
        case .send(let outgoing):
            return Reply.result(["id": try await send(outgoing.draft).rawValue])
        case .resend(let id):
            return Reply.result(["id": try await resend(ExchangeID(rawValue: id)).rawValue])
        case .draft(let id):
            return Reply.result(WireOutgoing(try await draft(ExchangeID(rawValue: id))))
        case .curl(let id):
            return Reply.result(["command": try await curl(ExchangeID(rawValue: id))])
        case .saveSession(let path, let hidesSecrets):
            try await saveSession(to: URL(fileURLWithPath: path), hidingSecrets: hidesSecrets)
            return Reply.result(Empty())
        case .exportHAR(let path, let ids, let includesResponseBodies, let hidesSecrets, let version):
            let exported = try await exportHAR(
                to: URL(fileURLWithPath: path), ids: ids?.map(ExchangeID.init(rawValue:)),
                includesResponseBodies: includesResponseBodies, hidesSecrets: hidesSecrets, creatorVersion: version)
            return Reply.result(["exported": exported])
        case .copyableBody(let id):
            return Reply.result(WireCopyableBody(try await copyableBody(ExchangeID(rawValue: id))))
        }
    }
}

/// Every row's exchange, as `rowIDs` replies.
struct WireRowIDs: Encodable {
    var version: Int
    var ids: [UInt64]
}

/// A body as Copy Response Body copies it, with one of the three.
struct WireCopyableBody: Encodable, Equatable {
    var text: String?
    /// The image's bytes, in base64.
    var image: String?
    var hex: String?

    init(_ body: CopyableBody) {
        switch body {
        case .text(let text): self.text = text
        case .image(let data): image = data.base64EncodedString()
        case .hex(let hex): self.hex = hex
        }
    }
}
