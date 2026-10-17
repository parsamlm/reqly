import BodyKit
import Capture
import CertificateAuthority
import DeviceBridge
import Foundation
import HAR
import Presentation
import ProxyEngine
import ReqlyModel
import TrafficStore
import WindowsSystem

/// One session for the app: the live one, or a saved one it opened. It keeps the request list
/// the way the Mac app does, with the same ``TrafficList``, and tells the app how the rows
/// change, so the app only ever asks for the rows it shows.
public actor SessionHost {
    /// More rows than this joining at once are sent as every row instead.
    static let resetThreshold = 10_000

    /// Reqly itself, as the app that sent the requests you write and resend.
    static let reqly = Source(name: "Reqly", path: CommandLine.arguments.first)

    public nonisolated let capture: CaptureSession
    /// HTTPS decryption, for a live session with a certificate store.
    private let https: HTTPSHost?
    private let send: @Sendable (Data) -> Void
    private var list = TrafficList()
    private var version = 0
    private var storeSearch: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    /// The sidebar rows' scopes, by key, as the latest `sidebar` event named them.
    private var scopes: [String: TrafficList.Scope] = ["all": .all, "pinned": .pinned]
    /// The list's names as the latest `sidebar` event showed them.
    private var namesSent = -1
    /// The total and pinned counts the latest sidebar or counts event showed.
    private var totalsSent = (total: -1, pinned: -1)
    /// Requests and responses held at breakpoints, as you're editing them, by exchange.
    private var paused: [UInt64: PausedEdit] = [:]
    /// The rules, as the Rules window edits them.
    private var rules = RulesBook()
    /// The upstream proxy, the reverse proxies and the client certificates, as Settings edit them.
    private var connections = ConnectionsBook()
    /// Why each reverse proxy that's on isn't listening, while capturing.
    private var reverseProxyProblems: [UUID: String] = [:]
    /// The `.proto` files bodies are read with, which every session shares.
    private let protobuf: ProtobufLibrary
    /// The devices you let in, the ones waiting, and the names you gave devices.
    private var devices = DevicesBook()
    private var devicesFile: URL?
    private var allowsNetworkDevices = false
    /// Why devices can't connect, or why the devices you let in can't be saved.
    private var devicesProblem: String?
    /// The connections from each waiting device, waiting for you to decide.
    private var waitingDevices: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// The devices you let in, for naming their connections as they open.
    private let origins: DeviceOrigins
    /// Bodies made ready to show lately, so the Tree view's paths and the Hex view's bytes need no
    /// second reading.
    private var presented: [(key: PresentedBody, body: BodyPresentation)] = []
    /// The latest change sent to the session. Each waits for the one before, so a pin made just
    /// before clearing is saved in time to keep its exchange, as in the Mac app.
    private var lastSessionCall: Task<Void, Never>?

    /// Opens a session, live or from a file, and starts sending its events to `send`.
    public static func open(
        _ options: OpenOptions, protobuf: ProtobufLibrary = .shared, send: @escaping @Sendable (Data) -> Void
    ) async throws(Problem) -> SessionHost {
        let folder = URL(fileURLWithPath: options.sessionsFolder, isDirectory: true)
        let store: TrafficStore
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let file = options.file {
                let url = URL(fileURLWithPath: file)
                if url.pathExtension.lowercased() == "har" {
                    // A HAR file, from a browser or another tool, becomes a session of its own.
                    let entries = try HARReader.entries(from: try Data(contentsOf: url))
                    var messages: [ExchangeID: [WebSocketMessage]] = [:]
                    for entry in entries where !entry.messages.isEmpty {
                        messages[entry.exchange.id] = entry.messages
                    }
                    store = try await TrafficStore.newSession(
                        in: folder, with: entries.map(\.exchange), messages: messages)
                } else {
                    store = try await TrafficStore.openSession(url, in: folder)
                }
            } else {
                store = try TrafficStore.newSession(in: folder)
            }
        } catch SessionFileError.notASession {
            throw Problem(.failed, "This file isn't a session that Reqly saved.")
        } catch SessionFileError.savedByNewerReqly {
            throw Problem(.failed, "A newer version of Reqly saved this session. Update Reqly to open it.")
        } catch HARError.unreadable(let reason) {
            throw Problem(.failed, reason)
        } catch {
            throw Problem(.failed, "Reqly couldn't open the session: \(error.localizedDescription)")
        }
        let extraRoots = (options.extraTrustedRoots ?? []).compactMap { Data(base64Encoded: $0).map([UInt8].init) }
        let origins = DeviceOrigins()
        let capture = CaptureSession(
            store: store, systemProxy: systemProxy(options), extraTrustedRoots: extraRoots,
            findOrigin: originFinder(options, devices: origins))
        let https = rootStore(options).map { HTTPSHost(store: $0, capture: capture) }
        await https?.load()
        let host = SessionHost(capture: capture, https: https, protobuf: protobuf, origins: origins, send: send)
        await host.begin(showingStoredTraffic: options.file != nil)
        return host
    }

    /// Where Reqly's certificate lives: Windows' store, or a stand-in file for test runs.
    private static func rootStore(_ options: OpenOptions) -> (any RootStore)? {
        guard options.file == nil else { return nil }
        if let standIn = options.rootStandIn {
            return FileRootStore(file: URL(fileURLWithPath: standIn))
        }
        #if os(Windows)
            return options.rootFile.map { WindowsRootStore(file: URL(fileURLWithPath: $0)) }
        #else
            return nil
        #endif
    }

    /// Windows' own proxy switch, for a live session that asks for it, or the same switch on a
    /// stand-in for Windows' settings, for a test run.
    private static func systemProxy(_ options: OpenOptions) -> (any SystemProxySwitch)? {
        guard options.file == nil, options.setsSystemProxy == true, let restore = options.proxyRestoreFile else {
            return nil
        }
        let restoreFile = URL(fileURLWithPath: restore)
        if let standIn = options.proxySettingsStandIn {
            return UserProxySwitch(
                settings: FileProxySettings(file: URL(fileURLWithPath: standIn)), restoreFile: restoreFile)
        }
        #if os(Windows)
            return UserProxySwitch(settings: WinINetProxySettings(), restoreFile: restoreFile)
        #else
            return nil
        #endif
    }

    /// Finds where each connection came from: a device on the network you let in, or the app that
    /// opened it on this computer, from Windows' connection table.
    private static func originFinder(_ options: OpenOptions, devices: DeviceOrigins) -> CaptureSession.OriginFinder? {
        guard options.file == nil else { return nil }
        #if os(Windows)
            let apps = options.findsApps != false ? AppLookup() : nil
        #endif
        return { client, proxyPort in
            guard client.isLoopback else {
                return devices.device(atAddress: client.ip).map { Origin(device: $0) }
            }
            #if os(Windows)
                return apps?.origin(clientPort: client.port, proxyPort: client.localPort ?? proxyPort)
            #else
                return nil
            #endif
        }
    }

    init(
        capture: CaptureSession, https: HTTPSHost? = nil, protobuf: ProtobufLibrary = .shared,
        origins: DeviceOrigins = DeviceOrigins(), send: @escaping @Sendable (Data) -> Void
    ) {
        self.capture = capture
        self.https = https
        self.protobuf = protobuf
        self.origins = origins
        self.send = send
    }

    private func begin(showingStoredTraffic: Bool) async {
        let changes = capture.changes
        watching = Task { [weak self] in
            for await change in changes {
                await self?.apply(change)
            }
        }
        if showingStoredTraffic {
            await capture.publishStoredTraffic()
        }
        publishSidebar()
    }

    /// Stops capturing and lets go of the session's folder, as quitting does.
    public func close() async {
        await lastSessionCall?.value
        try? await capture.stop()
        storeSearch?.cancel()
        watching?.cancel()
        await capture.flush()
        capture.store.discard()
    }

    /// Answers a request with a reply, both JSON.
    public func reply(to request: Data) async -> Data {
        do {
            return try await handle(try Call(json: request))
        } catch {
            return Reply.problem(error)
        }
    }

    func handle(_ call: Call) async throws(Problem) -> Data {
        switch call {
        case .version:
            return Reply.result(["version": interfaceVersion])
        case .startCapturing(let port):
            do {
                let listening = try await capture.start(port: port)
                // Reverse proxies listen while Reqly captures, unless their ports are taken.
                reverseProxyProblems = await capture.reverseProxyProblems.mapValues(\.message)
                return Reply.result(["port": listening])
            } catch CaptureError.portInUse(let port) {
                throw Problem(.portInUse, "Another app already uses port \(port).")
            } catch {
                throw Problem(.failed, "Reqly couldn't start capturing: \(error.localizedDescription)")
            }
        case .stopCapturing:
            do {
                try await capture.stop()
                return Reply.result(Empty())
            } catch {
                throw Problem(.failed, "Reqly couldn't stop capturing: \(error.localizedDescription)")
            }
        case .rowIDs:
            return Reply.result(RowIDs(version: version, ids: list.rows.map(\.rawValue)))
        case .rows(let ids):
            let rows = ids.compactMap { list.summary(ExchangeID(rawValue: $0)).map(WireRow.init) }
            return Reply.result(["rows": rows])
        case .trafficSummary:
            return Reply.result(WireTrafficSummary(list.all))
        case .setSearch(let text):
            setSearch(text)
            return Reply.result(Empty())
        case .details(let id):
            guard let exchange = await capture.exchange(ExchangeID(rawValue: id)) else {
                throw Problem(.notFound, "The session has no exchange \(id).")
            }
            return Reply.result(WireDetails(exchange))
        case .presentBody(let id, let part):
            let exchange = try await exchange(id)
            let body = await presentation(exchange, part: part)
            let reading = await protobuf.reading(for: Self.protobufKey(exchange, part: part))
            var wire = WireBody(body)
            wire.chosenType = reading.chosenType
            wire.hasMessageTypes = !reading.schema.messageNames.isEmpty
            return Reply.result(wire)
        case .bodyNode(let id, let part, let node):
            let body = await presentation(try await exchange(id), part: part)
            guard let tree = body.tree, (0..<tree.count).contains(node) else {
                throw Problem(.notFound, "The body has no node \(node).")
            }
            return Reply.result(["path": tree.path(to: node), "copy": tree.copyText(of: node)])
        case .raw(let id, let showsSecrets):
            let exchange = try await exchange(id)
            let request = RawMessage(
                request: exchange.request, body: exchange.requestBody, hidingSecrets: !showsSecrets)
            let response = exchange.response.map {
                RawMessage(
                    response: $0, body: exchange.responseBody, trailers: exchange.responseTrailers,
                    hidingSecrets: !showsSecrets)
            }
            let hasSecrets =
                exchange.request.headers.contains(where: \.isSecret)
                || (exchange.response?.headers.contains(where: \.isSecret) ?? false)
            return Reply.result(
                WireRaw(
                    request: WireCode(text: request.text, tokens: request.tokens, isCode: false),
                    response: response.map { WireCode(text: $0.text, tokens: $0.tokens, isCode: false) },
                    hasSecrets: hasSecrets))
        case .messages(let id, let from):
            let messages = await capture.messages(of: ExchangeID(rawValue: id), from: from)
            return Reply.result([
                "messages": messages.enumerated().map { WireMessage(number: from + $0.offset, $0.element) }
            ])
        case .presentMessage(let id, let number):
            guard let message = await capture.messages(of: ExchangeID(rawValue: id), from: number).first else {
                throw Problem(.notFound, "The exchange has no message \(number).")
            }
            let headers: Headers = [
                "Content-Type": message.kind == .binary ? "application/octet-stream" : "text/plain; charset=utf-8"
            ]
            let body = await Task.detached(priority: .userInitiated) {
                BodyPresentation(data: message.data, headers: headers, rootLabel: "Message")
            }.value
            return Reply.result(WireBody(body))
        case .https:
            return Reply.result(try await withHTTPS { await $0.wire })
        case .setUpHTTPS:
            let https = try await withHTTPS { $0 }
            return Reply.result(try await https.setUp())
        case .removeHTTPS:
            let https = try await withHTTPS { $0 }
            return Reply.result(try await https.remove())
        case .setDecryptedHosts(let hosts):
            return try await changeHosts { $0 = hosts }
        case .decryptHost(let host):
            return try await changeHosts { $0.decrypt(host) }
        case .stopDecryptingHost(let host):
            return try await changeHosts { $0.stopDecrypting(host) }
        case .addDecryptedHost(let text):
            let https = try await withHTTPS { $0 }
            return Reply.result(try await https.addHost(text))
        case .removeDecryptedHosts(let patterns):
            return try await changeHosts { $0.remove(Set(patterns)) }
        case .setHostDecrypted(let pattern, let isOn):
            return try await changeHosts { $0.setDecrypts(isOn, pattern) }
        case .setDecryptsEveryHost(let isOn):
            return try await changeHosts { $0.includesEveryHost = isOn }
        case .decryptsHost(let host):
            return Reply.result(["decrypts": try await withHTTPS { await $0.decrypts(host) }])
        case .setScope(let key):
            guard let scope = scopes[key] else { throw Problem(.notFound, "The sidebar has no row \(key).") }
            show(steps(for: list.setScope(scope)))
            return Reply.result(Empty())
        case .setFilter(let wire):
            show(steps(for: list.setFilter(try wire.filter())))
            return Reply.result(Empty())
        case .annotate(let id, let isPinned, let color, let comment):
            let exchange = ExchangeID(rawValue: id)
            guard var annotation = list.summary(exchange)?.annotation else {
                throw Problem(.notFound, "The session has no exchange \(id).")
            }
            if let isPinned {
                annotation.isPinned = isPinned
            }
            switch color {
            case .set(let color): annotation.color = color
            case .remove: annotation.color = nil
            case nil: break
            }
            switch comment {
            case .set(let text):
                // Spaces around it are dropped, and an empty one removes the comment.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                annotation.comment = trimmed.isEmpty ? nil : trimmed
            case .remove: annotation.comment = nil
            case nil: break
            }
            annotate(exchange, with: annotation)
            return Reply.result(Empty())
        case .unpinAll:
            for summary in list.all where summary.annotation.isPinned {
                var annotation = summary.annotation
                annotation.isPinned = false
                annotate(summary.id, with: annotation)
            }
            return Reply.result(Empty())
        case .clear:
            // Requests held at breakpoints go on as they are first, as on the Mac.
            continueAllPaused()
            callSession { await $0.clear() }
            await lastSessionCall?.value
            return Reply.result(Empty())
        case .setRules(let set):
            _ = changeRules { $0 = set }
            return Reply.result(Empty())
        case .openRules(let path):
            rules.open(URL(fileURLWithPath: path))
            capture.setRules(rules.set)
            return Reply.result(rules.wire)
        case .rules:
            return Reply.result(rules.wire)
        case .setRuleKindOn(let kind, let isOn):
            return changeRules { set in
                if isOn {
                    set.kindsOn.insert(kind)
                } else {
                    set.kindsOn.remove(kind)
                }
            }
        case .setRuleOn(let id, let isOn):
            return changeRules { set in
                if let index = set.rules.firstIndex(where: { $0.id == id }) {
                    set.rules[index].isOn = isOn
                }
            }
        case .removeRules(let ids):
            return changeRules { $0.rules.removeAll { ids.contains($0.id) } }
        case .moveRule(let id, let place):
            return changeRules { $0.move(id, to: place) }
        case .duplicateRule(let id):
            return changeRules { set in
                guard var copy = set.rules.first(where: { $0.id == id }) else { return }
                copy.id = UUID()
                copy.name = "\(copy.name) copy"
                set.rules.append(copy)
            }
        case .newRuleDraft(let kind, let id):
            guard kind != .slowNetwork else { throw Problem(.badRequest, "Slow Network has no rules of its own.") }
            var summary: ExchangeSummary?
            if let id {
                guard let found = list.summary(ExchangeID(rawValue: id)) else {
                    throw Problem(.notFound, "There's no exchange \(id).")
                }
                summary = found
            }
            return Reply.result(WireRuleDraft(RuleDraft(kind: kind, from: summary)))
        case .ruleDraft(let id):
            guard let rule = rules.set.rules.first(where: { $0.id == id }) else {
                throw Problem(.notFound, "There's no rule \(id.uuidString).")
            }
            return Reply.result(WireRuleDraft(RuleDraft(rule: rule)))
        case .checkRuleDraft(let wire):
            let draft = wire.draft
            let matching = draft.kind == .script ? draft.matchingRequests(in: list.all) : nil
            return Reply.result(
                WireRuleCheck(
                    problem: draft.problem, defaultName: draft.defaultName, matchCount: draft.matchCount(in: list.all),
                    matching: matching?.map {
                        WireRuleCheck.Request(id: $0.id.rawValue, description: RuleDraft.describe($0))
                    }))
        case .saveRuleDraft(let wire):
            let draft = wire.draft
            guard let rule = draft.rule else {
                throw Problem(.badRequest, draft.problem ?? "Slow Network has no rules of its own.")
            }
            return changeRules { set in
                if let index = set.rules.firstIndex(where: { $0.id == rule.id }) {
                    set.rules[index] = rule
                } else {
                    set.rules.append(rule)
                }
                // A rule you just made should act, so its kind comes on with it.
                if draft.isNew {
                    set.kindsOn.insert(rule.kind)
                }
            }
        case .setNetwork(let network):
            return changeRules { $0.network = network }
        case .networkPresets:
            return Reply.result(NetworkProfile.presets)
        case .scriptExamples:
            return Reply.result(ScriptExamples.all.map { ["id": $0.id, "code": $0.code] })
        case .openProtobuf(let path):
            return Reply.result(await protobuf.open(URL(fileURLWithPath: path)))
        case .protobuf:
            return Reply.result(await protobuf.wire)
        case .addProtobufSources(let paths):
            return Reply.result(await protobuf.add(paths.map { URL(fileURLWithPath: $0) }))
        case .removeProtobufSource(let path):
            return Reply.result(await protobuf.remove(path))
        case .reloadProtobuf:
            return Reply.result(await protobuf.reload())
        case .openDevices(let path, let allows):
            let url = URL(fileURLWithPath: path)
            devicesFile = url
            devices = DevicesBook(DevicesFile.load(from: url))
            origins.use(devices)
            capture.setDeviceAdmission { [weak self] client in
                await self?.admit(client) ?? false
            }
            await setAllowsNetworkDevices(allows)
            return Reply.result(devicesWire)
        case .devices:
            return Reply.result(devicesWire)
        case .setAllowsNetworkDevices(let allows):
            await setAllowsNetworkDevices(allows)
            return Reply.result(devicesWire)
        case .decideDevice(let id, let allow, let name):
            decideDevice(id, allow: allow, name: name)
            return Reply.result(devicesWire)
        case .forgetDevice(let id):
            devices.forget(id)
            saveDevices()
            return Reply.result(devicesWire)
        case .renameDevice(let id, let name):
            guard devices.rename(id, to: name), let named = devices.names[id] else {
                throw Problem(.badRequest, "Enter a name for the device.")
            }
            saveDevices()
            await capture.renameDevice(id, to: named)
            show(steps(for: list.renameDevice(id, to: named)))
            publishSidebar()
            return Reply.result(devicesWire)
        case .qrCode(let text):
            guard let code = QRCode(text) else { throw Problem(.badRequest, "The text is too long for a QR code.") }
            return Reply.result(["rows": code.modules.map { row in row.map { $0 ? "1" : "0" }.joined() }])
        case .emulators(let port):
            guard let adb = AndroidDebugBridge.find() else {
                return Reply.result(WireEmulators(hasAdb: false, emulators: [], problem: AndroidDebugBridge.missing))
            }
            do {
                let proxy = AndroidDebugBridge.proxy(port: port)
                let emulators = try await adb.emulators().map {
                    WireEmulators.Emulator(
                        id: $0.id, name: $0.name, proxy: $0.proxy, isReady: $0.isReady, usesReqly: $0.proxy == proxy)
                }
                return Reply.result(WireEmulators(hasAdb: true, emulators: emulators, problem: nil))
            } catch {
                return Reply.result(
                    WireEmulators(hasAdb: true, emulators: [], problem: AndroidDebugBridge.listingProblem(error)))
            }
        case .setEmulatorUsesReqly(let serial, let isOn, let port):
            guard let adb = AndroidDebugBridge.find() else { throw Problem(.notAvailable, AndroidDebugBridge.missing) }
            do {
                try await adb.setProxy(isOn ? AndroidDebugBridge.proxy(port: port) : nil, on: serial)
                return Reply.result(WireCheck(problem: nil, note: nil))
            } catch {
                return Reply.result(WireCheck(problem: error.localizedDescription, note: nil))
            }
        case .copyCertificateToEmulator(let serial, let certificate):
            guard let adb = AndroidDebugBridge.find() else { throw Problem(.notAvailable, AndroidDebugBridge.missing) }
            guard let der = Data(base64Encoded: certificate) else {
                throw Problem(.badRequest, "The certificate isn't base64.")
            }
            do {
                try await adb.copyCertificate(der: [UInt8](der), to: serial)
                try await adb.openSecuritySettings(on: serial)
                return Reply.result(WireCheck(problem: nil, note: "Copied “Reqly CA.crt” to Downloads."))
            } catch {
                return Reply.result(WireCheck(problem: error.localizedDescription, note: nil))
            }
        case .chooseMessageType(let id, let part, let type):
            let key = Self.protobufKey(try await exchange(id), part: part)
            await protobuf.choose(type, for: key)
            return Reply.result(Empty())
        case .openConnections(let path, let secretsPath, let protectsSecrets):
            connections.open(
                URL(fileURLWithPath: path),
                secrets: SecretFile(file: URL(fileURLWithPath: secretsPath), isProtected: protectsSecrets))
            capture.setUpstreamProxy(connections.activeUpstreamProxy)
            capture.setClientIdentities(connections.activeIdentities)
            await applyReverseProxies()
            return Reply.result(connectionsWire)
        case .connections:
            reverseProxyProblems = await capture.reverseProxyProblems.mapValues(\.message)
            return Reply.result(connectionsWire)
        case .checkUpstreamProxy(let proxy, let port):
            return Reply.result(["problem": proxy.draft.problem(proxyPort: port)])
        case .setUpstreamProxy(let wire, let port):
            let draft = wire.draft
            if let problem = draft.problem(proxyPort: port) {
                throw Problem(.badRequest, problem)
            }
            let proxy = draft.proxy
            connections.setUpstreamProxy(proxy, isOn: draft.isOn && proxy != nil)
            capture.setUpstreamProxy(connections.activeUpstreamProxy)
            return Reply.result(connectionsWire)
        case .newReverseProxy(let port):
            let proxies = connections.contents.reverseProxies
            let proxy = ReverseProxy(
                localPort: ReverseProxy.suggestedPort(among: proxies, proxyPort: port), serverURL: "")
            return Reply.result(WireReverseProxy(proxy))
        case .checkReverseProxy(let wire, let port):
            let proxy = wire.proxy(keeping: nil)
            let problem = proxy.problem(port: wire.port, proxyPort: port, among: connections.contents.reverseProxies)
            let note =
                problem == nil
                ? proxy.server.map { "Apps that use http://localhost:\(String(proxy.localPort)) reach \($0.url)." }
                : nil
            return Reply.result(WireCheck(problem: problem, note: note))
        case .saveReverseProxy(let wire, let port):
            let proxies = connections.contents.reverseProxies
            let proxy = wire.proxy(keeping: proxies.first { $0.id == wire.id })
            if let problem = proxy.problem(port: wire.port, proxyPort: port, among: proxies) {
                throw Problem(.badRequest, problem)
            }
            connections.saveReverseProxy(proxy)
            await applyReverseProxies()
            return Reply.result(connectionsWire)
        case .removeReverseProxy(let id):
            connections.removeReverseProxy(id)
            await applyReverseProxies()
            return Reply.result(connectionsWire)
        case .setReverseProxyOn(let id, let isOn):
            connections.setReverseProxy(id, isOn: isOn)
            await applyReverseProxies()
            return Reply.result(connectionsWire)
        case .checkHosts(let text):
            let list = HostList(text)
            return Reply.result(WireHostsCheck(problem: list.problem, count: list.patterns.count))
        case .addClientCertificate(let files, let password, let text):
            let hosts = try Self.hosts(text)
            let identity: ClientIdentity
            do {
                identity = try ClientIdentity.read(
                    files.map { URL(fileURLWithPath: $0) }, password: password, hosts: hosts)
            } catch {
                throw Problem(.badRequest, error.message)
            }
            connections.addClientCertificate(identity)
            capture.setClientIdentities(connections.activeIdentities)
            return Reply.result(connectionsWire)
        case .setClientCertificateHosts(let id, let text):
            connections.setHosts(try Self.hosts(text), of: id)
            capture.setClientIdentities(connections.activeIdentities)
            return Reply.result(connectionsWire)
        case .setClientCertificateOn(let id, let isOn):
            connections.setClientCertificate(id, isOn: isOn)
            capture.setClientIdentities(connections.activeIdentities)
            return Reply.result(connectionsWire)
        case .removeClientCertificate(let id):
            connections.removeClientCertificate(id)
            capture.setClientIdentities(connections.activeIdentities)
            return Reply.result(connectionsWire)
        case .decide(let id, let changes):
            guard var edit = paused[id] else {
                throw Problem(.notFound, "Nothing is waiting at a breakpoint for exchange \(id).")
            }
            if let changes {
                changes.apply(to: &edit)
                let message: PausedMessage
                do {
                    message = try edit.edited()
                } catch {
                    paused[id] = edit
                    throw Problem(.badRequest, error.message)
                }
                capture.decide(ExchangeID(rawValue: id), .resume(message))
            } else {
                capture.decide(ExchangeID(rawValue: id), .cancel)
            }
            paused[id] = nil
            send(Event.resumed(id: id).json)
            return Reply.result(Empty())
        case .continueAllPaused:
            continueAllPaused()
            return Reply.result(Empty())
        case .checkScript(let code):
            return Reply.result(["problem": await capture.checkScript(code)])
        case .highlightScript(let code):
            // Past the limit, the script shows without colors, as long bodies do.
            let tokens = code.utf16.count <= HighlightedText.highlightLimit ? JavaScriptSyntax.tokens(in: code) : []
            return Reply.result(["tokens": WireCode.parts(tokens)])
        case .tryScript(let code, let id):
            let trials = await capture.tryScript(code, on: ExchangeID(rawValue: id)).map {
                WireScriptTrial(part: $0.part.rawValue, detail: $0.detail, logs: $0.logs, failed: $0.failed)
            }
            return Reply.result(["trials": trials])
        case .send(let outgoing):
            let request = try outgoing.request()
            return Reply.result(["id": await capture.send(request, from: Self.reqly).rawValue])
        case .resend(let id):
            let exchange = try await readable(id)
            guard let request = OutgoingRequest(resending: exchange.request, body: exchange.requestBody) else {
                throw Problem(.notAvailable, "This request can't be sent again.")
            }
            return Reply.result(["id": await capture.send(request, from: Self.reqly).rawValue])
        case .draft(let id):
            return Reply.result(WireOutgoing(try await readable(id)))
        case .curl(let id):
            let exchange = try await readable(id)
            return Reply.result(["command": CurlCommand.make(exchange.request, body: exchange.requestBody)])
        case .saveSession(let path, let hidesSecrets):
            // Pins and comments on their way are saved first.
            await lastSessionCall?.value
            await capture.flush()
            do {
                try await capture.store.saveSession(to: URL(fileURLWithPath: path), hidingSecrets: hidesSecrets)
            } catch {
                throw Problem(.failed, "Reqly couldn't save the session. \(error.localizedDescription)")
            }
            return Reply.result(Empty())
        case .exportHAR(let path, let ids, let includesResponseBodies, let hidesSecrets, let version):
            return Reply.result([
                "exported": try await exportHAR(
                    to: URL(fileURLWithPath: path), ids: ids.map { $0.map(ExchangeID.init(rawValue:)) } ?? list.rows,
                    options: HARWriter.Options(
                        includesResponseBodies: includesResponseBodies, hidesSecrets: hidesSecrets),
                    version: version)
            ])
        case .copyableBody(let id):
            let exchange = try await readable(id)
            guard let response = exchange.response else {
                throw Problem(.notAvailable, "This request has no response yet.")
            }
            return Reply.result(Self.copyable(exchange.responseBody, headers: response.headers))
        }
    }

    private func exchange(_ id: UInt64) async throws(Problem) -> Exchange {
        guard let exchange = await capture.exchange(ExchangeID(rawValue: id)) else {
            throw Problem(.notFound, "The session has no exchange \(id).")
        }
        return exchange
    }

    /// A body made ready to show. Formatting a big one takes a moment, so it happens away from the
    /// session, and the latest few are kept.
    private func presentation(_ exchange: Exchange, part: BodyPart) async -> BodyPresentation {
        let data = part == .request ? exchange.requestBody : exchange.responseBody
        let schema = await protobuf.reading(for: Self.protobufKey(exchange, part: part))
        let key = PresentedBody(
            id: exchange.id.rawValue, part: part, size: data.count, schemaVersion: schema.version,
            chosenType: schema.chosenType)
        if let kept = presented.first(where: { $0.key == key }) {
            return kept.body
        }
        let headers = part == .request ? exchange.request.headers : exchange.response?.headers ?? Headers()
        let rootLabel = part == .request ? "Request" : "Response"
        let reading = ProtobufReading(
            schema: schema.schema, path: exchange.request.url?.path(percentEncoded: false),
            isRequest: part == .request, chosenType: schema.chosenType)
        let body = await Task.detached(priority: .userInitiated) {
            BodyPresentation(data: data, headers: headers, rootLabel: rootLabel, protobuf: reading)
        }.value
        presented.removeAll { $0.key == key }
        presented.insert((key, body), at: 0)
        if presented.count > 4 {
            presented.removeLast()
        }
        return body
    }

    /// A body as it was when it was made ready to show. A body that grew since, or one to read with
    /// other `.proto` files or as another message type, is made ready again.
    private struct PresentedBody: Hashable {
        var id: UInt64
        var part: BodyPart
        var size: Int
        var schemaVersion: Int
        var chosenType: String?
    }

    /// Bodies like this one share a chosen message type: the same part of requests to the same host and path.
    private static func protobufKey(_ exchange: Exchange, part: BodyPart) -> String {
        ProtobufFiles.key(for: exchange.request.url, isRequest: part == .request)
    }

    /// Writes exchanges to a HAR file, telling the app how far it got as it goes. Encrypted
    /// connections are left out, since their requests can't be read.
    private func exportHAR(to url: URL, ids: [ExchangeID], options: HARWriter.Options, version: String)
        async throws(Problem) -> Int
    {
        await lastSessionCall?.value
        await capture.flush()
        var exported = 0
        do {
            let writer = try HARWriter(url: url, options: options, creatorVersion: version)
            for (done, id) in ids.enumerated() {
                if let exchange = await capture.exchange(id), exchange.kind == .http {
                    let messages = exchange.messageCount > 0 ? await capture.messages(of: id) : []
                    try writer.append(exchange, messages: messages)
                    exported += 1
                }
                if done % 25 == 0 {
                    send(Event.exportProgress(done: done, total: ids.count).json)
                }
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Problem(.failed, "Reqly couldn't export: \(error.localizedDescription)")
        }
        return exported
    }

    /// An exchange with a request to read: not an encrypted connection.
    private func readable(_ id: UInt64) async throws(Problem) -> Exchange {
        guard let exchange = await capture.exchange(ExchangeID(rawValue: id)) else {
            throw Problem(.notFound, "The session has no exchange \(id).")
        }
        guard exchange.kind == .http else {
            throw Problem(.notAvailable, "An encrypted connection has no request to copy.")
        }
        return exchange
    }

    /// A body unpacked: as text when it's text, as an image when it's an image, and otherwise
    /// its first megabyte as hex, as the Mac app's Copy Response Body copies it.
    static func copyable(_ data: Data, headers: Headers) -> CopyableBody {
        let body = headers["Content-Encoding"].flatMap { BodyDecoder.decode(data, contentEncoding: $0) } ?? data
        if let text = BodyText.decode(body, contentType: headers["Content-Type"]) {
            return CopyableBody(text: text)
        }
        if case .image = BodyKind.detect(body, contentType: headers["Content-Type"]) {
            return CopyableBody(image: body.base64EncodedString())
        }
        return CopyableBody(hex: body.prefix(1 << 20).map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    struct CopyableBody: Encodable, Equatable {
        var text: String?
        /// The image's bytes, in base64.
        var image: String?
        var hex: String?
    }

    /// Lets every held request and response go on as it was.
    private var devicesWire: WireDevices {
        WireDevices(
            devices, allowsNetworkDevices: allowsNetworkDevices, addresses: NetworkAddresses.current(),
            problem: devicesProblem)
    }

    /// Whether a device on the network may send its traffic through Reqly: yes if you let it in
    /// before, and otherwise once you decide. Every connection from it waits on the same decision.
    func admit(_ client: ClientAddress) async -> Bool {
        let id = DevicesFile.identity(ip: client.ip, hardwareAddress: NetworkNeighbors.hardwareAddress(of: client.ip))
        let saved = devices.contents
        let verdict = devices.admit(id: id, address: client.ip, allowsNetworkDevices: allowsNetworkDevices)
        if devices.contents != saved {
            saveDevices()
        }
        switch verdict {
        case .allow:
            origins.use(devices)
            return true
        case .refuse:
            return false
        case .ask(let isNewRequest):
            if isNewRequest {
                send(Event.deviceWaiting(id: id, address: client.ip, waiting: devices.requests.count).json)
            }
            return await withCheckedContinuation { continuation in
                waitingDevices[id, default: []].append(continuation)
            }
        }
    }

    private func decideDevice(_ id: String, allow: Bool, name: String?) {
        devices.decide(id, allow: allow, name: name)
        if allow {
            saveDevices()
        }
        for continuation in waitingDevices.removeValue(forKey: id) ?? [] {
            continuation.resume(returning: allow)
        }
    }

    private func setAllowsNetworkDevices(_ allows: Bool) async {
        allowsNetworkDevices = allows
        if !allows {
            for id in devices.refuseAll() {
                for continuation in waitingDevices.removeValue(forKey: id) ?? [] {
                    continuation.resume(returning: false)
                }
            }
        }
        do {
            try await capture.setListensOnNetwork(allows)
            devicesProblem = nil
        } catch {
            devicesProblem = DevicesFile.listeningProblem(error)
        }
    }

    /// Saves the devices you let in and their names, and names their connections from now on.
    private func saveDevices() {
        origins.use(devices)
        guard let devicesFile else { return }
        do {
            try DevicesFile.save(devices.contents, to: devicesFile)
        } catch {
            devicesProblem = DevicesFile.saveProblem(error)
        }
    }

    private var connectionsWire: WireConnections {
        connections.wire(reverseProxyProblems: reverseProxyProblems)
    }

    /// Gives the session the reverse proxies, which listen while it captures, and keeps why any can't.
    private func applyReverseProxies() async {
        reverseProxyProblems = await capture.setReverseProxies(connections.contents.reverseProxies).mapValues(\.message)
    }

    /// The hosts a certificate is for, as typed, or what's wrong with them.
    private static func hosts(_ text: String) throws(Problem) -> [HostPattern] {
        let list = HostList(text)
        if let problem = list.problem {
            throw Problem(.badRequest, problem)
        }
        guard !list.patterns.isEmpty else {
            throw Problem(.badRequest, "Enter the hosts to present the certificate to, such as api.example.com.")
        }
        return list.patterns
    }

    /// Changes the rules, saves them and gives them to the session, then lists them as they are.
    private func changeRules(_ body: (inout RuleSet) -> Void) -> Data {
        if rules.change(body) {
            capture.setRules(rules.set)
        }
        return Reply.result(rules.wire)
    }

    private func continueAllPaused() {
        for (id, edit) in paused {
            capture.decide(ExchangeID(rawValue: id), .resume(edit.original))
            send(Event.resumed(id: id).json)
        }
        paused.removeAll()
    }

    /// Changes the list right away, then saves the change.
    private func annotate(_ id: ExchangeID, with annotation: Annotation) {
        guard let old = list.summary(id)?.annotation, annotation != old else { return }
        show(steps(for: list.setAnnotation(annotation, of: id)))
        callSession { await $0.annotate(id, with: annotation) }
    }

    private func callSession(_ call: @escaping @Sendable (CaptureSession) async -> Void) {
        let previous = lastSessionCall
        let capture = self.capture
        lastSessionCall = Task {
            await previous?.value
            await call(capture)
        }
    }

    private func changeHosts(_ change: @escaping @Sendable (inout DecryptedHosts) -> Void) async throws(Problem)
        -> Data
    {
        Reply.result(try await withHTTPS { await $0.changeHosts(change) })
    }

    private func withHTTPS<Result: Sendable>(_ body: (HTTPSHost) async -> Result) async throws(Problem) -> Result {
        guard let https else {
            throw Problem(
                .notAvailable, "This session doesn't decrypt HTTPS: it's a saved one, or it has no certificate store.")
        }
        return await body(https)
    }

    /// Part of a body as bytes, from `offset`, at most `limit` of them: as it came, or unpacked,
    /// as the Hex and Preview views show it.
    public func body(_ id: UInt64, part: BodyPart, offset: Int, limit: Int, unpacked: Bool = false) async -> Data? {
        guard let exchange = await capture.exchange(ExchangeID(rawValue: id)) else { return nil }
        let data =
            unpacked
            ? await presentation(exchange, part: part).content
            : part == .request ? exchange.requestBody : exchange.responseBody
        guard offset >= 0, limit >= 0, offset <= data.count else { return nil }
        let start = data.startIndex + offset
        return Data(data[start..<min(data.endIndex, start + limit)])
    }

    // MARK: - The list

    private func apply(_ change: SessionChange) {
        switch change {
        case .cleared:
            show(steps(for: list.removeUnpinned()))
            // What was held went on with the clear, rows and all, so its editor goes too.
            for id in paused.keys where list.summary(ExchangeID(rawValue: id)) == nil {
                paused[id] = nil
                send(Event.resumed(id: id).json)
            }
        case .updated(let summaries, let removed):
            // A held exchange that finished, as when its app gave up waiting, or went, isn't held.
            for summary in summaries where summary.state.isFinished && paused[summary.id.rawValue] != nil {
                paused[summary.id.rawValue] = nil
                send(Event.resumed(id: summary.id.rawValue).json)
            }
            for id in removed where paused[id.rawValue] != nil {
                paused[id.rawValue] = nil
                send(Event.resumed(id: id.rawValue).json)
            }
            // Past the session's size limit, the oldest exchanges go as new ones come, and the
            // app shows both in one go.
            var rowSteps = self.steps(for: list.update(summaries))
            rowSteps += self.steps(for: list.remove(removed))
            show(rowSteps)
            if !summaries.isEmpty {
                // New traffic may have the search text in its headers or body.
                searchStore(after: TrafficList.newTrafficSearchDelay, restarting: false)
            }
        case .storageProblem(let message):
            send(Event.storageProblem(message).json)
        case .paused(let id, let message, let breakpoint):
            let edit = PausedEdit(message, breakpoint: breakpoint)
            paused[id.rawValue] = edit
            send(Event.paused(WirePaused(id: id.rawValue, edit)).json)
        }
    }

    private func setSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query != list.query else { return }
        show(steps(for: list.setQuery(query)))
        searchStore(after: TrafficList.storeSearchDelay, restarting: true)
    }

    /// Asks the store which exchanges have the search text in their headers or bodies.
    ///
    /// - Parameter restarting: Start over when the search text changes. While traffic arrives,
    ///   a search already on its way is enough.
    private func searchStore(after delay: Duration, restarting: Bool) {
        let query = list.query
        guard query.unicodeScalars.count >= TrafficStore.minimumSearchLength else {
            storeSearch?.cancel()
            storeSearch = nil
            return
        }
        if restarting {
            storeSearch?.cancel()
        } else if storeSearch != nil {
            return
        }
        let capture = self.capture
        storeSearch = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let found = await capture.search(query)
            guard !Task.isCancelled else { return }
            await self?.storeFound(found, for: query)
        }
    }

    private func storeFound(_ found: Set<ExchangeID>, for query: String) {
        storeSearch = nil
        guard list.query == query else { return }
        show(steps(for: list.setStoreMatches(found)))
    }

    /// The list's changes as the app takes them. New rows come with their exchanges, read
    /// from the rows right after the change that made them.
    private func steps(for changes: [TrafficList.RowChange]) -> [RowStep] {
        changes.map { change in
            switch change {
            case .removed(let rows):
                return .removed(Array(rows))
            case .inserted(let rows):
                return .inserted(rows.map { RowStep.InsertedRow(row: $0, id: list.rows[$0].rawValue) })
            case .changed(let ids):
                return .changed(ids.map(\.rawValue))
            }
        }
    }

    private func show(_ steps: [RowStep]) {
        if !steps.isEmpty {
            version += 1
            let joining = steps.reduce(0) { count, step in
                if case .inserted(let rows) = step { count + rows.count } else { count }
            }
            let sent = joining > Self.resetThreshold ? [RowStep.reset(list.rows.map(\.rawValue))] : steps
            send(Event.rows(version: version, total: list.all.count, shown: list.rows.count, steps: sent).json)
        }
        publishSidebar()
    }

    // MARK: - The sidebar

    /// Sends the sidebar again when rows came or went, and otherwise the counts that changed.
    private func publishSidebar() {
        let changed = list.takeChangedCounts()
        let totals = (total: list.all.count, pinned: list.pinnedCount)
        if list.namesVersion != namesSent {
            namesSent = list.namesVersion
            totalsSent = totals
            send(Event.sidebar(sidebar()).json)
        } else if !changed.isEmpty || totals != totalsSent {
            totalsSent = totals
            var counts: [String: Int] = [:]
            for scope in changed {
                counts[Self.key(scope)] = list.count(of: scope)
            }
            send(Event.counts(total: list.all.count, pinned: list.pinnedCount, counts: counts).json)
        }
    }

    private func sidebar() -> WireSidebar {
        var rows = SidebarRows(list: list)
        let devices = list.devices.map { entry in
            let device = rows.row(.device(entry.choice), entry.device?.name ?? "")
            return WireSidebar.DeviceRow(
                key: device.key, id: WireDevice.name(entry.choice), name: entry.device?.name,
                kind: entry.device?.kind.rawValue, count: device.count,
                apps: rows.apps(on: entry.choice),
                otherHosts: (list.otherHostsByDevice[entry.choice] ?? []).map {
                    rows.row(.deviceHost($0, on: entry.choice), $0)
                })
        }
        let sidebar = WireSidebar(
            total: list.all.count, pinned: list.pinnedCount, apps: rows.apps(on: .thisMac),
            hosts: list.hosts.map { rows.row(.host($0), $0) }, devices: devices, methods: list.methods,
            sources: list.sources)
        scopes = rows.scopes
        return sidebar
    }

    /// Makes the sidebar's rows, and notes each one's scope by its key.
    private struct SidebarRows {
        let list: TrafficList
        var scopes: [String: TrafficList.Scope] = ["all": .all, "pinned": .pinned]

        mutating func row(_ scope: TrafficList.Scope, _ name: String, path: String? = nil) -> WireSidebar.Row {
            let key = SessionHost.key(scope)
            scopes[key] = scope
            return WireSidebar.Row(key: key, name: name, count: list.count(of: scope), path: path)
        }

        mutating func apps(on device: DeviceChoice) -> [WireSidebar.Row] {
            (list.appsByDevice[device] ?? []).map { row(.source($0, on: device), $0.name, path: $0.path) }
        }
    }

    /// A sidebar row's key, the same for as long as the row shows.
    static func key(_ scope: TrafficList.Scope) -> String {
        // The unit separator never comes up in names.
        let separator = "\u{1F}"
        return switch scope {
        case .all: "all"
        case .pinned: "pinned"
        case .host(let host): ["host", host].joined(separator: separator)
        case .device(let device): ["device", WireDevice.name(device)].joined(separator: separator)
        case .source(let source, let device):
            ["app", WireDevice.name(device), source.name, source.path ?? "", source.bundleID ?? ""]
                .joined(separator: separator)
        case .deviceHost(let host, let device):
            ["deviceHost", WireDevice.name(device), host].joined(separator: separator)
        }
    }

    private struct RowIDs: Encodable {
        var version: Int
        var ids: [UInt64]
    }
}
