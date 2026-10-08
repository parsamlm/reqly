import Foundation
import ProxyEngine
import ReqlyModel

/// Builds exchanges from the engine's events, and keeps them while they're in progress.
///
/// Bodies don't stay here. Capture hands their bytes to TrafficStore as they arrive, so the
/// assembler only counts them.
public struct ExchangeAssembler: Sendable {
    public private(set) var exchanges: [ExchangeID: Exchange] = [:]
    private var openConnections: Set<ConnectionID> = []
    /// What opened each open connection, and on which device, once Capture has found out.
    private var origins: [ConnectionID: Origin] = [:]

    public init() {}

    /// Applies one event and returns the exchange it changed, if any.
    @discardableResult
    public mutating func apply(_ event: ProxyEvent) -> ExchangeID? {
        switch event {
        case .connectionOpened(let connection, _, _):
            openConnections.insert(connection)
            return nil

        case .connectionClosed(let connection, _):
            openConnections.remove(connection)
            origins[connection] = nil
            return nil

        case .requestHead(let id, let connection, let head, let time):
            let kind: ExchangeKind = head.method == "CONNECT" ? .tunnel : .http
            var exchange = Exchange(id: id, connectionID: connection, kind: kind, request: head, started: time)
            exchange.source = Self.source(of: head, origin: origins[connection])
            exchange.device = origins[connection]?.device
            exchanges[id] = exchange
            return id

        case .requestBody(let id, let data):
            return update(id) { $0.bytesSent += Int64(data.count) }

        case .requestEnd(let id, let time):
            return update(id) { exchange in
                exchange.timing.requestEnded = time
                if exchange.state == .sending {
                    exchange.state = .waiting
                }
            }

        case .serverConnecting(let id, let time):
            return update(id) { $0.timing.connectStarted = time }

        case .serverResolved(let id, let time):
            return update(id) { $0.timing.resolved = time }

        case .serverConnected(let id, let address, let time):
            return update(id) { exchange in
                exchange.timing.connected = time
                exchange.remoteAddress = address
            }

        case .serverSecured(let id, let tlsVersion, let time):
            return update(id) { exchange in
                exchange.timing.secured = time
                exchange.tlsVersion = tlsVersion
            }

        case .serverReused(let id, let address, let tlsVersion):
            return update(id) { exchange in
                exchange.reusedConnection = true
                exchange.remoteAddress = address
                exchange.tlsVersion = tlsVersion
            }

        case .requestSent(let id, let time):
            return update(id) { $0.timing.requestSent = time }

        case .responseHead(let id, let head, let time):
            return update(id) { exchange in
                exchange.response = head
                exchange.timing.responseStarted = time
                exchange.state = .receiving
            }

        case .responseBody(let id, let data):
            return update(id) { $0.bytesReceived += Int64(data.count) }

        case .responseTrailers(let id, let trailers):
            return update(id) { $0.responseTrailers = trailers }

        case .responseEnd(let id, let time):
            return update(id) { exchange in
                exchange.timing.ended = time
                exchange.state = .completed
            }

        case .serverProtocol(let id, let name):
            return update(id) { $0.serverProtocol = name }

        case .upstreamProxy(let id, let address):
            return update(id) { $0.upstreamProxy = address }

        case .reverseProxy(let id, let address):
            return update(id) { $0.reverseProxy = address }

        case .clientCertificate(let id, let name):
            return update(id) { $0.clientCertificate = name }

        case .sentByReqly(let id):
            return update(id) { $0.sentByReqly = true }

        case .scriptOutput(let id, let output):
            return update(id) { $0.scriptOutput.append(output) }

        case .webSocketMessage(let id, let message):
            // A WebSocket's sizes are what its messages carried, since its response has no body.
            return update(id) { exchange in
                exchange.messageCount += 1
                if message.direction == .sent {
                    exchange.bytesSent += Int64(message.size)
                } else {
                    exchange.bytesReceived += Int64(message.size)
                }
            }

        case .ruleApplied(let id, let rule):
            return update(id) { $0.appliedRules.append(rule) }

        case .paused(let id, let message, _):
            return update(id) { $0.state = .paused(message.part) }

        case .resumed(let id, let part):
            return update(id) { $0.state = part == .request ? .waiting : .receiving }

        case .tunnelOpened(let id, _):
            return update(id) { $0.state = .open }

        case .tunnelClosed(let id, let sent, let received, let time):
            return update(id) { exchange in
                if exchange.kind == .tunnel {
                    exchange.bytesSent = sent
                    exchange.bytesReceived = received
                }
                exchange.timing.ended = time
                if !exchange.state.isFinished {
                    exchange.state = .completed
                }
            }

        case .failed(let id, let failure, let time):
            return update(id) { exchange in
                exchange.timing.ended = time
                exchange.state = .failed(failure)
            }
        }
    }

    /// Credits a connection's exchanges to the app and device it came from, both the exchanges
    /// so far and the ones to come.
    ///
    /// - Returns: The exchanges that changed.
    public mutating func setOrigin(_ origin: Origin, for connection: ConnectionID) -> [ExchangeID] {
        if openConnections.contains(connection) {
            origins[connection] = origin
        }
        // Changing an exchange while looping over them would copy them all, so change them after.
        var changed: [(id: ExchangeID, source: Source?)] = []
        for (id, exchange) in exchanges where exchange.connectionID == connection {
            let source = Self.source(of: exchange.request, origin: origin)
            guard exchange.source != source || exchange.device != origin.device else { continue }
            changed.append((id, source))
        }
        for (id, source) in changed {
            exchanges[id]?.source = source
            exchanges[id]?.device = origin.device
        }
        return changed.map(\.id).sorted()
    }

    /// The app that sent a request: the one at the connection's other end, found on this Mac,
    /// or for a phone or an emulator, the one its User-Agent names. A simulator's apps run on
    /// this Mac, so they're found like the Mac's.
    private static func source(of request: RequestHead, origin: Origin?) -> Source? {
        if let source = origin?.source {
            return source
        }
        guard let device = origin?.device, device.kind != .simulator else { return nil }
        return UserAgent.app(from: request.headers["User-Agent"])
    }

    /// Renames a device in the exchanges it sent, and in the ones still to come.
    ///
    /// - Returns: The exchanges that changed.
    public mutating func renameDevice(_ id: String, to name: String) -> [ExchangeID] {
        for (connection, origin) in origins where origin.device?.id == id {
            origins[connection]?.device?.name = name
        }
        let changed = exchanges.compactMap { exchangeID, exchange in
            exchange.device?.id == id && exchange.device?.name != name ? exchangeID : nil
        }
        for exchangeID in changed {
            exchanges[exchangeID]?.device?.name = name
        }
        return changed.sorted()
    }

    /// Lets go of the exchanges that finished before `date`, except the ones in `keeping`.
    ///
    /// Finished exchanges stay a moment longer, because one can start again: after a switch to
    /// another protocol, such as WebSocket, a finished exchange opens again as a tunnel.
    public mutating func removeFinished(before date: Date, keeping: Set<ExchangeID> = []) {
        exchanges = exchanges.filter { id, exchange in
            guard exchange.state.isFinished, let ended = exchange.timing.ended else { return true }
            return ended >= date || keeping.contains(id)
        }
    }

    /// Keeps an exchange's annotation, so the summaries saved from now on carry it.
    public mutating func annotate(_ id: ExchangeID, with annotation: Annotation) {
        exchanges[id]?.annotation = annotation
    }

    public mutating func remove(_ ids: some Sequence<ExchangeID>) {
        for id in ids {
            exchanges[id] = nil
        }
    }

    /// Lets go of every exchange except the pinned ones. Open connections stay, so their next
    /// exchanges still get their source.
    public mutating func removeUnpinned() {
        exchanges = exchanges.filter { $0.value.annotation.isPinned }
    }

    private mutating func update(_ id: ExchangeID, _ change: (inout Exchange) -> Void) -> ExchangeID? {
        guard exchanges[id] != nil else { return nil }
        change(&exchanges[id]!)
        return id
    }
}
