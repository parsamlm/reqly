import AppSetup
import CGtk
import CoreInterface
import Foundation
import GtkBinding
import LinuxApps
import ReqlyModel

extension SelfCheck {
    /// The sidebar, search and filters: what narrows the list.
    static let findParts: [Part] = [
        Part(name: "sidebar", seconds: 120) { try await $0.checkSidebar() },
        Part(name: "search", seconds: 60) { try await $0.checkSearch() },
        Part(name: "filters", seconds: 120) { try await $0.checkFilters() },
    ]

    /// Sends its requests through Reqly's proxy on one connection, as an app does, and keeps it
    /// open until a file says Reqly has named the app, or 20 s:
    /// `python3 -I -c <this> <proxy port> <server> <file> <path>…`.
    private static let pythonRequests = """
        import http.client, os, sys, time
        connection = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=10)
        for path in sys.argv[4:]:
            connection.request("GET", "http://" + sys.argv[2] + path)
            connection.getresponse().read()
        for _ in range(400):
            if os.path.exists(sys.argv[3]):
                break
            time.sleep(0.05)
        """

    // MARK: - The sidebar

    /// The sidebar of an empty session: All Traffic, and Hosts with its line. With requests from
    /// two apps to three hosts: the apps and the hosts in the session's order, h2 before h10, with
    /// their counts, in the view too. Pinned shows once a request is pinned. The arrow keys and the
    /// session's keys choose Pinned, a host and an app, and the list and its header bar's words
    /// follow; Pinned's menu, from Shift+F10, unpins them all, and Pinned stays while it's chosen,
    /// then goes. Shown over the list, the sidebar stays while the arrow keys choose, and Enter puts
    /// it away. A click on Hosts folds it, ← and → and Enter fold it and show it again, and your
    /// settings remember it. Screen readers hear each row's name, its count and its section, and
    /// whether a section shows. GTK warns of nothing meanwhile. Then, in a copy of Reqly with the
    /// Mac's saved session, each device shows with its apps and hosts under it.
    func checkSidebar() async throws {
        try await withoutWarnings {
            if app.options.smokeSession != nil {
                try await checkTheSavedSidebar()
            } else {
                try await checkTheLiveSidebar()
            }
        }
    }

    private func checkTheLiveSidebar() async throws {
        let window = window
        let sidebar = window.sidebar
        let session = try await emptySession()
        for section in [SidebarRows.Section.apps, .devices, .hosts] {
            sidebar.fold(section, false)
        }
        await settle()
        let empty = Self.names(sidebar.rows)
        try require(
            empty == [["All Traffic"], [], [], ["Hosts", SidebarRows.hint]], "the empty session's sidebar is \(empty)")
        try require(
            sidebarShows() == ["All Traffic", "Hosts", SidebarRows.hint], "the view shows \(sidebarShows())")
        note("empty: \(sidebarShows().joined(separator: " · "))")

        // Two apps, the self-check and python3, and three hosts; two of them refuse.
        let server = try TestServer()
        defer { server.stop() }
        let me = try present(Processes.read(getpid()), "this process can't be read").name
        try await capturing { client in
            let credited = scratch.appending(path: "credited-\(UUID().uuidString)")
            let arguments = [
                String(client.proxyPort), server.origin, credited.path, "/json", "/text", "/html", "/ok?status=404",
            ]
            let python = Task {
                try await Program.run(["python3", "-I", "-c", Self.pythonRequests] + arguments, seconds: 30)
            }
            // python3 stops waiting once it's there, whatever happens.
            defer { _ = FileManager.default.createFile(atPath: credited.path, contents: nil) }
            // The refused ones' answers may close their connections.
            let held = [
                try await sendAsAnApp(
                    [server.url(.json), server.url(.xml), server.url(.ok), "http://127.0.0.2:1/sidebar"],
                    through: client.proxyPort),
                try await sendAsAnApp(["http://127.0.0.10:1/sidebar"], through: client.proxyPort),
            ]
            defer { held.forEach { close($0) } }
            try await until("the 9 requests, each with its app", seconds: 15) {
                window.list.total == 9 && sidebar.rows.sections[1].count == 3
                    && sidebar.rows.sections[1].reduce(0) { $0 + $1.count } == 9
            }
            _ = FileManager.default.createFile(atPath: credited.path, contents: nil)
            let ended = try await python.value
            try require(ended.status == 0, "python3's requests ended with \(ended.status ?? -1): \(ended.errors)")
        }
        await settle()
        let rows = sidebar.rows
        let apps = rows.sections[1].dropFirst().map(\.name)
        let python = try present(apps.first { $0 != me }, "the apps are \(apps), with no python3")
        try require(
            apps == [me, python].sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "the apps are \(apps), not by name")
        let counted = rows.all.filter(\.isScope).map { "\($0.name) \($0.count)" }
        try require(
            counted == ["All Traffic 9"] + apps.map { "\($0) \($0 == me ? 5 : 4)" } + [
                "127.0.0.1 7", "127.0.0.2 1", "127.0.0.10 1",
            ],
            "the rows and their counts are \(counted)")
        let lines = rows.all.map { [$0.name, $0.badge()].filter { !$0.isEmpty }.joined(separator: " ") }
        try require(sidebarShows() == lines, "the view shows \(sidebarShows()), not \(lines)")
        note("with traffic: \(lines.joined(separator: " · "))")

        // Pinned, once a request is.
        let ids = await session.rowIDs().ids
        let refused = try present(
            await session.rows(ids).first { $0.host == "127.0.0.2" }, "there's no request to 127.0.0.2")
        try await session.annotate(refused.id, isPinned: true)
        try await until("Pinned to show", seconds: 5) { sidebar.rows.row("pinned")?.count == 1 }
        try require(
            sidebar.rows.sections[0].map(\.name) == ["All Traffic", "Pinned"], "Pinned isn't after All Traffic")
        note("pinned: Pinned shows after All Traffic, with 1")

        try await checkScopes(python: python)
        try await checkUnpinAll()
        try await checkOverTheList()
        try await checkFolding()
        try await checkSidebarsWords()
        try await takePicture("sidebar.png")

        let saved = try await runInCopy(
            ["sidebar"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"])
        for line in saved where !line.hasSuffix("parts passed") {
            note("copy with the Mac's session: \(line.trimmingCharacters(in: .whitespaces))")
        }
        _ = try await emptySession()
    }

    /// The arrow keys choose Pinned, and the session's keys a host and an app, and the list shows
    /// their requests, its header bar their names and counts, and the status line the session's.
    private func checkScopes(python: String) async throws {
        let window = window
        let sidebar = window.sidebar
        let list = window.list
        sidebar.focus()
        try await until("the sidebar to have the focus", seconds: 3) { self.sidebarHasFocus("All Traffic") }
        try FakeInput.press("Down", in: window.window)
        try await until("Down to choose Pinned, and the list to show it", seconds: 5) {
            sidebar.scope.key == "pinned" && list.count == 1
        }
        try await checkTitle("Pinned", "1 request", "1 of 9 requests")
        var chosen = ["Pinned, with Down: 1 request"]

        for (name, count) in [("127.0.0.1", 7), (python, 4), ("All Traffic", 9)] {
            let row = try present(sidebar.rows.all.first { $0.name == name && $0.isScope }, "there's no row \(name)")
            sidebar.choose(row.key)
            try await until("\(name) to show its \(count) requests", seconds: 5) {
                sidebar.scope.key == row.key && list.count == count
            }
            let requests = ListTitle.requests(count)
            try await checkTitle(name, requests, count == 9 ? requests : "\(count) of 9 requests")
            chosen.append("\(name): \(requests)")
        }
        note("scopes: \(chosen.joined(separator: "; ")); the header bar and the status line say so")
    }

    /// Shift+F10 on Pinned opens its menu, whose Unpin All Requests unpins them all; Pinned stays
    /// while it's chosen, with the no-matches page, and goes once another row is.
    private func checkUnpinAll() async throws {
        let window = window
        let sidebar = window.sidebar
        sidebar.choose("pinned")
        try await until("Pinned to be chosen", seconds: 5) { sidebar.scope.key == "pinned" && window.list.count == 1 }
        sidebar.focus()
        try await until("Pinned to have the focus", seconds: 3) { self.sidebarHasFocus("Pinned") }
        try FakeInput.press("Shift_L", "F10", in: window.window)
        try await until("Shift+F10 to open Pinned's menu", seconds: 3) { gtk_widget_get_mapped(sidebar.menu) != 0 }
        await settle()
        let item = try present(
            Self.descendant(of: sidebar.menu, typed: "GtkModelButton"), "Pinned's menu has no Unpin All Requests")
        try FakeInput.click(item)
        try await until("Unpin All Requests to unpin them", seconds: 5) {
            sidebar.rows.row("pinned")?.count == 0 && window.list.count == 0
        }
        await settle()
        try require(gtk_widget_get_mapped(sidebar.menu) == 0, "Pinned's menu is still open")
        try require(sidebar.rows.row("pinned") != nil, "Pinned went while it's chosen")
        try require(
            gtk_widget_get_mapped(window.noMatches.widget) != 0 && window.noMatches.words.title == "No Requests",
            "with nothing pinned, the list's pane says \(window.noMatches.words.title)")
        sidebar.choose("all")
        try await until("Pinned to go once All Traffic is chosen", seconds: 5) {
            sidebar.scope.key == "all" && sidebar.rows.row("pinned") == nil && window.list.count == 9
        }
        note(
            "Unpin All Requests, from Shift+F10: Pinned shows 0 while it's chosen, with “No Requests”, and goes "
                + "with All Traffic")
    }

    /// At 700 pixels, with the sidebar shown over the list by F9: the arrow keys choose the next
    /// row, and the list and its title follow, but the sidebar stays; Enter puts it away, with the
    /// focus in the list's pane.
    private func checkOverTheList() async throws {
        let window = window
        let sidebar = window.sidebar
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        func restore() async {
            gtk_window_set_default_size(cast(window.window), width, height)
            await settle()
            adw_overlay_split_view_set_show_sidebar(
                window.outer, cBool(adw_overlay_split_view_get_collapsed(window.outer) == 0))
            await settle()
        }
        do {
            gtk_window_set_default_size(cast(window.window), 700, height)
            try await until("the sidebar to fold away at 700 pixels", seconds: 5) {
                adw_overlay_split_view_get_collapsed(window.outer) != 0 && !window.sidebarIsOver
            }
            await settle()
            try FakeInput.press("F9", in: window.window)
            try await until("F9 to show the sidebar over the list, All Traffic focused", seconds: 3) {
                window.sidebarIsOver && self.sidebarHasFocus("All Traffic")
            }
            await settle()
            // Past Apps' title, which takes the focus, but isn't a scope.
            let next = try present(
                sidebar.rows.all.dropFirst().first { $0.isScope }, "there's no row after All Traffic")
            for _ in 0..<2 {
                try FakeInput.press("Down", in: window.window)
                await settle()
            }
            try await until("Down to choose \(next.name), and its count to show", seconds: 5) {
                sidebar.scope.key == next.key && window.list.count == next.count
            }
            try await checkTitle(next.heading, ListTitle.requests(next.count), "\(next.count) of 9 requests")
            await settle()
            try require(window.sidebarIsOver, "the sidebar went once Down chose \(next.name)")
            try FakeInput.press("Return", in: window.window)
            try await until("Enter to put the sidebar away, with the focus in the list's pane", seconds: 3) {
                !window.sidebarIsOver && self.focusWidget.map { window.isInside($0, window.listPane) } == true
            }
            note(
                "over the list, at 700 pixels: Down, past Apps, chooses \(next.name), the title following, and the "
                    + "sidebar stays; Enter puts it away")
        } catch {
            await restore()
            throw error
        }
        await restore()
        sidebar.choose("all")
        try await until("All Traffic again", seconds: 5) { window.list.count == 9 }
    }

    /// A click on Hosts folds it, and → shows it again, ← folds it and Enter shows it, and your
    /// settings, in memory and on disk, say so each time.
    private func checkFolding() async throws {
        let window = window
        let sidebar = window.sidebar
        let settingsFile = model.folders.settingsFile
        func saved() -> Bool { AppSettings.load(from: settingsFile).sidebarShowsHosts }
        let title = try present(sidebarRow("Hosts"), "Hosts' title doesn't show")
        try FakeInput.click(title)
        try await until("a click to fold Hosts", seconds: 3) {
            sidebar.isFolded(.hosts) && sidebar.rows.sections[3].count == 1
        }
        await settle()
        try require(!model.settings.sidebarShowsHosts && !saved(), "the settings don't say Hosts is folded")
        try require(self.sidebarHasFocus("Hosts"), "Hosts' title doesn't have the focus")
        let folded = sidebarShows()
        var steps = ["a click folds it"]
        for (key, folds) in [("Right", false), ("Left", true), ("Return", false)] {
            try FakeInput.press(key, in: window.window)
            try await until("\(key) to \(folds ? "fold" : "show") Hosts", seconds: 3) {
                sidebar.isFolded(.hosts) == folds && self.model.settings.sidebarShowsHosts == !folds
            }
            try require(saved() == !folds, "after \(key), the settings file says Hosts shows: \(saved())")
            steps.append("\(key == "Return" ? "Enter" : key == "Left" ? "←" : "→") \(folds ? "folds" : "shows") it")
        }
        await settle()
        try require(sidebarShows().contains("127.0.0.10 1"), "Hosts' rows didn't come back: \(sidebarShows())")
        note(
            "folding Hosts: \(steps.joined(separator: ", ")); folded, the view shows \(folded.joined(separator: " · "))"
        )
    }

    /// What screen readers hear of the sidebar: each row's name and count, with its section, and
    /// whether a section's title shows its rows.
    private func checkSidebarsWords() async throws {
        let sidebar = window.sidebar
        func items() async throws -> [AccessibilityTree.Node] {
            try await AccessibilityTree.read().subtree { $0.role == "list" && $0.name == "Sidebar" }
                .filter { $0.role == "list item" }
        }
        let open = try await items()
        let host = try present(
            open.first { $0.name == "127.0.0.1, 7 requests" }, "screen readers hear \(open.map(\.line))")
        try require(host.description == "Hosts", "127.0.0.1's row is described as “\(host.description)”")
        let all = try present(open.first { $0.name == "All Traffic, 9 requests" }, "there's no All Traffic")
        let title = try present(open.first { $0.name == "Hosts" }, "screen readers hear no Hosts")
        try require(title.has("expanded"), "Hosts' title is \(title.states), not expanded")
        sidebar.fold(.hosts, true)
        await settle()
        let closed = try present(try await items().first { $0.name == "Hosts" }, "Hosts' title went")
        sidebar.fold(.hosts, false)
        try require(!closed.has("expanded"), "folded, Hosts' title is \(closed.states)")
        note(
            "screen readers: \(all.line.trimmingCharacters(in: .whitespaces)); "
                + "\(host.line.trimmingCharacters(in: .whitespaces)); Hosts [\(title.states.joined(separator: ", "))], "
                + "then folded [\(closed.states.joined(separator: ", "))]")
    }

    /// In a copy of Reqly with the Mac's saved session: the devices, each with its apps and the
    /// hosts of its other traffic under it, and no Apps; each device's own rows choose its scope.
    private func checkTheSavedSidebar() async throws {
        let window = window
        let sidebar = window.sidebar
        try await until("the saved session's sidebar", seconds: 10) { sidebar.rows.row("all")?.count == 16 }
        await settle()
        let expected = [
            ["All Traffic", "Pinned"], [],
            [
                "Devices", SidebarRows.thisComputer, "Microsoft Edge", "Weatherly", "api.weatherly.dev",
                "weather.invalid", "iPhone 17 Pro", "Weatherly", "Parsa's iPhone", "api.weatherly.dev", "Pixel 9",
                "api.weatherly.dev",
            ],
            [
                "Hosts", "ads.weatherly.dev", "api.weatherly.dev", "grpc.weatherly.dev", "live.weatherly.dev",
                "maps.weatherly.dev", "weather.invalid",
            ],
        ]
        let names = Self.names(sidebar.rows)
        try require(names == expected, "the saved session's sidebar is \(names)")
        let devices = sidebar.rows.sections[2]
        try require(
            devices.map(\.isIndented) == [false, false, true, true, true, true, false, true, false, true, false, true],
            "the devices' own rows aren't under them")
        note("rows: \(sidebar.rows.all.map { $0.isIndented ? "  \($0.name)" : $0.name }.joined(separator: " · "))")
        for (heading, count) in [("Weatherly on iPhone 17 Pro", 1), ("Pixel 9", 1), (SidebarRows.thisComputer, 13)] {
            let row = try present(devices.first { $0.heading == heading }, "there's no row for \(heading)")
            sidebar.choose(row.key)
            try await until("\(heading) to show its requests", seconds: 5) {
                sidebar.scope.key == row.key && window.list.count == count
            }
            let requests = ListTitle.requests(count)
            try await checkTitle(heading, requests, "\(count) of 16 requests")
            note("\(heading): \(requests)")
        }
        sidebar.choose("all")
        try await until("All Traffic again", seconds: 5) { window.list.count == 16 }
    }

    // MARK: - Search

    /// Ctrl+F opens the search, and typing narrows the list to the requests with the text in their
    /// addresses; a word only a body has shows its request once the store has searched, 150 ms
    /// after; the header bar and the status line count what shows. Escape closes the search and
    /// clears it. Typing in the list opens it with what was typed, and text nothing has shows
    /// “No Results”, without Clear Filters.
    func checkSearch() async throws {
        try await withoutWarnings { try await checkSearching() }
    }

    private func checkSearching() async throws {
        let window = window
        let search = window.search
        let list = window.list
        _ = try await emptySession()
        let server = try TestServer()
        defer { server.stop() }
        try await capturing { client in
            let paths: [TestServer.Path] = [.json, .json, .text, .html, .xml, .ok]
            let burst = await client.burst(paths.enumerated().map { server.url($1, "n=\($0)") }, connections: 1)
            try require(burst.answered == 6, "of 6 requests, \(burst.answered) were answered")
            try await until("the 6 requests", seconds: 10) { list.total == 6 && list.count == 6 }
        }
        await settle()

        try FakeInput.press("Control_L", "f", in: window.window)
        try await until("Ctrl+F to open the search, its field focused", seconds: 3) {
            search.isOpen && self.focusWidget.map { window.isInside($0, search.entry) } == true
        }
        for key in ["j", "s", "o", "n"] {
            try FakeInput.press(key, in: window.window)
        }
        try await until("“json” to narrow the list to its 2 requests", seconds: 5) {
            search.query == "json" && list.count == 2 && self.shown().count == 2
        }
        let targets = shown().map(\.path)
        try require(targets.allSatisfy { $0.hasPrefix("/json") }, "“json” shows \(targets)")
        try await checkTitle("All Traffic", "2 of 6 requests", "2 of 6 requests")
        note("typed “json”: the list shows \(targets.joined(separator: ", ")), 2 of 6 requests")

        // A word only the text's body has.
        let typed = monotonicMicroseconds()
        gtk_editable_set_text(cast(search.entry), "skies")
        try await until("the store to find “skies” in the text's body", seconds: 5) {
            search.query == "skies" && list.count == 1 && list.summary(at: 0)?.path.hasPrefix("/text") == true
        }
        let found = (monotonicMicroseconds() - typed) / 1000
        try require(found >= 150, "the store's match came after \(found) ms, before its 150")
        try await checkTitle("All Traffic", "1 of 6 requests", "1 of 6 requests")
        note("“skies”, only in the text's body: the store found it after \(found) ms")

        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the search and clear it", seconds: 3) {
            !search.isOpen && search.query.isEmpty && list.count == 6
        }
        let text = string(gtk_editable_get_text(cast(search.entry))) ?? ""
        try require(text.isEmpty, "the closed search still has “\(text)”")
        note("Escape: closes the search, which clears it, and the list shows its 6 again")

        // Typing in the list.
        try require(list.focusSelection() || gtk_widget_grab_focus(list.view) != 0, "the list can't have the focus")
        try await until("the list to have the focus", seconds: 3) {
            self.focusWidget.map { window.isInside($0, list.view) } == true
        }
        for key in ["t", "e", "h"] {
            try FakeInput.press(key, in: window.window)
        }
        try await until("typing in the list to open the search with “teh”", seconds: 5) {
            search.isOpen && search.query == "teh"
        }
        try await until("“teh” to find Tehran in 5 bodies", seconds: 5) { list.count == 5 }
        note("typing “teh” in the list: the search opens with it, and finds Tehran in 5 bodies")

        gtk_editable_set_text(cast(search.entry), "zzqx")
        try await until("nothing to match “zzqx”", seconds: 5) {
            list.count == 0 && gtk_widget_get_mapped(window.noMatches.widget) != 0
        }
        await settle()
        let words = window.noMatches.words
        try require(
            words.title == "No Results for “zzqx”" && gtk_widget_get_visible(window.noMatches.clearButton) == 0,
            "with nothing matching, the page says \(words.title), and Clear Filters shows")
        try await takePicture("search-no-results.png")
        note("“zzqx”: \(words.title) · \(words.description)")
        search.close()
        try await until("the list again", seconds: 3) { list.count == 6 && gtk_widget_get_mapped(list.view) != 0 }
        _ = try await emptySession()
    }

    // MARK: - Filters

    /// The filter bar is hidden while the session is empty. Each status button shows its kind,
    /// any of them may match, and All every status; Failed shows the failed alone. The content
    /// types, the App, Host and Method menus, and their tokens, each with its remove button; the
    /// tokens fold into one where they don't fit. Clear All. With nothing to show, “No Matching
    /// Requests”, with Clear Filters, and with a search too, “No Results”. A menu keeps a host
    /// whose traffic has gone.
    func checkFilters() async throws {
        try await withoutWarnings { try await checkFiltering() }
    }

    private func checkFiltering() async throws {
        let window = window
        let filters = window.filters
        let list = window.list
        let session = try await emptySession()
        await settle()
        try require(gtk_widget_get_visible(filters.widget) == 0, "the filter bar shows with no traffic")
        let server = try TestServer()
        defer { server.stop() }
        // The self-check's 8, the failed one last, as its server's closing may close the connection;
        // and 2 Reqly sends itself, an app of its own.
        try await capturing { client in
            let urls = [
                server.url(.ok), server.url(.json), server.url(.image), server.url(.html),
                server.url(.ok, "status=301"),
                server.url(.ok, "status=404"), server.url(.ok, "status=500"), server.url(.fail),
            ]
            let held = try await sendAsAnApp(urls, through: client.proxyPort)
            defer { close(held) }
            _ = try await session.send(RequestDraft(method: "POST", url: server.url(.json)))
            _ = try await session.send(RequestDraft(url: "http://127.0.0.2:1/filters"))
            do {
                try await until("the 10 requests, each with its app", seconds: 15) {
                    list.total == 10 && list.count == 10 && gtk_widget_get_mapped(filters.widget) != 0
                        && window.sidebar.rows.sections[1].reduce(0) { $0 + $1.count } == 10
                }
            } catch {
                let rows = window.sidebar.rows.all.map { "\($0.name) \($0.count)" }
                throw Failure("\(error); the list has \(list.count) of \(list.total), and the sidebar \(rows)")
            }
        }
        await settle()
        note("hidden while the session is empty, and shown with its 10 requests")

        try await checkStatuses()
        try await checkPopover()
        try await checkTokens(session)
        try await checkNoMatches()

        // A host whose traffic has gone stays in its menu.
        let kept = try present(
            await session.rows(await session.rowIDs().ids).first { $0.host == "127.0.0.2" }, "no request to 127.0.0.2")
        var filter = TrafficFilter()
        filter.host = kept.host
        filters.set(filter)
        try await until("the host's filter", seconds: 5) { list.count == 1 }
        await session.clear()
        try await until("Clear to empty the session, and hide the bar", seconds: 5) {
            list.total == 0 && gtk_widget_get_visible(filters.widget) == 0
        }
        _ = try await session.send(RequestDraft(url: server.url(.ok)))
        // The host's filter leaves it out, so it comes with no rows, but the sidebar counts it.
        try await until("the bar with the next request", seconds: 5) {
            window.sidebar.total == 1 && list.count == 0 && gtk_widget_get_visible(filters.widget) != 0
        }
        try await checkTitle("All Traffic", "0 of 1 request", "0 of 1 request")
        gtk_menu_button_popup(cast(filters.filtersButton))
        try await until("Filters to open", seconds: 3) { gtk_widget_get_mapped(filters.popover) != 0 }
        await settle()
        let hosts = Self.choices(filters.hostChoice)
        let chosen = Self.choices(filters.hostChoice)[Int(gtk_drop_down_get_selected(cast(filters.hostChoice)))]
        gtk_menu_button_popdown(cast(filters.filtersButton))
        try require(
            hosts == ["Any host", "127.0.0.1", "127.0.0.2"] && chosen == "127.0.0.2",
            "with 127.0.0.2's traffic gone, the Host menu offers \(hosts), with \(chosen) chosen")
        note("kept: with its traffic cleared, the Host menu offers \(hosts.joined(separator: ", ")), 127.0.0.2 chosen")
        filters.clear()
        _ = try await emptySession()
    }

    /// Each status button alone, two at once, All, and Failed, which shows only the failed.
    private func checkStatuses() async throws {
        let window = window
        let filters = window.filters
        let list = window.list
        let success = try present(filters.statusButtons[.success], "there's no 2xx")
        try FakeInput.click(success)
        try await until("2xx to show its 5 requests", seconds: 5) {
            filters.filter.statuses == [.success] && list.count == 5 && self.shown().count == 5
        }
        try require(
            shown().allSatisfy(StatusFilter.success.matches),
            "2xx shows \(shown().map(\.status))")
        try require(
            gtk_toggle_button_get_active(cast(success)) != 0
                && gtk_toggle_button_get_active(cast(filters.allButton)) == 0, "2xx and All aren't as chosen")
        var seen = ["2xx: 5, with a click"]
        let steps: [(StatusFilter?, Set<StatusFilter>, Int)] = [
            (.clientError, [.success, .clientError], 6), (nil, [], 10), (.redirection, [.redirection], 1),
            (.redirection, [], 10), (.serverError, [.serverError], 1), (.serverError, [], 10), (.failed, [.failed], 2),
        ]
        for (status, statuses, count) in steps {
            emit(raw(status.flatMap { filters.statusButtons[$0] } ?? filters.allButton), "clicked")
            try await until("\(status?.title ?? "All") to show \(count)", seconds: 5) {
                filters.filter.statuses == statuses && list.count == count && self.shown().count == count
            }
            seen.append(
                "\(statuses.isEmpty ? "All" : statuses.map(\.title).sorted().joined(separator: " and ")): \(count)")
        }
        try require(shown().allSatisfy(StatusFilter.failed.matches), "Failed shows \(shown().map(\.status))")
        try require(
            gtk_toggle_button_get_active(cast(filters.allButton)) == 0, "All is on, with Failed chosen")
        emit(raw(filters.allButton), "clicked")
        try await until("All to show every request", seconds: 5) { filters.filter.statuses.isEmpty && list.count == 10 }
        note("statuses: \(seen.joined(separator: "; ")); Failed shows only the failed")
    }

    /// The popover's content types, two to a row, and its App, Host and Method menus, each of
    /// which narrows the list, and how many requests show.
    private func checkPopover() async throws {
        let window = window
        let filters = window.filters
        let list = window.list
        try FakeInput.click(filters.filtersButton)
        try await until("Filters to open", seconds: 3) { gtk_widget_get_mapped(filters.popover) != 0 }
        await settle()
        let json = try present(filters.contentChecks[.json], "there's no JSON")
        let images = try present(filters.contentChecks[.image], "there's no Images")
        gtk_check_button_set_active(cast(json), 1)
        try await until("JSON to show its 2", seconds: 5) { filters.filter.contents == [.json] && list.count == 2 }
        gtk_check_button_set_active(cast(images), 1)
        try await until("JSON and Images to show 3", seconds: 5) { list.count == 3 }
        try require(
            Self.label(filters.shownLabel) == "3 requests", "the popover counts \(Self.label(filters.shownLabel))")
        try require(
            filters.tokens == [FilterToken(kind: .contents, title: "JSON or Images")],
            "the tokens are \(filters.tokens)")
        try await takePicture("filters-popover.png", ofTheScreen: true)
        var seen = ["JSON: 2", "JSON or Images: 3, the popover saying 3 requests"]
        gtk_check_button_set_active(cast(json), 0)
        gtk_check_button_set_active(cast(images), 0)
        try await until("no content type", seconds: 5) { filters.filter.contents.isEmpty && list.count == 10 }

        let apps = Self.choices(filters.appChoice)
        let hosts = Self.choices(filters.hostChoice)
        let methods = Self.choices(filters.methodChoice)
        try require(apps.first == "Any app" && apps.count == 3, "the App menu offers \(apps)")
        try require(hosts == ["Any host", "127.0.0.1", "127.0.0.2"], "the Host menu offers \(hosts)")
        try require(methods == ["Any method", "GET", "POST"], "the Method menu offers \(methods)")
        let me = try present(Processes.read(getpid()), "this process can't be read").name
        let steps: [(Widget, String, Int)] = [
            (filters.hostChoice, "127.0.0.2", 1), (filters.hostChoice, "Any host", 10),
            (filters.methodChoice, "POST", 1), (filters.methodChoice, "Any method", 10), (filters.appChoice, me, 8),
            (filters.appChoice, "Any app", 10),
        ]
        for (choice, title, count) in steps {
            let index = try present(Self.choices(choice).firstIndex(of: title), "no menu offers \(title)")
            gtk_drop_down_set_selected(cast(choice), UInt32(index))
            try await until("\(title) to show \(count)", seconds: 5) { list.count == count }
            seen.append("\(title): \(count)")
        }
        gtk_menu_button_popdown(cast(filters.filtersButton))
        note(
            "Filters: \(seen.joined(separator: "; ")); the menus offer \(apps.dropFirst().joined(separator: ", ")), "
                + "\(hosts.dropFirst().joined(separator: ", ")) and \(methods.dropFirst().joined(separator: ", "))")
    }

    /// A token for each filter, whose button removes it and no other, and whose name says which;
    /// where they don't fit, one for them all, whose button removes them all. Screen readers hear
    /// the buttons' names and the filters, and which status buttons are on.
    private func checkTokens(_ session: SessionHost) async throws {
        let window = window
        let filters = window.filters
        let list = window.list
        var filter = TrafficFilter()
        filter.host = "127.0.0.2"
        filter.method = "GET"
        filter.statuses = [.failed]
        filters.set(filter)
        try await until("the host's and method's filter", seconds: 5) { list.count == 1 }
        await settle()
        let buttons = Self.tokenButtons(filters.tokensBox)
        try require(
            !filters.isFolded && buttons.count == 2
                && filters.tokens.map(\.removal) == [
                    "Remove Host Filter", "Remove Method Filter",
                ], "the tokens are \(filters.tokens), \(filters.isFolded ? "folded" : "beside each other")")
        let heard = try await AccessibilityTree.read().nodes
        let removals = heard.filter { $0.role == "push button" && $0.name.hasPrefix("Remove ") }
        let said = removals.map { "\($0.name) (\($0.description))" }
        try require(
            said == ["Remove Host Filter (Host: 127.0.0.2)", "Remove Method Filter (Method: GET)"],
            "screen readers hear the tokens' buttons as \(said)")
        let toggles = heard.filter { $0.role == "toggle button" }
        let failed = try present(toggles.first { $0.name == "Failed" }, "screen readers hear no Failed")
        let success = try present(toggles.first { $0.name == "2xx" }, "screen readers hear no 2xx")
        try require(
            failed.has("pressed") || failed.has("checked"), "Failed, chosen, is \(failed.states) to screen readers")
        try require(!success.has("pressed") && !success.has("checked"), "2xx is \(success.states)")
        note(
            "screen readers: \(said.joined(separator: ", ")); \(toggles.map(\.name).joined(separator: ", ")), "
                + "Failed [\(failed.states.joined(separator: ", "))]")
        emit(raw(buttons[0]), "clicked")
        try await until("the host's token to go", seconds: 5) { filters.filter.host == nil && list.count == 2 }
        await settle()
        try require(
            filters.filter.method == "GET" && filters.filter.statuses == [.failed] && filters.tokens.count == 1,
            "removing the host's token left \(filters.tokens)")
        let focused = focusWidget.map { $0 == filters.filtersButton || window.isInside($0, filters.filtersButton) }
        try require(
            focused == true,
            "once its token went, the focus is on \(focusWidget.map { typeName(raw($0)) } ?? "nothing")")
        note(
            "tokens: Host and Method, each with its remove button; Remove Host Filter left Method, and the focus on Filters"
        )

        // Four of them, in a narrow window.
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        let me = try present(Processes.read(getpid()), "this process can't be read").name
        filter.host = "127.0.0.1"
        filter.statuses = []
        filter.contents = [.json, .image, .html]
        filter.source = await session.rows(await session.rowIDs().ids).first { $0.source?.name == me }?.source
        filters.set(filter)
        gtk_window_set_default_size(cast(window.window), 700, height)
        do {
            try await until("the tokens to fold into one at 700 pixels", seconds: 5) {
                filters.isFolded && gtk_widget_get_mapped(filters.foldedToken) != 0
            }
            await settle()
            let folded = Self.tokenButtons(filters.foldedToken)
            let label = Self.label(gtk_widget_get_first_child(gtk_widget_get_first_child(filters.foldedToken)))
            try require(
                label == "4 filters" && folded.count == 1 && filters.tokens.count == 4,
                "folded, the token says \(label), with \(folded.count) buttons")
            try await takePicture("filters-folded.png")
            emit(raw(folded[0]), "clicked")
            try await until("its button to remove all four", seconds: 5) { filters.tokens.isEmpty && list.count == 10 }
        } catch {
            gtk_window_set_default_size(cast(window.window), width, height)
            throw error
        }
        gtk_window_set_default_size(cast(window.window), width, height)
        try await until("the window to be as wide as before", seconds: 5) {
            gtk_widget_get_width(window.window) > 700
        }
        filter = TrafficFilter()
        filter.method = "POST"
        filters.set(filter)
        try await until("one token, beside the others again", seconds: 5) {
            !filters.isFolded && gtk_widget_get_mapped(filters.tokensBox) != 0 && list.count == 1
        }
        note("at 700 pixels, 4 tokens fold into “4 filters”, whose Remove 4 Filters removes them all; one unfolds")

        // Clear All, in the popover.
        filter.statuses = [.success]
        filters.set(filter)
        try FakeInput.click(filters.filtersButton)
        try await until("Filters to open", seconds: 3) { gtk_widget_get_mapped(filters.popover) != 0 }
        await settle()
        try FakeInput.click(filters.clearAllButton)
        try await until("Clear All to take every filter off", seconds: 5) {
            !filters.isActive && list.count == 10 && gtk_widget_get_sensitive(filters.clearAllButton) == 0
        }
        gtk_menu_button_popdown(cast(filters.filtersButton))
        note("Clear All: takes the statuses off too, and turns itself off")
    }

    /// With the filters leaving nothing: “No Matching Requests”, with Clear Filters; with a search
    /// too, “No Results”, which says so. Clear Filters takes the filters off, and the search stays.
    private func checkNoMatches() async throws {
        let window = window
        let filters = window.filters
        let list = window.list
        var filter = TrafficFilter()
        filter.method = "POST"
        filter.statuses = [.redirection]
        filters.set(filter)
        try await until("nothing to match", seconds: 5) {
            list.count == 0 && gtk_widget_get_mapped(window.noMatches.widget) != 0
        }
        await settle()
        var words = window.noMatches.words
        try require(
            words.title == "No Matching Requests" && gtk_widget_get_mapped(window.noMatches.clearButton) != 0,
            "with the filters leaving nothing, the page says \(words.title)")
        var seen = ["\(words.title) · \(words.description)"]
        window.openSearch()
        gtk_editable_set_text(cast(window.search.entry), "tehran")
        try await until("the search's words", seconds: 5) {
            window.search.query == "tehran" && window.noMatches.words.title == "No Results for “tehran”"
        }
        words = window.noMatches.words
        try require(
            words.description == "No requests match both the search and the filters.",
            "the page says \(words.description)")
        seen.append("\(words.title) · \(words.description)")
        try await takePicture("filters-no-matches.png")
        try FakeInput.click(window.noMatches.clearButton)
        try await until("Clear Filters to take them off, and “tehran” to find its bodies", seconds: 5) {
            !filters.isActive && window.search.query == "tehran" && list.count == 3
                && gtk_widget_get_mapped(window.noMatches.widget) == 0
        }
        seen.append("Clear Filters takes them off, leaving “tehran”, which finds 3")
        window.search.close()
        try await until("every request again", seconds: 5) { list.count == 10 }
        note("no matches: \(seen.joined(separator: "; "))")
    }

    // MARK: - Helpers

    /// Sends requests for `urls` through Reqly's proxy, one after another on one connection, as an
    /// app does, and gives the connection, which stays open until the caller closes it: the kernel
    /// names a socket's owner only while it's open, and Reqly asks once the connection has opened,
    /// which may be after a quick app's last request.
    private func sendAsAnApp(_ urls: [String], through port: Int) async throws -> Int32 {
        try await onOwnThread { () -> Result<Int32, any Error> in
            Result {
                let socket = try Loopback.connect(to: port)
                let wire = HTTPWire(socket)
                for url in urls {
                    let authority = url.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first ?? ""
                    guard wire.write(Array("GET \(url) HTTP/1.1\r\nHost: \(authority)\r\n\r\n".utf8)),
                        wire.response() != nil
                    else {
                        close(socket)
                        throw Loopback.Failed(step: "the request for \(url)")
                    }
                }
                return socket
            }
        }.get()
    }

    /// The session with nothing in it: no traffic, nothing pinned, All Traffic chosen, no search and
    /// no filters.
    private func emptySession() async throws -> SessionHost {
        let session = try await session()
        window.search.close()
        window.filters.clear()
        window.sidebar.choose("all")
        await session.unpinAll()
        await session.clear()
        try await until("the session to be empty", seconds: 10) {
            window.list.total == 0 && window.list.count == 0 && window.sidebar.scope == .all
                && window.sidebar.rows.row("pinned") == nil
        }
        return session
    }

    /// Runs `body` while Reqly captures, with a client of its proxy, and stops capturing after,
    /// whatever happens.
    private func capturing(_ body: (ProxyClient) async throws -> Void) async throws {
        _ = try await switchReady()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        try await setCapture(on: true)
        do {
            try await body(ProxyClient(proxyPort: try present(model.listeningPort, "capturing has no port")))
        } catch {
            try? await setCapture(on: false)
            throw error
        }
        try await setCapture(on: false)
    }

    /// The list's header bar and the status line say `title`, `subtitle` and `count`, soon.
    private func checkTitle(_ title: String, _ subtitle: String, _ count: String) async throws {
        let window = window
        func said() -> (String, String, String) {
            (
                string(adw_window_title_get_title(cast(window.listTitle))) ?? "",
                string(adw_window_title_get_subtitle(cast(window.listTitle))) ?? "", Self.label(window.statusCount)
            )
        }
        do {
            try await until("the header bar to say \(title), \(subtitle)", seconds: 3) {
                said() == (title, subtitle, count)
            }
        } catch {
            let (title, subtitle, count) = said()
            throw Failure("the header bar says \(title), \(subtitle), and the status line \(count)")
        }
    }

    /// A picture of the window, or with `ofTheScreen`, of the whole screen, with its popovers, once
    /// the window has settled.
    private func takePicture(_ name: String, ofTheScreen: Bool = false) async throws {
        await settle()
        let file = try picture(name)
        let size = ofTheScreen ? try await Pictures.screen(to: file) : try await ownPicture(window.window, to: file)
        note("    picture: \(name) (\(size))")
    }

    /// The list's rows' contents, as far as the list has them.
    private func shown() -> [ExchangeSummary] {
        (0..<window.list.count).compactMap { window.list.summary(at: $0) }
    }

    /// The sections' row names.
    private static func names(_ rows: SidebarRows) -> [[String]] {
        rows.sections.map { $0.map(\.name) }
    }

    /// What the sidebar's view shows, row by row, top to bottom: each row's name, and its count
    /// when it has one.
    private func sidebarShows() -> [String] {
        sidebarRows().map { row in
            let name = gtk_widget_get_next_sibling(gtk_widget_get_first_child(row))
            let count = name.flatMap { gtk_widget_get_next_sibling($0) }
            let shown = [Self.label(name), count.map { gtk_widget_get_visible($0) != 0 ? Self.label($0) : "" } ?? ""]
            return shown.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// The sidebar's rows that show, top to bottom: each list item's own box.
    private func sidebarRows() -> [Widget] {
        let view = window.sidebar.view
        var rows: [(y: Float, box: Widget)] = []
        var child = gtk_widget_get_first_child(view)
        while let row = child {
            child = gtk_widget_get_next_sibling(row)
            var bounds = graphene_rect_t()
            guard gtk_widget_get_mapped(row) != 0, let box = gtk_widget_get_first_child(row),
                gtk_widget_compute_bounds(row, view, &bounds) != 0
            else { continue }
            rows.append((bounds.origin.y, box))
        }
        return rows.sorted { $0.y < $1.y }.map(\.box)
    }

    /// The box of the sidebar's row named `name`.
    private func sidebarRow(_ name: String) -> Widget? {
        sidebarRows().first { Self.label(gtk_widget_get_next_sibling(gtk_widget_get_first_child($0))) == name }
    }

    /// Whether the sidebar's row named `name` has the keyboard's focus.
    private func sidebarHasFocus(_ name: String) -> Bool {
        guard let box = sidebarRow(name), let row = gtk_widget_get_parent(box) else { return false }
        return focusWidget == row
    }

    /// The remove buttons of the tokens in `box`, in order.
    private static func tokenButtons(_ box: Widget) -> [Widget] {
        var buttons: [Widget] = []
        var token = gtk_widget_get_first_child(box)
        while let found = token {
            token = gtk_widget_get_next_sibling(found)
            if let button = descendant(of: found, typed: "GtkButton") {
                buttons.append(button)
            }
        }
        return buttons
    }

    /// The titles a menu offers.
    private static func choices(_ choice: Widget) -> [String] {
        guard let list = gtk_drop_down_get_model(cast(choice)) else { return [] }
        return (0..<g_list_model_get_n_items(list)).map {
            string(gtk_string_list_get_string(cast(list), $0)) ?? ""
        }
    }

    /// A label's text.
    private static func label(_ label: Widget?) -> String {
        label.flatMap { string(gtk_label_get_text(cast($0))) } ?? ""
    }

    /// The first widget of a type under `root`, depth first.
    private static func descendant(of root: Widget, typed name: String) -> Widget? {
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            if typeName(raw(widget)) == name {
                return widget
            }
            if let found = descendant(of: widget, typed: name) {
                return found
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return nil
    }
}
