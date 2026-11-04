import CGtk
import CoreInterface
import Foundation
import GtkBinding
import Presentation
import ReqlyModel

extension SelfCheck {
    /// Parts that run only when `--smoke-parts` names them, as Windows' speed part does: each takes
    /// minutes, and measures rather than checks.
    static let speedParts: [Part] = [
        Part(name: "speed", seconds: 2_100) { try await $0.checkSpeed() }
    ]

    /// How the window keeps up with a live session at the store's limit, 100,000 requests, against
    /// Windows' 80–135 ms and the Mac's 63–70 ms longest wait, as PLAN.md's speed part says. Through
    /// Reqly's proxy, to four servers on 127.0.0.1, to localhost and to hosts that refuse, with
    /// python3 as a second app, it fills the session in bursts of 5,000 requests of many paths,
    /// statuses, sizes and kinds, then sends three more, each of which takes out as many as it puts
    /// in. For each burst, the window's longest wait (``ThreadWatch``), how soon the newest row
    /// shows after the last answer, and how soon the core's rows event brought it. Then, each
    /// apart: a row selected and its details shown while a burst comes; a search typed a character
    /// at a time and cleared; a filter added and taken off; a host chosen in the sidebar and All
    /// Traffic again; the list scrolled from its top to its end, by its scroll bar and a page at a
    /// time; and Clear. Memory at 0, 50,000 and 100,000 requests, after the three bursts and after
    /// Clear. The search runs in a copy of Reqly that fills a session of its own, since the list
    /// can take minutes to show what a search leaves, and every step after it would wait for that:
    /// the copy waits a few minutes at most. Then each body view at sizes either side of the
    /// bodies' inline limit, as the Request page shows it, and as it would without the limit. It
    /// prints a table of each, and fails only when what it measures doesn't happen.
    func checkSpeed() async throws {
        BodyView.chosen = [:]
        defer { BodyView.chosen = [:] }
        let session = try await emptyTheList()
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        gtk_window_set_default_size(cast(window.window), 1280, 760)
        defer { gtk_window_set_default_size(cast(window.window), width, height) }
        try await until("the window to be 1280 pixels wide", seconds: 5) {
            gtk_widget_get_width(self.window.window) > 1260
        }
        let traffic = try await startTraffic()
        var servers = [traffic.server]
        defer { servers.forEach { $0.stop() } }
        for _ in 1..<4 {
            servers.append(try TestServer())
        }
        let meter = SpeedMeter(self, session, client: traffic.client, mix: SpeedMix(servers: servers))
        let isTheSearchsCopy = app.options.sessionLimit == SpeedMeter.searchCopy
        do {
            if isTheSearchsCopy {
                try await meter.measureTheSearch()
            } else {
                try await meter.measureTheList()
                try await meter.measureTheBodies(on: servers[0])
            }
        } catch {
            meter.stop()
            try? await stopTraffic()
            throw error
        }
        meter.stop()
        try await stopTraffic()
        // The copy goes, with its list still showing the search, maybe.
        if !isTheSearchsCopy {
            try await emptyTheList()
        }
    }
}

/// The speed part's measurements, one step at a time, with the window's thread watched all along.
@MainActor
private final class SpeedMeter {
    let check: SelfCheck
    let session: SessionHost
    let client: ProxyClient
    let mix: SpeedMix
    let watch = ThreadWatch()
    let events = RowsEvents()
    /// The newest request sent, whose ID the session gave in order, and how many of the mix's
    /// requests have gone.
    private var newest = ExchangeID(rawValue: 0)
    private var sent = 0
    /// The bursts after which the list didn't show its newest row, as it had stopped following.
    private var unfollowed: [String] = []

    init(_ check: SelfCheck, _ session: SessionHost, client: ProxyClient, mix: SpeedMix) {
        self.check = check
        self.session = session
        self.client = client
        self.mix = mix
        let events = events
        check.model.listen { event in
            guard events.isListening, case .rows(_, _, let shown, let steps) = event else { return }
            events.take(steps, shown: shown)
        }
        watch.start()
    }

    func stop() {
        watch.stop()
        events.isListening = false
    }

    private var window: MainWindow { check.window }
    private var list: RequestList { check.window.list }

    /// The session limit the copy that measures the search is given, which is the store's own, so
    /// it changes nothing but tells the copy what it's for.
    static let searchCopy = 100_000

    // MARK: - The list

    func measureTheList() async throws {
        var table = SpeedTable()
        let check = check
        check.note(
            "the window: \(gtk_widget_get_width(window.window)) × \(gtk_widget_get_height(window.window)) px, the "
                + "details \(adw_navigation_split_view_get_collapsed(window.inner) == 0 ? "beside" : "over") the list; "
                + "\(ProcessInfo.processInfo.activeProcessorCount) processors")
        table.add(SpeedLine(step: "Memory, 0 requests", memory: .now()))

        try await sendAsAnotherApp(1_000)
        var bursts = try await fill(from: 1_000, to: 50_000)
        table.add(SpeedLine(step: "Memory, 50,000 requests", memory: .now()))
        bursts += try await fill(from: 50_000, to: 100_000)
        let full = Memory.now()
        for (index, line) in bursts.enumerated() {
            check.note("filling, burst \(index + 1): \(line.said)")
        }
        table.add(bursts[0].named("Filling: the first burst, 4,000"))
        table.add(SpeedLine.median(of: Array(bursts.dropFirst()), "Filling: bursts 2–20, the median"))
        table.add(SpeedLine.worst(of: Array(bursts.dropFirst()), "Filling: bursts 2–20, the worst"))
        table.add(SpeedLine(step: "Memory, 100,000 requests", memory: full))

        for index in 1...3 {
            let line = try await burst(5_000, "past the limit, burst \(index)")
            try check.require(
                list.count == 100_000 && events.removed == 5_000,
                "past the limit, the list has \(list.count) rows, and \(events.removed) went")
            check.note("past the limit, burst \(index): \(line.said)")
            table.add(line.named("A burst of 5,000 at the limit, \(index)"))
        }
        table.add(SpeedLine(step: "Memory, after 3 bursts at the limit", memory: .now()))
        table.add(try await selectDuringABurst())

        table.add(SpeedLine(step: "Bursts after which the list had stopped following", count: unfollowed.count))
        if !unfollowed.isEmpty {
            check.note("the list had stopped following after: \(unfollowed.joined(separator: "; "))")
        }
        table.add(contentsOf: try await filter())
        table.add(contentsOf: try await chooseAHost())
        table.add(contentsOf: try await scroll())
        table.add(contentsOf: try await clear())

        let copy = try await check.runInCopy(
            ["speed"], options: ["--session-limit", String(Self.searchCopy), "--starts-capturing", "yes"],
            seconds: 900, accessible: true)
        for line in copy where !line.hasSuffix("parts passed") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") {
                table.add(text)
            } else {
                check.note("the search's copy: \(text)")
            }
        }
        check.note("the list, at 100,000 requests (times in ms, memory in MB):")
        for line in [SpeedLine.heading] + table.lines {
            check.note("    \(line)")
        }
    }

    /// In the copy of Reqly that measures the search: a session of 100,000 requests, filled as the
    /// main run fills its own, then the search typed and cleared with the list at its top, and
    /// again at its end, where it is while it follows traffic; the main run takes their table
    /// lines. A list that starts empty can stop following its first burst of thousands, which
    /// isn't what the copy measures, so it waits for each burst's rows rather than for its newest
    /// to show.
    func measureTheSearch() async throws {
        _ = try await fill(from: 0, to: 100_000, showingEach: false)
        let list = list
        let adjustment = try check.present(gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
        for isAtTheEnd in [false, true] {
            let end = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            gtk_adjustment_set_value(adjustment, isAtTheEnd ? end : 0)
            try await check.until("the list to be at its \(isAtTheEnd ? "end" : "top")", seconds: 10) {
                list.isSettled && (isAtTheEnd ? list.showsEnd() : gtk_adjustment_get_value(adjustment) < 1)
            }
            await check.settle()
            for line in try await search("tehran", where: isAtTheEnd ? "the list at its end" : "the list at its top") {
                check.note("\(line)")
            }
        }
    }

    /// Bursts of 5,000 until the session has `end` requests, from `start`, each one's newest row
    /// showing before the next, or with `showingEach` false, its rows in the list.
    private func fill(from start: Int, to end: Int, showingEach: Bool = true) async throws -> [SpeedLine] {
        var lines: [SpeedLine] = []
        var count = start
        while count < end {
            let size = min(5_000, end - count, count % 5_000 == 0 ? 5_000 : 5_000 - count % 5_000)
            lines.append(try await burst(size, "filling, to \(Format.count(count + size))", showing: showingEach))
            count += size
        }
        try check.require(list.count == end, "the list has \(list.count) rows, not \(Format.count(end))")
        return lines
    }

    /// Requests from another app than the self-check, python3, as a desktop has more than one:
    /// `count`, on two connections that stay open until Reqly has named their app, since it names
    /// an app only while its connection is open.
    private func sendAsAnotherApp(_ count: Int) async throws {
        let check = check
        let sidebar = window.sidebar
        let named = check.scratch.appending(path: "named-\(UUID().uuidString)")
        let origin = mix.servers[0].origin
        let started = monotonicMicroseconds()
        let arguments = [String(client.proxyPort), origin, named.path, String(count)]
        let python = Task {
            try await Program.run(["python3", "-I", "-c", Self.pythonRequests] + arguments, seconds: 120)
        }
        // python3 stops waiting once it's there, whatever happens.
        defer { _ = FileManager.default.createFile(atPath: named.path, contents: nil) }
        try await check.until("python3's requests, each with its app", seconds: 90) {
            let apps = sidebar.rows.sections[1].filter(\.isScope)
            return self.list.count == count && apps.contains { $0.count == count }
        }
        let took = (monotonicMicroseconds() - started) / 1000
        _ = FileManager.default.createFile(atPath: named.path, contents: nil)
        let ended = try await python.value
        try check.require(ended.status == 0, "python3's requests ended with \(ended.problem ?? "a problem")")
        newest = try check.present(await session.trafficSummary().newest?.id, "python3's requests have no rows")
        let apps = sidebar.rows.sections[1].filter(\.isScope).map { "\($0.name) \(Format.count($0.count))" }
        check.note("another app: \(apps.joined(separator: ", ")), sent and named in \(took) ms")
    }

    /// `python3 -I -c <this> <proxy port> <server> <file> <count>`: sends `count` requests through
    /// Reqly's proxy on two connections at once, and keeps them open until the file is there, or
    /// a minute.
    private static let pythonRequests = """
        import http.client, os, sys, threading, time
        port, origin, named, count = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
        paths = ["/json?city=tehran&", "/text?", "/v1/weather?", "/v1/forecast?status=404&", "/image.png?"]
        def send(first):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            for n in range(first, count, 2):
                connection.request("GET", "http://%s%sfrom=python&n=%d" % (origin, paths[n % len(paths)], n))
                connection.getresponse().read()
            for _ in range(1200):
                if os.path.exists(named):
                    break
                time.sleep(0.05)
        threads = [threading.Thread(target=send, args=(first,)) for first in (0, 1)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        """

    /// Sends `count` of the mix's requests as fast as Reqly answers, on 8 connections, and waits
    /// for the newest one's row to show, or with `showing` false, to be the list's last, with
    /// `during` run meanwhile: how long the burst took to send, how soon after its last answer the
    /// core's rows event brought its newest request and the row showed, and the window's longest
    /// wait from its start until then.
    private func burst(
        _ count: Int, _ step: String, showing: Bool = true, during: (@MainActor () async throws -> String)? = nil
    ) async throws -> SpeedLine {
        let urls = (sent..<sent + count).map(mix.url)
        sent += count
        newest = ExchangeID(rawValue: newest.rawValue + UInt64(count))
        events.reset(awaiting: newest)
        let client = client
        let started = monotonicMicroseconds()
        let sending = Task { await client.burst(urls) }
        let said = try await during?()
        let burst = await sending.value
        let answered = monotonicMicroseconds()
        try check.require(burst.answered == count, "of \(count), \(burst.answered) were answered: \(burst.problems)")
        let shownAt = try await waitForNewest(step, showing: showing)
        let shown = shownAt ?? monotonicMicroseconds()
        var line = SpeedLine(step: step)
        line.took = (answered - started) / 1000
        line.newest = shownAt.map { ($0 - answered) / 1000 }
        line.core = events.awaitedAt.map { ($0 - answered) / 1000 }
        line.waits = watch.waits(from: started, to: shown)
        let newestWords =
            line.newest.map { "the newest row \($0) ms" }
            ?? "the newest row not shown, as the list had stopped following,"
        line.said =
            "sent in \(line.took ?? 0) ms; the core's rows event \(line.core.map { "\($0) ms" } ?? "never") and "
            + "\(newestWords) after the last answer; \(events.count) rows events, the largest putting in "
            + "\(Format.count(events.largest)), \(Format.count(events.removed)) rows out; "
            + "\(line.waits.map { "\($0)" } ?? "")" + (said.map { "; \($0)" } ?? "")
        return line
    }

    /// Waits until the list's last row is the newest request's, with every change in, and unless
    /// `showing` is false, the row shows whole; then gives when. A list that has stopped following
    /// doesn't show it: then it's noted and brought back to its end, to follow the next, and this
    /// gives `nil`.
    private func waitForNewest(_ step: String, showing: Bool = true, seconds: Int = 60) async throws -> Int? {
        let list = list
        let newest = newest
        let check = check
        do {
            try await check.until("the rows of \(step)", seconds: seconds) {
                list.isSettled && list.exchange(at: list.count - 1) == newest
            }
        } catch {
            let last = list.exchange(at: list.count - 1).map { "#\($0.rawValue)" } ?? "none"
            throw SelfCheck.Failure(
                "after \(step), the newest row, #\(newest.rawValue), isn't the last: the last row is \(last), "
                    + "\(list.count) rows, \(list.isSettled ? "settled" : "still changing")")
        }
        guard showing else { return monotonicMicroseconds() }
        // The list shows its newest row within 100 ms of the last change while it follows.
        do {
            try await check.until("the newest row to show, after \(step)", seconds: 5) {
                list.isSettled && check.rowShows(newest)
            }
            return monotonicMicroseconds()
        } catch {
            unfollowed.append("\(step), the list \(list.showsEnd() ? "at" : "not at") its end")
            let adjustment = try check.present(
                gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
            // As the list goes to its end: GTK places the rows it hasn't laid out by a guess at
            // their height, so the end moves as it lays them out.
            gtk_column_view_scroll_to(cast(list.view), UInt32(list.count - 1), nil, GTK_LIST_SCROLL_NONE, nil)
            try await check.until("the newest row to show once the list is at its end", seconds: 10) {
                gtk_adjustment_set_value(
                    adjustment, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
                return list.isSettled && check.rowShows(newest)
            }
            return nil
        }
    }

    /// While a burst comes, a row near the list's end, a JSON response's, is selected, as a click
    /// selects it, and the details show it on the Response page, with its body.
    private func selectDuringABurst() async throws -> SpeedLine {
        let list = list
        let details = window.details
        details.show(page: .response)
        var line = try await burst(5_000, "a burst while a row is selected") {
            try await Task.sleep(for: .milliseconds(100))
            let rows = max(0, list.count - 20)..<list.count
            let chosen = try self.check.present(
                rows.reversed().compactMap { list.summary(at: $0) }.first {
                    $0.contentType?.contains("json") == true && $0.bytesReceived > 0
                }?.id, "no row near the end is a JSON response")
            let started = monotonicMicroseconds()
            list.select(id: chosen)
            try await self.check.until("the details to show the row's response", seconds: 30) {
                details.shown == chosen && details.isBuilt(.response)
                    && details.bodies[.response].map(Self.isReady) == true
            }
            let took = (monotonicMicroseconds() - started) / 1000
            let waits = self.watch.waits(from: started)
            return "the details showed #\(chosen.rawValue)'s response, its body formatted, \(took) ms after it was "
                + "selected, \(waits)"
        }
        line.step = "A row selected, and its details shown, during a burst"
        list.select(id: nil)
        await check.settle()
        details.show(page: .overview)
        check.note("selected during a burst: \(line.said)")
        return line
    }

    /// Types `word` in the search bar a character at a time, 200 ms apart, as you'd type it, so
    /// the list's own match runs for each, and the store's from the third, 150 ms after; then
    /// closes the bar, which clears it, and every row comes back. `place` says where the list is.
    private func search(_ word: String, where place: String) async throws -> [SpeedLine] {
        let check = check
        let search = window.search
        search.open()
        await check.settle()
        let started = monotonicMicroseconds()
        var lastKey = started
        events.reset()
        for count in 1...word.count {
            if count > 1 {
                try await Task.sleep(for: .milliseconds(200))
            }
            lastKey = monotonicMicroseconds()
            gtk_editable_set_text(cast(search.entry), String(word.prefix(count)))
        }
        let settledAt = try await settled(since: lastKey, quiet: 1_000, seconds: 240)
        let end = settledAt ?? monotonicMicroseconds()
        var typed = SpeedLine(step: "Search typed, “\(word)”, a character every 200 ms, \(place)")
        typed.took = settledAt.map { ($0 - lastKey) / 1000 }
        typed.over = settledAt == nil ? (end - lastKey) / 1000 : nil
        typed.waits = watch.waits(from: started, to: end)
        let after = events.times.filter { $0 > lastKey }
        let first = after.first.map { "\(($0 - lastKey) / 1000) ms" } ?? "no change"
        let last = after.count > 1 ? after.last.map { "\(($0 - lastKey) / 1000) ms" } ?? "" : "no change"
        typed.said =
            "after the last character: the list's own match \(first), the store's \(last); "
            + (settledAt == nil
                ? "not settled \((end - lastKey) / 1000) ms after, showing \(Format.count(list.count)) rows of the "
                    + "\(Format.count(events.shown)) it leaves"
                : "\(Format.count(list.count)) rows shown, all in \(typed.took ?? 0) ms")
            + "; \(events.count) rows events while typing, in \(Format.count(events.runs)) runs; "
            + "\(typed.waits.map { "\($0)" } ?? "")"
        check.note("search, \(place): \(typed.said)")

        let cleared = monotonicMicroseconds()
        events.reset()
        search.close()
        let back = try await settled(since: cleared, seconds: settledAt == nil ? 60 : 240)
        let clearedEnd = back ?? monotonicMicroseconds()
        var clearing = SpeedLine(step: "Search cleared, every row back, \(place)")
        clearing.took = back.map { ($0 - cleared) / 1000 }
        clearing.over = back == nil ? (clearedEnd - cleared) / 1000 : nil
        clearing.waits = watch.waits(from: cleared, to: clearedEnd)
        clearing.said =
            "\(events.count) rows events, \(events.resets) of them every row, in \(Format.count(events.runs)) runs, "
            + (back == nil
                ? "not settled \((clearedEnd - cleared) / 1000) ms after, as the search's rows still go in"
                : "settled in \(clearing.took ?? 0) ms")
        check.note("search cleared, \(place): \(clearing.said); \(clearing.waits.map { "\($0)" } ?? "")")
        if back != nil {
            try check.require(list.count == 100_000, "after the search, the list has \(list.count) rows")
        }
        return [typed, clearing]
    }

    /// 4xx, a status button, on and then off, as a click toggles it.
    private func filter() async throws -> [SpeedLine] {
        let button = try check.present(window.filters.statusButtons[.clientError], "there's no 4xx button")
        let lines = [
            try await change("Filter added, 4xx") { gtk_toggle_button_set_active(cast(button), 1) },
            try await change("Filter taken off") { gtk_toggle_button_set_active(cast(button), 0) },
        ]
        try check.require(list.count == 100_000, "after the filter, the list has \(list.count) rows")
        return lines
    }

    /// The sidebar's localhost, then All Traffic again, as choosing each row does.
    private func chooseAHost() async throws -> [SpeedLine] {
        let sidebar = window.sidebar
        let host = try check.present(
            sidebar.rows.all.first { $0.kind == .host && $0.name == "localhost" }, "the sidebar has no localhost")
        let lines = [
            try await change("Sidebar: localhost chosen") { sidebar.choose(host.key) },
            try await change("Sidebar: All Traffic again") { sidebar.choose("all") },
        ]
        try check.require(list.count == 100_000, "after All Traffic, the list has \(list.count) rows")
        return lines
    }

    /// Makes a change to what the list shows, and waits for the list to settle with it.
    private func change(_ step: String, _ body: () -> Void) async throws -> SpeedLine {
        let started = monotonicMicroseconds()
        events.reset()
        body()
        let done = try check.present(
            try await settled(since: started, seconds: 900), "after “\(step)”, the list didn't settle in 900 s")
        var line = SpeedLine(step: step)
        line.took = (done - started) / 1000
        line.waits = watch.waits(from: started, to: done)
        line.said = "\(Format.count(list.count)) rows, \(events.count) rows events in \(Format.count(events.runs)) runs"
        check.note("\(step): \(line.said), in \(line.took ?? 0) ms; \(line.waits.map { "\($0)" } ?? "")")
        return line
    }

    /// The list from its top to its end: by its scroll bar, dragged down in 2 seconds, a step a
    /// frame; then from its top a page at a time, 300 pages, one a frame, as Page Down held does.
    private func scroll() async throws -> [SpeedLine] {
        let check = check
        let list = list
        let adjustment = try check.present(gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
        var lines: [SpeedLine] = []
        for (step, frames) in [("Scrolled by the scroll bar, top to end in 120 frames", 120), ("300 pages down", 300)] {
            gtk_adjustment_set_value(adjustment, 0)
            try await check.until("the list to be at its top", seconds: 10) {
                list.isSettled && gtk_adjustment_get_value(adjustment) < 1
            }
            await check.settle()
            let byPages = frames == 300
            let scrolling = Scrolling()
            let started = monotonicMicroseconds()
            tick(list.view) { clock in
                scrolling.frames.append(Int(gdk_frame_clock_get_frame_time(clock)))
                let page = gtk_adjustment_get_page_size(adjustment)
                let end = gtk_adjustment_get_upper(adjustment) - page
                guard scrolling.step < frames else {
                    scrolling.isDone = true
                    return false
                }
                scrolling.step += 1
                let value = byPages ? Double(scrolling.step) * page : end * Double(scrolling.step) / Double(frames)
                gtk_adjustment_set_value(adjustment, min(end, value))
                return true
            }
            try await check.until("the scrolling to end", seconds: 120) { scrolling.isDone }
            let scrolled = monotonicMicroseconds()
            try await check.until("the rows to show", seconds: 30) { list.isSettled }
            let done = monotonicMicroseconds()
            var line = SpeedLine(step: step)
            line.took = (scrolled - started) / 1000
            line.waits = watch.waits(from: started, to: done)
            let gaps = zip(scrolling.frames.dropFirst(), scrolling.frames).map { ($0 - $1) / 1000 }
            line.said =
                "\(frames) frames in \(line.took ?? 0) ms, \(gaps.isEmpty ? 0 : gaps.reduce(0, +) / gaps.count) ms a "
                + "frame, the longest \(gaps.max() ?? 0) ms; the rows filled in \((done - scrolled) / 1000) ms after; "
                + "the first row \(list.exchange(at: 0).map { "#\($0.rawValue)" } ?? "none"), at "
                + "\(Int(gtk_adjustment_get_value(adjustment))) of \(Int(gtk_adjustment_get_upper(adjustment))) px"
            lines.append(line)
            check.note("\(step): \(line.said); \(line.waits.map { "\($0)" } ?? "")")
        }
        return lines
    }

    /// Clear Traffic, as Ctrl+K does, with 100,000 requests, then memory once it's done, a few
    /// seconds after, and once malloc has given back what it kept.
    private func clear() async throws -> [SpeedLine] {
        let check = check
        let list = list
        let started = monotonicMicroseconds()
        events.reset()
        g_action_group_activate_action(cast(window.window), "clear", nil)
        try await check.until("the list to be empty", seconds: 60) { list.count == 0 && list.isSettled }
        let done = monotonicMicroseconds()
        var line = SpeedLine(step: "Clear, 100,000 requests")
        line.took = (done - started) / 1000
        line.waits = watch.waits(from: started, to: done)
        line.said = "\(events.count) rows events, \(Format.count(events.removed)) rows out"
        check.note("clear: \(line.said), in \(line.took ?? 0) ms; \(line.waits.map { "\($0)" } ?? "")")
        line.memory = .now()
        try await Task.sleep(for: .seconds(5))
        let later = SpeedLine(step: "Memory, 5 s after Clear", memory: .now())
        // What malloc keeps for later, apart from what's still in use.
        guard Memory.trim() else { return [line, later] }
        return [line, later, SpeedLine(step: "Memory, then malloc_trim(0)", memory: .now())]
    }

    /// Waits for the rows events a change since `start` set off to end, and the list to settle with
    /// them: until it has settled and no event has come for `quiet` milliseconds, for at most
    /// `seconds`. Gives when it settled, after the last event, or `nil` when it hadn't by then.
    private func settled(since start: Int, quiet: Int = 500, seconds: Int) async throws -> Int? {
        let list = list
        let events = events
        var settledAt: Int?
        var latest = events.latest
        let limit = monotonicMicroseconds() + seconds * 1_000_000
        while monotonicMicroseconds() < limit {
            try Task.checkCancellation()
            let now = monotonicMicroseconds()
            if events.latest != latest {
                latest = events.latest
                settledAt = nil
            }
            if !list.isSettled {
                settledAt = nil
            } else if settledAt == nil {
                settledAt = now
            }
            if let settledAt, now - max(latest, start) >= quiet * 1000 {
                return settledAt
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        check.note(
            "unsettled after \((monotonicMicroseconds() - start) / 1000) ms: \(Format.count(list.count)) rows, "
                + "\(events.count) rows events in \(Format.count(events.runs)) runs, the latest "
                + "\((monotonicMicroseconds() - events.latest) / 1000) ms ago")
        return nil
    }

    // MARK: - The bodies

    /// JSON and text bodies either side of the inline limit, sent as requests' bodies: each in each
    /// of its views as the Request page shows it, from the row's selection to the view ready, with
    /// the window's longest wait; and each code view's text as it would show without the limit, in
    /// a page as wide as the details' own.
    func measureTheBodies(on server: TestServer) async throws {
        let check = check
        let details = window.details
        let bodies = Self.bodies
        let before = await session.trafficSummary().newest?.id.rawValue ?? 0
        for body in bodies {
            _ = try await client.send(
                server.url(.ok, "body=\(body.name)"), method: "POST", headers: [("Content-Type", body.type)],
                body: body.bytes)
        }
        let names = Set(bodies.map(\.name))
        var ids: [String: ExchangeID] = [:]
        try await check.until("the bodies' requests", seconds: 30) {
            for row in 0..<self.list.count {
                guard let summary = self.list.summary(at: row), summary.id.rawValue > before,
                    summary.state == .completed,
                    let name = summary.target.split(separator: "body=").last.map(String.init), names.contains(name)
                else { continue }
                ids[name] = summary.id
            }
            return ids.count == bodies.count
        }
        try await check.stopTraffic()

        // GtkSourceView and the monospace font load with the run's first code view.
        details.show(page: .request)
        let warm = try check.present(ids[bodies[0].name], "no first body")
        check.window.list.select(id: warm)
        try await check.until("the first code view", seconds: 30) {
            details.bodies[.request].map(Self.isReady) == true
        }
        let page = try await BodyPage.open(over: window.window)
        defer { page.close() }
        let room = gtk_widget_get_width(try check.present(details.contents[.request], "no Request page"))
        page.resize(width: room + 24)
        check.note("the bodies: the Request page's box is \(room) px wide, and so is the page without the limit")

        var lines: [BodyLine] = []
        for body in bodies {
            let id = try check.present(ids[body.name], "no \(body.name) request")
            let presented = try await session.presentBody(id, part: .request).body
            for mode in presented.modes where [BodyMode.formatted, .raw, .tree, .hex].contains(mode) {
                var line = BodyLine(body: body.title, view: BodyWords.title(of: mode, in: presented))
                let shipped = try await showAsShipped(id, mode)
                (line.shipped, line.shippedTook, line.shippedWaits) = (shipped.shows, shipped.took, shipped.waits)
                if mode == .formatted || mode == .raw,
                    let code = mode == .formatted ? presented.formatted ?? presented.raw : presented.raw
                {
                    let uncut = try await showUncut(code, on: page)
                    (line.uncut, line.uncutTook, line.uncutWaits) = (uncut.shows, uncut.took, uncut.waits)
                }
                check.note("    \(line.said)")
                lines.append(line)
            }
        }
        check.window.list.select(id: nil)
        details.show(page: .overview)
        check.note("the bodies (times in ms):")
        for text in BodyLine.table(lines) {
            check.note("    \(text)")
        }
        for limit in [70, 135] {
            let fitting = lines.filter { ($0.uncutWaits?.longest ?? .infinity) <= Double(limit) }
            check.note(
                "without the limit, the longest wait is \(limit) ms or less for: "
                    + fitting.map { "\($0.body), \($0.view)" }.joined(separator: "; "))
        }
    }

    /// Selects `id`'s row, with `mode` chosen for request bodies, and waits for the Request page's
    /// body to be ready in it: what shows, how long it took, and the window's waits until it settled.
    private func showAsShipped(
        _ id: ExchangeID, _ mode: BodyMode
    ) async throws -> (shows: String, took: Int, waits: ThreadWatch.Waits) {
        let check = check
        let list = list
        let details = window.details
        BodyView.chosen[.request] = mode
        list.select(id: nil)
        await check.settle()
        let started = monotonicMicroseconds()
        list.select(id: id)
        try await check.until("the request's body in its view", seconds: 120) {
            details.shown == id && details.bodies[.request].map { $0.mode == mode && Self.isReady($0) } == true
        }
        let ready = monotonicMicroseconds()
        await check.settle()
        let view = try check.present(details.bodies[.request], "no body view")
        let shows: String
        switch view.views[mode] {
        case let holder as CodeHolder:
            let text = try check.present(holder.code?.text, "no code")
            shows = text.isCut ? "\(Format.count(text.shownLines)) of \(Format.count(text.lines)) lines" : "all"
        case let tree as TreeView: shows = "\(Format.count(tree.rowCount)) rows"
        case let hex as HexView: shows = "\(hex.shownLines.count) lines read"
        default: shows = ""
        }
        return (shows, (ready - started) / 1000, watch.waits(from: started))
    }

    /// `code` as the page would show it without the limit: laid out away from the window, then in
    /// a code view on `page`, until it's in its buffer and colored.
    private func showUncut(
        _ code: BodyPresentation.Code, on page: BodyPage
    ) async throws -> (shows: String, took: Int, waits: ThreadWatch.Waits) {
        let started = monotonicMicroseconds()
        let text = await Task.detached(priority: .userInitiated) {
            CodeText(code, lineLimit: .max, byteLimit: .max)
        }.value
        let laidOut = monotonicMicroseconds()
        let view = CodeView(text)
        gtk_box_append(cast(page.box), view.widget)
        defer { gtk_box_remove(cast(page.box), view.widget) }
        try await check.until("the whole text in a code view", seconds: 120) { view.isFilled }
        let ready = monotonicMicroseconds()
        await page.settle()
        let shows = "\(Format.count(text.lines)) lines, laid out in \((laidOut - started) / 1000) ms"
        return (shows, (ready - started) / 1000, watch.waits(from: laidOut))
    }

    /// Whether a body view's mode is ready: code in its buffer and colored, a tree with rows, hex
    /// lines with their bytes.
    private static func isReady(_ view: BodyView) -> Bool {
        guard let mode = view.mode, let made = view.views[mode] else { return view.mode == nil }
        switch made {
        case let holder as CodeHolder: return holder.code?.isFilled == true
        case let tree as TreeView: return tree.rowCount > 0
        case let hex as HexView: return !hex.shownLines.isEmpty && !hex.isReading
        default: return true
        }
    }

    /// The bodies, by size and by lines: JSON on one line, as APIs send it, each item eight lines
    /// formatted, and text in lines of 62 characters.
    private static let bodies: [SpeedBody] = {
        var bodies: [SpeedBody] = []
        for kilobytes in [64, 256, 512, 1_024] {
            bodies.append(SpeedBody(json: SpeedBody.forecasts(bytes: kilobytes << 10), "JSON, \(size(kilobytes))"))
        }
        for lines in [1_000, 5_000, 20_000] {
            bodies.append(
                SpeedBody(json: SpeedBody.forecasts(items: lines / 8), "JSON, \(Format.count(lines)) lines formatted"))
        }
        for kilobytes in [64, 256, 512, 1_024] {
            bodies.append(SpeedBody(text: SpeedBody.text(bytes: kilobytes << 10), "Text, \(size(kilobytes))"))
        }
        for lines in [1_000, 5_000, 20_000] {
            bodies.append(SpeedBody(text: SpeedBody.text(bytes: lines * 63), "Text, \(Format.count(lines)) lines"))
        }
        return bodies
    }()

    private static func size(_ kilobytes: Int) -> String {
        kilobytes >= 1_024 ? "\(kilobytes / 1_024) MB" : "\(kilobytes) KB"
    }
}

/// The rows events the speed part hears, since its latest step began.
@MainActor
private final class RowsEvents {
    var isListening = true
    /// The request whose rows event a burst waits for, and when it came, in monotonic
    /// microseconds.
    private(set) var awaited: ExchangeID?
    private(set) var awaitedAt: Int?
    /// How many came, how many rows they put in at most and took out in all, in how many runs of
    /// neighbors, which the list splices one at a time, how many brought every row, and when the
    /// first and the latest came.
    private(set) var count = 0
    private(set) var largest = 0
    private(set) var removed = 0
    private(set) var runs = 0
    private(set) var resets = 0
    private(set) var times: [Int] = []
    private(set) var latest = 0
    /// How many rows the session shows, as the latest event said.
    private(set) var shown = 0

    func reset(awaiting id: ExchangeID? = nil) {
        awaited = id
        awaitedAt = nil
        count = 0
        largest = 0
        removed = 0
        runs = 0
        resets = 0
        times = []
    }

    func take(_ steps: [RowStep], shown: Int) {
        let now = monotonicMicroseconds()
        self.shown = shown
        count += 1
        times.append(now)
        latest = now
        for step in steps {
            switch step {
            case .inserted(let rows):
                largest = max(largest, rows.count)
                runs += Self.runs(rows.map(\.row))
                if awaitedAt == nil, let awaited, rows.contains(where: { $0.id == awaited }) {
                    awaitedAt = now
                }
            case .removed(let rows):
                removed += rows.count
                runs += Self.runs(rows)
            case .reset(let ids):
                resets += 1
                runs += 1
                largest = max(largest, ids.count)
                if awaitedAt == nil, let awaited, ids.last == awaited || ids.contains(awaited) {
                    awaitedAt = now
                }
            case .changed:
                break
            }
        }
    }

    /// How many runs of neighbors `rows` has.
    private static func runs(_ rows: [Int]) -> Int {
        let sorted = rows.sorted()
        return zip(sorted.dropFirst(), sorted).reduce(sorted.isEmpty ? 0 : 1) { $0 + ($1.0 == $1.1 + 1 ? 0 : 1) }
    }
}

/// Where a scroll a frame at a time has got to.
@MainActor
private final class Scrolling {
    var step = 0
    var isDone = false
    /// Each frame's time, in the frame clock's microseconds.
    var frames: [Int] = []
}

/// The requests the speed part sends, the same in every run: a thousand at a time, in the same
/// shares, to four servers on 127.0.0.1 by their ports, to localhost and to 40 hosts on
/// 127.0.0.x that refuse, with each request's number in its query.
private struct SpeedMix: Sendable {
    let servers: [TestServer]

    /// The `n`th request's URL.
    func url(_ n: Int) -> String {
        let server = servers[n % servers.count]
        let base = "http://\(server.origin)"
        // Each thousand in another order, with the same shares.
        let pick = (n * 7_919) % 1_000
        var share = 0
        for (size, target) in Self.shares {
            share += size
            if pick < share {
                return target(base, server, n)
            }
        }
        return "\(base)/ok?n=\(n)"
    }

    /// Each kind of request, by how many of each thousand: JSON, a form, a picture and the rest
    /// of what the server answers; bodies of 2, 24 and 64 KB; 302, 401, 404, 500 and 503; some
    /// waiting 15 ms; ones that fail, and ones to localhost.
    private static let shares: [(Int, @Sendable (String, TestServer, Int) -> String)] = [
        (170, { base, _, n in "\(base)/json?city=tehran&n=\(n)" }),
        (100, { base, _, n in "\(base)/api/v2/users/\(n % 997)?n=\(n)" }),
        (70, { base, _, n in "\(base)/cookies?n=\(n)" }),
        (50, { base, _, n in "\(base)/me?n=\(n)" }),
        (60, { base, _, n in "\(base)/gzip?n=\(n)" }),
        (60, { base, _, n in "\(base)/image.png?n=\(n)" }),
        (40, { base, _, n in "\(base)/xml?n=\(n)" }),
        (40, { base, _, n in "\(base)/html?n=\(n)" }),
        (50, { base, _, n in "\(base)/text?n=\(n)" }),
        (30, { base, _, n in "\(base)/form?n=\(n)" }),
        (20, { base, _, n in "\(base)/multipart?n=\(n)" }),
        (60, { base, _, n in "\(base)/big?bytes=2048&n=\(n)" }),
        (20, { base, _, n in "\(base)/big?bytes=24576&n=\(n)" }),
        (5, { base, _, n in "\(base)/big?bytes=65536&n=\(n)" }),
        (30, { base, _, n in "\(base)/static/app-\(n % 31).js?status=302&n=\(n)" }),
        (25, { base, _, n in "\(base)/v1/forecast/\(n % 1_009)?status=404&n=\(n)" }),
        (10, { base, _, n in "\(base)/v1/upload?status=500&n=\(n)" }),
        (10, { base, _, n in "\(base)/v1/upload?status=503&n=\(n)" }),
        (15, { base, _, n in "\(base)/v1/sign-in?status=302&n=\(n)" }),
        (20, { base, _, n in "\(base)/v1/live?ms=15&n=\(n)" }),
        (30, { _, _, n in "http://127.0.0.\(2 + n % 40):1/v1/ping?n=\(n)" }),
        (85, { _, server, n in "http://localhost:\(server.port)/json?city=tehran&n=\(n)" }),
    ]
}

/// A body the speed part shows: its name in the request's query, its title, its type and bytes.
private struct SpeedBody: Sendable {
    var name: String
    var title: String
    var type: String
    var bytes: [UInt8]

    init(json bytes: [UInt8], _ title: String) {
        self.init(title, type: "application/json", bytes)
    }

    init(text bytes: [UInt8], _ title: String) {
        self.init(title, type: "text/plain", bytes)
    }

    private init(_ title: String, type: String, _ bytes: [UInt8]) {
        name = title.lowercased().filter { $0.isLetter || $0.isNumber }
        self.title = title
        self.type = type
        self.bytes = bytes
    }

    /// Forecasts in a JSON array on one line, about `bytes` of them, or `items`.
    static func forecasts(bytes: Int = .max, items: Int = .max) -> [UInt8] {
        var text = "["
        var item = 0
        while text.utf8.count < bytes - 120, item < items {
            if item > 0 {
                text += ","
            }
            text +=
                #"{"id":\#(item),"name":"item \#(item)","sky":"clear","high":\#(item % 40),"rain":false,"wind":null}"#
            item += 1
        }
        return Array((text + "]").utf8)
    }

    /// Lines of text, 62 characters and a line break each, to about `bytes`.
    static func text(bytes: Int) -> [UInt8] {
        let line = Array("The quick brown fox jumps over the lazy dog, again and again..\n".utf8)
        return (0..<bytes).map { line[$0 % line.count] }
    }
}

/// A step's measurements: what it took, in milliseconds, and the window's waits meanwhile, or
/// memory, with a few words on what it found.
private struct SpeedLine: CustomStringConvertible {
    var step: String
    /// How long the step took: a burst's sending, or until the list settled; or, for a step that
    /// hadn't settled, how long it was given.
    var took: Int?
    var over: Int?
    /// From a burst's last answer to its newest row showing, and to the core's rows event that
    /// brought it.
    var newest: Int?
    var core: Int?
    var waits: ThreadWatch.Waits?
    var memory: Memory?
    /// How many times something happened, for a step that counts.
    var count: Int?
    var said = ""

    func named(_ step: String) -> SpeedLine {
        var line = self
        line.step = step
        return line
    }

    /// Each number the median of `lines`', the window's longest wait too.
    static func median(of lines: [SpeedLine], _ step: String) -> SpeedLine {
        func middle(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
        var line = SpeedLine(step: step)
        line.took = middle(lines.compactMap(\.took))
        line.newest = middle(lines.compactMap(\.newest))
        line.core = middle(lines.compactMap(\.core))
        let waits = lines.compactMap(\.waits).sorted { $0.longest < $1.longest }
        line.waits = waits.isEmpty ? nil : waits[waits.count / 2]
        return line
    }

    /// Each number the worst of `lines`'.
    static func worst(of lines: [SpeedLine], _ step: String) -> SpeedLine {
        var line = SpeedLine(step: step)
        line.took = lines.compactMap(\.took).max()
        line.newest = lines.compactMap(\.newest).max()
        line.core = lines.compactMap(\.core).max()
        let waits = lines.compactMap(\.waits)
        if var worst = waits.max(by: { $0.longest < $1.longest }) {
            worst.over100 = waits.map(\.over100).max() ?? 0
            line.waits = worst
        }
        return line
    }

    static let heading =
        "| Step | Took | Newest row | Core's rows event | Longest wait | Waits over 100 ms | VmRSS / VmHWM, RssAnon | "
        + "Against the targets |"

    /// Where the window's longest wait stands against the Mac's 63–70 ms and Windows' 80–135 ms.
    var standing: String {
        guard let longest = waits?.longest else { return "" }
        return longest <= 70 ? "within the Mac's" : longest <= 135 ? "within Windows'" : "over both"
    }

    var description: String {
        let cells: [String] = [
            step,
            took.map { Format.count($0) } ?? over.map { "over \(Format.count($0))" } ?? count.map { "\($0)" } ?? "",
            newest.map { Format.count($0) } ?? "",
            core.map { Format.count($0) } ?? "", waits.map { String(format: "%.0f", $0.longest) } ?? "",
            waits.map { "\($0.over100)" } ?? "", memory.map { "\($0)" } ?? "", standing,
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }
}

/// The speed part's table of the list's steps, as its rows are written.
private struct SpeedTable {
    private(set) var lines: [String] = []

    mutating func add(_ line: SpeedLine) {
        lines.append(line.description)
    }

    mutating func add(contentsOf more: [SpeedLine]) {
        lines += more.map(\.description)
    }

    /// A row as the search's copy wrote it.
    mutating func add(_ row: String) {
        lines.append(row)
    }
}

/// A body in one view: what the Request page shows, and the code without the limit.
private struct BodyLine {
    var body: String
    var view: String
    var shipped = ""
    var shippedTook = 0
    var shippedWaits: ThreadWatch.Waits?
    var uncut = ""
    var uncutTook: Int?
    var uncutWaits: ThreadWatch.Waits?

    var said: String {
        let uncutWords = uncutTook.map { took in
            "; without the limit, \(uncut), ready in \(took) ms, \(uncutWaits.map { "\($0)" } ?? "")"
        }
        return "\(body), \(view): \(shipped), ready in \(shippedTook) ms, \(shippedWaits.map { "\($0)" } ?? "")"
            + (uncutWords ?? "")
    }

    static func table(_ lines: [BodyLine]) -> [String] {
        ["| Body | View | Shows | Ready | Longest wait | Without the limit | Ready | Longest wait |"]
            + lines.map { line in
                let cells = [
                    line.body, line.view, line.shipped, Format.count(line.shippedTook),
                    line.shippedWaits.map { String(format: "%.0f", $0.longest) } ?? "", line.uncut,
                    line.uncutTook.map { Format.count($0) } ?? "",
                    line.uncutWaits.map { String(format: "%.0f", $0.longest) } ?? "",
                ]
                return "| " + cells.joined(separator: " | ") + " |"
            }
    }
}

/// This process's memory, from /proc/self/status: resident now, and at most so far, and of what's
/// resident, how much is the process's own, rather than files' or memory shared with the X server.
private struct Memory: CustomStringConvertible {
    /// In kilobytes.
    var resident: Int
    var peak: Int
    var anonymous: Int

    static func now() -> Memory {
        let status = (try? String(contentsOfFile: "/proc/self/status", encoding: .utf8)) ?? ""
        func kilobytes(_ name: String) -> Int {
            let line = status.split(separator: "\n").first { $0.hasPrefix(name + ":") } ?? ""
            return Int(line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first ?? "") ?? 0
        }
        return Memory(resident: kilobytes("VmRSS"), peak: kilobytes("VmHWM"), anonymous: kilobytes("RssAnon"))
    }

    /// Gives malloc's free memory back to the system, as `malloc_trim(0)` does, so what stays
    /// resident after is memory still in use, not memory malloc keeps for later.
    static func trim() -> Bool {
        typealias Trim = @convention(c) (Int) -> Int32
        guard let trim = Newer.lookup("malloc_trim", as: Trim.self) else { return false }
        _ = trim(0)
        return true
    }

    var description: String {
        "\(resident / 1_024) / \(peak / 1_024), \(anonymous / 1_024)"
    }
}
