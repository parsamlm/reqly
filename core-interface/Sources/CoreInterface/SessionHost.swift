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

/// One session for the app: the live one, or a saved one it opened. It keeps the request list
/// the way the Mac app does, with the same ``TrafficList``, and tells the app how the rows
/// change, so the app only ever asks for the rows it shows.
///
/// Its methods take and give Swift values, the core's own wherever it has one, and its events
/// come as ``Event``s. The Linux app calls them directly; the Windows app reaches the same
/// methods through JSON messages, which `reply(to:)` answers.
public actor SessionHost {
    /// More rows than this joining at once are sent as every row instead.
    static let resetThreshold = 10_000

    /// Reqly itself, as the app that sent the requests you write and resend.
    static let reqly = Source(name: "Reqly", path: CommandLine.arguments.first)

    public nonisolated let capture: CaptureSession
    /// The `.proto` files bodies are read with, which every session shares.
    public nonisolated let protobuf: ProtobufLibrary
    /// HTTPS decryption, for a live session with a certificate store.
    private let httpsHost: HTTPSHost?
    /// Where events go, as they happen, until the session closes.
    private var events: (@Sendable (Event) -> Void)?
    /// Finds Android's tools as each emulator call starts. Tests hide them this way, rather than
    /// by changing the environment while other tests read it.
    private var findAdb: @Sendable () -> AndroidDebugBridge? = { AndroidDebugBridge.find() }
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
    private var rulesBook = RulesBook()
    /// The upstream proxy, the reverse proxies and the client certificates, as Settings edit them.
    private var connectionsBook = ConnectionsBook()
    /// Why each reverse proxy that's on isn't listening, while capturing.
    private var reverseProxyProblems: [UUID: String] = [:]
    /// The devices you let in, the ones waiting, and the names you gave devices.
    private var devicesBook = DevicesBook()
    private var devicesFile: URL?
    private var allowsNetworkDevices = false
    /// Why devices can't connect, or why the devices you let in can't be saved.
    private var devicesProblem: String?
    /// The connections from each waiting device, waiting for you to decide.
    private var waitingDevices: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// The devices you let in, for naming their connections as they open.
    private let origins: DeviceOrigins
    /// What only the system Reqly runs on has: its secrets and network addresses, here.
    private let system: SystemParts
    /// Bodies made ready to show lately, so the Tree view's paths and the Hex view's bytes need no
    /// second reading.
    private var presented: [(key: BodyKey, body: BodyPresentation)] = []
    /// The latest change sent to the session. Each waits for the one before, so a pin made just
    /// before clearing is saved in time to keep its exchange, as in the Mac app.
    private var lastSessionCall: Task<Void, Never>?

    /// Opens a session, live or from a file, with the parts of the system it runs on, and starts
    /// handing its events to `events`, in the order they happen. Each event is handed over on the
    /// session's own executor, before the session goes on, so `events` should only pass it on,
    /// such as to the window's thread. The session lets go of `events` when it closes, so it may
    /// hold on to what holds the session.
    public static func open(
        _ options: OpenOptions, system: SystemParts, protobuf: ProtobufLibrary = .shared,
        events: @escaping @Sendable (Event) -> Void
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
            store: store, systemProxy: systemProxy(options, system), extraTrustedRoots: extraRoots,
            findOrigin: originFinder(options, system, devices: origins))
        let https = rootStore(options, system).map { HTTPSHost(store: $0, capture: capture) }
        // The certificate may wait for your keyring, so the session opens without waiting for it.
        await https?.startLoading()
        let host = SessionHost(
            capture: capture, https: https, protobuf: protobuf, origins: origins, system: system, events: events)
        await host.begin(showingStoredTraffic: options.file != nil)
        return host
    }

    /// Where Reqly's certificate lives: the system's store, or a stand-in file for test runs.
    private static func rootStore(_ options: OpenOptions, _ system: SystemParts) -> (any RootStore)? {
        guard options.file == nil else { return nil }
        if let standIn = options.rootStandIn {
            return FileRootStore(file: URL(fileURLWithPath: standIn))
        }
        guard let rootStore = system.rootStore, let rootFile = options.rootFile else { return nil }
        return rootStore(URL(fileURLWithPath: rootFile))
    }

    /// The system's own proxy switch, for a live session that asks for it, or the same switch on a
    /// stand-in for the system's settings, for a test run.
    private static func systemProxy(_ options: OpenOptions, _ system: SystemParts) -> (any SystemProxySwitch)? {
        guard options.file == nil, options.setsSystemProxy == true, let restore = options.proxyRestoreFile else {
            return nil
        }
        return system.proxySwitch(
            URL(fileURLWithPath: restore), options.proxySettingsStandIn.map { URL(fileURLWithPath: $0) })
    }

    /// Finds where each connection came from: a device on the network you let in, or the app that
    /// opened it on this computer, as the system tells.
    private static func originFinder(
        _ options: OpenOptions, _ system: SystemParts, devices: DeviceOrigins
    ) -> CaptureSession.OriginFinder? {
        guard options.file == nil else { return nil }
        let apps = options.findsApps != false ? system.appFinder?() : nil
        return { client, proxyPort in
            guard client.isLoopback else {
                return devices.device(atAddress: client.ip).map { Origin(device: $0) }
            }
            return apps?.origin(clientPort: client.port, proxyPort: client.localPort ?? proxyPort)
        }
    }

    init(
        capture: CaptureSession, https: HTTPSHost? = nil, protobuf: ProtobufLibrary = .shared,
        origins: DeviceOrigins = DeviceOrigins(), system: SystemParts, events: @escaping @Sendable (Event) -> Void
    ) {
        self.capture = capture
        self.httpsHost = https
        self.protobuf = protobuf
        self.origins = origins
        self.system = system
        self.events = events
    }

    /// Hands an event to the app, unless the session has closed.
    private func emit(_ event: Event) {
        events?(event)
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

    /// Stops capturing and lets go of the session's folder, as quitting does. No events come
    /// after.
    public func close() async {
        await lastSessionCall?.value
        try? await capture.stop()
        storeSearch?.cancel()
        watching?.cancel()
        await capture.flush()
        capture.store.discard()
        events = nil
    }

    // MARK: - Capturing

    /// Starts the proxy on a port, and says the one it listens on; 0 picks a free one.
    public func startCapturing(port: Int) async throws(Problem) -> Int {
        do {
            let listening = try await capture.start(port: port)
            // Reverse proxies listen while Reqly captures, unless their ports are taken.
            reverseProxyProblems = await capture.reverseProxyProblems.mapValues(\.message)
            return listening
        } catch CaptureError.portInUse(let port) {
            throw Problem(.portInUse, "Another app already uses port \(port).")
        } catch {
            throw Problem(.failed, "Reqly couldn't start capturing: \(error.localizedDescription)")
        }
    }

    public func stopCapturing() async throws(Problem) {
        do {
            try await capture.stop()
        } catch {
            throw Problem(.failed, "Reqly couldn't stop capturing: \(error.localizedDescription)")
        }
    }

    // MARK: - The list

    /// Every row's exchange, in order, as of a version of the rows: the one the latest `rows`
    /// event had.
    public func rowIDs() -> (version: Int, ids: [ExchangeID]) {
        (version, list.rows)
    }

    /// The rows for some exchanges, as the list shows them. Exchanges the session doesn't have
    /// are left out.
    public func rows(_ ids: [ExchangeID]) -> [ExchangeSummary] {
        ids.compactMap { list.summary($0) }
    }

    /// The whole session at a glance, whatever the list shows: how many exchanges, what they
    /// sent and received, and the newest one, as the panel in the notification area shows them.
    public func trafficSummary() -> TrafficSummary {
        TrafficSummary(list.all)
    }

    /// Narrows the list to exchanges with the text in their address, headers, body, app,
    /// device or comment. Empty text shows them all again.
    public func setSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query != list.query else { return }
        show(steps(for: list.setQuery(query)))
        searchStore(after: TrafficList.storeSearchDelay, restarting: true)
    }

    /// Narrows the list to a sidebar row's exchanges, by the row's key from the latest
    /// `sidebar` event.
    public func setScope(_ key: String) throws(Problem) {
        guard let scope = scopes[key] else { throw Problem(.notFound, "The sidebar has no row \(key).") }
        show(steps(for: list.setScope(scope)))
    }

    /// Narrows the list to the exchanges a filter lets through.
    public func setFilter(_ filter: TrafficFilter) {
        show(steps(for: list.setFilter(filter)))
    }

    /// Pins an exchange or not, marks it with a color, and comments on it. What's left out stays.
    /// Spaces around a comment are dropped, and an empty one removes it.
    public func annotate(
        _ id: ExchangeID, isPinned: Bool? = nil, color: ValueChange<MarkColor>? = nil,
        comment: ValueChange<String>? = nil
    ) throws(Problem) {
        guard var annotation = list.summary(id)?.annotation else {
            throw Problem(.notFound, "The session has no exchange \(id.rawValue).")
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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            annotation.comment = trimmed.isEmpty ? nil : trimmed
        case .remove: annotation.comment = nil
        case nil: break
        }
        annotate(id, with: annotation)
    }

    public func unpinAll() {
        for summary in list.all where summary.annotation.isPinned {
            var annotation = summary.annotation
            annotation.isPinned = false
            annotate(summary.id, with: annotation)
        }
    }

    /// Clears the session's traffic. Pinned exchanges stay.
    public func clear() async {
        // Requests held at breakpoints go on as they are first, as on the Mac.
        continueAllPaused()
        callSession { await $0.clear() }
        await lastSessionCall?.value
    }

    // MARK: - An exchange

    /// An exchange, with its details and bodies.
    public func exchange(_ id: ExchangeID) async throws(Problem) -> Exchange {
        guard let exchange = await capture.exchange(id) else {
            throw Problem(.notFound, "The session has no exchange \(id.rawValue).")
        }
        return exchange
    }

    /// A body made ready to show, with the message type chosen for bodies like it.
    public func presentBody(_ id: ExchangeID, part: BodyPart) async throws(Problem) -> PresentedBody {
        let exchange = try await exchange(id)
        let body = await presentation(exchange, part: part)
        let reading = await protobuf.reading(for: Self.protobufKey(exchange, part: part))
        return PresentedBody(
            body: body, chosenType: reading.chosenType, hasMessageTypes: !reading.schema.messageNames.isEmpty)
    }

    /// A tree node's path, such as `hourly[0].time`, and its value to copy.
    public func bodyNode(_ id: ExchangeID, part: BodyPart, node: Int) async throws(Problem)
        -> (path: String, copyText: String)
    {
        let body = await presentation(try await exchange(id), part: part)
        guard let tree = body.tree, (0..<tree.count).contains(node) else {
            throw Problem(.notFound, "The body has no node \(node).")
        }
        return (tree.path(to: node), tree.copyText(of: node))
    }

    /// The request and the response as text, the way HTTP/1.1 writes them, with or without
    /// secrets such as cookies.
    public func raw(_ id: ExchangeID, showsSecrets: Bool) async throws(Problem) -> RawExchange {
        let exchange = try await exchange(id)
        let request = RawMessage(request: exchange.request, body: exchange.requestBody, hidingSecrets: !showsSecrets)
        let response = exchange.response.map {
            RawMessage(
                response: $0, body: exchange.responseBody, trailers: exchange.responseTrailers,
                hidingSecrets: !showsSecrets)
        }
        let hasSecrets =
            exchange.request.headers.contains(where: \.isSecret)
            || (exchange.response?.headers.contains(where: \.isSecret) ?? false)
        return RawExchange(request: request, response: response, hasSecrets: hasSecrets)
    }

    /// An exchange's WebSocket messages, from the one numbered `from` on.
    public func messages(_ id: ExchangeID, from: Int = 0) async -> [WebSocketMessage] {
        await capture.messages(of: id, from: from)
    }

    /// A WebSocket message made ready to show, as a body is.
    public func presentMessage(_ id: ExchangeID, number: Int) async throws(Problem) -> BodyPresentation {
        guard let message = await capture.messages(of: id, from: number).first else {
            throw Problem(.notFound, "The exchange has no message \(number).")
        }
        let headers: Headers = [
            "Content-Type": message.kind == .binary ? "application/octet-stream" : "text/plain; charset=utf-8"
        ]
        return await Task.detached(priority: .userInitiated) {
            BodyPresentation(data: message.data, headers: headers, rootLabel: "Message")
        }.value
    }

    /// Part of a body as bytes, from `offset`, at most `limit` of them: as it came, or unpacked,
    /// as the Hex and Preview views show it.
    public func body(_ id: ExchangeID, part: BodyPart, offset: Int, limit: Int, unpacked: Bool = false) async -> Data? {
        guard let exchange = await capture.exchange(id) else { return nil }
        let data =
            unpacked
            ? await presentation(exchange, part: part).content
            : part == .request ? exchange.requestBody : exchange.responseBody
        guard offset >= 0, limit >= 0, offset <= data.count else { return nil }
        let start = data.startIndex + offset
        return Data(data[start..<min(data.endIndex, start + limit)])
    }

    /// A body made ready to show. Formatting a big one takes a moment, so it happens away from the
    /// session, and the latest few are kept.
    private func presentation(_ exchange: Exchange, part: BodyPart) async -> BodyPresentation {
        let data = part == .request ? exchange.requestBody : exchange.responseBody
        let schema = await protobuf.reading(for: Self.protobufKey(exchange, part: part))
        let key = BodyKey(
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
    private struct BodyKey: Hashable {
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

    /// Reads bodies like this one, the same part of requests to the same host and path, as a
    /// message type from now on; or with none, as Reqly works out.
    public func chooseMessageType(_ type: String?, for id: ExchangeID, part: BodyPart) async throws(Problem) {
        let key = Self.protobufKey(try await exchange(id), part: part)
        await protobuf.choose(type, for: key)
    }

    // MARK: - Copying and sending

    /// A request to write, filled in from an exchange, for Edit and Resend.
    public func draft(_ id: ExchangeID) async throws(Problem) -> RequestDraft {
        RequestDraft(try await readable(id))
    }

    /// A cURL command that sends the request again.
    public func curl(_ id: ExchangeID) async throws(Problem) -> String {
        let exchange = try await readable(id)
        return CurlCommand.make(exchange.request, body: exchange.requestBody)
    }

    /// The response body as Copy Response Body copies it: unpacked, as text when it's text, as an
    /// image when it's an image, and otherwise as hex.
    public func copyableBody(_ id: ExchangeID) async throws(Problem) -> CopyableBody {
        let exchange = try await readable(id)
        guard let response = exchange.response else {
            throw Problem(.notAvailable, "This request has no response yet.")
        }
        return CopyableBody(exchange.responseBody, headers: response.headers)
    }

    /// Sends a request you wrote, straight to its server, and records it like any other.
    public func send(_ draft: RequestDraft) async throws(Problem) -> ExchangeID {
        let request = try draft.request()
        return await capture.send(request, from: Self.reqly)
    }

    /// Sends a request again, as the app sent it.
    public func resend(_ id: ExchangeID) async throws(Problem) -> ExchangeID {
        let exchange = try await readable(id)
        guard let request = OutgoingRequest(resending: exchange.request, body: exchange.requestBody) else {
            throw Problem(.notAvailable, "This request can't be sent again.")
        }
        return await capture.send(request, from: Self.reqly)
    }

    /// An exchange with a request to read: not an encrypted connection.
    private func readable(_ id: ExchangeID) async throws(Problem) -> Exchange {
        guard let exchange = await capture.exchange(id) else {
            throw Problem(.notFound, "The session has no exchange \(id.rawValue).")
        }
        guard exchange.kind == .http else {
            throw Problem(.notAvailable, "An encrypted connection has no request to copy.")
        }
        return exchange
    }

    // MARK: - Breakpoints

    /// The request or the response a breakpoint holds for an exchange, as you're editing it.
    public func pausedEdit(_ id: ExchangeID) -> PausedEdit? {
        paused[id.rawValue]
    }

    /// Lets a request or a response held at a breakpoint go on, as `edit` has it. An edit that
    /// can't go on, such as one with a URL that isn't one, is kept as the one you're editing, and
    /// the problem says what to fix.
    public func resumePaused(_ id: ExchangeID, as edit: PausedEdit) throws(Problem) {
        try checkPaused(id)
        let message: PausedMessage
        do {
            message = try edit.edited()
        } catch {
            paused[id.rawValue] = edit
            throw Problem(.badRequest, error.message)
        }
        capture.decide(id, .resume(message))
        paused[id.rawValue] = nil
        emit(.resumed(id: id))
    }

    /// Stops a request or a response held at a breakpoint: it goes no further, and its app gets
    /// no answer from it.
    public func stopPaused(_ id: ExchangeID) throws(Problem) {
        try checkPaused(id)
        capture.decide(id, .cancel)
        paused[id.rawValue] = nil
        emit(.resumed(id: id))
    }

    private func checkPaused(_ id: ExchangeID) throws(Problem) {
        guard paused[id.rawValue] != nil else {
            throw Problem(.notFound, "Nothing is waiting at a breakpoint for exchange \(id.rawValue).")
        }
    }

    /// Lets every request and response held at a breakpoint go on as it was.
    public func continueAllPaused() {
        for (id, edit) in paused {
            capture.decide(ExchangeID(rawValue: id), .resume(edit.original))
            emit(.resumed(id: ExchangeID(rawValue: id)))
        }
        paused.removeAll()
    }

    // MARK: - Scripts

    /// What's wrong with a script, or nothing when it reads.
    public func checkScript(_ code: String) async -> String? {
        await capture.checkScript(code)
    }

    /// A script's syntax, to color it as you type: its keywords, strings, numbers, literals and
    /// comments. Past the limit, the script shows without colors, as long bodies do.
    public nonisolated func highlightScript(_ code: String) -> [SyntaxToken] {
        code.utf16.count <= HighlightedText.highlightLimit ? JavaScriptSyntax.tokens(in: code) : []
    }

    /// Runs a script on a captured exchange, as it would run on traffic, and says what it would do.
    public func tryScript(_ code: String, on id: ExchangeID) async -> [ScriptTrial] {
        await capture.tryScript(code, on: id)
    }

    /// Scripts to start from, for the script editor's Examples menu.
    public nonisolated func scriptExamples() -> [ScriptExamples.Example] {
        ScriptExamples.all
    }

    // MARK: - Saving

    /// Saves the session as a file that Reqly opens on the Mac, on Windows and on Linux alike.
    public func saveSession(to url: URL, hidingSecrets: Bool) async throws(Problem) {
        // Pins and comments on their way are saved first.
        await lastSessionCall?.value
        await capture.flush()
        do {
            try await capture.store.saveSession(to: url, hidingSecrets: hidingSecrets)
        } catch {
            throw Problem(.failed, "Reqly couldn't save the session. \(error.localizedDescription)")
        }
    }

    /// Writes exchanges to a HAR file, these or with none the list as it shows, in order, and
    /// says how many it wrote. It sends `exportProgress` events as it goes. Encrypted connections
    /// are left out, since their requests can't be read.
    public func exportHAR(
        to url: URL, ids: [ExchangeID]? = nil, includesResponseBodies: Bool = true, hidesSecrets: Bool = true,
        creatorVersion: String
    ) async throws(Problem) -> Int {
        let ids = ids ?? list.rows
        let options = HARWriter.Options(includesResponseBodies: includesResponseBodies, hidesSecrets: hidesSecrets)
        await lastSessionCall?.value
        await capture.flush()
        var exported = 0
        do {
            let writer = try HARWriter(url: url, options: options, creatorVersion: creatorVersion)
            for (done, id) in ids.enumerated() {
                if let exchange = await capture.exchange(id), exchange.kind == .http {
                    let messages = exchange.messageCount > 0 ? await capture.messages(of: id) : []
                    try writer.append(exchange, messages: messages)
                    exported += 1
                }
                if done % 25 == 0 {
                    emit(.exportProgress(done: done, total: ids.count))
                }
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Problem(.failed, "Reqly couldn't export: \(error.localizedDescription)")
        }
        return exported
    }

    // MARK: - HTTPS

    /// Whether HTTPS is set up, and the hosts to decrypt. As the session opens, it waits for the
    /// certificate to be read, as each of the HTTPS calls does.
    public func https() async throws(Problem) -> HTTPSState {
        try await withHTTPS { await $0.currentState() }
    }

    /// Makes Reqly's certificate if there isn't one, and asks the system to trust it.
    public func setUpHTTPS() async throws(Problem) -> HTTPSState {
        let https = try await withHTTPS { $0 }
        return try await https.setUp()
    }

    /// Removes the certificate, its key and the system's trust in it.
    public func removeHTTPS() async throws(Problem) -> HTTPSState {
        let https = try await withHTTPS { $0 }
        return try await https.remove()
    }

    /// Reads the certificate from the store again, and whether it's trusted, after the app made
    /// it or trusted it itself, as the Linux app does, place by place. The session decrypts once
    /// any place trusts it. A session that doesn't decrypt, such as a saved one, says HTTPS isn't
    /// set up.
    public func reloadHTTPS() async -> HTTPSState {
        guard let httpsHost else { return HTTPSState(status: .notSetUp, hosts: DecryptedHosts()) }
        return await httpsHost.reload()
    }

    /// The hosts to decrypt, as the app saved them.
    public func setDecryptedHosts(_ hosts: DecryptedHosts) async throws(Problem) -> HTTPSState {
        try await changeHosts { $0 = hosts }
    }

    /// Decrypts a host from now on: switches its entry on, or adds one.
    public func decryptHost(_ host: String) async throws(Problem) -> HTTPSState {
        try await changeHosts { $0.decrypt(host) }
    }

    /// Stops decrypting a host. It stays on the list, switched off.
    public func stopDecryptingHost(_ host: String) async throws(Problem) -> HTTPSState {
        try await changeHosts { $0.stopDecrypting(host) }
    }

    /// Adds a host or a wildcard, such as `*.example.com`, to the list, or says why it can't.
    public func addDecryptedHost(_ text: String) async throws(Problem) -> HTTPSState {
        let https = try await withHTTPS { $0 }
        return try await https.addHost(text)
    }

    public func removeDecryptedHosts(_ patterns: [HostPattern]) async throws(Problem) -> HTTPSState {
        try await changeHosts { $0.remove(Set(patterns)) }
    }

    public func setHostDecrypted(_ pattern: HostPattern, isOn: Bool) async throws(Problem) -> HTTPSState {
        try await changeHosts { $0.setDecrypts(isOn, pattern) }
    }

    public func setDecryptsEveryHost(_ isOn: Bool) async throws(Problem) -> HTTPSState {
        try await changeHosts { $0.includesEveryHost = isOn }
    }

    /// Whether Reqly decrypts a host now.
    public func decryptsHost(_ host: String) async throws(Problem) -> Bool {
        try await withHTTPS { await $0.decrypts(host) }
    }

    private func changeHosts(_ change: @escaping @Sendable (inout DecryptedHosts) -> Void) async throws(Problem)
        -> HTTPSState
    {
        try await withHTTPS { await $0.changeHosts(change) }
    }

    private func withHTTPS<Result: Sendable>(_ body: (HTTPSHost) async -> Result) async throws(Problem) -> Result {
        guard let httpsHost else {
            throw Problem(
                .notAvailable, "This session doesn't decrypt HTTPS: it's a saved one, or it has no certificate store.")
        }
        return await body(httpsHost)
    }

    // MARK: - Rules

    /// Opens the rules file and gives the session its rules. Each change after is saved to it.
    public func openRules(_ file: URL) -> RulesState {
        rulesBook.open(file)
        capture.setRules(rulesBook.set)
        return rulesBook.state
    }

    /// The rules, as the Rules window lists them.
    public func rules() -> RulesState {
        rulesBook.state
    }

    /// Replaces every rule, the kinds that are on and the network conditions with a set of
    /// rules, such as one read from a rules file.
    public func setRules(_ set: RuleSet) {
        changeRules { $0 = set }
    }

    /// Switches a kind of rule on or off, such as breakpoints. A rule acts only while its kind is on.
    @discardableResult
    public func setRuleKindOn(_ kind: RuleKind, isOn: Bool) -> RulesState {
        changeRules { set in
            if isOn {
                set.kindsOn.insert(kind)
            } else {
                set.kindsOn.remove(kind)
            }
        }
    }

    @discardableResult
    public func setRuleOn(_ id: UUID, isOn: Bool) -> RulesState {
        changeRules { set in
            if let index = set.rules.firstIndex(where: { $0.id == id }) {
                set.rules[index].isOn = isOn
            }
        }
    }

    @discardableResult
    public func removeRules(_ ids: [UUID]) -> RulesState {
        changeRules { $0.rules.removeAll { ids.contains($0.id) } }
    }

    /// Moves a rule to another place among the rules of its kind.
    @discardableResult
    public func moveRule(_ id: UUID, to place: Int) -> RulesState {
        changeRules { $0.move(id, to: place) }
    }

    /// Adds a copy of a rule, last among the rules of its kind.
    @discardableResult
    public func duplicateRule(_ id: UUID) -> RulesState {
        changeRules { set in
            guard var copy = set.rules.first(where: { $0.id == id }) else { return }
            copy.id = UUID()
            copy.name = "\(copy.name) copy"
            set.rules.append(copy)
        }
    }

    /// A new rule to edit, filled in from an exchange when there is one.
    public func newRuleDraft(kind: RuleKind, from id: ExchangeID? = nil) throws(Problem) -> RuleDraft {
        guard kind != .slowNetwork else { throw Problem(.badRequest, "Slow Network has no rules of its own.") }
        var summary: ExchangeSummary?
        if let id {
            guard let found = list.summary(id) else {
                throw Problem(.notFound, "There's no exchange \(id.rawValue).")
            }
            summary = found
        }
        return RuleDraft(kind: kind, from: summary)
    }

    /// A saved rule, to edit.
    public func ruleDraft(_ id: UUID) throws(Problem) -> RuleDraft {
        guard let rule = rulesBook.set.rules.first(where: { $0.id == id }) else {
            throw Problem(.notFound, "There's no rule \(id.uuidString).")
        }
        return RuleDraft(rule: rule)
    }

    /// What to fix in a draft, the name it gets, and how many requests captured so far it matches.
    public func checkRuleDraft(_ draft: RuleDraft) -> RuleCheck {
        RuleCheck(
            problem: draft.problem, defaultName: draft.defaultName, matchCount: draft.matchCount(in: list.all),
            matching: draft.kind == .script ? draft.matchingRequests(in: list.all) : nil)
    }

    /// Saves a draft's rule. A new rule's kind comes on with it, so the rule acts.
    @discardableResult
    public func saveRuleDraft(_ draft: RuleDraft) throws(Problem) -> RulesState {
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
    }

    /// What Slow Network slows down, and how much.
    @discardableResult
    public func setNetwork(_ network: NetworkConditions) -> RulesState {
        changeRules { $0.network = network }
    }

    /// Slow Network's profiles to choose from: 3G, LTE and a lossy network.
    public nonisolated func networkPresets() -> [NetworkProfile] {
        NetworkProfile.presets
    }

    /// Changes the rules, saves them and gives them to the session, then lists them as they are.
    @discardableResult
    private func changeRules(_ body: (inout RuleSet) -> Void) -> RulesState {
        if rulesBook.change(body) {
            capture.setRules(rulesBook.set)
        }
        return rulesBook.state
    }

    // MARK: - Connections

    /// Opens the connection settings and gives the session its upstream proxy, reverse proxies
    /// and client certificates; each change after is saved. The proxy's password and the
    /// certificates' keys go in the secrets file, which the system keeps for your user unless
    /// `protectsSecrets` is false, as for a test run.
    public func openConnections(_ file: URL, secrets: URL, protectsSecrets: Bool = true) async -> ConnectionsState {
        // Reading the secrets may wait for you to unlock your keyring.
        let storage = system.secrets(secrets, protectsSecrets)
        let loaded = await offThread { Result { try storage.load() } }
        connectionsBook.open(file, secrets: storage, loaded: loaded)
        capture.setUpstreamProxy(connectionsBook.activeUpstreamProxy)
        capture.setClientIdentities(connectionsBook.activeIdentities)
        await applyReverseProxies()
        return connectionsState
    }

    /// The connection settings, with why each reverse proxy that's on isn't listening.
    public func connections() async -> ConnectionsState {
        reverseProxyProblems = await capture.reverseProxyProblems.mapValues(\.message)
        return connectionsState
    }

    /// What's wrong with the upstream proxy as you edit it. `proxyPort` is the one Reqly listens on.
    public nonisolated func checkUpstreamProxy(_ draft: UpstreamProxyDraft, proxyPort: Int) -> String? {
        draft.problem(proxyPort: proxyPort)
    }

    /// Applies the upstream proxy, which reconnects what goes another way now.
    public func setUpstreamProxy(_ draft: UpstreamProxyDraft, proxyPort: Int) throws(Problem) -> ConnectionsState {
        if let problem = draft.problem(proxyPort: proxyPort) {
            throw Problem(.badRequest, problem)
        }
        let proxy = draft.proxy
        connectionsBook.setUpstreamProxy(proxy, isOn: draft.isOn && proxy != nil)
        capture.setUpstreamProxy(connectionsBook.activeUpstreamProxy)
        return connectionsState
    }

    /// A new reverse proxy to edit, on a port none uses yet.
    public func newReverseProxy(proxyPort: Int) -> ReverseProxyDraft {
        let proxies = connectionsBook.contents.reverseProxies
        return ReverseProxyDraft(
            ReverseProxy(localPort: ReverseProxy.suggestedPort(among: proxies, proxyPort: proxyPort), serverURL: ""))
    }

    /// What's wrong with a reverse proxy as you edit it, or where it sends requests.
    public func checkReverseProxy(_ draft: ReverseProxyDraft, proxyPort: Int) -> CheckResult {
        let proxy = draft.proxy(keeping: nil)
        let problem = proxy.problem(
            port: draft.port, proxyPort: proxyPort, among: connectionsBook.contents.reverseProxies)
        let note =
            problem == nil
            ? proxy.server.map { "Apps that use http://localhost:\(String(proxy.localPort)) reach \($0.url)." }
            : nil
        return CheckResult(problem: problem, note: note)
    }

    /// Adds a reverse proxy, or changes the one with the same ID.
    public func saveReverseProxy(_ draft: ReverseProxyDraft, proxyPort: Int) async throws(Problem)
        -> ConnectionsState
    {
        let proxies = connectionsBook.contents.reverseProxies
        let proxy = draft.proxy(keeping: proxies.first { $0.id == draft.id })
        if let problem = proxy.problem(port: draft.port, proxyPort: proxyPort, among: proxies) {
            throw Problem(.badRequest, problem)
        }
        connectionsBook.saveReverseProxy(proxy)
        await applyReverseProxies()
        return connectionsState
    }

    @discardableResult
    public func removeReverseProxy(_ id: UUID) async -> ConnectionsState {
        connectionsBook.removeReverseProxy(id)
        await applyReverseProxies()
        return connectionsState
    }

    @discardableResult
    public func setReverseProxyOn(_ id: UUID, isOn: Bool) async -> ConnectionsState {
        connectionsBook.setReverseProxy(id, isOn: isOn)
        await applyReverseProxies()
        return connectionsState
    }

    /// What's wrong with hosts as typed, such as `api.example.com, *.example.com`, and the hosts
    /// they name.
    public nonisolated func checkHosts(_ text: String) -> HostList {
        HostList(text)
    }

    /// Reads a certificate and its private key from files, and presents them to the hosts from now on.
    public func addClientCertificate(files: [URL], password: String = "", hosts text: String) throws(Problem)
        -> ConnectionsState
    {
        let hosts = try Self.hosts(text)
        let identity: ClientIdentity
        do {
            identity = try ClientIdentity.read(files, password: password, hosts: hosts)
        } catch {
            throw Problem(.badRequest, error.message)
        }
        connectionsBook.addClientCertificate(identity)
        capture.setClientIdentities(connectionsBook.activeIdentities)
        return connectionsState
    }

    @discardableResult
    public func setClientCertificateHosts(_ id: UUID, hosts text: String) throws(Problem) -> ConnectionsState {
        connectionsBook.setHosts(try Self.hosts(text), of: id)
        capture.setClientIdentities(connectionsBook.activeIdentities)
        return connectionsState
    }

    @discardableResult
    public func setClientCertificateOn(_ id: UUID, isOn: Bool) -> ConnectionsState {
        connectionsBook.setClientCertificate(id, isOn: isOn)
        capture.setClientIdentities(connectionsBook.activeIdentities)
        return connectionsState
    }

    @discardableResult
    public func removeClientCertificate(_ id: UUID) -> ConnectionsState {
        connectionsBook.removeClientCertificate(id)
        capture.setClientIdentities(connectionsBook.activeIdentities)
        return connectionsState
    }

    private var connectionsState: ConnectionsState {
        connectionsBook.state(reverseProxyProblems: reverseProxyProblems)
    }

    /// Gives the session the reverse proxies, which listen while it captures, and keeps why any can't.
    private func applyReverseProxies() async {
        reverseProxyProblems = await capture.setReverseProxies(connectionsBook.contents.reverseProxies)
            .mapValues(\.message)
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

    // MARK: - Devices

    /// Opens the devices you let in, and asks the app about each new one from then on, with a
    /// `deviceWaiting` event. While devices are allowed, the proxy listens on the network.
    public func openDevices(_ file: URL, allowsNetworkDevices allows: Bool) async -> DevicesState {
        devicesFile = file
        devicesBook = DevicesBook(DevicesFile.load(from: file))
        origins.use(devicesBook)
        capture.setDeviceAdmission { [weak self] client in
            await self?.admit(client) ?? false
        }
        return await setAllowsNetworkDevices(allows)
    }

    /// The devices you let in, the ones waiting, and this computer's addresses for them.
    public func devices() -> DevicesState {
        devicesState
    }

    /// Lets phones and tablets on the network connect, once you let each one in, or only this
    /// computer. Turning it off closes their connections and turns away the ones waiting.
    @discardableResult
    public func setAllowsNetworkDevices(_ allows: Bool) async -> DevicesState {
        allowsNetworkDevices = allows
        if !allows {
            for id in devicesBook.refuseAll() {
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
        return devicesState
    }

    /// Lets a waiting device in, with the name you gave it, or turns it away until Reqly quits.
    @discardableResult
    public func decideDevice(_ id: String, allow: Bool, name: String? = nil) -> DevicesState {
        devicesBook.decide(id, allow: allow, name: name)
        if allow {
            saveDevices()
        }
        for continuation in waitingDevices.removeValue(forKey: id) ?? [] {
            continuation.resume(returning: allow)
        }
        return devicesState
    }

    /// Stops letting a device in. It's asked about again the next time it connects.
    @discardableResult
    public func forgetDevice(_ id: String) -> DevicesState {
        devicesBook.forget(id)
        saveDevices()
        return devicesState
    }

    /// Names a device's traffic, from now on and in the list already.
    @discardableResult
    public func renameDevice(_ id: String, to name: String) async throws(Problem) -> DevicesState {
        guard devicesBook.rename(id, to: name), let named = devicesBook.names[id] else {
            throw Problem(.badRequest, "Enter a name for the device.")
        }
        saveDevices()
        await capture.renameDevice(id, to: named)
        show(steps(for: list.renameDevice(id, to: named)))
        publishSidebar()
        return devicesState
    }

    /// A QR code for a short text, such as the setup page's address.
    public nonisolated func qrCode(_ text: String) throws(Problem) -> QRCode {
        guard let code = QRCode(text) else { throw Problem(.badRequest, "The text is too long for a QR code.") }
        return code
    }

    /// The Android emulators that run, and whether each sends its traffic through Reqly on `port`.
    public func emulators(port: Int) async -> Emulators {
        guard let adb = findAdb() else {
            return Emulators(hasAdb: false, emulators: [], problem: AndroidDebugBridge.missing)
        }
        do {
            let proxy = AndroidDebugBridge.proxy(port: port)
            let emulators = try await adb.emulators().map {
                Emulators.Row(emulator: $0, usesReqly: $0.proxy == proxy)
            }
            return Emulators(hasAdb: true, emulators: emulators, problem: nil)
        } catch {
            return Emulators(hasAdb: true, emulators: [], problem: AndroidDebugBridge.listingProblem(error))
        }
    }

    /// Points an emulator's traffic at Reqly on `port`, or back to a direct connection.
    public func setEmulatorUsesReqly(serial: String, isOn: Bool, port: Int) async throws(Problem) -> CheckResult {
        let adb = try adb()
        do {
            try await adb.setProxy(isOn ? AndroidDebugBridge.proxy(port: port) : nil, on: serial)
            return CheckResult(problem: nil, note: nil)
        } catch {
            return CheckResult(problem: error.localizedDescription, note: nil)
        }
    }

    /// Copies Reqly's certificate, in DER, into an emulator's Downloads, and opens its security
    /// settings, where you install it.
    public func copyCertificateToEmulator(serial: String, certificate: Data) async throws(Problem) -> CheckResult {
        let adb = try adb()
        do {
            try await adb.copyCertificate(der: [UInt8](certificate), to: serial)
            try await adb.openSecuritySettings(on: serial)
            return CheckResult(problem: nil, note: "Copied “Reqly CA.crt” to Downloads.")
        } catch {
            return CheckResult(problem: error.localizedDescription, note: nil)
        }
    }

    /// Android's tools, or the problem that says they aren't there.
    func adb() throws(Problem) -> AndroidDebugBridge {
        guard let adb = findAdb() else { throw Problem(.notAvailable, AndroidDebugBridge.missing) }
        return adb
    }

    /// Finds Android's tools another way from now on, such as not at all, for tests.
    func findAdb(with find: @escaping @Sendable () -> AndroidDebugBridge?) {
        findAdb = find
    }

    private var devicesState: DevicesState {
        DevicesState(
            devicesBook, allowsNetworkDevices: allowsNetworkDevices, addresses: system.networkAddresses(),
            problem: devicesProblem)
    }

    /// Whether a device on the network may send its traffic through Reqly: yes if you let it in
    /// before, and otherwise once you decide. Every connection from it waits on the same decision.
    func admit(_ client: ClientAddress) async -> Bool {
        let id = DevicesFile.identity(ip: client.ip, hardwareAddress: system.hardwareAddress(client.ip))
        let saved = devicesBook.contents
        let verdict = devicesBook.admit(id: id, address: client.ip, allowsNetworkDevices: allowsNetworkDevices)
        if devicesBook.contents != saved {
            saveDevices()
        }
        switch verdict {
        case .allow:
            origins.use(devicesBook)
            return true
        case .refuse:
            return false
        case .ask(let isNewRequest):
            if isNewRequest {
                emit(.deviceWaiting(id: id, address: client.ip, waiting: devicesBook.requests.count))
            }
            return await withCheckedContinuation { continuation in
                waitingDevices[id, default: []].append(continuation)
            }
        }
    }

    /// Saves the devices you let in and their names, and names their connections from now on.
    private func saveDevices() {
        origins.use(devicesBook)
        guard let devicesFile else { return }
        do {
            try DevicesFile.save(devicesBook.contents, to: devicesFile)
        } catch {
            devicesProblem = DevicesFile.saveProblem(error)
        }
    }

    // MARK: - The session's changes

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

    private func apply(_ change: SessionChange) {
        switch change {
        case .cleared:
            show(steps(for: list.removeUnpinned()))
            // What was held went on with the clear, rows and all, so its editor goes too.
            for id in paused.keys where list.summary(ExchangeID(rawValue: id)) == nil {
                paused[id] = nil
                emit(.resumed(id: ExchangeID(rawValue: id)))
            }
        case .updated(let summaries, let removed):
            // A held exchange that finished, as when its app gave up waiting, or went, isn't held.
            for summary in summaries where summary.state.isFinished && paused[summary.id.rawValue] != nil {
                paused[summary.id.rawValue] = nil
                emit(.resumed(id: summary.id))
            }
            for id in removed where paused[id.rawValue] != nil {
                paused[id.rawValue] = nil
                emit(.resumed(id: id))
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
            emit(.storageProblem(message))
        case .paused(let id, let message, let breakpoint):
            let edit = PausedEdit(message, breakpoint: breakpoint)
            paused[id.rawValue] = edit
            emit(.paused(id: id, edit: edit))
        }
    }

    // MARK: - The list's changes

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
                return .inserted(rows.map { RowStep.InsertedRow(row: $0, id: list.rows[$0]) })
            case .changed(let ids):
                return .changed(Array(ids))
            }
        }
    }

    private func show(_ steps: [RowStep]) {
        if !steps.isEmpty {
            version += 1
            let joining = steps.reduce(0) { count, step in
                if case .inserted(let rows) = step { count + rows.count } else { count }
            }
            let sent = joining > Self.resetThreshold ? [RowStep.reset(list.rows)] : steps
            emit(.rows(version: version, total: list.all.count, shown: list.rows.count, steps: sent))
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
            emit(.sidebar(sidebar()))
        } else if !changed.isEmpty || totals != totalsSent {
            totalsSent = totals
            var counts: [String: Int] = [:]
            for scope in changed {
                counts[Self.key(scope)] = list.count(of: scope)
            }
            emit(.counts(total: list.all.count, pinned: list.pinnedCount, counts: counts))
        }
    }

    private func sidebar() -> Sidebar {
        var rows = SidebarRows(list: list)
        let devices = list.devices.map { entry in
            let device = rows.row(.device(entry.choice), entry.device?.name ?? "")
            return Sidebar.DeviceRow(
                key: device.key, device: entry.choice, name: entry.device?.name, kind: entry.device?.kind,
                count: device.count, apps: rows.apps(on: entry.choice),
                otherHosts: (list.otherHostsByDevice[entry.choice] ?? []).map {
                    rows.row(.deviceHost($0, on: entry.choice), $0)
                })
        }
        let sidebar = Sidebar(
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

        mutating func row(_ scope: TrafficList.Scope, _ name: String, path: String? = nil) -> Sidebar.Row {
            let key = SessionHost.key(scope)
            scopes[key] = scope
            return Sidebar.Row(key: key, name: name, count: list.count(of: scope), path: path)
        }

        mutating func apps(on device: DeviceChoice) -> [Sidebar.Row] {
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
}
