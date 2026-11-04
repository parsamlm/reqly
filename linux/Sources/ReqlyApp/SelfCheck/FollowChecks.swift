import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The list follows new traffic, as the Mac's does: from its last row, the newest row shows
    /// after each single request and each burst, and a list scrolled up doesn't move, until it's
    /// back at its end. A burst of 10,000 requests all arrive; a filter that leaves every other
    /// one, and takes them back, shows within seconds with the list at its end; and every row of
    /// the session coming again, as a search ends, goes in before the newest row shows, once. A
    /// burst into an empty list is followed to its newest row too. Then, in a copy of Reqly
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
        try await checkScrollingUpBeforeAReveal(&follower)

        // 10,000 in one burst, as fast as Reqly answers, every other one answered 404 for the
        // filter after. The window keeps answering meanwhile: far from the speed part's numbers,
        // but a row's cells that cost too much show here.
        let watch = ThreadWatch()
        watch.start()
        defer { watch.stop() }
        let started = monotonicMicroseconds()
        try await follower.send(10_000, seconds: 90) { $0 % 2 == 0 ? 404 : 200 }
        let burstWaits = watch.waits(from: started)
        note("10,000 at once: \(follower.said.joined(separator: "; ")); the window's thread: \(burstWaits)")
        try require(burstWaits.longest < 250, "the window's thread waited \(burstWaits.longest) ms during the burst")
        follower.said = []
        try await checkFilteringEveryOtherRow(watch)

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
        try await until("the no-matches page to show in the list's place", seconds: 3) {
            gtk_widget_get_mapped(self.window.noMatches.widget) != 0
        }
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
        try await checkABurstIntoAnEmptyList(&follower)
    }

    /// The 4xx filter on, then off, with the list at its end, where every other request of the
    /// burst before was answered 404: 5,000 rows go, each apart from the next, then come back, and
    /// the list shows what's left within seconds, at its end still. GTK takes a change near the
    /// list's end slowly, a few milliseconds each, so the list doesn't give it one for each row.
    private func checkFilteringEveryOtherRow(_ watch: ThreadWatch) async throws {
        let list = window.list
        let button = try present(window.filters.statusButtons[.clientError], "there's no 4xx button")
        let all = list.count
        var said: [String] = []
        for (isOn, rows) in [(true, 5_000), (false, all)] {
            let what = isOn ? "with the 4xx filter" : "with it off again"
            let started = monotonicMicroseconds()
            gtk_toggle_button_set_active(cast(button), cBool(isOn))
            do {
                try await until("the list's rows \(what)", seconds: 10) { list.count == rows && list.isSettled }
            } catch {
                throw Failure(
                    "\(what), the list shows \(Format.count(list.count)) rows, not \(Format.count(rows)), "
                        + "\((monotonicMicroseconds() - started) / 1000) ms after, "
                        + "\(list.isSettled ? "settled" : "still changing")")
            }
            let took = (monotonicMicroseconds() - started) / 1000
            let last = try present(list.exchange(at: list.count - 1), "\(what), the list has no last row")
            try await until("the list's last row to show, \(what)", seconds: 5) {
                list.isSettled && self.rowShows(last)
            }
            said.append(
                "\(what), \(Format.count(rows)) rows in \(took) ms, the last showing; \(watch.waits(from: started))")
        }
        note("every other row filtered, at the list's end: \(said.joined(separator: "; "))")
    }

    /// Requests into an empty list, as when capturing starts, twice: 1,000 on two connections,
    /// as an app sends them, then a burst of 4,000. The list follows them to the newest row, though
    /// when it first shows rows, GTK has yet to go to the row it was asked to.
    private func checkABurstIntoAnEmptyList(_ follower: inout Follower) async throws {
        follower.said = []
        for _ in 1...2 {
            try await emptyTheList()
            try await follower.send(1_000, seconds: 30, connections: 2)
            try await follower.send(4_000, seconds: 30)
        }
        note("into an empty list: \(follower.said.joined(separator: "; "))")
        follower.said = []
    }

    /// The wheel, turned up while the newest row waits to show, as rows came within 100 ms of
    /// the last it showed, here as a search for the newest request ends just after its row
    /// showed: the list doesn't go to the newest row once it's time. Then at its end, it follows
    /// again.
    private func checkScrollingUpBeforeAReveal(_ follower: inout Follower) async throws {
        let list = window.list
        let session = try await session()
        let adjustment = try present(gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
        var tries = 0
        var reveals: Int?
        while reveals == nil, tries < 5 {
            tries += 1
            await session.setSearch("n=\(follower.newest.rawValue + 1)")
            try await until("the search to leave no rows", seconds: 5) { list.count == 0 && list.isSettled }
            let before = list.reveals
            try await follower.sendOnly()
            let shown = monotonicMicroseconds() + 2_000_000
            while list.reveals == before, monotonicMicroseconds() < shown {
                try? await Task.sleep(for: .milliseconds(1))
            }
            await session.setSearch("")
            let deadline = monotonicMicroseconds() + 150_000
            while reveals == nil, monotonicMicroseconds() < deadline {
                // Long enough before the reveal for the wheel to reach the window first.
                if let due = list.revealDue, due - monotonicMicroseconds() >= 20_000 {
                    try FakeInput.scrollUp(list.view, notches: 5)
                    reveals = list.reveals
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            try await until("every row to be back", seconds: 10) { list.isSettled }
            if reveals == nil {
                try await follower.waitForNewest("a search that ended")
            }
        }
        let scrolled = try present(reveals, "in \(tries) tries, the newest row never waited its turn to show")
        await settle()
        // GTK may keep the rows it's laying out where they were, wheel or not, but the list
        // doesn't go to its newest row.
        try require(
            list.reveals == scrolled && list.revealDue == nil,
            "scrolled up before the newest row showed, the list showed it \(list.reveals - scrolled) times")
        note("the wheel, turned up as the newest row waited to show (try \(tries)): the list doesn't go to it")
        gtk_adjustment_set_value(
            adjustment, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        await settle()
        try await follower.send(1)
        follower.said = []
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
    /// the list doesn't follow, when it waits for every change to be in. A burst goes on
    /// `connections` at once. `status` gives the status each is answered with, by its place in the
    /// burst, from 1.
    mutating func send(
        _ count: Int, follows: Bool = true, seconds: Int = 15, connections: Int = 8,
        status: (UInt64) -> Int = { _ in 200 }
    ) async throws {
        let (server, client) = (traffic.server, traffic.client)
        let base = newest.rawValue
        let started = monotonicMicroseconds()
        let urls = (1...UInt64(count)).map { place in
            let answer = status(place)
            return server.url(.ok, (answer == 200 ? "" : "status=\(answer)&") + "n=\(base + place)")
        }
        if count == 1 {
            _ = try await client.send(urls[0])
        } else {
            let burst = await client.burst(urls, connections: connections)
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

    /// Sends one request, and waits only for its answer.
    mutating func sendOnly() async throws {
        let base = newest.rawValue
        _ = try await traffic.client.send(traffic.server.url(.ok, "n=\(base + 1)"))
        newest = ExchangeID(rawValue: base + 1)
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
