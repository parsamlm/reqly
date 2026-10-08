import ReqlyModel
import SwiftUI

/// Where an exchange's time went: a waterfall of its steps, then the connection it used.
struct TimingTab: View {
    let exchange: Exchange

    var body: some View {
        if case .failed(let failure) = exchange.state {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        let phases = exchange.timingPhases
        // A request that never left Reqly has no steps to show; the failure above says why.
        if !phases.isEmpty || !exchange.state.isFinished {
            Waterfall(exchange: exchange, phases: phases)
        }
        DetailSection("Connection") {
            if exchange.kind == .tunnel {
                DetailRow("HTTPS", exchange.tunnelEncryption)
            } else {
                DetailRow("Protocol", exchange.request.version)
                if let serverProtocol = exchange.serverProtocol {
                    DetailRow("To the server", serverProtocol)
                }
            }
            if let address = exchange.remoteAddress {
                DetailRow("Remote address", address, monospaced: true)
            }
            if let tlsVersion = exchange.tlsVersion {
                DetailRow("TLS", tlsVersion)
            }
            if exchange.kind == .http, exchange.reusedConnection || exchange.timing.connectStarted != nil {
                DetailRow("Reused connection", exchange.reusedConnection ? "Yes" : "No")
            }
        }
    }
}

/// The steps as bars on one timeline, with the total below them.
private struct Waterfall: View {
    let exchange: Exchange
    let phases: [TimingPhase]

    var body: some View {
        let start = exchange.timing.started
        let end = ([exchange.timing.ended].compactMap(\.self) + phases.map(\.end)).max() ?? start
        let span = max(end.timeIntervalSince(start), 0.000_001)
        let isFailed = if case .failed = exchange.state { true } else { false }
        VStack(spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                WaterfallRow(phase.step.title, Format.duration(phase.duration, showingTenths: true)) {
                    TimingBar(
                        offset: phase.start.timeIntervalSince(start) / span,
                        length: phase.duration / span,
                        color: isFailed && index == phases.count - 1 ? .red : Self.color(for: phase.step)
                    )
                }
            }
            WaterfallRow("Total", total, isTotal: true) { Color.clear }
        }
    }

    private var total: String {
        if exchange.state == .open {
            return "Still open"
        }
        guard exchange.state.isFinished, let duration = exchange.timing.duration else { return "In progress" }
        return Format.duration(duration, showingTenths: true)
    }

    /// The server's own time stands out; the transfer after it is a lighter shade of the same.
    private static func color(for step: TimingPhase.Step) -> Color {
        switch step {
        case .waiting: .accentColor
        case .downloading, .open: .accentColor.opacity(0.5)
        case .queued, .dnsLookup, .connecting, .tlsHandshake, .requestSent: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

private struct WaterfallRow<Bar: View>: View {
    let title: String
    let value: String
    var isTotal = false
    @ViewBuilder let bar: Bar

    init(_ title: String, _ value: String, isTotal: Bool = false, @ViewBuilder bar: () -> Bar) {
        self.title = title
        self.value = value
        self.isTotal = isTotal
        self.bar = bar()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(isTotal ? .primary : .secondary)
                .frame(width: 130, alignment: .leading)
            bar
                .frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
                .accessibilityHidden(true)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 64, alignment: .trailing)
        }
        .font(isTotal ? .callout.weight(.semibold) : .callout)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }
}

/// A step's bar, placed on the timeline by when it started and how long it took.
private struct TimingBar: View {
    /// Where the bar starts, as a fraction of the timeline.
    let offset: Double
    /// How long the bar is, as a fraction of the timeline.
    let length: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = max(3, geometry.size.width * length)
            let x = min(geometry.size.width * offset, geometry.size.width - width)
            Capsule()
                .fill(color)
                .frame(width: width, height: 8)
                .offset(x: max(0, x))
        }
    }
}

extension TimingPhase.Step {
    var title: String {
        switch self {
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
}
