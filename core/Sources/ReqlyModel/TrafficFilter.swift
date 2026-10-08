import Foundation

/// The request list's filters. An exchange shows when it passes every filter that's set, and a
/// filter that's left empty lets everything through.
public struct TrafficFilter: Hashable, Sendable {
    /// The kinds of status to show. An exchange needs to match just one of them.
    public var statuses: Set<StatusFilter> = []
    public var source: Source?
    /// The Mac's own traffic, or one device's.
    public var device: DeviceChoice?
    public var host: String?
    public var method: String?
    /// The kinds of response body to show. An exchange needs to match just one of them.
    public var contents: Set<ContentGroup> = []

    public init() {}

    public var isActive: Bool {
        !statuses.isEmpty || source != nil || device != nil || host != nil || method != nil || !contents.isEmpty
    }

    public func matches(_ summary: ExchangeSummary) -> Bool {
        if !statuses.isEmpty, !statuses.contains(where: { $0.matches(summary) }) {
            return false
        }
        if let source, summary.source != source {
            return false
        }
        if let device, !device.matches(summary.device) {
            return false
        }
        if let host, summary.host != host {
            return false
        }
        if let method, summary.method != method {
            return false
        }
        if !contents.isEmpty, !contents.contains(summary.contentGroup) {
            return false
        }
        return true
    }
}

/// The kinds of status to filter by, as the chips above the request list name them.
public enum StatusFilter: Hashable, Sendable, CaseIterable {
    case success, redirection, clientError, serverError
    /// Exchanges that failed. The list shows them as failed whatever status they got, so they
    /// match only this.
    case failed

    public func matches(_ summary: ExchangeSummary) -> Bool {
        if case .failed = summary.state {
            return self == .failed
        }
        switch self {
        case .success: return summary.statusClass == .success
        case .redirection: return summary.statusClass == .redirection
        case .clientError: return summary.statusClass == .clientError
        case .serverError: return summary.statusClass == .serverError
        case .failed: return false
        }
    }
}

/// Kinds of response body, told apart by their `Content-Type`.
public enum ContentGroup: Hashable, Sendable, CaseIterable {
    case json, xml, html, javascript, css, image, media
    /// Everything else, including responses with no `Content-Type`.
    case other

    public init(contentType: String?) {
        guard let contentType else {
            self = .other
            return
        }
        let type = contentType.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces).lowercased()
        if type.hasPrefix("image/") {
            self = .image
        } else if type.hasPrefix("audio/") || type.hasPrefix("video/") || Self.mediaTypes.contains(type) {
            self = .media
        } else if type == "text/html" || type == "application/xhtml+xml" {
            self = .html
        } else if Self.jsonTypes.contains(type) || type.hasSuffix("+json") {
            self = .json
        } else if type == "application/xml" || type == "text/xml" || type.hasSuffix("+xml") {
            self = .xml
        } else if Self.javaScriptTypes.contains(type) {
            self = .javascript
        } else if type == "text/css" {
            self = .css
        } else {
            self = .other
        }
    }

    private static let jsonTypes: Set<String> = [
        "application/json", "text/json", "application/x-ndjson", "application/jsonl",
    ]
    private static let javaScriptTypes: Set<String> = [
        "application/javascript", "text/javascript", "application/x-javascript", "application/ecmascript",
        "text/ecmascript",
    ]
    /// Streaming playlists, which name the media segments a player fetches next.
    private static let mediaTypes: Set<String> = [
        "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/dash+xml",
    ]
}
