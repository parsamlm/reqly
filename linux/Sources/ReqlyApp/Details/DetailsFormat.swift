import CoreInterface
import Foundation
import Presentation
import ReqlyModel

/// Numbers, sizes, durations and times as the details write them, in the Mac's formats: `340 ms`,
/// `1.24 s`, `4 min 12 s`; `1.2 KB`; and times on a 24-hour clock, such as `11:05:59`.
enum DetailsFormat {
    /// `340 ms`, `1.24 s`, `4 min 12 s` or `2 h 5 min`, or nothing for no duration. With
    /// `showingTenths`, times under 10 ms keep a tenth of a millisecond, such as `0.4 ms`, for the
    /// Timing page's short steps.
    static func duration(_ seconds: TimeInterval?, showingTenths: Bool = false, locale: Locale = .current) -> String {
        guard let seconds else { return "" }
        if showingTenths, seconds < 0.00995 {
            return "\((seconds * 1000).formatted(.number.precision(.fractionLength(1)).locale(locale))) ms"
        }
        if seconds < 0.9995 {
            return "\(Int((seconds * 1000).rounded()).formatted(.number.locale(locale))) ms"
        }
        if seconds < 59.995 {
            return "\(seconds.formatted(.number.precision(.fractionLength(2)).locale(locale))) s"
        }
        let whole = Int(seconds.rounded())
        if whole < 3600 {
            return "\(whole / 60) min \(whole % 60) s"
        }
        return "\(whole / 3600) h \(whole % 3600 / 60) min"
    }

    /// The core's sizes: `713 B`, `4.1 KB`, `1.2 MB`.
    static func size(_ bytes: Int64) -> String {
        ByteCount.text(bytes)
    }

    /// When a request started, as the list has it: `11:05:59`.
    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter("HH:mm:ss", template: false, locale: Locale(identifier: "en_US_POSIX"), timeZone: timeZone)
            .string(from: date)
    }

    /// When a request started, to the millisecond, as Overview has it, such as `Oct 3 at 10:42:07.123`.
    static func moment(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        formatter("MMMdHHmmssSSS", template: true, locale: locale, timeZone: timeZone).string(from: date)
    }

    /// When a cookie expires, such as `Oct 21, 2026 at 07:28`.
    static func day(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        formatter("MMMdyyyyHHmm", template: true, locale: locale, timeZone: timeZone).string(from: date)
    }

    /// "1 message", or "1,204 messages".
    static func messages(_ count: Int, locale: Locale = .current) -> String {
        count == 1 ? "1 message" : "\(count.formatted(.number.locale(locale))) messages"
    }

    /// A count, such as a section's, as `locale` writes it: `12` or `1,204`.
    static func count(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.locale(locale))
    }

    /// The host, with the port when it isn't the scheme's own, such as `localhost:8080`.
    static func host(scheme: String, host: String, port: Int) -> String {
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return isDefaultPort ? host : "\(host):\(port)"
    }

    private static func formatter(_ format: String, template: Bool, locale: Locale, timeZone: TimeZone)
        -> DateFormatter
    {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        if template {
            formatter.setLocalizedDateFormatFromTemplate(format)
        } else {
            formatter.dateFormat = format
        }
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
    /// exchange, which the row doesn't have.
    init(
        _ summary: ExchangeSummary, reason: String?, grpc: GRPCStatus?, locale: Locale = .current,
        timeZone: TimeZone = .current
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
            facts.append(DetailsFormat.duration(duration, locale: locale))
        }
        facts.append(DetailsFormat.size(summary.bytesReceived))
        facts.append(DetailsFormat.time(summary.started, timeZone: timeZone))
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

/// The colors a request can be marked with, in words, as the Mac's menus say them.
enum DetailsMarks {
    static func title(_ color: MarkColor) -> String {
        switch color {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
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
