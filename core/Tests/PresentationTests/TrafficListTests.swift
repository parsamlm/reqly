import Foundation
import Presentation
import ReqlyModel
import Testing

/// Summaries of made-up exchanges, as the session sends them to the list.
enum Traffic {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let weatherly = Source(name: "Weatherly", bundleID: "dev.weatherly")
    static let safari = Source(name: "Safari", bundleID: "com.apple.Safari")
    static let phone = Device(id: "phone", kind: .network, name: "Phone", address: "192.168.1.20")
    static let tablet = Device(id: "tablet", kind: .network, name: "Tablet", address: "192.168.1.21")

    static func summary(
        _ id: UInt64, host: String = "api.weatherly.dev", target: String = "/v2/forecast", method: String = "GET",
        status: Int? = 200, source: Source? = weatherly, device: Device? = nil, annotation: Annotation = Annotation()
    ) -> ExchangeSummary {
        var exchange = Exchange(
            id: ExchangeID(rawValue: id),
            connectionID: ConnectionID(rawValue: 1),
            kind: .http,
            request: RequestHead(method: method, scheme: "https", host: host, port: 443, target: target),
            started: start + Double(id)
        )
        if let status {
            exchange.response = ResponseHead(status: status, reason: "OK")
            exchange.state = .completed
        }
        exchange.source = source
        exchange.device = device
        exchange.annotation = annotation
        return exchange.summary
    }

    static func ids(_ values: UInt64...) -> [ExchangeID] {
        values.map(ExchangeID.init(rawValue:))
    }
}

@Suite struct TrafficListTests {
    /// Makes a change and checks what it reports: the rows before, changed as it says, are the
    /// rows after. That's what the table does with them.
    @discardableResult
    func change(_ list: inout TrafficList, _ change: (inout TrafficList) -> [TrafficList.RowChange])
        -> [TrafficList.RowChange]
    {
        let before = list.rows
        let changes = change(&list)
        #expect(Self.applying(changes, to: before, giving: list.rows) == list.rows)
        // A table that missed the change catches up the same way.
        #expect(Self.applying(list.changes(from: before), to: before, giving: list.rows) == list.rows)
        return changes
    }

    /// The rows before, changed as the table changes its rows: rows removed at their places
    /// before, then rows put in at their places after.
    static func applying(_ changes: [TrafficList.RowChange], to before: [ExchangeID], giving after: [ExchangeID])
        -> [ExchangeID]
    {
        var rows = before
        for change in changes {
            switch change {
            case .removed(let removed):
                for row in removed.reversed() {
                    rows.remove(at: row)
                }
            case .inserted(let inserted):
                for row in inserted {
                    rows.insert(after[row], at: row)
                }
            case .changed:
                break
            }
        }
        return rows
    }

    @Test func showsNewTrafficAtTheEnd() {
        var list = TrafficList()
        let changes = change(&list) { $0.update([Traffic.summary(1), Traffic.summary(2)]) }
        #expect(list.rows == Traffic.ids(1, 2))
        #expect(changes.count == 1)
        #expect(list.count(of: .all) == 2)
        #expect(list.count(of: .host("api.weatherly.dev")) == 2)
        #expect(list.count(of: .source(Traffic.weatherly, on: .thisMac)) == 2)
        #expect(list.count(of: .device(.thisMac)) == 2)

        // A newer summary of the same exchange changes its row, and no count.
        let changed = change(&list) { $0.update([Traffic.summary(1, status: 404)]) }
        guard case .changed(let ids) = changed.last else {
            Issue.record("expected the row to change, got \(changed)")
            return
        }
        #expect(ids == Traffic.ids(1))
        #expect(list.summary(ExchangeID(rawValue: 1))?.status == 404)
        #expect(list.count(of: .all) == 2)
        #expect(list.takeChangedCounts().contains(.all))
    }

    @Test func keepsEachExchangeOnceAsItsLatestSummary() {
        var list = TrafficList()
        change(&list) {
            $0.update([Traffic.summary(1, status: nil), Traffic.summary(2), Traffic.summary(1, status: 201)])
        }
        #expect(list.rows == Traffic.ids(1, 2))
        #expect(list.summary(ExchangeID(rawValue: 1))?.status == 201)
    }

    @Test func narrowsToTheSidebarsSelection() {
        var list = TrafficList()
        change(&list) {
            $0.update([
                Traffic.summary(1),
                Traffic.summary(2, host: "cdn.weatherly.dev"),
                Traffic.summary(3, source: Traffic.safari),
                Traffic.summary(4, source: nil, device: Traffic.phone),
                Traffic.summary(5, annotation: Annotation(isPinned: true)),
            ])
        }
        change(&list) { $0.setScope(.host("cdn.weatherly.dev")) }
        #expect(list.rows == Traffic.ids(2))
        change(&list) { $0.setScope(.source(Traffic.safari, on: .thisMac)) }
        #expect(list.rows == Traffic.ids(3))
        change(&list) { $0.setScope(.device(.device("phone"))) }
        #expect(list.rows == Traffic.ids(4))
        change(&list) { $0.setScope(.deviceHost("api.weatherly.dev", on: .device("phone"))) }
        #expect(list.rows == Traffic.ids(4))
        change(&list) { $0.setScope(.pinned) }
        #expect(list.rows == Traffic.ids(5))
        #expect(list.pinnedCount == 1)
        change(&list) { $0.setScope(.all) }
        #expect(list.rows == Traffic.ids(1, 2, 3, 4, 5))
        // Choosing what's already chosen changes nothing.
        #expect(list.setScope(.all).isEmpty)
    }

    @Test func filtersAndSearchesTogether() {
        var list = TrafficList()
        change(&list) {
            $0.update([
                Traffic.summary(1, method: "POST", annotation: Annotation(comment: "The slow one")),
                Traffic.summary(2, target: "/v2/cities"),
                Traffic.summary(3, host: "cdn.weatherly.dev", method: "POST"),
            ])
        }
        var filter = TrafficFilter()
        filter.method = "POST"
        change(&list) { $0.setFilter(filter) }
        #expect(list.rows == Traffic.ids(1, 3))

        change(&list) { $0.setFilter(TrafficFilter()) }
        // The host, path, method, app, device and comment are searched in the list itself.
        change(&list) { $0.setQuery("cities") }
        #expect(list.rows == Traffic.ids(2))
        change(&list) { $0.setQuery("slow") }
        #expect(list.rows == Traffic.ids(1))
        change(&list) { $0.setQuery("cdn") }
        #expect(list.rows == Traffic.ids(3))
        // Typing on narrows what was found.
        change(&list) { $0.setQuery("weatherly") }
        #expect(list.rows == Traffic.ids(1, 2, 3))
        change(&list) { $0.setQuery("weatherly.dev/") }
        #expect(list.rows.isEmpty)
        change(&list) { $0.setQuery("") }
        #expect(list.rows == Traffic.ids(1, 2, 3))
    }

    @Test func addsWhatTheStoreFoundInHeadersAndBodies() {
        var list = TrafficList()
        change(&list) { $0.update([Traffic.summary(1), Traffic.summary(2), Traffic.summary(3)]) }
        change(&list) { $0.setQuery("Tehran") }
        #expect(list.rows.isEmpty)
        change(&list) { $0.setStoreMatches(Set(Traffic.ids(1, 3))) }
        #expect(list.rows == Traffic.ids(1, 3))
        change(&list) { $0.setStoreMatches(Set(Traffic.ids(3))) }
        #expect(list.rows == Traffic.ids(3))
        // New search text: what the store found for the old text no longer counts.
        change(&list) { $0.setQuery("Lisbon") }
        #expect(list.rows.isEmpty)
    }

    @Test func dropsExchangesAndTheirCounts() {
        var list = TrafficList()
        change(&list) {
            $0.update([
                Traffic.summary(1, host: "a.dev"), Traffic.summary(2, host: "b.dev"), Traffic.summary(3, host: "a.dev"),
            ])
        }
        #expect(list.hosts == ["a.dev", "b.dev"])
        let version = list.namesVersion
        change(&list) { $0.remove(Traffic.ids(2)) }
        #expect(list.rows == Traffic.ids(1, 3))
        #expect(list.count(of: .host("b.dev")) == 0)
        #expect(list.hosts == ["a.dev"])
        #expect(list.namesVersion > version)
        #expect(list.remove(Traffic.ids(2)).isEmpty)
    }

    @Test func clearingKeepsPinnedExchanges() {
        var list = TrafficList()
        change(&list) {
            $0.update([
                Traffic.summary(1), Traffic.summary(2, annotation: Annotation(isPinned: true)), Traffic.summary(3),
            ])
        }
        change(&list) { $0.removeUnpinned() }
        #expect(list.rows == Traffic.ids(2))
        #expect(list.count(of: .all) == 1)
        #expect(list.pinnedCount == 1)
        #expect(list.count(of: .host("api.weatherly.dev")) == 1)
    }

    @Test func annotatesAndRenamesRightAway() {
        var list = TrafficList()
        change(&list) {
            $0.update([Traffic.summary(1, device: Traffic.phone), Traffic.summary(2, device: Traffic.phone)])
        }
        change(&list) { $0.setAnnotation(Annotation(isPinned: true, color: .red), of: ExchangeID(rawValue: 1)) }
        #expect(list.pinnedCount == 1)
        #expect(list.summary(ExchangeID(rawValue: 1))?.annotation.color == .red)
        // The same annotation again changes nothing.
        #expect(list.setAnnotation(Annotation(isPinned: true, color: .red), of: ExchangeID(rawValue: 1)).isEmpty)
        #expect(list.setAnnotation(Annotation(), of: ExchangeID(rawValue: 9)).isEmpty)

        change(&list) { $0.renameDevice("phone", to: "Work Phone") }
        #expect(list.all.allSatisfy { $0.device?.name == "Work Phone" })
        #expect(list.devices.map { $0.device?.name } == [nil, "Work Phone"])
        #expect(list.renameDevice("nobody", to: "x").isEmpty)
    }

    @Test func listsNamesInTheOrderPeopleExpect() {
        var list = TrafficList()
        change(&list) {
            $0.update([
                Traffic.summary(1, host: "h10.dev", method: "PATCH"),
                Traffic.summary(2, host: "h2.dev", method: "PROPFIND", source: Traffic.safari),
                Traffic.summary(3, host: "b.dev", method: "GET", source: nil, device: Traffic.tablet),
                Traffic.summary(4, method: "DELETE", device: Traffic.phone),
            ])
        }
        // Numbers in names sort by their value, so h2 comes before h10.
        #expect(list.hosts == ["api.weatherly.dev", "b.dev", "h2.dev", "h10.dev"])
        #expect(list.sources == [Traffic.safari, Traffic.weatherly])
        // The common methods come first, in their usual order.
        #expect(list.methods == ["GET", "PATCH", "DELETE", "PROPFIND"])
        // This computer first, then the devices by name.
        #expect(list.devices.map(\.choice) == [.thisMac, .device("phone"), .device("tablet")])
        #expect(list.appsByDevice[.thisMac] == [Traffic.safari, Traffic.weatherly])
        #expect(list.appsByDevice[.device("phone")] == [Traffic.weatherly])
        #expect(list.otherHostsByDevice[.device("tablet")] == ["b.dev"])
    }

    @Test func findsRowsAndKeepsUpOverManyChanges() {
        var list = TrafficList()
        change(&list) { $0.update((1...3000).map { Traffic.summary($0, host: $0 % 3 == 0 ? "a.dev" : "b.dev") }) }
        change(&list) { $0.setScope(.host("a.dev")) }
        #expect(list.rows.count == 1000)
        #expect(list.row(of: ExchangeID(rawValue: 3000)) == 999)
        #expect(list.row(of: ExchangeID(rawValue: 1)) == nil)
        // The oldest go, as at the session's size limit, while new ones come.
        change(&list) { $0.remove((1...2000).map(ExchangeID.init(rawValue:))) }
        change(&list) { $0.update((3001...3600).map { Traffic.summary($0, host: "a.dev") }) }
        // 334 of the exchanges left are on a.dev, and all the new ones.
        #expect(list.rows.count == 334 + 600)
        #expect(list.all.count == 1600)
        #expect(list.all.position(of: ExchangeID(rawValue: 2001)) == 0)
        #expect(list.row(of: ExchangeID(rawValue: 3600)) == list.rows.count - 1)
        // Many rows joining at once, as when the scope widens again.
        change(&list) { $0.setScope(.all) }
        #expect(list.rows.count == 1600)
        #expect(list.rows.first == ExchangeID(rawValue: 2001))
    }
}

@Suite struct ExchangeListTests {
    @Test func keepsPlacesWhenTheOldestGo() {
        var list = TrafficList()
        _ = list.update((1...5000).map { Traffic.summary($0) })
        // Pinned ones stay while the ones around them go, many times over, so the free slots
        // are given back now and then.
        for round in 0..<4 {
            let first = UInt64(round * 1000 + 1)
            _ = list.remove((first...(first + 998)).map(ExchangeID.init(rawValue:)))
        }
        #expect(list.all.count == 1004)
        #expect(list.all.map(\.id.rawValue).prefix(4) == [1000, 2000, 3000, 4000])
        for (position, summary) in list.all.enumerated() {
            #expect(list.all.position(of: summary.id) == position)
        }
        #expect(list.all.summary(ExchangeID(rawValue: 4001))?.id.rawValue == 4001)
        #expect(list.all.summary(ExchangeID(rawValue: 1)) == nil)
    }
}
