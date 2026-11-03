import CoreInterface
import Foundation
import ReqlyModel

/// Where an exchange's time went, as the Timing page shows it, after the Mac's: each step as a
/// bar on one timeline, with its duration, and the total under them; then the connection it used.
struct Waterfall: Hashable {
    /// How a step's bar is colored: the server's own time in the accent color, the transfer after
    /// it in half the accent, the rest dim, and a failed exchange's last step red.
    enum Look: Hashable {
        case accent
        case halfAccent
        case dim
        case failed
    }

    struct Step: Hashable {
        var title: String
        /// Its duration, with tenths of a millisecond under 10 ms, such as `0.4 ms`.
        var value: String
        /// Where its bar starts on the timeline, and how long it is, each a fraction of the whole.
        var offset: Double
        var length: Double
        var look: Look
    }

    var steps: [Step]
    /// "Total" says this: "Still open", "In progress", or the duration.
    var total: String
    /// Whether there's a waterfall: none for a request that never reached a server, which its
    /// failure explains.
    var isShown: Bool
    /// The connection's rows under it.
    var connection: [DetailsRow]

    init(_ details: ExchangeDetails, locale: Locale = .current) {
        let exchange = details.exchange
        let phases = details.phases
        let start = exchange.timing.started
        let end = ([exchange.timing.ended].compactMap(\.self) + phases.map(\.end)).max() ?? start
        let span = max(end.timeIntervalSince(start), 0.000_001)
        let isFailed = if case .failed = exchange.state { true } else { false }
        steps = phases.enumerated().map { index, phase in
            Step(
                title: Self.title(phase.step),
                value: DetailsFormat.duration(phase.duration, showingTenths: true, locale: locale),
                offset: phase.start.timeIntervalSince(start) / span, length: phase.duration / span,
                look: isFailed && index == phases.count - 1 ? .failed : Self.look(phase.step))
        }
        if exchange.state == .open {
            total = "Still open"
        } else if exchange.state.isFinished, let duration = exchange.timing.duration {
            total = DetailsFormat.duration(duration, showingTenths: true, locale: locale)
        } else {
            total = "In progress"
        }
        isShown = !phases.isEmpty || !exchange.state.isFinished

        var rows: [DetailsRow] = []
        if exchange.kind == .tunnel {
            rows.append(DetailsRow(name: "HTTPS", value: OverviewWords.tunnelEncryption(exchange)))
        } else {
            rows.append(DetailsRow(name: "Protocol", value: exchange.request.version))
            rows.append(DetailsRow(name: "To the server", value: exchange.serverProtocol ?? ""))
        }
        rows.append(DetailsRow(name: "Remote address", value: exchange.remoteAddress ?? "", isCode: true))
        rows.append(DetailsRow(name: "TLS", value: exchange.tlsVersion ?? ""))
        if exchange.kind == .http, exchange.reusedConnection || details.connectStarted != nil {
            rows.append(DetailsRow(name: "Reused connection", value: exchange.reusedConnection ? "Yes" : "No"))
        }
        connection = DetailsSection("Connection", rows: rows).rows
    }

    static func title(_ step: TimingPhase.Step) -> String {
        switch step {
        case .queued: "Queued"
        case .dnsLookup: "DNS lookup"
        case .connecting: "Connecting"
        case .tlsHandshake: "TLS handshake"
        case .requestSent: "Request sent"
        case .waiting: "Waiting for server"
        case .downloading: "Downloading"
        case .open: "Connection open"
        }
    }

    private static func look(_ step: TimingPhase.Step) -> Look {
        switch step {
        case .waiting: .accent
        case .downloading, .open: .halfAccent
        case .queued, .dnsLookup, .connecting, .tlsHandshake, .requestSent: .dim
        }
    }
}
