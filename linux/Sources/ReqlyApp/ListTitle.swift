import Foundation

/// What the list's header bar says, as the Mac's window title and subtitle do: what the list
/// shows, as you chose it in the sidebar, and how many of its requests show.
struct ListTitle: Equatable {
    var title: String
    var subtitle: String

    /// `scope` is what the sidebar calls the scope chosen, `shown` how many rows the list shows,
    /// `inScope` how many requests the scope has before search and filters, and `total` how many
    /// the session has. Until there are any, a live session says whether Reqly captures, and a
    /// saved one says it has none.
    init(
        scope: String, shown: Int, inScope: Int, total: Int, isCapturing: Bool, isSaved: Bool,
        locale: Locale = .current
    ) {
        title = scope
        if total == 0 {
            subtitle = isSaved ? "No requests" : isCapturing ? "Waiting for traffic" : "Not capturing"
        } else if shown == inScope {
            subtitle = Self.requests(inScope, locale: locale)
        } else {
            subtitle = "\(shown.formatted(.number.locale(locale))) of \(Self.requests(inScope, locale: locale))"
        }
    }

    /// What the status line says of the whole session, as the Mac's status bar does: "12,871
    /// requests", or "3 of 12,871 requests" while the list shows fewer. Nothing while it has none.
    static func sessionCount(shown: Int, total: Int, locale: Locale = .current) -> String {
        if total == 0 {
            ""
        } else if shown == total {
            requests(total, locale: locale)
        } else {
            "\(shown.formatted(.number.locale(locale))) of \(requests(total, locale: locale))"
        }
    }

    /// "1 request", or "12,871 requests", as `locale` writes the number.
    static func requests(_ count: Int, locale: Locale = .current) -> String {
        count == 1 ? "1 request" : "\(count.formatted(.number.locale(locale))) requests"
    }
}
