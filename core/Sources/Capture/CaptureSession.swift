import BodyKit
import CertificateAuthority
import Foundation
import ProxyEngine
import ReqlyModel
import Scripts
import TrafficStore

public enum CaptureError: Error, Equatable {
    /// Another app already listens on this port.
    case portInUse(Int)
}

/// A change to the session's traffic, for the interface to apply.
public enum SessionChange: Sendable {
    /// New or changed exchanges, oldest first, and the exchanges dropped to stay within the
    /// session's size limit, also oldest first. The store already has them. They come together,
    /// so the interface shows a save in one go.
    case updated([ExchangeSummary], removed: [ExchangeID] = [])
    /// Everything was cleared except the pinned exchanges. Their latest summaries follow.
    case cleared
    /// Saving traffic failed, with a message to show; or it works again, with `nil`.
    case storageProblem(String?)
    /// A breakpoint holds an exchange, with the request or response as it would go on, and the
    /// name of the breakpoint's rule. Answer with ``CaptureSession/decide(_:_:)``.
    case paused(ExchangeID, PausedMessage, breakpoint: String)
}

/// Runs the proxy and saves the traffic it sees in a TrafficStore. It stays alive for the app's
/// whole life, while capturing starts and stops.
///
/// Changes are saved and then published together, about ten times a second, so a busy network
/// doesn't flood the store or the interface.
public actor CaptureSession {
    /// Finds where a connection came from: for one from this Mac, the app or tool at its other
    /// end, found by its port and the proxy's; for one from the network, the device. Each
    /// platform finds them its own way.
    public typealias OriginFinder = @Sendable (_ client: ClientAddress, _ proxyPort: Int) async -> Origin?

    public nonisolated let changes: AsyncStream<SessionChange>
    /// Where the session's traffic is kept.
    public nonisolated let store: TrafficStore

    /// Finished exchanges stay in memory until the traffic is this far past their end, in case
    /// they start again.
    static let finishedGracePeriod: TimeInterval = 5

    private let server: ProxyServer
    /// Points the Mac's proxy at Reqly while capturing. Without one, apps must be pointed at
    /// Reqly by hand.
    private let systemProxy: (any SystemProxySwitch)?
    /// Without one, traffic isn't credited to apps or devices.
    private let findOrigin: OriginFinder?
    /// Whether devices on the network can connect, rather than only this Mac.
    private var listensOnNetwork = false
    private var listeningPort = 0
    private let continuation: AsyncStream<SessionChange>.Continuation
    /// Exchanges in progress, and ones that finished moments ago.
    private var assembler = ExchangeAssembler()
    /// Exchanges that changed since the last save.
    private var changed: Set<ExchangeID> = []
    /// Body bytes that arrived since the last save, in order.
    private var chunks: [BodyChunk] = []
    /// WebSocket messages that arrived since the last save, in order.
    private var messages: [StoredMessage] = []
    /// The latest job for the store. Each one waits for the one before, so they happen in order.
    private var lastStoreJob: Task<Void, Never>?
    private var isSaveScheduled = false
    /// Goes up with every clear. A save that began before a clear publishes nothing.
    private var generation = 0
    private var hasStorageProblem = false
    private var recording: Task<Void, Never>?
    /// What sent the requests Reqly sends itself, by their connection, until they're recorded.
    private var pendingOrigins: [ConnectionID: Origin] = [:]
    /// When the latest event recorded happened. Finished exchanges are let go by it, not by the
    /// clock, so when recording falls behind the traffic on a busy Mac, an exchange is still here
    /// when the events that open it again are recorded.
    private var latestEventTime = Date.distantPast

    /// - Parameter extraTrustedRoots: Root certificates, in DER, to trust when checking servers, on
    ///   top of the ones the Mac trusts. Debug builds use it to reach local test servers.
    public init(
        store: TrafficStore, systemProxy: (any SystemProxySwitch)? = nil, extraTrustedRoots: [[UInt8]] = [],
        findOrigin: OriginFinder? = nil
    ) {
        let (changes, continuation) = AsyncStream.makeStream(of: SessionChange.self)
        self.changes = changes
        self.continuation = continuation
        self.store = store
        self.server = ProxyServer(extraTrustedRoots: extraTrustedRoots)
        self.systemProxy = systemProxy
        self.findOrigin = findOrigin
    }

    public var isCapturing: Bool {
        get async { await server.isRunning }
    }

    /// Starts the proxy on `port`, points the Mac's proxy at it, and returns the port it listens on.
    @discardableResult
    public func start(port: Int) async throws -> Int {
        startRecording()
        let listening: Int
        do {
            listening = try await server.start(
                ProxyServer.Configuration(host: listensOnNetwork ? "0.0.0.0" : "127.0.0.1", port: port))
        } catch ProxyServer.ServerError.portInUse(let port) {
            throw CaptureError.portInUse(port)
        }
        listeningPort = listening
        do {
            try await systemProxy?.enable(port: listening)
        } catch {
            await server.stop()
            throw error
        }
        return listening
    }

    /// Sends a request from Reqly itself, such as one you composed, whether or not Reqly is
    /// capturing. It's recorded like any other, and credited to `source`.
    @discardableResult
    public func send(_ request: OutgoingRequest, from source: Source?) -> ExchangeID {
        startRecording()
        let (exchange, connection) = server.send(request)
        // Its events wait for this call to end, so they find the source here.
        if let source {
            pendingOrigins[connection] = Origin(source: source)
        }
        return exchange
    }

    /// Lets devices on the network connect, or only this Mac. While capturing, the change takes
    /// effect at once, and turning it off closes the devices' connections.
    public func setListensOnNetwork(_ listens: Bool) async throws {
        listensOnNetwork = listens
        guard await server.isRunning else { return }
        do {
            try await server.listen(on: listens ? "0.0.0.0" : "127.0.0.1")
        } catch ProxyServer.ServerError.portInUse(let port) {
            throw CaptureError.portInUse(port)
        }
    }

    /// Decides whether a device on the network may send its traffic through Reqly. Until it's
    /// decided, nothing from the device is read. Without a decider, devices are turned away.
    public nonisolated func setDeviceAdmission(_ admit: (@Sendable (ClientAddress) async -> Bool)?) {
        server.setDeviceAdmission(admit)
    }

    /// An exchange's WebSocket messages, in order, from the one numbered `number` on.
    public func messages(of id: ExchangeID, from number: Int = 0) async -> [WebSocketMessage] {
        await flush()
        return (try? await store.messages(of: id, from: number)) ?? []
    }

    /// Names a device, in the traffic so far and from now on.
    public func renameDevice(_ id: String, to name: String) async {
        let renamed = assembler.renameDevice(id, to: name)
        changed.formUnion(renamed)
        let previous = lastStoreJob
        let store = self.store
        let job = Task {
            await previous?.value
            try? await store.renameDevice(id, to: name)
        }
        lastStoreJob = job
        await job.value
    }

    private func startRecording() {
        guard recording == nil else { return }
        let events = server.events
        recording = Task { [weak self] in
            for await event in events {
                await self?.record(event)
            }
        }
    }

    /// The rules for the traffic from now on. Exchanges already on their way keep the rules
    /// they started with.
    public nonisolated func setRules(_ rules: RuleSet) {
        server.setRules(rules)
    }

    /// Lets an exchange held at a breakpoint go on, or stops it.
    public nonisolated func decide(_ exchange: ExchangeID, _ decision: PausedDecision) {
        server.decide(exchange, decision)
    }

    /// Decrypts connections to the hosts that `hosts` decrypts, with certificates from `authority`.
    public nonisolated func setDecryption(authority: CertificateAuthority?, hosts: DecryptedHosts) {
        server.setDecryption(authority: authority, hosts: hosts)
    }

    /// Sends Reqly's connections to servers through `proxy`, or straight to them without one.
    public nonisolated func setUpstreamProxy(_ proxy: UpstreamProxy?) {
        server.setUpstreamProxy(proxy)
    }

    /// Presents these client certificates to the servers they're for.
    public nonisolated func setClientIdentities(_ identities: [ClientIdentity]) {
        server.setClientIdentities(identities)
    }

    /// The reverse proxies, which listen while Reqly captures. Returns why any that are on
    /// can't listen.
    @discardableResult
    public func setReverseProxies(_ proxies: [ReverseProxy]) async -> [ReverseProxy.ID: ProxyServer.ReverseProxyProblem]
    {
        await server.setReverseProxies(proxies)
    }

    /// The script's syntax error, with its line, or `nil` when it compiles.
    public nonisolated func checkScript(_ code: String) async -> String? {
        await ScriptRunner.shared.check(code)
    }

    /// Runs a script on an exchange captured earlier, as it would run on traffic, and says what
    /// it would do. Nothing goes anywhere, and the script's `shared` object starts empty.
    public nonisolated func tryScript(_ code: String, on id: ExchangeID) async -> [ScriptTrial] {
        await flush()
        guard let exchange = await exchange(id) else { return [] }
        let script = Script(code: code)
        let request = ScriptRequest(
            method: exchange.request.method, url: exchange.request.url?.absoluteString ?? "",
            headers: exchange.request.headers, body: exchange.requestBody)
        var trials: [ScriptTrial] = []
        var shared: String?
        if script.runsOnRequest {
            let run = await ScriptRunner.shared.run(script, on: request)
            shared = run.shared
            let detail: String =
                switch run.outcome {
                case _ where run.error != nil: "Failed: \(run.error!)"
                case .request(let changed): ScriptChanges.describe(from: request, to: changed)
                case .answer(let answer): "Would answer with \(answer.status), without asking the server."
                default: "Changes nothing."
                }
            trials.append(ScriptTrial(part: .request, detail: detail, logs: run.logs, failed: run.error != nil))
        }
        if script.runsOnResponse, let head = exchange.response {
            // Scripts get bodies unpacked, as Reqly asks servers not to compress them.
            var headers = head.headers
            var body = exchange.responseBody
            if let encoding = headers["Content-Encoding"],
                let unpacked = BodyDecoder.decode(body, contentEncoding: encoding)
            {
                body = unpacked
                headers.remove(named: "Content-Encoding")
            }
            let response = ScriptResponse(status: head.status, reason: head.reason, headers: headers, body: body)
            let run = await ScriptRunner.shared.run(script, on: response, to: request, shared: shared)
            let detail: String =
                switch run.outcome {
                case _ where run.error != nil: "Failed: \(run.error!)"
                case .response(let changed): ScriptChanges.describe(from: response, to: changed)
                default: "Changes nothing."
                }
            trials.append(ScriptTrial(part: .response, detail: detail, logs: run.logs, failed: run.error != nil))
        }
        return trials
    }

    /// Why reverse proxies that are on aren't listening, while capturing.
    public var reverseProxyProblems: [ReverseProxy.ID: ProxyServer.ReverseProxyProblem] {
        get async { await server.reverseProxyProblems }
    }

    /// Puts the Mac's proxy back, then stops the proxy. If the proxy settings can't be put back,
    /// the proxy keeps running, so apps still reach the internet through it.
    public func stop() async throws {
        try await systemProxy?.disable()
        await server.stop()
    }

    /// Waits until the store has everything so far: the traffic, and the pins and comments.
    public func flush() async {
        await lastStoreJob?.value
    }

    /// Tells the interface about the traffic the store already holds, such as a saved session's.
    public func publishStoredTraffic() async {
        let previous = lastStoreJob
        let store = self.store
        let job = Task { [weak self] in
            await previous?.value
            if let summaries = try? await store.summaries(), !summaries.isEmpty {
                await self?.publish(.updated(summaries))
            }
        }
        lastStoreJob = job
        await job.value
    }

    /// The exchange with its bodies, read from the store.
    public nonisolated func exchange(_ id: ExchangeID) async -> Exchange? {
        try? await store.exchange(id)
    }

    /// The exchanges whose URL, headers or body text contain `text`. Searching needs at least
    /// ``TrafficStore/minimumSearchLength`` characters.
    public nonisolated func search(_ text: String) async -> Set<ExchangeID> {
        (try? await store.search(text)) ?? []
    }

    /// Clears the session's traffic. Pinned exchanges stay, along with what's still on its way
    /// for them.
    public func clear() async {
        generation += 1
        assembler.removeUnpinned()
        let kept = Set(assembler.exchanges.keys)
        changed.formIntersection(kept)
        chunks.removeAll { !kept.contains($0.exchange) }
        messages.removeAll { !kept.contains($0.exchange) }
        continuation.yield(.cleared)
        let previous = lastStoreJob
        let store = self.store
        let removal = Task { [weak self] in
            await previous?.value
            try? await store.removeUnpinned()
            // A save cut short by the clear may not have shown the pinned exchanges' latest state.
            if let pinned = try? await store.summaries(), !pinned.isEmpty {
                await self?.publish(.updated(pinned))
            }
        }
        lastStoreJob = removal
        await removal.value
    }

    /// Pins, marks or comments on an exchange, after the saves already on their way.
    public func annotate(_ id: ExchangeID, with annotation: Annotation) async {
        assembler.annotate(id, with: annotation)
        let previous = lastStoreJob
        let store = self.store
        let job = Task { [weak self] in
            await previous?.value
            try? await store.annotate(id, with: annotation)
            if let summary = try? await store.summary(id) {
                await self?.publish(.updated([summary]))
            }
        }
        lastStoreJob = job
        await job.value
    }

    private func publish(_ change: SessionChange) {
        continuation.yield(change)
    }

    // MARK: - Recording

    func record(_ event: ProxyEvent) {
        if let time = event.time {
            latestEventTime = time
        }
        if case .connectionOpened(let connection, let client, _) = event {
            assembler.apply(event)
            if let origin = pendingOrigins.removeValue(forKey: connection) {
                credit(connection, to: origin)
            } else {
                lookUpOrigin(of: connection, from: client)
            }
            return
        }
        guard let id = assembler.apply(event) else { return }
        changed.insert(id)
        if case .paused(_, let message, let breakpoint) = event {
            // Someone's waiting on it, so it goes out now rather than with the next save.
            continuation.yield(.paused(id, message, breakpoint: breakpoint))
        }
        switch event {
        case .requestBody(_, let data):
            keep(data, of: id, part: .request, total: assembler.exchanges[id]?.bytesSent ?? 0)
        case .responseBody(_, let data):
            keep(data, of: id, part: .response, total: assembler.exchanges[id]?.bytesReceived ?? 0)
        case .webSocketMessage(_, let message):
            let number = (assembler.exchanges[id]?.messageCount ?? 1) - 1
            messages.append(StoredMessage(exchange: id, number: number, message: message))
        default:
            break
        }
        scheduleSave()
    }

    /// Starts finding where a connection came from. Its exchanges are credited once that's known.
    private func lookUpOrigin(of connection: ConnectionID, from client: ClientAddress) {
        // Requests Reqly sends itself have no client.
        guard let findOrigin, !client.ip.isEmpty else { return }
        // An app that uses a reverse proxy connected to that one's port instead.
        let proxyPort = client.localPort ?? listeningPort
        Task { [weak self] in
            guard let origin = await findOrigin(client, proxyPort) else { return }
            await self?.credit(connection, to: origin)
        }
    }

    private func credit(_ connection: ConnectionID, to origin: Origin) {
        let credited = assembler.setOrigin(origin, for: connection)
        guard !credited.isEmpty else { return }
        changed.formUnion(credited)
        scheduleSave()
    }

    /// Queues body bytes for the store, up to its limit for one body. `total` is the size of the
    /// body so far, including `data`.
    private func keep(_ data: Data, of id: ExchangeID, part: BodyPart, total: Int64) {
        let room = store.limits.bodySize - (Int(total) - data.count)
        guard room > 0 else { return }
        chunks.append(BodyChunk(exchange: id, part: part, data: data.prefix(room)))
    }

    private func scheduleSave(after delay: Duration = .milliseconds(100)) {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        let previous = lastStoreJob
        let generation = self.generation
        lastStoreJob = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await previous?.value
            await self?.save(scheduledIn: generation)
        }
    }

    /// Saves what changed since the last save, then tells the interface.
    private func save(scheduledIn generation: Int) async {
        isSaveScheduled = false
        guard generation == self.generation else {
            // The session was cleared after this save was planned. What's new since then is
            // saved after the store is cleared.
            if !changed.isEmpty || !chunks.isEmpty || !messages.isEmpty {
                scheduleSave()
            }
            return
        }
        let exchanges = changed.sorted().compactMap { assembler.exchanges[$0] }
        let chunks = self.chunks
        let messages = self.messages
        changed.removeAll()
        self.chunks.removeAll()
        self.messages.removeAll()
        guard !exchanges.isEmpty || !chunks.isEmpty || !messages.isEmpty else { return }
        do {
            let removed = try await store.write(exchanges, chunks: chunks, messages: messages)
            guard generation == self.generation else { return }
            published(exchanges, removed: removed)
        } catch {
            guard generation == self.generation else { return }
            // Try again soon, with these changes first. If the store stays broken, body bytes
            // stop piling up in memory.
            changed.formUnion(exchanges.map(\.id))
            self.chunks = chunks + self.chunks
            if self.chunks.reduce(0, { $0 + $1.data.count }) > store.limits.bodySize {
                self.chunks.removeAll()
            }
            self.messages = messages + self.messages
            if self.messages.count > 10_000 {
                self.messages.removeAll()
            }
            hasStorageProblem = true
            continuation.yield(.storageProblem("Reqly can't save new traffic. \(error.localizedDescription)"))
            scheduleSave(after: .seconds(1))
        }
    }

    private func published(_ exchanges: [Exchange], removed: [ExchangeID]) {
        let removedSet = Set(removed)
        // An annotation made while this save was on its way is newer than the save's copy.
        let summaries = exchanges.filter { !removedSet.contains($0.id) }.map { exchange in
            var exchange = exchange
            exchange.annotation = assembler.exchanges[exchange.id]?.annotation ?? exchange.annotation
            return exchange.summary
        }
        assembler.remove(removed)
        changed.subtract(removedSet)
        chunks.removeAll { removedSet.contains($0.exchange) }
        messages.removeAll { removedSet.contains($0.exchange) }
        assembler.removeFinished(before: latestEventTime - Self.finishedGracePeriod, keeping: changed)
        if hasStorageProblem {
            hasStorageProblem = false
            continuation.yield(.storageProblem(nil))
        }
        if !summaries.isEmpty || !removed.isEmpty {
            continuation.yield(.updated(summaries, removed: removed))
        }
    }
}
