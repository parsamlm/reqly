import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The list follows new traffic, as the Mac's does: from its last row, the newest row shows
    /// after each single request and each burst, and a list scrolled up doesn't move, until it's
    /// back at its end. A burst of 10,000 requests all arrive, and every row of the session coming
    /// again, as a search ends, goes in before the newest row shows, once. Then, in a copy of Reqly
    /// whose session keeps 300 requests, the list goes on following past that limit, where as many
    /// rows go as new ones come. In that copy, this part checks only that.
    func checkFollowing() async throws {
        if let limit = app.options.sessionLimit {
            try await checkFollowingPastTheLimit(limit)
            return
        }
        let session = try await emptyTheList()
        let traffic = try await startTraffic()
        defer { traffic.server.stop() }
        do {
            try await withoutWarnings { try await checkFollowing(session, traffic) }
        } catch {
            try? await stopTraffic()
            throw error
        }
        try await stopTraffic()
        try await emptyTheList()
        let limited = try await runInCopy(
            ["follow"], options: ["--session-limit", "300", "--starts-capturing", "yes"], seconds: 120)
        for line in limited where !line.hasSuffix("parts passed") {
            note("copy limited to 300: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    private func checkFollowing(_ session: SessionHost, _ traffic: Traffic) async throws {
        let list = window.list
        var follower = try await Follower(self, session, traffic)
        for size in [1, 1, 300, 1, 1, 50, 50] {
            try await follower.send(size)
        }
        note("following: \(follower.said.joined(separator: "; "))")
        follower.said = []

        // Scrolled up, the list stays where it is.
        let adjustment = try present(gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
        gtk_adjustment_set_value(adjustment, 0)
        await settle()
        let top = try present(list.exchange(at: 0), "the list has no first row")
        let reveals = list.reveals
        try await follower.send(1, follows: false)
        try await follower.send(50, follows: false)
        await settle()
        let value = gtk_adjustment_get_value(adjustment)
        try require(
            value < 1 && rowShows(top) && list.reveals == reveals,
            "scrolled up, the list moved to \(value), with \(list.reveals - reveals) reveals")
        note("scrolled up: \(follower.said.joined(separator: "; ")), the list stays at its top, its first row showing")
        follower.said = []

        // Back at its end, it follows again.
        gtk_adjustment_set_value(
            adjustment, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        await settle()
        try await follower.send(1)
        note("back at its end: \(follower.said.joined(separator: "; "))")
        follower.said = []

        // 10,000 in one burst, as fast as Reqly answers. The window keeps answering meanwhile:
        // far from the speed part's numbers, but a row's cells that cost too much show here.
        let watch = ThreadWatch()
        watch.start()
        defer { watch.stop() }
        let started = monotonicMicroseconds()
        try await follower.send(10_000, seconds: 90)
        let burstWaits = watch.waits(from: started)
        note("10,000 at once: \(follower.said.joined(separator: "; ")); the window's thread: \(burstWaits)")
        try require(burstWaits.longest < 250, "the window's thread waited \(burstWaits.longest) ms during the burst")
        follower.said = []

        // Every row again: a search that leaves none, then the search ending.
        let resets = ResetsSeen()
        model.listen { event in
            guard resets.isListening, case .rows(_, _, _, let steps) = event else { return }
            for case .reset(let ids) in steps {
                resets.sizes.append(ids.count)
            }
        }
        defer { resets.isListening = false }
        await session.setSearch("no request has this")
        try await until("the search to leave no rows", seconds: 20) { list.count == 0 && list.isSettled }
        let page = gtk_stack_get_visible_child(cast(list.widget))
        try require(page == list.noMatches, "with no rows matching, the list shows \(typeName(raw(page)))")
        let revealsBefore = list.reveals
        let searched = monotonicMicroseconds()
        await session.setSearch("")
        let rows = await session.rowIDs().ids.count
        try await until("every row to come back", seconds: 60) { list.count == rows && list.isSettled }
        try await follower.waitForNewest("every row came back")
        let back = (monotonicMicroseconds() - searched) / 1000
        let resetWaits = watch.waits(from: searched)
        note(
            "a search ended: every row, \(Format.count(rows)), came back as \(resets.sizes.count) reset of "
                + "\(resets.sizes.map { Format.count($0) }.joined(separator: ", ")) rows, all in \(back) ms, the newest "
                + "showing after \(list.reveals - revealsBefore) reveal; the window's thread: \(resetWaits)")
        try require(!resets.sizes.isEmpty, "the search's end came as steps, not every row")
        try require(resetWaits.longest < 250, "the window's thread waited \(resetWaits.longest) ms as every row came")
        try require(
            list.reveals - revealsBefore == 1, "the list showed its newest row \(list.reveals - revealsBefore) times")
        try await checkKeepingTheSelection(session, &follower)
    }

    /// The selection stays with its request through a burst, through a search that hides its
    /// row, when the details still show it, and as the search ends, when its row is selected
    /// again.
    private func checkKeepingTheSelection(_ session: SessionHost, _ follower: inout Follower) async throws {
        let list = window.list
        let details = window.details
        let chosen = try present(list.exchange(at: list.count / 2), "the list has no middle row")
        list.select(id: chosen)
        try await until("the row to be selected", seconds: 3) {
            list.selected == chosen && list.shownSelection == chosen && details.shown == chosen
        }
        // Chosen in the middle, the list doesn't follow.
        try await follower.send(50, follows: false)
        try require(
            list.selected == chosen && list.shownSelection == chosen, "after a burst, the selection is somewhere else")
        await session.setSearch("n=first")
        try await until("the search to leave one row", seconds: 20) { list.count == 1 && list.isSettled }
        try require(
            list.selected == chosen && list.shownSelection == nil && details.shown == chosen,
            "hidden by a search, the request isn't selected, or the details don't show it")
        await session.setSearch("")
        let rows = await session.rowIDs().ids.count
        try await until("every row to come back", seconds: 60) { list.count == rows && list.isSettled }
        try require(
            list.selected == chosen && list.shownSelection == chosen, "once the search ended, its row isn't selected")
        note(
            "the selection: #\(chosen.rawValue) stays selected through a burst, hidden by a search with the details "
                + "showing it, and its row selected again as the search ends")
        list.select(id: nil)
    }

    /// In a copy whose session keeps `limit` requests: a burst fills it, then single requests and
    /// bursts each show the newest row, though the list's count stays the same, and a list
    /// scrolled up stays where it is.
    private func checkFollowingPastTheLimit(_ limit: Int) async throws {
        let session = try await session()
        try await until("capturing to start") { model.capture == .capturing || model.problem != nil }
        let port = try present(model.listeningPort, model.problem ?? "capturing didn't start")
        let traffic = Traffic(server: try TestServer(), client: ProxyClient(proxyPort: port), port: port)
        defer { traffic.server.stop() }
        let list = window.list
        let moves = BalancedRows()
        model.listen { event in
            guard moves.isListening, case .rows(_, _, _, let steps) = event else { return }
            var inserted = 0
            var removed = 0
            for step in steps {
                switch step {
                case .inserted(let rows): inserted += rows.count
                case .removed(let rows): removed += rows.count
                case .changed, .reset: break
                }
            }
            if inserted > 0, inserted == removed {
                moves.count += 1
            }
        }
        defer { moves.isListening = false }
        var follower = try await Follower(self, session, traffic)
        try await follower.send(limit - 1)
        try require(list.count == limit, "the list has \(list.count) rows, not \(limit)")
        for size in [1, 1, 1, 25, 25] {
            try await follower.send(size)
            try require(list.count == limit, "past the limit, the list has \(list.count) rows, not \(limit)")
        }
        note("following past \(limit): \(follower.said.joined(separator: "; "))")
        note("rows events that took out as many rows as they put in: \(moves.count)")
        try require(moves.count > 0, "no rows event took out as many rows as it put in")
        follower.said = []

        let adjustment = try present(gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
        gtk_adjustment_set_value(adjustment, 0)
        await settle()
        let reveals = list.reveals
        try await follower.send(25, follows: false)
        await settle()
        let value = gtk_adjustment_get_value(adjustment)
        try require(
            value < 1 && list.reveals == reveals,
            "scrolled up, the list moved to \(value), with \(list.reveals - reveals) reveals")
        note("scrolled up: \(follower.said.joined(separator: "; ")), and the list stays at its top")

        // The oldest request, selected, goes as the session trims it, and the details with it.
        let oldest = try present(list.exchange(at: 0), "the list has no first row")
        list.select(id: oldest)
        try await until("the oldest row to be selected", seconds: 3) {
            list.selected == oldest && self.window.details.shown == oldest
        }
        try await follower.send(5, follows: false)
        try await until("the selection to go with its request", seconds: 5) {
            list.selected == nil && self.window.details.shown == nil
        }
        note("the selection: the oldest request, selected, went as the session trimmed it, and the details with it")
    }
}

/// Sends requests through Reqly, and waits for the newest one's row to show: a single request
/// or a burst at a time, counting the exchanges, whose IDs the session gives in order.
@MainActor
private struct Follower {
    let check: SelfCheck
    let session: SessionHost
    let traffic: SelfCheck.Traffic
    /// The newest request sent.
    private(set) var newest: ExchangeID
    /// What each send found.
    var said: [String] = []

    /// Sends a first request, and learns its ID.
    init(_ check: SelfCheck, _ session: SessionHost, _ traffic: SelfCheck.Traffic) async throws {
        self.check = check
        self.session = session
        self.traffic = traffic
        _ = try await traffic.client.send(traffic.server.url(.ok, "n=first"))
        var newest: ExchangeID?
        let deadline = monotonicMicroseconds() + 5_000_000
        while newest == nil, monotonicMicroseconds() < deadline {
            newest = await session.trafficSummary().newest?.id
            try await Task.sleep(for: .milliseconds(20))
        }
        self.newest = try check.present(newest, "the first request has no row")
        try await waitForNewest("the first request")
    }

    /// Sends `count` requests, one or a burst, then waits for the newest row to show, unless
    /// the list doesn't follow, when it waits for every change to be in.
    mutating func send(_ count: Int, follows: Bool = true, seconds: Int = 15) async throws {
        let (server, client) = (traffic.server, traffic.client)
        let base = newest.rawValue
        let started = monotonicMicroseconds()
        if count == 1 {
            _ = try await client.send(server.url(.ok, "n=\(base + 1)"))
        } else {
            let burst = await client.burst((1...UInt64(count)).map { server.url(.ok, "n=\(base + $0)") })
            try check.require(
                burst.answered == count, "of \(count), \(burst.answered) were answered: \(burst.problems)")
        }
        let answered = monotonicMicroseconds()
        newest = ExchangeID(rawValue: base + UInt64(count))
        let what = count == 1 ? "a request" : "a burst of \(Format.count(count))"
        if follows {
            try await waitForNewest(what, seconds: seconds)
        } else {
            let list = check.window.list
            let newest = newest
            let session = session
            var arrived = false
            let deadline = monotonicMicroseconds() + seconds * 1_000_000
            while !arrived, monotonicMicroseconds() < deadline {
                arrived = await session.trafficSummary().newest?.id == newest && list.isSettled
                try await Task.sleep(for: .milliseconds(20))
            }
            try check.require(arrived, "the rows of \(what) didn't arrive")
            try check.require(!check.rowShows(newest), "scrolled up, the newest row shows after \(what)")
        }
        let sent = (answered - started) / 1000
        let shown = (monotonicMicroseconds() - answered) / 1000
        said.append("\(what) sent in \(sent) ms, \(follows ? "its newest row showing" : "all in") \(shown) ms after")
    }

    /// Waits until the list's last row is the newest request's, with every change in, and the
    /// row shows whole.
    func waitForNewest(_ what: String, seconds: Int = 15) async throws {
        let list = check.window.list
        let newest = newest
        let check = check
        do {
            try await check.until("the newest row to show, after \(what)", seconds: seconds) {
                list.isSettled && list.exchange(at: list.count - 1) == newest && check.rowShows(newest)
            }
        } catch {
            let last = list.exchange(at: list.count - 1).map { "#\($0.rawValue)" } ?? "none"
            throw SelfCheck.Failure(
                "after \(what), the newest row, #\(newest.rawValue), doesn't show: the last row is \(last), "
                    + "\(list.count) rows, \(list.isSettled ? "settled" : "still changing"), "
                    + "\(list.showsEnd() ? "at" : "not at") its end")
        }
    }
}

/// The resets the follow part saw, by how many rows each had.
@MainActor
private final class ResetsSeen {
    var sizes: [Int] = []
    var isListening = true
}

/// How many rows events past the limit took out as many rows as they put in.
@MainActor
private final class BalancedRows {
    var count = 0
    var isListening = true
}
