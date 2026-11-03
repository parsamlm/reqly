import CoreInterface
import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

@Suite struct SidebarRowsTests {
    static let english = Locale(identifier: "en_US")
    static let firefox = Source(name: "Firefox", bundleID: "org.mozilla.firefox", path: "/usr/lib/firefox/firefox")
    static let curl = Source(name: "curl", path: "/usr/bin/curl")

    static func row(_ key: String, _ name: String, _ count: Int, path: String? = nil) -> CoreInterface.Sidebar.Row {
        CoreInterface.Sidebar.Row(key: key, name: name, count: count, path: path)
    }

    /// A session's sidebar: two apps on this computer and three hosts, or with `devices`, those.
    static func sidebar(
        pinned: Int = 0, devices: [CoreInterface.Sidebar.DeviceRow] = [], hosts: [String] = ["h2", "h10", "api.test"]
    ) -> CoreInterface.Sidebar {
        CoreInterface.Sidebar(
            total: 12, pinned: pinned,
            apps: [
                row("app\u{1F}curl", "curl", 3, path: curl.path),
                row("app\u{1F}Firefox", "Firefox", 9, path: firefox.path),
            ],
            hosts: hosts.enumerated().map { row("host\u{1F}\($1)", $1, $0 + 1) }, devices: devices, methods: ["GET"],
            sources: [curl, firefox])
    }

    static func keys(_ rows: SidebarRows) -> [[String]] {
        rows.sections.map { $0.map(\.name) }
    }

    @Test func listsAllTrafficTheAppsAndTheHostsInTheSessionsOrder() {
        let sidebar = Self.sidebar()
        let rows = SidebarRows(sidebar, counts: SidebarRows.counts(of: sidebar), chosen: "all", folded: [])
        #expect(
            Self.keys(rows) == [["All Traffic"], ["Apps", "curl", "Firefox"], [], ["Hosts", "h2", "h10", "api.test"]])
        let all = rows.all
        #expect(all.map(\.kind) == [.all, .title, .app, .app, .title, .host, .host, .host])
        #expect(rows.row("all")?.count == 12)
        #expect(rows.row("app\u{1F}Firefox")?.source == Self.firefox)
        #expect(rows.row("app\u{1F}curl")?.source == Self.curl)
        #expect(rows.row("host\u{1F}h10")?.heading == "h10")
        #expect(rows.position(of: "host\u{1F}h2") == 5)
        #expect(rows.position(of: "pinned") == nil)
        // The titles and the hint aren't scopes.
        #expect(
            all.filter(\.isScope).map(\.key) == [
                "all", "app\u{1F}curl", "app\u{1F}Firefox", "host\u{1F}h2",
                "host\u{1F}h10", "host\u{1F}api.test",
            ])
    }

    @Test func saysHostsShowUpWhileThereAreNone() {
        let empty = SidebarRows.empty
        #expect(Self.keys(empty) == [["All Traffic"], [], [], ["Hosts", SidebarRows.hint]])
        #expect(empty.row(SidebarRows.hintKey)?.kind == .hint)
        #expect(empty.row(SidebarRows.hintKey)?.isScope == false)
        #expect(empty.row("all")?.count == 0)
    }

    @Test func showsPinnedWhileSomethingIsPinnedOrWhileItsChosen() {
        let sidebar = Self.sidebar(pinned: 2)
        let pinned = SidebarRows(sidebar, counts: SidebarRows.counts(of: sidebar), chosen: "all", folded: [])
        #expect(pinned.sections[0].map(\.name) == ["All Traffic", "Pinned"])
        #expect(pinned.row("pinned")?.count == 2)
        // The counts since win: nothing pinned now.
        var counts = SidebarRows.counts(of: sidebar)
        counts["pinned"] = 0
        #expect(
            SidebarRows(sidebar, counts: counts, chosen: "all", folded: []).sections[0].map(\.name) == ["All Traffic"])
        let chosen = SidebarRows(sidebar, counts: counts, chosen: "pinned", folded: [])
        #expect(chosen.sections[0].map(\.name) == ["All Traffic", "Pinned"])
        #expect(chosen.row("pinned")?.count == 0)
    }

    @Test func takesTheNewerCounts() {
        let sidebar = Self.sidebar()
        var counts = SidebarRows.counts(of: sidebar)
        counts["all"] = 40
        counts["host\u{1F}h2"] = 30
        let rows = SidebarRows(sidebar, counts: counts, chosen: "all", folded: [])
        #expect(rows.row("all")?.count == 40)
        #expect(rows.row("host\u{1F}h2")?.count == 30)
        #expect(rows.row("host\u{1F}h10")?.count == 2)
    }

    @Test func foldsASectionAwayLeavingItsTitle() {
        let sidebar = Self.sidebar()
        let counts = SidebarRows.counts(of: sidebar)
        let rows = SidebarRows(sidebar, counts: counts, chosen: "host\u{1F}h2", folded: [.hosts])
        #expect(Self.keys(rows) == [["All Traffic"], ["Apps", "curl", "Firefox"], [], ["Hosts"]])
        #expect(rows.row(SidebarRows.titleKey(.hosts))?.kind == .title)
        #expect(rows.row(SidebarRows.titleKey(.hosts))?.isFolded == true)
        #expect(rows.row(SidebarRows.titleKey(.apps))?.isFolded == false)
        #expect(rows.row("host\u{1F}h2") == nil)
        let both = SidebarRows(sidebar, counts: counts, chosen: "all", folded: [.apps, .hosts])
        #expect(Self.keys(both) == [["All Traffic"], ["Apps"], [], ["Hosts"]])
    }

    @Test func showsEachDeviceWithItsAppsAndHostsUnderIt() {
        let devices = [
            CoreInterface.Sidebar.DeviceRow(
                key: "device\u{1F}", device: .thisMac, count: 10, apps: [Self.row("app\u{1F}a", "Firefox", 8)],
                otherHosts: [Self.row("deviceHost\u{1F}a", "weather.invalid", 2)]),
            CoreInterface.Sidebar.DeviceRow(
                key: "device\u{1F}p", device: .device("p"), name: "Pixel 9", kind: .emulator, count: 2, apps: [],
                otherHosts: [Self.row("deviceHost\u{1F}p", "api.test", 2)]),
        ]
        let sidebar = Self.sidebar(devices: devices)
        let rows = SidebarRows(sidebar, counts: SidebarRows.counts(of: sidebar), chosen: "all", folded: [])
        // No Apps while a device sent traffic: each device has its own.
        #expect(
            Self.keys(rows) == [
                ["All Traffic"], [],
                ["Devices", "This Computer", "Firefox", "weather.invalid", "Pixel 9", "api.test"],
                ["Hosts", "h2", "h10", "api.test"],
            ])
        let section = rows.sections[2]
        #expect(section.map(\.isIndented) == [false, false, true, true, false, true])
        #expect(section[1].kind == .device(nil))
        #expect(section[4].kind == .device(.emulator))
        #expect(section[2].heading == "Firefox on This Computer")
        #expect(section[3].heading == "weather.invalid on This Computer")
        #expect(section[5].heading == "api.test on Pixel 9")
        #expect(section.map(\.section) == Array(repeating: .devices, count: 6))
        #expect(rows.row("device\u{1F}p")?.count == 2)
    }

    @Test func saysEachRowsNameAndCount() {
        let sidebar = Self.sidebar()
        var counts = SidebarRows.counts(of: sidebar)
        counts["host\u{1F}h2"] = 12_871
        counts["host\u{1F}api.test"] = 0
        let rows = SidebarRows(sidebar, counts: counts, chosen: "all", folded: [])
        #expect(rows.row("host\u{1F}h2")?.badge(locale: Self.english) == "12,871")
        // As the Mac's badges, none shows nothing.
        #expect(rows.row("host\u{1F}api.test")?.badge(locale: Self.english) == "")
        #expect(rows.row("host\u{1F}h2")?.spoken(locale: Self.english) == "h2, 12,871 requests")
        #expect(rows.row("app\u{1F}curl")?.spoken(locale: Self.english) == "curl, 3 requests")
        #expect(rows.row("host\u{1F}h10")?.spoken(locale: Self.english) == "h10, 2 requests")
        #expect(rows.row(SidebarRows.titleKey(.apps))?.spoken(locale: Self.english) == "Apps")
        #expect(rows.row("app\u{1F}curl")?.section.title == "Apps")
        #expect(rows.row("all")?.section.title == nil)
    }

    @Test func countsTheWholeSessionInTheStatusLine() {
        #expect(ListTitle.sessionCount(shown: 0, total: 0, locale: Self.english) == "")
        #expect(ListTitle.sessionCount(shown: 1, total: 1, locale: Self.english) == "1 request")
        #expect(ListTitle.sessionCount(shown: 12_871, total: 12_871, locale: Self.english) == "12,871 requests")
        #expect(ListTitle.sessionCount(shown: 0, total: 3, locale: Self.english) == "0 of 3 requests")
        #expect(
            ListTitle.sessionCount(shown: 1_200, total: 100_000, locale: Self.english) == "1,200 of 100,000 requests")
    }
}
