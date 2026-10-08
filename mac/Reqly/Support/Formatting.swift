import AppKit
import ReqlyModel
import SwiftUI

/// Formats numbers the way the design guidelines ask: `1.2 KB`, `340 ms`, `10:42:07`.
enum Format {
    /// Decimal units, as Finder uses: `713 B`, `4.1 KB`, `254 KB`, `1.2 MB`.
    static func size(_ bytes: Int64) -> String {
        guard bytes >= 1000 else { return "\(bytes.formatted()) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value < 100 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(units[unit])"
    }

    /// `340 ms`, `1.24 s`, `4 min 12 s` or `2 h 5 min`. With `showingTenths`, times under
    /// 10 ms keep a tenth of a millisecond, such as `0.4 ms`, for the Timing tab's short steps.
    static func duration(_ seconds: TimeInterval?, showingTenths: Bool = false) -> String {
        guard let seconds else { return "" }
        if showingTenths, seconds < 0.00995 {
            return "\((seconds * 1000).formatted(.number.precision(.fractionLength(1)))) ms"
        }
        if seconds < 0.9995 {
            return "\(Int((seconds * 1000).rounded()).formatted()) ms"
        }
        if seconds < 59.995 {
            return "\(seconds.formatted(.number.precision(.fractionLength(2)))) s"
        }
        let whole = Int(seconds.rounded())
        if whole < 3600 {
            return "\(whole / 60) min \(whole % 60) s"
        }
        return "\(whole / 3600) h \(whole % 3600 / 60) min"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// The date and time for a file's name, as screenshots name theirs: `2026-10-03 at 10.15`.
    static func fileStamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d at %02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0)
    }

    static func requests(_ count: Int) -> String {
        count == 1 ? "1 request" : "\(count.formatted()) requests"
    }

    /// An exact count, such as `12,871 bytes`, for where every byte matters.
    static func bytes(_ count: Int) -> String {
        count == 1 ? "1 byte" : "\(count.formatted()) bytes"
    }
}

extension StatusClass {
    /// The status dot's color. 2xx is always Reqly teal; the other classes use system colors.
    var color: Color {
        switch self {
        case .informational: .gray
        case .success: Color("StatusSuccess")
        case .redirection: .blue
        case .clientError: .orange
        case .serverError: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .informational: .systemGray
        case .success: Self.success
        case .redirection: .systemBlue
        case .clientError: .systemOrange
        case .serverError: .systemRed
        }
    }

    /// Looked up once. It's a dynamic color, so it still follows light and dark mode, and every
    /// new row in the list asks for it.
    private static let success = NSColor(named: "StatusSuccess") ?? .systemTeal
}

extension ExchangeSummary {
    /// The summary without its annotation, so pinning or commenting doesn't load the details again.
    var ignoringAnnotation: ExchangeSummary {
        var summary = self
        summary.annotation = Annotation()
        return summary
    }

    /// The host, with the port when it isn't the scheme's default.
    var displayHost: String {
        let isDefaultPort = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return isDefaultPort ? host : "\(host):\(port)"
    }

    /// What the status column says, in words, for VoiceOver and for rows without a status code.
    var statusDescription: String {
        if case .failed(let failure) = state { return failure.message }
        if case .paused(let part) = state { return "Paused at a breakpoint, before the \(part.rawValue) goes on" }
        if kind == .tunnel { return state == .open ? "Encrypted connection, open" : "Encrypted connection" }
        if let status, let grpcStatus, grpcStatus != 0 {
            let call = GRPCStatus(code: grpcStatus)
            return "\(status), gRPC status \(call.code) \(call.title.lowercased())"
        }
        if let status { return String(status) }
        return "In progress"
    }
}

extension Exchange {
    /// What became of a tunnel's encryption: passed through, or a decryption the app refused.
    var tunnelEncryption: String {
        if case .failed(let failure) = state, failure.isDecryptionFailure {
            return "Reqly tried to decrypt it, but the app's handshake failed"
        }
        return "Encrypted, passed through untouched"
    }
}
