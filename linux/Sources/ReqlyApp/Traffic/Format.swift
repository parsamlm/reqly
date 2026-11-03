import Foundation
import Presentation
import ReqlyModel

/// Numbers and times as the Mac writes them, as the design guidelines ask: `340 ms`, `1.24 s`,
/// `11:05:59`, `1.2 KB`, each as your locale writes its digits.
enum Format {
    /// `340 ms`, `1.24 s`, `4 min 12 s` or `2 h 5 min`, or nothing while there's no duration yet.
    /// With `showingTenths`, times under 10 ms keep a tenth of a millisecond, such as `0.4 ms`, for
    /// the timing's short steps.
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

    /// The time of day, to the second, as your locale writes it, such as `11:05:59 AM`.
    static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard, locale: locale, timeZone: timeZone))
    }

    /// Decimal units, as GNOME's Files uses: `713 B`, `4.1 KB`, `254 KB`, `1.2 MB`.
    static func size(_ bytes: Int64) -> String {
        ByteCount.text(bytes)
    }

    /// A count, with its digits grouped as your locale groups them, such as `10,000`.
    static func count(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.locale(locale))
    }
}

extension MarkColor {
    /// What menus and screen readers call the color, as the Mac does, after Finder's tags.
    var title: String {
        switch self {
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

extension StatusClass {
    /// The status dot's style class, which colors it as the design guidelines color the class.
    var styleClass: String {
        switch self {
        case .informational: "status-1xx"
        case .success: "status-2xx"
        case .redirection: "status-3xx"
        case .clientError: "status-4xx"
        case .serverError: "status-5xx"
        }
    }
}
