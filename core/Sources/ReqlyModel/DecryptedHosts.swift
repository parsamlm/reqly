import Foundation

/// The hosts Reqly decrypts: the ones on the list that are switched on, and, with
/// `includesEveryHost`, every host the list doesn't switch off.
///
/// When more than one entry matches a host, the most specific one decides: an exact host before
/// a wildcard, and `*.api.weatherly.dev` before `*.weatherly.dev`. So `api.weatherly.dev`
/// switched off stays encrypted while `*.weatherly.dev` is on.
public struct DecryptedHosts: Hashable, Sendable, Codable {
    public struct Entry: Hashable, Sendable, Codable {
        public var pattern: HostPattern
        public var isOn: Bool

        public init(_ pattern: HostPattern, isOn: Bool = true) {
            self.pattern = pattern
            self.isOn = isOn
        }
    }

    public var entries: [Entry]
    /// Decrypts every host that no entry switches off. Some apps stop working when their
    /// traffic is decrypted, so it's off unless you turn it on.
    public var includesEveryHost: Bool

    public init(entries: [Entry] = [], includesEveryHost: Bool = false) {
        self.entries = entries
        self.includesEveryHost = includesEveryHost
    }

    /// These hosts, all switched on.
    public init(_ patterns: [HostPattern]) {
        self.init(entries: patterns.map { Entry($0) })
    }

    public func decrypts(_ host: String) -> Bool {
        entry(for: host)?.isOn ?? includesEveryHost
    }

    /// The entry that decides for a host: the most specific one that matches it.
    public func entry(for host: String) -> Entry? {
        entries.filter { $0.pattern.matches(host) }.max { $0.pattern.specificity < $1.pattern.specificity }
    }

    /// The entries switched on.
    public var onCount: Int {
        entries.count { $0.isOn }
    }
}

extension HostPattern {
    /// Whether it stands for every subdomain of a domain, such as `*.weatherly.dev`.
    public var isWildcard: Bool { rawValue.hasPrefix("*.") }

    /// An exact host is more specific than any wildcard, and a longer wildcard than a shorter one.
    var specificity: Int { isWildcard ? rawValue.count : .max }
}
