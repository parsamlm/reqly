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

    // MARK: - Changing the list

    /// Decrypts a host from now on: switches its entry on, or adds one.
    public mutating func decrypt(_ host: String) {
        guard !decrypts(host), let pattern = HostPattern(rawValue: host) else { return }
        if let index = entries.firstIndex(where: { $0.pattern == pattern }) {
            entries[index].isOn = true
        } else {
            entries.append(Entry(pattern))
        }
    }

    /// Stops decrypting a host: switches its entry off, or adds one switched off, so a wildcard
    /// or `includesEveryHost` leaves it alone. It stays on the list, to switch on again.
    public mutating func stopDecrypting(_ host: String) {
        guard decrypts(host), let pattern = HostPattern(rawValue: host) else { return }
        if let index = entries.firstIndex(where: { $0.pattern == pattern }) {
            entries[index].isOn = false
        } else {
            entries.append(Entry(pattern, isOn: false))
        }
    }

    /// Adds a host to the list, switched on, or says why it can't.
    public mutating func add(_ text: String) -> AddProblem? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let pattern = HostPattern(rawValue: text) else { return .notAHost(text) }
        guard !entries.contains(where: { $0.pattern == pattern }) else { return .onTheList(pattern) }
        entries.append(Entry(pattern))
        return nil
    }

    public mutating func remove(_ patterns: Set<HostPattern>) {
        entries.removeAll { patterns.contains($0.pattern) }
    }

    public mutating func setDecrypts(_ isOn: Bool, _ pattern: HostPattern) {
        guard let index = entries.firstIndex(where: { $0.pattern == pattern }) else { return }
        entries[index].isOn = isOn
    }

    /// Why a host can't join the list.
    public enum AddProblem: Error, Hashable, Sendable {
        case notAHost(String)
        case onTheList(HostPattern)

        public var message: String {
            switch self {
            case .notAHost(let text):
                "“\(text)” isn't a host. Enter a name like api.example.com, or *.example.com for its subdomains."
            case .onTheList(let pattern): "\(pattern) is on the list already."
            }
        }
    }
}

extension HostPattern {
    /// Whether it stands for every subdomain of a domain, such as `*.weatherly.dev`.
    public var isWildcard: Bool { rawValue.hasPrefix("*.") }

    /// An exact host is more specific than any wildcard, and a longer wildcard than a shorter one.
    var specificity: Int { isWildcard ? rawValue.count : .max }
}
