import Foundation

/// One step of an exchange, for the Timing tab's waterfall.
public struct TimingPhase: Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        /// From reading the request to starting on a connection to the server.
        case queued
        case dnsLookup
        /// Opening the TCP connection.
        case connecting
        case tlsHandshake
        /// Sending the request on to the server, once the connection was ready.
        case requestSent
        /// From the end of the request to the first byte of the response.
        case waiting
        case downloading
        /// A tunnel, or a connection that switched protocols, passing bytes through.
        case open
    }

    public var step: Step
    public var start: Date
    public var end: Date

    public init(_ step: Step, from start: Date, to end: Date) {
        self.step = step
        self.start = start
        self.end = end
    }

    /// Never negative, even when a server answers before the whole request has reached it.
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

extension Exchange {
    /// The steps of the exchange in order, each starting where the one before ended.
    ///
    /// Steps that didn't happen are left out: a reused connection has no DNS lookup, connecting
    /// or TLS handshake, an IP address needs no lookup, and plain HTTP has no handshake. When the
    /// exchange failed, the last step is the one it failed in, up to the moment it failed. An
    /// exchange that never reached a server has no steps.
    public var timingPhases: [TimingPhase] {
        guard timing.connectStarted != nil || reusedConnection else { return [] }
        var steps: [(step: TimingPhase.Step, end: Date?)] = []
        if timing.connectStarted != nil {
            steps.append((.queued, timing.connectStarted))
            if timing.resolved != nil || !Self.isIPAddress(request.host) {
                steps.append((.dnsLookup, timing.resolved))
            }
            steps.append((.connecting, timing.connected))
            if kind == .http, request.scheme == "https" {
                steps.append((.tlsHandshake, timing.secured))
            }
        }
        // A tunnel, or a connection that switched protocols, has no end while it's open.
        let ended = state == .open ? nil : timing.ended
        switch kind {
        case .http:
            steps.append((.requestSent, timing.requestSent))
            steps.append((.waiting, timing.responseStarted))
            steps.append((response?.status == 101 ? .open : .downloading, ended))
        case .tunnel:
            steps.append((.open, ended))
        }

        var phases: [TimingPhase] = []
        var start = timing.started
        for (step, end) in steps {
            if let end {
                phases.append(TimingPhase(step, from: start, to: end))
                start = end
            } else if case .failed = state, let failed = timing.ended {
                phases.append(TimingPhase(step, from: start, to: failed))
                break
            }
        }
        return phases
    }

    /// Whether a host is an IP address rather than a name. Hosts are stored without brackets,
    /// so only IPv6 addresses hold colons.
    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}
