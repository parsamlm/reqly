import CoreInterface
import Foundation
import Presentation
import ReqlyModel

/// What only the details write, in the Mac's formats: when a request started, to the
/// millisecond; when a cookie expires; how many messages; and a host with its port. Durations,
/// sizes, times of day and counts are the list's, in ``Format``.
enum DetailsFormat {
    /// When a request started, to the millisecond, as Overview has it, such as `Oct 3 at 10:42:07.123 AM`:
    /// in the locale's own clock, 12 or 24 hours, as the list's times are.
    static func moment(_ date: Date, locale: Locale = TimeLocale.current, timeZone: TimeZone = .current) -> String {
        formatter("MMMdjmmssSSS", locale: locale, timeZone: timeZone).string(from: date)
    }

    /// When a cookie expires, such as `Oct 21, 2026 at 7:28 AM`, in the locale's own clock.
    static func day(_ date: Date, locale: Locale = TimeLocale.current, timeZone: TimeZone = .current) -> String {
        formatter("MMMdyyyyjmm", locale: locale, timeZone: timeZone).string(from: date)
    }

    /// "1 message", or "1,204 messages".
    static func messages(_ count: Int, locale: Locale = .current) -> String {
        count == 1 ? "1 message" : "\(count.formatted(.number.locale(locale))) messages"
    }

    /// The host, with the port when it isn't the scheme's own, such as `localhost:8080`.
    static func host(scheme: String, host: String, port: Int) -> String {
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return isDefaultPort ? host : "\(host):\(port)"
    }

    /// A formatter of `template`'s fields, in the order and words `locale` puts them, in the
    /// Gregorian calendar, as the list's times and dates are.
    private static func formatter(_ template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = TimeLocale.gregorian(locale)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

/// What the details' heading says of a request, as the Mac's does: its method and its path, or
/// the host for an encrypted connection; where it went, what sent it and from which device; and a
/// line with its status, such as "200 OK · 161 ms · 292 B · 11:05:59".
struct DetailsHeading: Equatable {
    /// What stands before the status: a dot in its class's color, a warning, a pause, or a lock.
    enum Mark: Equatable {
        case dot(StatusClass?)
        case failed
        case paused
        case lock
        case none
    }

    var method: String
    var title: String
    /// "api.weatherly.dev · Weatherly · iPhone 17 Pro".
    var subtitle: String
    var mark: Mark
    /// The status code, which the line shows in bold, such as "200".
    var code: String?
    /// The status in words, after the code: "OK", "Failed", "Paused", "Open" or "In progress".
    var status: String
    /// gRPC's status, the messages, the duration, the size received and when it started.
    var facts: [String]

    /// `reason` is the response's own, such as "OK", and `grpc` the call's status, from the
    /// exchange, which the row doesn't have. Numbers go by `locale`, and the time by `timeLocale`.
    init(
        _ summary: ExchangeSummary, reason: String?, grpc: GRPCStatus?, locale: Locale = .current,
        timeLocale: Locale = TimeLocale.current, timeZone: TimeZone = .current
    ) {
        let isTunnel = summary.kind == .tunnel
        let host = DetailsFormat.host(scheme: summary.scheme, host: summary.host, port: summary.port)
        method = isTunnel ? "CONNECT" : summary.method
        title = isTunnel ? host : summary.path
        subtitle = [isTunnel ? "Encrypted connection" : host, summary.source?.name, summary.device?.name]
            .compactMap { $0 }.joined(separator: " · ")
        code = nil
        switch summary.state {
        case .failed:
            mark = .failed
            status = "Failed"
        case .paused:
            mark = .paused
            status = "Paused"
        default:
            if let code = summary.status {
                mark = .dot(summary.statusClass)
                self.code = String(code)
                status = reason ?? ""
            } else if isTunnel {
                mark = .lock
                status = summary.state == .open ? "Open" : "Closed"
            } else {
                mark = .none
                status = "In progress"
            }
        }
        var facts: [String] = []
        if let grpc {
            facts.append("gRPC \(grpc.name)")
        }
        if summary.isWebSocket {
            facts.append(DetailsFormat.messages(summary.messageCount, locale: locale))
        }
        if let duration = summary.duration {
            facts.append(Format.duration(duration, locale: locale))
        }
        facts.append(Format.size(summary.bytesReceived))
        facts.append(Format.time(summary.started, locale: timeLocale, timeZone: timeZone))
        self.facts = facts
    }

    /// The status line, in words: "200 OK · 161 ms · 292 B · 11:05:59".
    var line: String {
        let first = [code, status.isEmpty ? nil : status].compactMap { $0 }.joined(separator: " ")
        return ([first] + facts).joined(separator: " · ")
    }

    /// The line after the code, which shows in bold before it: "OK · 161 ms · 292 B · 11:05:59".
    var afterCode: String {
        let rest = (status.isEmpty ? [] : [status]) + facts
        return (code != nil && status.isEmpty ? "· " : "") + rest.joined(separator: " · ")
    }
}

extension ExchangeSummary {
    /// Whether the details showing `shown` need reading again for this, the row's latest summary:
    /// when anything but its pin, color or comment changed, as on the Mac, since those come from
    /// the list's copy.
    func differsInDetails(from shown: ExchangeSummary?) -> Bool {
        guard var shown else { return true }
        shown.annotation = annotation
        return shown != self
    }
}
