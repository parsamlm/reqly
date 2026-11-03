import CoreInterface
import Foundation
import ReqlyModel

/// The sidebar's rows, as the Mac's sidebar has them, from the session's latest sidebar event and
/// the counts since: All Traffic; Pinned, while something is pinned or while it's chosen; this
/// computer's apps, while all its traffic comes from this computer, or else each device, with its
/// apps and the hosts of its other traffic under it; then the hosts, with a line that says they
/// show up, while there are none. Each section starts with a row of its title, which folds it away
/// and back. The rows keep the session's order.
struct SidebarRows: Equatable {
    /// A part of the sidebar, under its title. The first, with All Traffic and Pinned, has none.
    enum Section: CaseIterable {
        case scopes, apps, devices, hosts

        var title: String? {
            switch self {
            case .scopes: nil
            case .apps: "Apps"
            case .devices: "Devices"
            case .hosts: "Hosts"
            }
        }
    }

    struct Row: Equatable {
        enum Kind: Equatable {
            case all, pinned, app, host
            /// This computer, with `nil`, or a device of a kind.
            case device(Device.Kind?)
            /// A section's title, which folds it away and back.
            case title
            /// The line that says hosts show up as apps talk to them.
            case hint
        }

        /// The session's key for the row's scope, or one of ``SidebarRows``' own for a title or
        /// the hint, which never names a scope.
        var key: String
        var kind: Kind
        var section: Section
        /// What the row says.
        var name: String
        /// What the list's header bar says while the row is chosen, such as "Weatherly on Pixel 9".
        var heading: String
        var count = 0
        /// Whether it's a device's, under the device's row.
        var isIndented = false
        /// Whether it's a title whose section is folded away.
        var isFolded = false
        /// The app, for its icon.
        var source: Source?

        /// Whether choosing the row narrows the list to it: every row but the titles and the hint.
        var isScope: Bool { kind != .title && kind != .hint }

        /// The count beside the name: nothing for none, as the Mac's badges have it.
        func badge(locale: Locale = .current) -> String {
            count == 0 ? "" : count.formatted(.number.locale(locale))
        }

        /// What screen readers say of the row: its name and count, such as "Weatherly, 12 requests".
        func spoken(locale: Locale = .current) -> String {
            isScope ? "\(heading), \(ListTitle.requests(count, locale: locale))" : name
        }
    }

    /// The rows of each section, in the sidebar's order, as ``Section/allCases`` has them. A
    /// section that doesn't show has none, and one folded away has only its title.
    private(set) var sections: [[Row]]
    /// Where each row is, by key: its section's place and its own in the section.
    private var places: [String: (section: Int, row: Int)] = [:]

    /// The line under Hosts while there are none.
    static let hint = "Hosts show up here as apps talk to them."
    /// What the sidebar calls this computer, among the devices.
    static let thisComputer = "This Computer"

    /// The rows for `sidebar`, with the counts in `counts` by key, which are newer than its own,
    /// and "all" and "pinned" among them; while `chosen` is the key of the row chosen, and the
    /// sections in `folded` are folded away.
    init(_ sidebar: CoreInterface.Sidebar, counts: [String: Int], chosen: String, folded: Set<Section>) {
        func count(_ key: String, _ given: Int) -> Int { counts[key] ?? given }
        func app(_ row: CoreInterface.Sidebar.Row, on device: String?, section: Section) -> Row {
            Row(
                key: row.key, kind: .app, section: section, name: row.name,
                heading: device.map { "\(row.name) on \($0)" } ?? row.name, count: count(row.key, row.count),
                isIndented: device != nil,
                source: sidebar.sources.first { $0.name == row.name && $0.path == row.path })
        }

        var scopes = [
            Row(
                key: "all", kind: .all, section: .scopes, name: "All Traffic", heading: "All Traffic",
                count: count("all", sidebar.total))
        ]
        let pinned = count("pinned", sidebar.pinned)
        if pinned > 0 || chosen == "pinned" {
            scopes.append(
                Row(key: "pinned", kind: .pinned, section: .scopes, name: "Pinned", heading: "Pinned", count: pinned))
        }

        var apps: [Row] = []
        var devices: [Row] = []
        if sidebar.devices.isEmpty {
            // All of it came from this computer.
            apps = sidebar.apps.map { app($0, on: nil, section: .apps) }
        } else {
            // A phone, a simulator or an emulator sent some: this computer and each device show
            // with their own apps, then the hosts of traffic no app is known for.
            for device in sidebar.devices {
                let name = device.name ?? Self.thisComputer
                devices.append(
                    Row(
                        key: device.key, kind: .device(device.kind), section: .devices, name: name, heading: name,
                        count: count(device.key, device.count)))
                devices += device.apps.map { app($0, on: name, section: .devices) }
                devices += device.otherHosts.map { host in
                    Row(
                        key: host.key, kind: .host, section: .devices, name: host.name,
                        heading: "\(host.name) on \(name)", count: count(host.key, host.count), isIndented: true)
                }
            }
        }

        var hosts = sidebar.hosts.map { host in
            Row(
                key: host.key, kind: .host, section: .hosts, name: host.name, heading: host.name,
                count: count(host.key, host.count))
        }
        if hosts.isEmpty {
            hosts = [Row(key: Self.hintKey, kind: .hint, section: .hosts, name: Self.hint, heading: Self.hint)]
        }

        func titled(_ section: Section, _ rows: [Row]) -> [Row] {
            guard !rows.isEmpty, let title = section.title else { return rows }
            var row = Row(key: Self.titleKey(section), kind: .title, section: section, name: title, heading: title)
            row.isFolded = folded.contains(section)
            return row.isFolded ? [row] : [row] + rows
        }
        sections = [scopes, titled(.apps, apps), titled(.devices, devices), titled(.hosts, hosts)]
        for (section, rows) in sections.enumerated() {
            for (index, row) in rows.enumerated() {
                places[row.key] = (section, index)
            }
        }
    }

    static func == (first: SidebarRows, second: SidebarRows) -> Bool {
        first.sections == second.sections
    }

    /// No rows yet, before the session's first sidebar event.
    static let empty = SidebarRows(
        CoreInterface.Sidebar(total: 0, pinned: 0, apps: [], hosts: [], devices: [], methods: [], sources: []),
        counts: [:], chosen: "all", folded: [])

    /// Every row, in order.
    var all: [Row] { sections.flatMap { $0 } }

    /// The row with `key`, while it shows.
    func row(_ key: String) -> Row? {
        places[key].map { sections[$0.section][$0.row] }
    }

    /// Where the row with `key` is, counted from the first, while it shows.
    func position(of key: String) -> Int? {
        places[key].map { place in sections[..<place.section].reduce(place.row) { $0 + $1.count } }
    }

    /// The key of a section's title. The session's keys never start with the unit separator.
    static func titleKey(_ section: Section) -> String {
        "\u{1F}title\u{1F}\(section.title ?? "")"
    }

    static let hintKey = "\u{1F}hint"

    /// Each row's count, by key, as a sidebar event gives them, with "all" and "pinned".
    static func counts(of sidebar: CoreInterface.Sidebar) -> [String: Int] {
        var counts = ["all": sidebar.total, "pinned": sidebar.pinned]
        for row in sidebar.apps + sidebar.hosts {
            counts[row.key] = row.count
        }
        for device in sidebar.devices {
            counts[device.key] = device.count
            for row in device.apps + device.otherHosts {
                counts[row.key] = row.count
            }
        }
        return counts
    }
}
