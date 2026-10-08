import Foundation
import ReqlyModel

/// What the request list shows, kept up to date one change at a time: the session's exchanges,
/// the ones the sidebar, the filters and the search leave, and the counts the sidebar shows.
///
/// New traffic arrives about ten times a second, so each change costs about as much as what
/// changed, not as much as the whole session. Only changing what the list shows, such as a
/// filter, goes through every exchange.
nonisolated struct TrafficList {
    /// What the sidebar has selected.
    enum Scope: Hashable {
        case all
        case pinned
        /// One app's traffic, on this Mac or on one device.
        case source(Source, on: DeviceChoice)
        /// The Mac's own traffic, or one device's.
        case device(DeviceChoice)
        case host(String)
        /// One device's traffic to a host, from apps Reqly couldn't name, such as a phone's
        /// encrypted connections.
        case deviceHost(String, on: DeviceChoice)
    }

    /// How the rows changed, in order: the table makes the same changes. Even when a filter
    /// changes every row, the table is told which went and which came, so it moves the rows it
    /// has and reuses their cells instead of making them all again.
    enum RowChange {
        /// Rows taken out, at their places before.
        case removed(IndexSet)
        /// Rows put in, at their places after.
        case inserted(IndexSet)
        /// Exchanges whose rows stay but show something new.
        case changed([ExchangeID])

        /// Whether rows go or come, rather than only show something new.
        var isRowsChange: Bool {
            if case .changed = self { false } else { true }
        }
    }

    /// Every exchange in the session, oldest first.
    private(set) var all = ExchangeList()
    /// The exchanges the list shows, in the order of `all`.
    private(set) var rows: [ExchangeID] = []

    private(set) var scope = Scope.all
    private(set) var filter = TrafficFilter()
    /// The search text, without the spaces around it.
    private(set) var query = ""
    /// Exchanges whose headers or bodies contain the search text, as the store found them.
    private var storeMatches: Set<ExchangeID> = []
    /// Exchanges whose host, path, method, app, device or comment contain the search text. Each
    /// is checked once, when it arrives or changes, not every time the list changes.
    private var textMatches: Set<ExchangeID> = []

    /// How many exchanges each host, app, device and device's host has, by the sidebar row that
    /// shows them. Rows with none are left out.
    private var counts: [Scope: Int] = [:]
    /// The apps that sent traffic, on this Mac or any device.
    private var sourceCounts: [Source: Int] = [:]
    private var methodCounts: [String: Int] = [:]
    private(set) var pinnedCount = 0
    /// Each device's oldest exchange. Its copy of the device, as named then, is the one shown.
    private var oldestByDevice: [String: ExchangeID] = [:]
    /// The counts that changed since ``takeChangedCounts()``.
    private var changedCounts: Set<Scope> = []

    /// The hosts that traffic went to, in the order people expect: h2 before h10.
    private(set) var hosts: [String] = []
    /// The apps and tools that sent traffic, by name.
    private(set) var sources: [Source] = []
    /// This Mac, then the devices that sent traffic, by name. Empty while all of it comes from
    /// this Mac.
    private(set) var devices: [DeviceEntry] = []
    /// The methods the session's requests used, the common ones first.
    private(set) var methods: [String] = []
    /// The apps on this Mac and on each device, by name.
    private(set) var appsByDevice: [DeviceChoice: [Source]] = [:]
    /// For each device, the hosts its traffic from no known app went to.
    private(set) var otherHostsByDevice: [DeviceChoice: [String]] = [:]
    /// Goes up each time the hosts, apps, devices or methods above change, so a copy of them is
    /// only refreshed when it's out of date.
    private(set) var namesVersion = 0
    private var namesAreStale = false

    // MARK: - Reading

    func summary(_ id: ExchangeID) -> ExchangeSummary? {
        all.summary(id)
    }

    /// How many exchanges a sidebar row covers.
    func count(of scope: Scope) -> Int {
        switch scope {
        case .all: all.count
        case .pinned: pinnedCount
        default: counts[scope] ?? 0
        }
    }

    /// The counts that changed since this was last asked.
    mutating func takeChangedCounts() -> Set<Scope> {
        defer { changedCounts.removeAll(keepingCapacity: true) }
        return changedCounts
    }

    /// The row that shows an exchange. Rows keep the order of `all`, so a binary search by
    /// place there finds it.
    func row(of id: ExchangeID) -> Int? {
        guard let place = all.position(of: id) else { return nil }
        var low = 0
        var high = rows.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let middlePlace = all.position(of: rows[middle])!
            if middlePlace == place { return middle }
            if middlePlace < place { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// How to change rows shown before, perhaps several changes ago, into the current ones.
    /// Rows of exchanges still in the session keep their order, so one pass through both lists
    /// finds the rows that went and the rows that came.
    func changes(from old: [ExchangeID]) -> [RowChange] {
        var removed = IndexSet()
        var inserted = IndexSet()
        var i = 0
        var j = 0
        while i < old.count, j < rows.count {
            if old[i] == rows[j] {
                i += 1
                j += 1
                continue
            }
            guard let oldPlace = all.position(of: old[i]) else {
                // Gone from the session.
                removed.insert(i)
                i += 1
                continue
            }
            if oldPlace < all.position(of: rows[j])! {
                removed.insert(i)
                i += 1
            } else {
                inserted.insert(j)
                j += 1
            }
        }
        removed.insert(integersIn: i..<old.count)
        inserted.insert(integersIn: j..<rows.count)
        return Self.changes(removed: removed, inserted: inserted)
    }

    // MARK: - Changing the traffic

    /// Adds new exchanges at the end and changes the ones already there.
    mutating func update(_ summaries: [ExchangeSummary]) -> [RowChange] {
        var leaving = IndexSet()
        var joining: [ExchangeID] = []
        var appended: [ExchangeID] = []
        var staying: [ExchangeID] = []
        for summary in Self.latest(summaries) {
            if let position = all.position(of: summary.id) {
                let old = all[position]
                let wasShown = row(of: summary.id)
                // Most changes are to a status or a size, which no count depends on.
                if !Self.countsAlike(old, summary) {
                    let keepsDevice = old.device?.id == summary.device?.id
                    tally(old, by: -1, at: position, keepingOldest: keepsDevice)
                    tally(summary, by: 1, at: position, keepingOldest: keepsDevice)
                    if keepsDevice, let device = summary.device, old.device != summary.device,
                        oldestByDevice[device.id] == summary.id
                    {
                        // The device's name, as the sidebar shows it, changed.
                        namesAreStale = true
                    }
                }
                all.replace(at: position, with: summary)
                checkText(summary)
                switch (wasShown, isShown(summary)) {
                case (_?, true): staying.append(summary.id)
                case (let row?, false): leaving.insert(row)
                case (nil, true): joining.append(summary.id)
                case (nil, false): break
                }
            } else {
                all.append(summary)
                tally(summary, by: 1, at: all.count - 1, keepingOldest: false)
                checkText(summary)
                if isShown(summary) {
                    appended.append(summary.id)
                }
            }
        }
        var changes = changeRows(leaving: leaving, joining: joining, appended: appended)
        if !staying.isEmpty {
            changes.append(.changed(staying))
        }
        refreshNames()
        return changes
    }

    /// Drops exchanges, such as the oldest ones past the session's size limit.
    mutating func remove(_ ids: [ExchangeID]) -> [RowChange] {
        var leaving = IndexSet()
        // Oldest first, so a device whose oldest exchange goes finds its next oldest among the
        // ones that stay.
        let removed = Set(ids).compactMap { id in all.position(of: id).map { (id: id, position: $0) } }
            .sorted { $0.position < $1.position }
        guard !removed.isEmpty else { return [] }
        for (id, position) in removed {
            if let row = row(of: id) {
                leaving.insert(row)
            }
            tally(all[position], by: -1, at: position, keepingOldest: false)
        }
        let changes = changeRows(leaving: leaving, joining: [], appended: [])
        let removedIDs = removed.map(\.id)
        all.remove(removedIDs)
        storeMatches.subtract(removedIDs)
        textMatches.subtract(removedIDs)
        refreshNames()
        return changes
    }

    /// Drops every exchange that isn't pinned, as clearing the traffic does.
    mutating func removeUnpinned() -> [RowChange] {
        let oldRows = rows
        let kept = all.filter(\.annotation.isPinned)
        all = ExchangeList()
        changedCounts.formUnion(counts.keys)
        counts = [:]
        sourceCounts = [:]
        methodCounts = [:]
        pinnedCount = 0
        oldestByDevice = [:]
        changedCounts.formUnion([.all, .pinned])
        namesAreStale = true
        storeMatches = []
        textMatches.formIntersection(kept.map(\.id))
        for summary in kept {
            all.append(summary)
            tally(summary, by: 1, at: all.count - 1, keepingOldest: false)
        }
        refreshNames()
        rows = []
        for summary in all where isShown(summary) {
            rows.append(summary.id)
        }
        return changes(from: oldRows)
    }

    // MARK: - Changing what the list shows

    mutating func setScope(_ scope: Scope) -> [RowChange] {
        guard scope != self.scope else { return [] }
        self.scope = scope
        return reshowAll()
    }

    mutating func setFilter(_ filter: TrafficFilter) -> [RowChange] {
        guard filter != self.filter else { return [] }
        self.filter = filter
        return reshowAll()
    }

    /// Searches for new text. What the store found for the old text no longer counts.
    mutating func setQuery(_ query: String) -> [RowChange] {
        storeMatches = []
        let old = self.query
        self.query = query
        if query.isEmpty {
            textMatches = []
        } else if !old.isEmpty, query.localizedCaseInsensitiveContains(old) {
            // Typing on only narrows the search: whatever has the new text has the old text.
            var memo = TextMemo()
            var matches: Set<ExchangeID> = []
            for id in textMatches {
                if let summary = all.summary(id), Self.hasText(query, summary, &memo) {
                    matches.insert(id)
                }
            }
            textMatches = matches
        } else {
            var memo = TextMemo()
            var matches: Set<ExchangeID> = []
            for summary in all where Self.hasText(query, summary, &memo) {
                matches.insert(summary.id)
            }
            textMatches = matches
        }
        return reshowAll()
    }

    /// Takes in what the store found for the search text: exchanges that have it in their
    /// headers or bodies. Only rows whose exchanges it adds or drops change.
    mutating func setStoreMatches(_ found: Set<ExchangeID>) -> [RowChange] {
        let added = found.subtracting(storeMatches)
        let dropped = storeMatches.subtracting(found)
        storeMatches = found
        var leaving = IndexSet()
        var joining: [ExchangeID] = []
        // An exchange with the text in its host, path and so on shows either way.
        for id in added.union(dropped) where !textMatches.contains(id) {
            guard let summary = all.summary(id) else { continue }
            switch (row(of: id), isShown(summary)) {
            case (let row?, false): leaving.insert(row)
            case (nil, true): joining.append(id)
            default: break
            }
        }
        return changeRows(leaving: leaving, joining: joining, appended: [])
    }

    // MARK: - Rows

    /// Whether the list shows an exchange. With search text, its text must be checked first.
    private func isShown(_ summary: ExchangeSummary) -> Bool {
        switch scope {
        case .all: break
        case .pinned: if !summary.annotation.isPinned { return false }
        case .source(let source, let device):
            if summary.source != source || !device.matches(summary.device) { return false }
        case .device(let choice): if !choice.matches(summary.device) { return false }
        case .host(let host): if summary.host != host { return false }
        case .deviceHost(let host, let device):
            if summary.source != nil || summary.host != host || !device.matches(summary.device) { return false }
        }
        if !filter.matches(summary) { return false }
        if query.isEmpty { return true }
        return storeMatches.contains(summary.id) || textMatches.contains(summary.id)
    }

    /// Works out the rows again from every exchange, as when a filter changes. The rows before
    /// are in the order of `all` too, so one pass through both finds the rows that went and the
    /// rows that came.
    private mutating func reshowAll() -> [RowChange] {
        var rows: [ExchangeID] = []
        rows.reserveCapacity(self.rows.count)
        var removed = IndexSet()
        var inserted = IndexSet()
        var old = 0
        for summary in all {
            let wasShown = old < self.rows.count && self.rows[old] == summary.id
            let isShown = isShown(summary)
            if wasShown, !isShown {
                removed.insert(old)
            } else if isShown, !wasShown {
                inserted.insert(rows.count)
            }
            if isShown {
                rows.append(summary.id)
            }
            if wasShown {
                old += 1
            }
        }
        self.rows = rows
        return Self.changes(removed: removed, inserted: inserted)
    }

    private static func changes(removed: IndexSet, inserted: IndexSet) -> [RowChange] {
        var changes: [RowChange] = []
        if !removed.isEmpty {
            changes.append(.removed(removed))
        }
        if !inserted.isEmpty {
            changes.append(.inserted(inserted))
        }
        return changes
    }

    /// Takes rows out, then puts rows back in their places, then adds rows for new exchanges at
    /// the end, and says how, in the table's terms.
    private mutating func changeRows(leaving: IndexSet, joining: [ExchangeID], appended: [ExchangeID])
        -> [RowChange]
    {
        var changes: [RowChange] = []
        if !leaving.isEmpty {
            rows.removeSubranges(RangeSet(leaving.rangeView.map { $0 }))
            changes.append(.removed(leaving))
        }
        guard !joining.isEmpty || !appended.isEmpty else { return changes }
        if !joining.isEmpty {
            let sorted = joining.map { (id: $0, place: all.position(of: $0)!) }.sorted { $0.place < $1.place }
            if sorted.count > 16 {
                rows = merged(sorted)
            } else {
                for entry in sorted {
                    rows.insert(entry.id, at: insertionRow(for: entry.place))
                }
            }
        }
        rows += appended
        var inserted = IndexSet(joining.compactMap { row(of: $0) })
        inserted.insert(integersIn: (rows.count - appended.count)..<rows.count)
        changes.append(.inserted(inserted))
        return changes
    }

    /// The row a new one goes in, to keep rows in the order of `all`.
    private func insertionRow(for place: Int) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if all.position(of: rows[middle])! < place { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The rows with others put in, in one pass, for when many join at once.
    private func merged(_ joining: [(id: ExchangeID, place: Int)]) -> [ExchangeID] {
        var result: [ExchangeID] = []
        result.reserveCapacity(rows.count + joining.count)
        var next = 0
        for id in rows {
            let place = all.position(of: id)!
            while next < joining.count, joining[next].place < place {
                result.append(joining[next].id)
                next += 1
            }
            result.append(id)
        }
        result += joining[next...].map(\.id)
        return result
    }

    // MARK: - Search

    /// Checks an exchange that arrived or changed for the search text.
    private mutating func checkText(_ summary: ExchangeSummary) {
        guard !query.isEmpty else { return }
        var memo = TextMemo()
        if Self.hasText(query, summary, &memo) {
            textMatches.insert(summary.id)
        } else {
            textMatches.remove(summary.id)
        }
    }

    /// Whether a host, method or name has the text, worked out once for each, since many
    /// exchanges share them.
    private typealias TextMemo = [String: Bool]

    private static func hasText(_ query: String, _ summary: ExchangeSummary, _ memo: inout TextMemo) -> Bool {
        func shared(_ text: String) -> Bool {
            if let known = memo[text] { return known }
            let found = text.localizedCaseInsensitiveContains(query)
            memo[text] = found
            return found
        }
        return shared(summary.host)
            || summary.target.localizedCaseInsensitiveContains(query)
            || shared(summary.method)
            || summary.source.map { shared($0.name) } == true
            || summary.device.map { shared($0.name) } == true
            || summary.annotation.comment?.localizedCaseInsensitiveContains(query) == true
    }

    // MARK: - Counts

    /// Counts an exchange in, or out with -1, at its place in `all`.
    ///
    /// - Parameter keepingOldest: The exchange stays on its device, so the device's oldest
    ///   exchange stays the same.
    private mutating func tally(_ summary: ExchangeSummary, by delta: Int, at position: Int, keepingOldest: Bool) {
        add(delta, to: .host(summary.host))
        let choice: DeviceChoice = summary.device.map { .device($0.id) } ?? .thisMac
        if let source = summary.source {
            if Self.add(delta, to: source, in: &sourceCounts) {
                namesAreStale = true
            }
            add(delta, to: .source(source, on: choice))
        } else {
            add(delta, to: .deviceHost(summary.host, on: choice))
        }
        add(delta, to: .device(choice))
        if Self.add(delta, to: summary.method, in: &methodCounts) {
            namesAreStale = true
        }
        if summary.annotation.isPinned {
            pinnedCount += delta
            changedCounts.insert(.pinned)
        }
        changedCounts.insert(.all)
        if let device = summary.device, !keepingOldest {
            if delta > 0 {
                if let oldest = oldestByDevice[device.id], let oldestPosition = all.position(of: oldest),
                    oldestPosition < position
                {
                    return
                }
                oldestByDevice[device.id] = summary.id
                namesAreStale = true
            } else if oldestByDevice[device.id] == summary.id {
                // The next oldest exchange from the device, if it has any left.
                oldestByDevice[device.id] = all[(position + 1)...].first { $0.device?.id == device.id }?.id
                namesAreStale = true
            }
        }
    }

    private mutating func add(_ delta: Int, to scope: Scope) {
        let count = (counts[scope] ?? 0) + delta
        if count == 0 || counts[scope] == nil {
            namesAreStale = true
        }
        counts[scope] = count == 0 ? nil : count
        changedCounts.insert(scope)
    }

    /// Adds to a count, and says whether that took the key in or out.
    private static func add<Key: Hashable>(_ delta: Int, to key: Key, in counts: inout [Key: Int]) -> Bool {
        let count = (counts[key] ?? 0) + delta
        let comesOrGoes = count == 0 || counts[key] == nil
        counts[key] = count == 0 ? nil : count
        return comesOrGoes
    }

    /// Sorts the hosts, apps, devices and methods again, once some came or went.
    private mutating func refreshNames() {
        guard namesAreStale else { return }
        namesAreStale = false
        namesVersion += 1
        var hosts: [String] = []
        var apps: [DeviceChoice: [Source]] = [:]
        var otherHosts: [DeviceChoice: [String]] = [:]
        var deviceIDs: [String] = []
        for scope in counts.keys {
            switch scope {
            case .host(let host): hosts.append(host)
            case .source(let source, let device): apps[device, default: []].append(source)
            case .deviceHost(let host, let device): otherHosts[device, default: []].append(host)
            case .device(.device(let id)): deviceIDs.append(id)
            default: break
            }
        }
        self.hosts = hosts.sorted(by: Self.naturalOrder)
        sources = sourceCounts.keys.sorted(by: Self.nameOrder)
        appsByDevice = apps.mapValues { $0.sorted(by: Self.nameOrder) }
        otherHostsByDevice = otherHosts.mapValues { $0.sorted(by: Self.naturalOrder) }
        let named = deviceIDs.compactMap { id in
            oldestByDevice[id].flatMap { all.summary($0)?.device }.map { DeviceEntry(device: $0) }
        }
        let byName = named.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        devices = byName.isEmpty ? [] : [DeviceEntry(device: nil)] + byName
        methods = methodCounts.keys.sorted { first, second in
            let firstRank = Self.commonMethods.firstIndex(of: first) ?? Self.commonMethods.count
            let secondRank = Self.commonMethods.firstIndex(of: second) ?? Self.commonMethods.count
            return firstRank != secondRank ? firstRank < secondRank : first < second
        }
    }

    private static let commonMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT"]

    private static func nameOrder(_ first: Source, _ second: Source) -> Bool {
        first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    /// Numbers in names sort by their value, as in Finder, so h2 comes before h10.
    private static func naturalOrder(_ first: String, _ second: String) -> Bool {
        switch first.localizedStandardCompare(second) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: first < second
        }
    }

    /// Whether two summaries of an exchange count the same in the sidebar and the filters.
    private static func countsAlike(_ first: ExchangeSummary, _ second: ExchangeSummary) -> Bool {
        first.host == second.host && first.source == second.source && first.device == second.device
            && first.method == second.method && first.annotation.isPinned == second.annotation.isPinned
    }

    /// The summaries with each exchange once, at its first place, as its last summary.
    private static func latest(_ summaries: [ExchangeSummary]) -> [ExchangeSummary] {
        var places: [ExchangeID: Int] = [:]
        var latest: [ExchangeSummary] = []
        for summary in summaries {
            if let place = places[summary.id] {
                latest[place] = summary
            } else {
                places[summary.id] = latest.count
                latest.append(summary)
            }
        }
        return latest
    }
}

/// This Mac or a device that sent traffic, as the sidebar lists it.
nonisolated struct DeviceEntry: Hashable, Identifiable {
    /// The device, or `nil` for this Mac.
    var device: Device?

    var choice: DeviceChoice { device.map { .device($0.id) } ?? .thisMac }
    var id: DeviceChoice { choice }
    var name: String { device?.name ?? "This Mac" }
}

/// The session's exchanges in the order they arrived, with each one's place at hand.
///
/// Dropping the oldest exchanges, as the session does at its size limit, moves only the few
/// kept before them, such as pinned ones, not the whole list. The space they leave at the
/// front is given back now and then, all at once.
nonisolated struct ExchangeList: RandomAccessCollection {
    /// The exchanges from `start` on. The slots before it are empty.
    private var slots: [ExchangeSummary?] = []
    private var start = 0
    /// How many slots were given back from the front so far. Places count them, so giving
    /// slots back changes no place.
    private var dropped = 0
    /// Each exchange's slot, plus `dropped`.
    private var places: [ExchangeID: Int] = [:]

    var startIndex: Int { 0 }
    var endIndex: Int { slots.count - start }

    subscript(position: Int) -> ExchangeSummary {
        slots[start + position]!
    }

    /// Where an exchange is in the list.
    func position(of id: ExchangeID) -> Int? {
        places[id].map { $0 - dropped - start }
    }

    func summary(_ id: ExchangeID) -> ExchangeSummary? {
        places[id].map { slots[$0 - dropped]! }
    }

    mutating func append(_ summary: ExchangeSummary) {
        places[summary.id] = slots.count + dropped
        slots.append(summary)
    }

    /// Puts a newer summary of the same exchange in its place.
    mutating func replace(at position: Int, with summary: ExchangeSummary) {
        slots[start + position] = summary
    }

    mutating func remove(_ ids: [ExchangeID]) {
        let removed = ids.compactMap { places.removeValue(forKey: $0) }.map { $0 - dropped }.sorted()
        guard let first = removed.first, let last = removed.last else { return }
        if last - start < slots.count - first {
            // Move the exchanges kept before the last one removed up to it, so the free slots
            // all end up at the front.
            var write = last
            var next = removed.count - 1
            for read in stride(from: last, through: start, by: -1) {
                if next >= 0, removed[next] == read {
                    next -= 1
                    continue
                }
                if write != read {
                    slots.swapAt(write, read)
                    places[slots[write]!.id] = write + dropped
                }
                write -= 1
            }
            for slot in start...write {
                slots[slot] = nil
            }
            start = write + 1
        } else {
            // Move the exchanges after the first one removed down.
            var write = first
            var next = 0
            for read in first..<slots.count {
                if next < removed.count, removed[next] == read {
                    next += 1
                    continue
                }
                if write != read {
                    slots.swapAt(write, read)
                    places[slots[write]!.id] = write + dropped
                }
                write += 1
            }
            slots.removeLast(slots.count - write)
        }
        // Give the free slots back once they're an eighth of the list, so the list never takes
        // much more room than its exchanges, and giving back seldom costs anything.
        if start >= 1024, start * 8 >= slots.count {
            slots.removeFirst(start)
            dropped += start
            start = 0
        }
    }
}
