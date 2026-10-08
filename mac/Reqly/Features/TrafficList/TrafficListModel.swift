import AppKit
import Capture
import Foundation
import Observation
import ReqlyModel
import TrafficStore

/// The traffic the request list shows: every exchange's summary, narrowed by the sidebar, the
/// filters and the search field.
///
/// ``TrafficList`` works the list and its counts out one change at a time. This model hands its
/// results to the views, each only the part it reads, so traffic arriving redraws what changed:
/// the table's rows and the counts, not the whole window.
@Observable
final class TrafficListModel {
    typealias Scope = TrafficList.Scope

    @ObservationIgnored private var list = TrafficList()

    /// Every exchange in the session, oldest first. A view that reads it updates with every
    /// change to the traffic, so busy views read the counts below instead.
    var all: ExchangeList {
        _ = revision
        return list.all
    }

    /// The exchanges the list shows. Building it reads every row, so views that only need how
    /// many read `visibleCount`.
    var visible: [ExchangeSummary] {
        _ = rowsVersion
        return list.rows.compactMap(list.summary)
    }

    /// How many exchanges the session has.
    private(set) var totalCount = 0
    /// How many exchanges the list shows.
    private(set) var visibleCount = 0
    private(set) var isEmpty = true
    /// Whether the sidebar, the filters and the search leave nothing to list.
    private(set) var nothingMatches = true
    /// Whether Clear Traffic has anything to clear. Pinned exchanges stay.
    private(set) var canClear = false
    private(set) var pinnedCount = 0
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
    private var appsByDevice: [DeviceChoice: [Source]] = [:]
    /// For each device, the hosts its traffic from no known app went to.
    private var otherHostsByDevice: [DeviceChoice: [String]] = [:]
    /// Why traffic can't be saved right now, if it can't.
    private(set) var storageProblem: String?
    /// The selected exchange's summary, kept apart so the views that show it don't update with
    /// every change to the traffic.
    private(set) var selectedSummary: ExchangeSummary?

    /// Goes up with every change to the traffic.
    private var revision = 0
    /// Goes up each time the rows change. The table reads it, then asks what changed.
    private(set) var rowsVersion = 0
    /// What changed in the rows at each of the latest versions.
    @ObservationIgnored private var rowChanges: [(version: Int, changes: [TrafficList.RowChange])] = []
    /// The sidebar's counts, each for the row that shows it.
    @ObservationIgnored private var tallies: [Scope: Tally] = [:]
    @ObservationIgnored private var namesVersion = 0
    /// Shows the counts a frame after the rows, as new traffic arrives.
    @ObservationIgnored private let nextFrame = NextFrame()

    var scope = Scope.all {
        didSet { if scope != oldValue { narrow { $0.setScope(scope) } } }
    }

    var filter = TrafficFilter() {
        didSet { if filter != oldValue { narrow { $0.setFilter(filter) } } }
    }

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            narrow { $0.setQuery(query) }
            searchStore(after: .milliseconds(150), restarting: true)
        }
    }

    var selection: ExchangeID? {
        didSet {
            if selection != oldValue {
                selectedSummary = selection.flatMap(list.summary)
            }
        }
    }
    /// The exchange whose comment to start editing in the detail pane, as the request list's
    /// Add Comment asks.
    var commentToEdit: ExchangeID?
    /// The Export as HAR sheet, while it's open.
    var harExport: HARExportRequest?
    /// Exchanges held at breakpoints, each as you're editing it.
    var paused: [ExchangeID: PausedDraft] = [:]

    private let session: CaptureSession
    private var storeSearch: Task<Void, Never>?
    /// The latest call to the session. Each waits for the one before, so a pin made just before
    /// clearing is saved in time to keep its exchange.
    private var lastSessionCall: Task<Void, Never>?
    #if DEBUG
        private var hasClearedForLaunch = false
        /// The places in the list that launch arguments already annotated.
        private var annotatedForLaunch: Set<Int> = []
    #endif

    init(session: CaptureSession) {
        self.session = session
        #if DEBUG
            filter = Self.filterFromLaunchArguments()
            if UserDefaults.standard.string(forKey: DefaultsKey.scope) == "pinned" {
                scope = .pinned
            }
            searchText = UserDefaults.standard.string(forKey: DefaultsKey.search) ?? ""
        #endif
        let changes = session.changes
        Task { [weak self] in
            for await change in changes {
                self?.apply(change)
            }
        }
    }

    /// How many exchanges the sidebar's selection covers, before any search.
    var scopeCount: Int {
        count(of: scope)
    }

    /// How many exchanges a sidebar row covers. A view that reads it updates only when that
    /// count changes.
    func count(of scope: Scope) -> Int {
        switch scope {
        case .all: return totalCount
        case .pinned: return pinnedCount
        default:
            if let tally = tallies[scope] {
                return tally.count
            }
            let tally = Tally(count: list.count(of: scope))
            tallies[scope] = tally
            return tally.count
        }
    }

    /// An exchange's summary. A view that reads it updates with every change to the traffic,
    /// unless it's the selected exchange.
    func summary(_ id: ExchangeID) -> ExchangeSummary? {
        if id == selection {
            return selectedSummary
        }
        _ = revision
        return list.summary(id)
    }

    // MARK: - For the table

    /// The exchanges the list shows, as the table reads them. Reading them doesn't make a view
    /// update; `rowsVersion` does.
    var rows: [ExchangeID] { list.rows }

    /// The summary for a row, as the table reads it.
    func rowSummary(_ id: ExchangeID) -> ExchangeSummary? {
        list.summary(id)
    }

    /// The row that shows an exchange.
    func row(of id: ExchangeID) -> Int? {
        list.row(of: id)
    }

    /// How to change rows the table showed into the current ones, for a table that missed the
    /// changes between.
    func rowChanges(from old: [ExchangeID]) -> [TrafficList.RowChange] {
        list.changes(from: old)
    }

    /// Lets go of the changes up to a version the table now shows.
    func forgetRowChanges(through version: Int) {
        rowChanges.removeAll { $0.version <= version }
    }

    /// What changed in the rows after a version the table showed, in order, or `nil` when the
    /// table has to start over.
    func rowChanges(since version: Int) -> [TrafficList.RowChange]? {
        guard version < rowsVersion else { return [] }
        guard let first = rowChanges.first, first.version <= version + 1 else { return nil }
        return rowChanges.filter { $0.version > version }.flatMap(\.changes)
    }

    // MARK: -

    /// Clears the traffic. Requests held at breakpoints go on as they are first.
    func clear() {
        continueAllPaused()
        callSession { await $0.clear() }
    }

    /// Lets a paused exchange go on, edited or not, or stops it.
    func decide(_ id: ExchangeID, _ decision: PausedDecision) {
        paused[id] = nil
        session.decide(id, decision)
    }

    /// Lets every paused exchange go on as it was.
    func continueAllPaused() {
        for (id, draft) in paused {
            decide(id, .resume(draft.original))
        }
    }

    /// Shows the traffic the session's store already holds, as for a file that just opened.
    func showStoredTraffic() async {
        await session.publishStoredTraffic()
    }

    /// Waits until the store has everything the list shows, including pins and comments that
    /// are still on their way.
    func settle() async {
        await lastSessionCall?.value
        await session.flush()
    }

    func saveSession(to url: URL, hidingSecrets: Bool) async throws {
        await settle()
        try await session.store.saveSession(to: url, hidingSecrets: hidingSecrets)
    }

    func togglePin(_ id: ExchangeID) {
        annotate(id) { $0.isPinned.toggle() }
    }

    func setColor(_ color: MarkColor?, for id: ExchangeID) {
        annotate(id) { $0.color = color }
    }

    /// Saves a comment. Spaces around it are dropped, and an empty one removes the comment.
    func setComment(_ text: String, for id: ExchangeID) {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        annotate(id) { $0.comment = comment.isEmpty ? nil : comment }
    }

    /// The apps that sent traffic from this Mac, or from one device, by name.
    func apps(on device: DeviceChoice) -> [Source] {
        appsByDevice[device] ?? []
    }

    /// The hosts that this Mac's or a device's traffic from no known app went to, by name.
    func otherHosts(on device: DeviceChoice) -> [String] {
        otherHostsByDevice[device] ?? []
    }

    /// What to call this Mac or a device in a menu.
    func deviceName(_ choice: DeviceChoice) -> String {
        switch choice {
        case .thisMac: "This Mac"
        case .device(let id): devices.first { $0.device?.id == id }?.name ?? "Device"
        }
    }

    /// Names a device in the list right away, then in the saved traffic.
    func renameDevice(_ id: String, to name: String) {
        let renamed = list.all.filter { $0.device?.id == id }.map { summary in
            var summary = summary
            summary.device?.name = name
            return summary
        }
        if !renamed.isEmpty {
            changeTraffic { $0.update(renamed) }
        }
        callSession { await $0.renameDevice(id, to: name) }
    }

    func unpinAll() {
        for id in list.all.filter(\.annotation.isPinned).map(\.id) {
            annotate(id) { $0.isPinned = false }
        }
    }

    /// Shows the exchange and starts editing its comment.
    func editComment(of id: ExchangeID) {
        selection = id
        commentToEdit = id
    }

    /// Changes the list right away, then saves the change.
    private func annotate(_ id: ExchangeID, _ change: (inout Annotation) -> Void) {
        guard var summary = list.summary(id) else { return }
        var annotation = summary.annotation
        change(&annotation)
        guard annotation != summary.annotation else { return }
        summary.annotation = annotation
        changeTraffic { $0.update([summary]) }
        callSession { await $0.annotate(id, with: annotation) }
    }

    private func callSession(_ call: @escaping (CaptureSession) async -> Void) {
        let previous = lastSessionCall
        let session = self.session
        lastSessionCall = Task {
            await previous?.value
            await call(session)
        }
    }

    func clearFilters() {
        filter = TrafficFilter()
    }

    /// An exchange's WebSocket messages, in order, from the one numbered `number` on.
    func messages(of id: ExchangeID, from number: Int = 0) async -> [WebSocketMessage] {
        await session.messages(of: id, from: number)
    }

    func exchange(_ id: ExchangeID) async -> Exchange? {
        await session.exchange(id)
    }

    /// The search text without the spaces around it.
    var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private func apply(_ change: SessionChange) {
        #if DEBUG
            let started = ContinuousClock.now
            let rowsBefore = list.all.count
        #endif
        switch change {
        case .cleared:
            // Pinned exchanges stay. The session sends their latest summaries next.
            changeTraffic { $0.removeUnpinned() }
            if let selection, list.summary(selection) == nil {
                self.selection = nil
            }
        case .updated(let summaries, let removed):
            // Touching `paused` would update every view that reads it, such as the Rules menu,
            // so it's only changed when an exchange there finished or went.
            for summary in summaries where summary.state.isFinished && paused[summary.id] != nil {
                // It failed while it waited, for example because its app gave up.
                paused[summary.id] = nil
            }
            for id in removed where paused[id] != nil {
                paused[id] = nil
            }
            // Past the session's size limit, the oldest exchanges go as new ones come, and the
            // table shows both in one go.
            changeTraffic(countsInNextFrame: true) { list in
                list.update(summaries) + list.remove(removed)
            }
            if let selection, removed.contains(selection) {
                self.selection = nil
            }
            if !summaries.isEmpty {
                // New traffic may match the search in its headers or body.
                searchStore(after: .milliseconds(250), restarting: false)
            }
            #if DEBUG
                applyLaunchAnnotations()
                let clearAt = UserDefaults.standard.integer(forKey: DefaultsKey.clearAt)
                if clearAt > 0, list.all.count >= clearAt, !hasClearedForLaunch {
                    hasClearedForLaunch = true
                    clear()
                }
                let select = UserDefaults.standard.string(forKey: DefaultsKey.selectRequest)
                if select == "last" {
                    selection = list.all.last?.id
                } else if let place = select.flatMap(Int.init), list.all.indices.contains(place - 1) {
                    selection = list.all[place - 1].id
                }
            #endif
        case .storageProblem(let problem):
            storageProblem = problem
            return
        case .paused(let id, let message, let breakpoint):
            paused[id] = PausedDraft(message, breakpoint: breakpoint)
            // It shows unless you're already looking at another one that's waiting.
            if selection.map({ paused[$0] == nil }) ?? true {
                selection = id
            }
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
            }
            #if DEBUG
                resumeForLaunch(id)
            #endif
            return
        }
        #if DEBUG
            PerfProbe.applied(change, rowsBefore: rowsBefore, started: started, traffic: self)
        #endif
    }

    /// Asks the store which exchanges contain the search text in their headers or bodies.
    ///
    /// - Parameter restarting: Start over when the search text changes. While traffic arrives,
    ///   a search already on its way is enough.
    private func searchStore(after delay: Duration, restarting: Bool) {
        let query = self.query
        guard query.unicodeScalars.count >= TrafficStore.minimumSearchLength else {
            storeSearch?.cancel()
            storeSearch = nil
            return
        }
        if restarting {
            storeSearch?.cancel()
        } else if storeSearch != nil {
            return
        }
        storeSearch = Task { [weak self, session] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            #if DEBUG
                let started = ContinuousClock.now
            #endif
            let found = await session.search(query)
            guard !Task.isCancelled, let self else { return }
            storeSearch = nil
            guard self.query == query else { return }
            narrow { $0.setStoreMatches(found) }
            #if DEBUG
                PerfProbe.searched(query: query, took: .now - started, matches: found.count)
            #endif
        }
    }

    /// Changes the session's traffic in the list, then shows the change.
    private func changeTraffic(
        countsInNextFrame: Bool = false, _ change: (inout TrafficList) -> [TrafficList.RowChange]
    ) {
        revision += 1
        narrow(countsInNextFrame: countsInNextFrame, change)
    }

    /// Changes the list, then shows the change.
    ///
    /// - Parameter countsInNextFrame: Show the counts a frame after the rows. New traffic
    ///   changes the window's subtitle, the status bar and the sidebar's badges, and each costs
    ///   about as much to show again as the new rows do. In a frame of their own, neither makes
    ///   the other wait, and the counts are only a frame behind.
    private func narrow(countsInNextFrame: Bool = false, _ change: (inout TrafficList) -> [TrafficList.RowChange]) {
        #if DEBUG
            let started = ContinuousClock.now
        #endif
        let changes = change(&list)
        #if DEBUG
            PerfProbe.refiltered(took: .now - started)
        #endif
        show(changes, countsInNextFrame: countsInNextFrame)
    }

    /// Hands what changed to the views that read it. Setting a property to the value it has
    /// already updates no view.
    private func show(_ changes: [TrafficList.RowChange], countsInNextFrame: Bool) {
        if !changes.isEmpty {
            rowsVersion += 1
            rowChanges.append((rowsVersion, changes))
            // The table takes them as it updates. Without one, as while nothing matches, only the
            // latest are kept, and a table further behind starts over.
            if rowChanges.count > 64 {
                rowChanges.removeFirst(rowChanges.count - 64)
            }
        }
        // The first traffic shows its count at once, as "Waiting for traffic" gives way to it.
        let hadTraffic = !isEmpty
        isEmpty = list.all.isEmpty
        nothingMatches = list.rows.isEmpty
        pinnedCount = list.pinnedCount
        canClear = list.all.count > list.pinnedCount
        if namesVersion != list.namesVersion {
            namesVersion = list.namesVersion
            hosts = list.hosts
            sources = list.sources
            devices = list.devices
            methods = list.methods
            appsByDevice = list.appsByDevice
            otherHostsByDevice = list.otherHostsByDevice
        }
        if countsInNextFrame, hadTraffic, !isEmpty {
            nextFrame.run { [weak self] in
                self?.showCounts()
            }
        } else {
            nextFrame.cancel()
            showCounts()
        }
        if let selection {
            selectedSummary = list.summary(selection)
        }
    }

    private func showCounts() {
        #if DEBUG
            let started = ContinuousClock.now
        #endif
        totalCount = list.all.count
        visibleCount = list.rows.count
        for scope in list.takeChangedCounts() {
            tallies[scope]?.count = list.count(of: scope)
        }
        #if DEBUG
            PerfProbe.countsShown(started: started)
        #endif
    }

    #if DEBUG
        /// Edits a paused exchange and continues it a moment later, as the editor would, when
        /// `-resumePaused YES` asks: a 201 with an X-Edited header, and "sunny" for "light-rain".
        private func resumeForLaunch(_ id: ExchangeID) {
            guard UserDefaults.standard.bool(forKey: DefaultsKey.resumePaused) else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard var draft = paused[id] else { return }
                if draft.part == .response {
                    draft.status = "201"
                    draft.reason = "Created"
                    draft.body = draft.body.replacingOccurrences(of: "light-rain", with: "sunny")
                }
                draft.headers.append(EditableHeader(name: "X-Edited", value: "yes"))
                if let message = draft.edited() {
                    decide(id, .resume(message))
                }
            }
        }

        /// Annotates requests as they arrive, as `-annotate "1:pin,red;3:comment=Slow"` asks.
        /// `edit` starts editing a request's comment, as Add Comment does.
        private func applyLaunchAnnotations() {
            let entries = (UserDefaults.standard.string(forKey: DefaultsKey.annotate) ?? "").split(separator: ";")
            for entry in entries {
                let parts = entry.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let place = Int(parts[0]), all.indices.contains(place - 1),
                    !annotatedForLaunch.contains(place)
                else { continue }
                annotatedForLaunch.insert(place)
                let id = all[place - 1].id
                for attribute in parts[1].split(separator: ",") {
                    if attribute == "pin" {
                        togglePin(id)
                    } else if attribute.hasPrefix("comment=") {
                        setComment(String(attribute.dropFirst("comment=".count)), for: id)
                    } else if attribute == "edit" {
                        editComment(of: id)
                    } else if let color = MarkColor(rawValue: String(attribute)) {
                        setColor(color, for: id)
                    }
                }
            }
        }

        /// Filters set by launch arguments, such as `-filterStatus 4xx,failed -filterContent json`.
        private static func filterFromLaunchArguments() -> TrafficFilter {
            let defaults = UserDefaults.standard
            func list(_ key: String) -> [String] {
                (defaults.string(forKey: key) ?? "").split(separator: ",").map { $0.lowercased() }
            }
            var filter = TrafficFilter()
            filter.statuses = Set(
                list(DefaultsKey.filterStatus).compactMap { name in
                    StatusFilter.allCases.first { $0.title.lowercased() == name }
                })
            filter.contents = Set(
                list(DefaultsKey.filterContent).compactMap { name in
                    ContentGroup.allCases.first { $0.title.lowercased() == name }
                })
            filter.host = defaults.string(forKey: DefaultsKey.filterHost)
            filter.method = defaults.string(forKey: DefaultsKey.filterMethod)
            return filter
        }
    #endif
}

/// One of the sidebar's counts. Each row watches only its own, so new traffic redraws just the
/// rows whose counts changed.
@Observable
final class Tally {
    fileprivate(set) var count: Int

    init(count: Int) {
        self.count = count
    }
}

/// Runs something in the frame after the one being made: once the main thread has finished
/// with this one and is about to wait, it waits for the screen's next refresh. Asked again
/// before then, it runs only the latest.
@MainActor
private final class NextFrame: NSObject {
    private var action: (() -> Void)?
    private var isWaiting = false
    private var link: CADisplayLink?

    func run(_ action: @escaping () -> Void) {
        self.action = action
        guard !isWaiting else { return }
        isWaiting = true
        // The refresh during this frame's work would run it in the same frame, so the screen's
        // refreshes count only once the main thread is about to wait.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.waitForRefresh()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Forgets what was asked.
    func cancel() {
        action = nil
        isWaiting = false
        link?.invalidate()
        link = nil
    }

    private func waitForRefresh() {
        guard isWaiting, link == nil else { return }
        guard let screen = NSScreen.main else {
            fire()
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A display link stops while its screen sleeps or goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak link] in
            if let self, let link, self.link === link {
                fire()
            }
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        fire()
    }

    private func fire() {
        let action = self.action
        cancel()
        action?()
    }
}
