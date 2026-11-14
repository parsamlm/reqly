import Foundation
import ReqlyModel

// What the filter bar and its popover say, as the Mac's do, apart from the window, so the words
// have tests of their own.

extension StatusFilter {
    /// The status button's title.
    var title: String {
        switch self {
        case .success: "2xx"
        case .redirection: "3xx"
        case .clientError: "4xx"
        case .serverError: "5xx"
        case .failed: "Failed"
        }
    }

    /// The name of the status menu's action for it, `filter.status-2xx` and the like.
    var actionName: String { "status-" + title.lowercased() }

    /// The status button's tooltip.
    var tip: String {
        switch self {
        case .success: "Show successful responses (2xx)"
        case .redirection: "Show redirects (3xx)"
        case .clientError: "Show client errors (4xx)"
        case .serverError: "Show server errors (5xx)"
        case .failed: "Show requests that failed"
        }
    }
}

extension ContentGroup {
    /// The content type's check button, and its part of the token.
    var title: String {
        switch self {
        case .json: "JSON"
        case .xml: "XML"
        case .html: "HTML"
        case .javascript: "JavaScript"
        case .css: "CSS"
        case .image: "Images"
        case .media: "Media"
        case .other: "Other"
        }
    }
}

/// The status menu's words: a narrow window's filter bar shows the menu in place of the status
/// buttons, with a short label, and a name for screen readers that says every status chosen.
struct StatusMenuWords: Equatable {
    var label: String
    var name: String

    init(_ statuses: Set<StatusFilter>) {
        let chosen = StatusFilter.allCases.filter(statuses.contains).map(\.title)
        switch chosen.count {
        case 0:
            label = "All Statuses"
            name = "Statuses: all"
        case 1:
            label = chosen[0]
            name = "Statuses: \(chosen[0])"
        default:
            label = "\(chosen.count) Statuses"
            name = "Statuses: " + chosen.dropLast().joined(separator: ", ") + " and " + chosen[chosen.count - 1]
        }
    }
}

/// A filter that's set, as its token in the filter bar says it, with a button to remove it.
struct FilterToken: Equatable {
    /// What the filter is on, as the token names it.
    enum Kind: String {
        case app = "App"
        case host = "Host"
        case method = "Method"
        case contents = "Content Type"
    }

    var kind: Kind
    /// What it's set to, such as "api.example.com", or for the content types, "JSON or Images".
    var title: String

    /// The remove button's name, for screen readers, such as "Remove Host Filter".
    var removal: String { "Remove \(kind.rawValue) Filter" }
    /// What the token's tooltip says, such as "Host: api.example.com", with the popover's words.
    var tip: String { "\(kind == .contents ? "Content type" : kind.rawValue): \(title)" }

    /// A token for each filter that's set, apart from the status buttons', in the popover's order.
    static func tokens(for filter: TrafficFilter) -> [FilterToken] {
        var tokens: [FilterToken] = []
        if let source = filter.source {
            tokens.append(FilterToken(kind: .app, title: source.name))
        }
        if let host = filter.host {
            tokens.append(FilterToken(kind: .host, title: host))
        }
        if let method = filter.method {
            tokens.append(FilterToken(kind: .method, title: method))
        }
        if !filter.contents.isEmpty {
            tokens.append(FilterToken(kind: .contents, title: contents(filter.contents)))
        }
        return tokens
    }

    /// The content types chosen, in the popover's order, such as "JSON, XML or Images".
    static func contents(_ chosen: Set<ContentGroup>) -> String {
        let titles = ContentGroup.allCases.filter(chosen.contains).map(\.title)
        guard let last = titles.last, titles.count > 1 else { return titles.first ?? "" }
        return titles.dropLast().joined(separator: ", ") + " or " + last
    }

    /// Takes the token's filter off `filter`.
    func clear(_ filter: inout TrafficFilter) {
        switch kind {
        case .app: filter.source = nil
        case .host: filter.host = nil
        case .method: filter.method = nil
        case .contents: filter.contents = []
        }
    }
}

/// The one token that stands for every token when they don't fit, such as "3 filters", with a
/// button that removes them all.
struct FoldedTokens: Equatable {
    var tokens: [FilterToken]

    var title: String { tokens.count == 1 ? "1 filter" : "\(tokens.count) filters" }
    /// The remove button's name, for screen readers.
    var removal: String { tokens.count == 1 ? "Remove 1 Filter" : "Remove \(tokens.count) Filters" }
    /// The tooltip: each filter on a line of its own.
    var tip: String { tokens.map(\.tip).joined(separator: "\n") }
    /// What screen readers hear after the remove button's name: the filters, one after another.
    var spoken: String { tokens.map(\.tip).joined(separator: ", ") }
}

/// What the list's pane says while there's traffic, but the sidebar's scope, the search and the
/// filters leave none of it to show, as the Mac's No Matches does: what's left nothing, and
/// Clear Filters while any filter is set.
struct NoMatches: Equatable {
    var title: String
    var description: String
    /// Whether it offers Clear Filters.
    var clearsFilters: Bool

    /// `query` is what the session searches for, without the spaces around it, and
    /// `filtersAreSet` whether any filter is, the status buttons' too.
    init(query: String, filtersAreSet: Bool) {
        title = query.isEmpty ? filtersAreSet ? "No Matching Requests" : "No Requests" : "No Results for “\(query)”"
        description =
            switch (filtersAreSet, query.isEmpty) {
            case (true, false): "No requests match both the search and the filters."
            case (true, true): "No requests match the filters."
            case (false, false): "Check the spelling or try a new search."
            case (false, true): "None of this session's requests are here."
            }
        clearsFilters = filtersAreSet
    }
}
