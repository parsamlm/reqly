#if DEBUG
    import AppKit
    import Capture
    import Darwin
    import Foundation
    import ReqlyModel
    import Synchronization

    /// Measures how well the main thread keeps up with traffic, as `-perfLog path` asks, in debug
    /// builds and perf builds only. It writes one JSON object per line, each with a `kind`:
    ///
    /// - `header`: the Mac's state when it started, such as the screen's refresh rate.
    /// - `tick`, every second: main-thread and process CPU, memory, how long the main thread took
    ///   to answer, the rows, and whether the window was covered.
    /// - `stall`: each time the main thread took more than 50 ms to answer.
    /// - `batch`: each change from the session, with how long applying it, filtering, updating the
    ///   table and settling took, and how long its new requests waited to show up.
    /// - `counts`: each time the counts were shown, with how long that took to settle. For new
    ///   traffic that's a frame after its rows, so a `batch` line's settling leaves them out.
    /// - `action`, `scroll`: the timed steps `-perfAt` runs.
    /// - `search`, `inspector`: each search of the store, and each request the detail pane loaded.
    /// - `final`: the totals, as Reqly quits.
    ///
    /// Times are in milliseconds. "Settle" ends when the main thread is about to sleep again, after
    /// SwiftUI, AppKit and Core Animation have done their part.
    enum PerfProbe {
        /// What the watchdog's thread reads: the main thread keeps it up to date.
        nonisolated struct Shared: Sendable {
            var rows = 0
            var visible = 0
            var isOccluded = false
            /// Whether Reqly was the active app. AppKit does more for each change while it is.
            var isActive = false
            /// What the main thread was last doing, for `stall` lines.
            var context = "launch"
        }

        nonisolated static let shared = Mutex(Shared())
        /// The list, for the scroll steps and to see whether its window is covered.
        static weak var table: NSTableView?

        private static var log: PerfLog?
        private static var watchdog: PerfWatchdog?
        private static var activity: (any NSObjectProtocol)?
        private static var batchCount = 0
        private static var peakRows = 0
        /// How long the list's last filtering took.
        private static var lastRefilter: Duration?
        /// How long the table's updates took since the last batch settled, and whether they only
        /// added rows.
        private static var tableTime: Duration?
        private static var tableGrew = true
        /// The sequences `-perfAt` started, one after another.
        private static var sequence: Task<Void, Never>?
        private static var isRunningSequence = false
        /// The store search the timed steps wait for, and when it filtered the list.
        private static var awaitedSearch: (query: String, found: ContinuousClock.Instant?)?

        /// Starts measuring if `-perfLog` asks.
        static func start(traffic: TrafficListModel) {
            let defaults = UserDefaults.standard
            guard let path = defaults.string(forKey: DefaultsKey.perfLog), let log = PerfLog(path: path) else {
                return
            }
            self.log = log
            // So App Nap and timer coalescing don't slow Reqly down while it's measured.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Measuring how Reqly keeps up")
            let process = ProcessInfo.processInfo
            log.write([
                ("kind", "header"),
                ("bundleID", .text(Bundle.main.bundleIdentifier ?? "")),
                ("pid", .int(Int(process.processIdentifier))),
                ("thermalState", .int(process.thermalState.rawValue)),
                ("lowPowerMode", .bool(process.isLowPowerModeEnabled)),
                ("framesPerSecond", .int(NSScreen.main?.maximumFramesPerSecond ?? 0)),
                ("perfAt", .text(defaults.string(forKey: DefaultsKey.perfAt) ?? "")),
                ("search", .text(traffic.searchText)),
            ])
            let watchdog = PerfWatchdog(log: log, mainThread: pthread_mach_thread_np(pthread_self()))
            watchdog.qualityOfService = .userInteractive
            watchdog.name = "Reqly perf watchdog"
            watchdog.start()
            self.watchdog = watchdog
        }

        /// Writes the totals and closes the log, as Reqly quits.
        static func finish() {
            guard let log else { return }
            watchdog?.cancel()
            var line: PerfLine = [("kind", "final"), ("batches", .int(batchCount)), ("peakRows", .int(peakRows))]
            line += watchdog?.totals() ?? []
            log.write(line)
            log.close()
            self.log = nil
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
            }
        }

        // MARK: - Hooks

        /// After the list applied a change from the session. Its `batch` line is written once the
        /// main thread has shown the change and is idle again.
        static func applied(
            _ change: SessionChange, rowsBefore: Int, started: ContinuousClock.Instant, traffic: TrafficListModel
        ) {
            let applied = ContinuousClock.now
            let rows = traffic.all.count
            let described: (kind: String, size: Int, removed: Int)? =
                switch change {
                case .updated(let summaries, let removed): ("updated", summaries.count, removed.count)
                case .cleared: ("cleared", 0, 0)
                case .storageProblem, .paused: nil
                }
            guard let log, let described else { return }
            let kind = described.kind
            batchCount += 1
            let number = batchCount
            peakRows = max(peakRows, rows)
            let isOccluded = !(table?.window?.occlusionState.contains(.visible) ?? false)
            let isActive = NSApp.isActive
            shared.withLock {
                $0.rows = rows
                $0.visible = traffic.rows.count
                $0.isOccluded = isOccluded
                $0.isActive = isActive
                $0.context = "batch at \(rows) rows"
            }
            // How long the new requests took to show up, from when they started. They're at the
            // end, and the ones they replaced past the session's size limit were at the start.
            let now = Date.now
            let added = kind == "updated" ? min(described.size, rows - rowsBefore + described.removed) : 0
            let delays =
                added > 0
                ? traffic.all[(rows - added)..<rows].map { now.timeIntervalSince($0.started) * 1000 }.sorted() : []
            var batch: PerfLine = [
                ("kind", "batch"),
                ("change", .text(kind)),
                ("size", .int(described.size)),
                ("removed", .int(described.removed)),
                ("rows", .int(rows)),
                ("new", .int(rows - rowsBefore)),
                ("visible", .int(traffic.rows.count)),
                ("apply_ms", .milliseconds(applied - started)),
                ("refilter_ms", lastRefilter.map(PerfValue.milliseconds) ?? .null),
                ("selected", .bool(traffic.selection != nil)),
                ("searching", .bool(!traffic.query.isEmpty)),
                ("active", .bool(isActive)),
            ]
            if !delays.isEmpty {
                batch += [("delay_p50_ms", .number(percentile(delays, 0.5))), ("delay_max_ms", .number(delays.last!))]
            }
            lastRefilter = nil
            Task { [batch] in
                let idle = await untilIdle()
                var line = batch
                line += [
                    ("table_ms", tableTime.map(PerfValue.milliseconds) ?? .null),
                    ("table_grew", .bool(tableGrew)),
                    ("settle_ms", .milliseconds(idle - started)),
                    // Another batch arrived before this one settled.
                    ("merged", .bool(batchCount != number)),
                ]
                tableTime = nil
                tableGrew = true
                log.write(line)
            }
        }

        /// After the counts were shown: for new traffic, a frame after its rows. Their `counts`
        /// line is written once the main thread is idle again.
        static func countsShown(started: ContinuousClock.Instant) {
            guard let log else { return }
            Task {
                let idle = await untilIdle()
                log.write([("kind", "counts"), ("settle_ms", .milliseconds(idle - started))])
            }
        }

        static func refiltered(took: Duration) {
            lastRefilter = took
        }

        static func tableUpdated(rows: Int, grew: Bool, took: Duration) {
            tableTime = (tableTime ?? .zero) + took
            tableGrew = tableGrew && grew
        }

        /// After a search of the store found its matches and the list was filtered by them.
        static func searched(query: String, took: Duration, matches: Int) {
            log?.write([
                ("kind", "search"), ("query", .text(query)), ("matches", .int(matches)),
                ("search_ms", .milliseconds(took)),
            ])
            if let awaited = awaitedSearch, awaited.query == query, awaited.found == nil {
                awaitedSearch?.found = .now
            }
        }

        /// After the detail pane loaded a request.
        static func inspectorShowed(_ id: ExchangeID, took: Duration) {
            log?.write([("kind", "inspector"), ("id", .int(Int(id.rawValue))), ("load_ms", .milliseconds(took))])
        }

        // MARK: - Timed steps

        /// Runs the timed steps once `count` requests have arrived, after any steps still running.
        /// Traffic keeps arriving meanwhile. They take about 30 seconds.
        static func runSequence(at count: Int, traffic: TrafficListModel) {
            guard log != nil else { return }
            let previous = sequence
            sequence = Task {
                await previous?.value
                isRunningSequence = true
                await steps(at: count, traffic: traffic)
                isRunningSequence = false
            }
        }

        private static func steps(at count: Int, traffic: TrafficListModel) async {
            let searchText = traffic.searchText
            /// Changes something and back, three times, timing each change.
            func toggle(_ name: String, on: () -> Void, off: () -> Void) async {
                for round in 1...3 {
                    await timed("\(name) on", at: count, round: round, traffic: traffic, on)
                    await timed("\(name) off", at: count, round: round, traffic: traffic, off)
                }
            }
            await toggle(
                "status 4xx", on: { traffic.filter.statuses = [.clientError] }, off: { traffic.filter.statuses = [] })
            await toggle(
                "content json", on: { traffic.filter.contents = [.json] }, off: { traffic.filter.contents = [] })
            // Nothing matches, so the list gives way to No Matches, and comes back whole.
            await toggle("method PATCH", on: { traffic.filter.method = "PATCH" }, off: { traffic.filter.method = nil })
            // Many requests match in the list itself.
            await toggle("search json", on: { traffic.searchText = "json" }, off: { traffic.searchText = searchText })
            // Few match, and only in their headers, so the store has to find them.
            for round in 1...3 {
                awaitedSearch = ("needle", nil)
                let typed = ContinuousClock.now
                await timed("search needle on", at: count, round: round, traffic: traffic) {
                    traffic.searchText = "needle"
                }
                while awaitedSearch?.found == nil, ContinuousClock.now - typed < .seconds(2) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                let found = awaitedSearch?.found
                awaitedSearch = nil
                log?.write([
                    ("kind", "action"), ("name", "search needle found"), ("at", .int(count)), ("round", .int(round)),
                    ("visible", .int(traffic.visibleCount)),
                    ("search_total_ms", found.map { .milliseconds($0 - typed) } ?? .null),
                ])
                await timed("search needle off", at: count, round: round, traffic: traffic) {
                    traffic.searchText = searchText
                }
            }
            await scroll(at: count, traffic: traffic)
            if !traffic.rows.isEmpty {
                let middle = traffic.rows[traffic.rows.count / 2]
                await timed("select", at: count, round: 1, traffic: traffic) { traffic.selection = middle }
                // The batches meanwhile say they arrived with a request selected.
                try? await Task.sleep(for: .seconds(5))
                await timed("deselect", at: count, round: 1, traffic: traffic) { traffic.selection = nil }
            }
        }

        /// Makes a change and logs how long it took: the change itself, and until the main thread
        /// was idle again. Then waits half a second.
        private static func timed(
            _ name: String, at count: Int, round: Int, traffic: TrafficListModel, _ change: () -> Void
        ) async {
            shared.withLock { $0.context = "action \(name)" }
            lastRefilter = nil
            let started = ContinuousClock.now
            change()
            let changed = ContinuousClock.now
            let refilter = lastRefilter
            let idle = await untilIdle()
            log?.write([
                ("kind", "action"),
                ("name", .text(name)),
                ("at", .int(count)),
                ("round", .int(round)),
                ("rows", .int(traffic.all.count)),
                ("visible", .int(traffic.visibleCount)),
                ("sync_ms", .milliseconds(changed - started)),
                ("refilter_ms", refilter.map(PerfValue.milliseconds) ?? .null),
                ("settle_ms", .milliseconds(idle - started)),
            ])
            shared.withLock { $0.context = "traffic" }
            try? await Task.sleep(for: .milliseconds(500))
        }

        /// Scrolls to the top, pages down 100 times, 40 rows at a time, then scrolls to the end,
        /// where the list follows new requests again.
        private static func scroll(at count: Int, traffic: TrafficListModel) async {
            guard let table, let scrollView = table.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            await timed("scroll to top", at: count, round: 1, traffic: traffic) { table.scrollRowToVisible(0) }
            shared.withLock { $0.context = "action page down" }
            var steps: [Double] = []
            for _ in 0..<100 {
                let started = ContinuousClock.now
                var origin = clipView.bounds.origin
                let bottom = max(0, table.bounds.height - clipView.bounds.height)
                origin.y = min(origin.y + 40 * (table.rowHeight + table.intercellSpacing.height), bottom)
                clipView.scroll(to: origin)
                scrollView.reflectScrolledClipView(clipView)
                steps.append(milliseconds(await untilIdle() - started))
            }
            steps.sort()
            log?.write([
                ("kind", "scroll"),
                ("at", .int(count)),
                ("rows", .int(traffic.all.count)),
                ("steps", .int(steps.count)),
                ("p50_ms", .number(percentile(steps, 0.5))),
                ("p95_ms", .number(percentile(steps, 0.95))),
                ("max_ms", .number(steps.last ?? 0)),
            ])
            await timed("scroll to end", at: count, round: 1, traffic: traffic) {
                table.scrollRowToVisible(table.numberOfRows - 1)
            }
        }

        // MARK: - Helpers

        /// When the main run loop is next about to sleep: after SwiftUI's update, AppKit's
        /// display cycle and Core Animation's commit.
        static func untilIdle() async -> ContinuousClock.Instant {
            await withCheckedContinuation { continuation in
                let observer = CFRunLoopObserverCreateWithHandler(
                    nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
                ) { _, _ in
                    continuation.resume(returning: .now)
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            }
        }

        nonisolated static func milliseconds(_ duration: Duration) -> Double {
            let (seconds, attoseconds) = duration.components
            return Double(seconds) * 1000 + Double(attoseconds) / 1e15
        }

        /// The value at `fraction` of the way through `sorted`, such as 0.95 for the 95th percentile.
        nonisolated static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
        }
    }

    // MARK: - Log

    /// One line of the log: its fields, in order.
    typealias PerfLine = [(String, PerfValue)]

    nonisolated enum PerfValue: Sendable, ExpressibleByStringLiteral {
        case int(Int)
        case number(Double)
        case text(String)
        case bool(Bool)
        case object(PerfLine)
        case null

        init(stringLiteral value: String) {
            self = .text(value)
        }

        static func milliseconds(_ duration: Duration) -> PerfValue {
            .number(PerfProbe.milliseconds(duration))
        }

        var json: String {
            switch self {
            case .int(let value): String(value)
            case .number(let value): value.isFinite ? String((value * 1000).rounded() / 1000) : "null"
            case .text(let value): Self.quoted(value)
            case .bool(let value): value ? "true" : "false"
            case .object(let fields):
                "{" + fields.map { Self.quoted($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
            case .null: "null"
            }
        }

        private static func quoted(_ text: String) -> String {
            var quoted = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": quoted += "\\\""
                case "\\": quoted += "\\\\"
                case _ where scalar.value < 0x20: quoted += String(format: "\\u%04x", scalar.value)
                default: quoted.unicodeScalars.append(scalar)
                }
            }
            return quoted + "\""
        }
    }

    /// Writes lines to the log file in order, on a queue of its own, never on the main thread.
    nonisolated final class PerfLog: @unchecked Sendable {
        private let queue = DispatchQueue(label: "net.reqly.perf-log")
        private let handle: FileHandle
        private var isClosed = false

        init?(path: String) {
            guard FileManager.default.createFile(atPath: path, contents: nil),
                let handle = FileHandle(forWritingAtPath: path)
            else { return nil }
            self.handle = handle
        }

        func write(_ line: PerfLine) {
            let text = PerfValue.object(line).json + "\n"
            queue.async { [self] in
                guard !isClosed else { return }
                try? handle.write(contentsOf: Data(text.utf8))
            }
        }

        /// Waits for the lines already written, then closes the file.
        func close() {
            queue.sync {
                isClosed = true
                try? handle.close()
            }
        }
    }

    // MARK: - Watchdog

    /// Pings the main thread every 10 ms from a thread of its own, and times each answer. Only one
    /// ping is out at a time, so a 300 ms stall shows as one 300 ms answer. Once a second it
    /// writes a `tick` line.
    nonisolated final class PerfWatchdog: Thread, @unchecked Sendable {
        private struct Totals {
            var pings = 0
            var stalls = 0
            var longest = 0.0
            /// Answers that took at least 16, 33, 50, 100 and 250 ms.
            var slower: [Int: Int] = [16: 0, 33: 0, 50: 0, 100: 0, 250: 0]
        }

        private let log: PerfLog
        private let mainThread: thread_act_t
        private let started = ContinuousClock.now
        private let counted = Mutex(Totals())

        init(log: PerfLog, mainThread: thread_act_t) {
            self.log = log
            self.mainThread = mainThread
            super.init()
        }

        override func main() {
            let answered = DispatchSemaphore(value: 0)
            var answers: [Double] = []
            var lastTick = ContinuousClock.now
            var lastMainCPU = cpuTime(of: mainThread)
            var lastProcessCPU = processCPUTime()
            var lastRows = 0
            while !isCancelled {
                let sent = ContinuousClock.now
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let now = ContinuousClock.now
                let waited = PerfProbe.milliseconds(now - sent)
                answers.append(waited)
                counted.withLock { totals in
                    totals.pings += 1
                    totals.longest = max(totals.longest, waited)
                    for limit in totals.slower.keys where waited >= Double(limit) {
                        totals.slower[limit, default: 0] += 1
                    }
                    if waited > 50 {
                        totals.stalls += 1
                    }
                }
                let shared = PerfProbe.shared.withLock { $0 }
                if waited > 50 {
                    log.write([
                        ("kind", "stall"), ("t", .milliseconds(sent - started)), ("ms", .number(waited)),
                        ("context", .text(shared.context)), ("rows", .int(shared.rows)),
                    ])
                }
                let elapsed = now - lastTick
                if elapsed >= .seconds(1) {
                    let seconds = PerfProbe.milliseconds(elapsed) / 1000
                    let mainCPU = cpuTime(of: mainThread)
                    let processCPU = processCPUTime()
                    answers.sort()
                    log.write([
                        ("kind", "tick"),
                        ("t", .milliseconds(now - started)),
                        ("main_cpu", .number((mainCPU - lastMainCPU) / seconds * 100)),
                        ("process_cpu", .number((processCPU - lastProcessCPU) / seconds * 100)),
                        ("footprint_mb", .number(Double(footprint()) / 1_048_576)),
                        ("ping_p50_ms", .number(PerfProbe.percentile(answers, 0.5))),
                        ("ping_p99_ms", .number(PerfProbe.percentile(answers, 0.99))),
                        ("ping_max_ms", .number(answers.last ?? 0)),
                        ("rows", .int(shared.rows)),
                        ("visible", .int(shared.visible)),
                        ("rows_per_s", .number(Double(shared.rows - lastRows) / seconds)),
                        ("occluded", .bool(shared.isOccluded)),
                        ("active", .bool(shared.isActive)),
                    ])
                    answers.removeAll(keepingCapacity: true)
                    lastTick = now
                    lastMainCPU = mainCPU
                    lastProcessCPU = processCPU
                    lastRows = shared.rows
                }
                Thread.sleep(forTimeInterval: 0.010)
            }
        }

        /// The totals for the `final` line.
        func totals() -> PerfLine {
            counted.withLock { totals in
                [
                    ("pings", .int(totals.pings)),
                    ("stalls", .int(totals.stalls)),
                    ("ping_max_ms", .number(totals.longest)),
                    (
                        "slower_than_ms",
                        .object(totals.slower.sorted { $0.key < $1.key }.map { (String($0.key), .int($0.value)) })
                    ),
                ]
            }
        }

        /// The CPU time a thread has used, in seconds.
        private func cpuTime(of thread: thread_act_t) -> Double {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
                + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        }

        /// The CPU time the whole process has used, in seconds.
        private func processCPUTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }

        /// The process's memory footprint, as Activity Monitor shows it, in bytes.
        private func footprint() -> UInt64 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
                }
            }
            return result == 0 ? info.ri_phys_footprint : 0
        }
    }
#endif
