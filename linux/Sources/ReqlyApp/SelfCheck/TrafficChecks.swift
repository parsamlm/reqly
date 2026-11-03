import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The request list's parts: its cells and words, following new traffic, and pins, colors and
    /// comments.
    static let trafficParts: [Part] = [
        Part(name: "list", seconds: 90) { try await $0.checkList() },
        Part(name: "follow", seconds: 240) { try await $0.checkFollowing() },
        Part(name: "annotate", seconds: 90) { try await $0.checkAnnotating() },
    ]

    /// A row of each kind, through Reqly's proxy: 2xx to 5xx, one that failed, one in progress,
    /// an encrypted connection, and ones pinned, marked and commented. Each row's cells say what
    /// the Mac's say, with the status's dot or symbol in its color, in light and in dark, the pin
    /// and the speech bubble, the comment as its tooltip, and the mark on the row. Screen readers
    /// hear each row through the accessibility bus as its cells' words and where it is, with no
    /// icon. Tab leaves the list in one stop, and Shift+Tab comes back to it.
    func checkList() async throws {
        let window = window
        let list = window.list
        let session = try await emptyTheList()
        let traffic = try await startTraffic()
        defer { traffic.server.stop() }
        do {
            try await withoutWarnings { try await checkEachKind(list, session, traffic) }
        } catch {
            try? await stopTraffic()
            throw error
        }
        try await stopTraffic()
        _ = try await emptyTheList()
    }

    /// The kinds of row the list part makes, in the order it makes them.
    private enum Kind: String, CaseIterable {
        case success = "2xx", redirection = "3xx", clientError = "4xx", serverError = "5xx", failed
        case inProgress = "in progress", encrypted = "encrypted connection"
        case pinned, marked, commented
    }

    private func checkEachKind(_ list: RequestList, _ session: SessionHost, _ traffic: Traffic) async throws {
        let (server, client) = (traffic.server, traffic.client)
        let comment = "Check Turin's forecast"
        var sent: [Kind: String] = [:]
        for (kind, query) in [
            (Kind.success, "200"), (.redirection, "302"), (.clientError, "404"), (.serverError, "503"),
        ] {
            let url = server.url(.ok, "status=\(query)&kind=\(kind.rawValue.prefix(3))")
            _ = try await client.send(url)
            sent[kind] = url
        }
        _ = try await client.send(server.url(.fail))
        sent[.failed] = server.url(.fail)
        // Answered once the part is done, as the server stops.
        let slow = Task { try? await client.send(server.url(.slow, "ms=30000")) }
        defer { slow.cancel() }
        sent[.inProgress] = server.url(.slow, "ms=30000")
        let tunnel = try await openTunnel(to: server, through: traffic.port)
        defer { close(tunnel) }
        for kind in [Kind.pinned, .marked, .commented] {
            let url = server.url(.ok, "for=\(kind.rawValue)")
            _ = try await client.send(url)
            sent[kind] = url
        }

        // Each kind's row, by what it sent.
        var ids: [Kind: ExchangeID] = [:]
        try await until("a row of each kind", seconds: 10) {
            ids = [:]
            for row in 0..<list.count {
                guard let summary = list.summary(at: row) else { continue }
                if summary.kind == .tunnel {
                    ids[.encrypted] = summary.id
                } else if let kind = sent.first(where: { summary.url?.absoluteString == $0.value })?.key {
                    ids[kind] = summary.id
                }
            }
            return ids.count == Kind.allCases.count
        }
        try await session.annotate(try present(ids[.pinned], "no pinned row"), isPinned: true)
        try await session.annotate(try present(ids[.marked], "no marked row"), color: .set(.red))
        try await session.annotate(try present(ids[.commented], "no commented row"), comment: .set(comment))
        try await until("the rows to show their marks, and the slow one still in progress", seconds: 10) {
            list.isSettled && list.text(of: ids[.commented]!)?.comment == comment
                && list.text(of: ids[.marked]!)?.color == .red && list.text(of: ids[.pinned]!)?.isPinned == true
                && list.text(of: ids[.inProgress]!)?.look == .waiting && list.text(of: ids[.failed]!)?.look == .failed
        }
        await settle()

        for kind in Kind.allCases {
            let id = try present(ids[kind], "no \(kind.rawValue) row")
            try checkCells(of: id, list, kind: kind.rawValue)
        }
        let marked = try present(list.rowWidget(of: ids[.marked]!), "the marked row has no widget")
        try require(
            gtk_widget_has_css_class(marked, "marked") != 0 && gtk_widget_has_css_class(marked, "mark-red") != 0,
            "the marked row has no red mark")
        let unmarked = try present(list.rowWidget(of: ids[.success]!), "the 2xx row has no widget")
        try require(gtk_widget_has_css_class(unmarked, "marked") == 0, "the 2xx row has a mark")
        let commented = try present(list.cell(.request, of: ids[.commented]!), "no commented cell")
        let tooltip = string(gtk_widget_get_tooltip_text(commented)) ?? ""
        try require(tooltip == comment, "the comment's tooltip is “\(tooltip)”")
        note(
            "marks: the pinned row's pin, the commented row's bubble with “\(tooltip)” as its tooltip, red on the marked"
        )

        try checkSymbols()
        try await checkDots(list, ids)
        try await checkWhatScreenReadersHear(list, ids)
        try await checkTab(list, ids[.success]!)
        try await checkBesideTheDetails(list)
    }

    /// At 1280 pixels, with the details beside the list, the columns fit the list's pane, so it
    /// doesn't scroll sideways, with a picture of it.
    private func checkBesideTheDetails(_ list: RequestList) async throws {
        let window = window
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        gtk_window_set_default_size(cast(window.window), 1280, 760)
        defer { gtk_window_set_default_size(cast(window.window), width, height) }
        try await until("the details to show beside the list", seconds: 5) {
            gtk_widget_get_width(window.window) > 1260 && adw_navigation_split_view_get_collapsed(window.inner) == 0
        }
        await settle()
        let columns = RequestList.Column.allCases.map { "\($0.title) \(list.width(of: $0))" }
        let sideways = try present(gtk_scrolled_window_get_hadjustment(cast(list.scroller)), "no adjustment")
        let room = gtk_adjustment_get_page_size(sideways)
        let needed = gtk_adjustment_get_upper(sideways)
        note("beside the details: columns \(columns.joined(separator: ", ")) px, in the list's \(Int(room)) px")
        try require(needed <= room + 1, "beside the details, the columns need \(Int(needed)) px of \(Int(room))")
        let file = try picture("list-beside-the-details.png")
        _ = try Pictures.own(window.window, to: file)
        note("picture: \(file.lastPathComponent)")
    }

    /// A row's cells, each saying what the row's words say, and its status's dot or symbol.
    private func checkCells(of id: ExchangeID, _ list: RequestList, kind: String) throws {
        let text = try present(list.text(of: id), "the \(kind) row has no words")
        var said: [String] = []
        for column in RequestList.Column.allCases {
            let cell = try present(list.cell(column, of: id), "the \(kind) row has no \(column.rawValue) cell")
            let words = RequestCells.words(of: cell, column)
            let expected: String =
                switch column {
                case .status: text.status
                case .method: text.method
                case .request: text.request.host + text.request.rest
                case .app: text.app
                case .time: text.time
                case .duration: text.duration
                case .size: text.size
                }
            try require(words == expected, "the \(kind) row's \(column.title) says “\(words)”, not “\(expected)”")
            said.append(words)
        }
        let status = try present(list.cell(.status, of: id), "no status cell")
        let symbol = try present(gtk_widget_get_first_child(status), "no symbol")
        let dot = try present(gtk_widget_get_next_sibling(symbol), "no dot")
        let shown: String
        if gtk_widget_get_visible(symbol) != 0 {
            shown = string(gtk_image_get_icon_name(cast(symbol))) ?? "?"
        } else if gtk_widget_get_visible(dot) != 0 {
            let classes = ["status-1xx", "status-2xx", "status-3xx", "status-4xx", "status-5xx", "waiting"]
            shown = classes.filter { gtk_widget_has_css_class(dot, $0) != 0 }.joined(separator: " ")
        } else {
            shown = "nothing"
        }
        let expected: String =
            switch text.look {
            case .status(let status): status.styleClass
            case .failed: Icons.warning
            case .paused: Icons.pause
            case .encrypted: "channel-secure-symbolic"
            case .waiting: "waiting"
            }
        try require(shown == expected, "the \(kind) row's status shows \(shown), not \(expected)")
        let request = try present(list.cell(.request, of: id), "no request cell")
        let pin = try present(gtk_widget_get_next_sibling(gtk_widget_get_first_child(request)), "no pin")
        let bubble = try present(gtk_widget_get_next_sibling(pin), "no bubble")
        try require(
            (gtk_widget_get_visible(pin) != 0) == text.isPinned
                && (gtk_widget_get_visible(bubble) != 0) == (text.comment != nil),
            "the \(kind) row's pin or bubble shows when it shouldn't, or doesn't")
        let marks = [text.isPinned ? "; a pin" : nil, text.comment != nil ? "; a bubble" : nil].compactMap { $0 }
        note("\(kind): \(shown); \(said.filter { !$0.isEmpty }.joined(separator: " | "))\(marks.joined())")
    }

    /// The list's symbols are drawn in the text's color, as symbolic icons, the theme's own or
    /// Reqly's where it has none, as with only hicolor.
    private func checkSymbols() throws {
        let theme = try present(gtk_icon_theme_get_for_display(gdk_display_get_default()), "there's no icon theme")
        let settings = try present(gtk_settings_get_default(), "there are no GTK settings")
        defer { gtk_settings_reset_property(settings, "gtk-icon-theme-name") }
        let names = [Icons.warning, Icons.pause, Icons.pin, Icons.comment, "channel-secure-symbolic"]
        for themeName in ["the default", "hicolor"] {
            if themeName == "hicolor" {
                set(raw(settings), "gtk-icon-theme-name", .string("hicolor"))
            }
            for name in names {
                let icon = gtk_icon_theme_lookup_icon(
                    theme, name, nil, 16, 1, GTK_TEXT_DIR_LTR, GtkIconLookupFlags(rawValue: 0))
                defer { g_object_unref(raw(icon)) }
                let file = gtk_icon_paintable_get_file(icon)
                defer { file.map { g_object_unref(raw($0)) } }
                let path = file.flatMap { takeString(g_file_get_path($0)) } ?? "nothing"
                try require(
                    gtk_icon_paintable_is_symbolic(icon) != 0,
                    "with \(themeName) theme, \(name) isn't symbolic: \(path)")
            }
        }
        note("symbols: \(names.joined(separator: ", ")), drawn as text, with the default theme and with hicolor's")
    }

    /// The dots in the guidelines' colors, light and dark, with a picture of each.
    private func checkDots(_ list: RequestList, _ ids: [Kind: ExchangeID]) async throws {
        let manager = adw_style_manager_get_default()
        defer { adw_style_manager_set_color_scheme(manager, runsColorScheme) }
        var pictures: [String] = []
        for (scheme, name, palette) in [
            (ADW_COLOR_SCHEME_FORCE_LIGHT, "light", ListStyles.light),
            (ADW_COLOR_SCHEME_FORCE_DARK, "dark", ListStyles.dark),
        ] {
            adw_style_manager_set_color_scheme(manager, scheme)
            await settle()
            var colors: [String] = []
            for (kind, status) in [
                (Kind.success, StatusClass.success), (.clientError, .clientError), (.serverError, .serverError),
            ] {
                let cell = try present(list.cell(.status, of: ids[kind]!), "no status cell")
                let dot = try present(gtk_widget_get_next_sibling(gtk_widget_get_first_child(cell)), "no dot")
                var color = GdkRGBA()
                gtk_widget_get_color(dot, &color)
                let expected = try present(palette.statuses[status], "no color for \(status)")
                let hex = Self.hex(color)
                try require(
                    hex == expected.lowercased(), "in \(name), the \(kind.rawValue) dot is \(hex), not \(expected)")
                colors.append("\(kind.rawValue) \(hex)")
            }
            let file = try picture("list-\(name).png")
            let size = try Pictures.own(window.window, to: file)
            pictures.append("\(file.lastPathComponent) (\(size))")
            note("dots in \(name): \(colors.joined(separator: ", "))")
        }
        note("pictures: \(pictures.joined(separator: ", "))")
    }

    /// Each row, through the accessibility bus: its name the row's words, its description where
    /// it is, and no icon in the list.
    private func checkWhatScreenReadersHear(_ list: RequestList, _ ids: [Kind: ExchangeID]) async throws {
        let tree = try await AccessibilityTree.read(depth: 40, children: 60)
        let table = tree.subtree { $0.name == "Requests" && $0.role.contains("table") }
        try require(!table.isEmpty, "the accessibility tree has no table called Requests")
        let rows = table.filter { $0.description.hasPrefix("Request ") }
        note("accessibility tree: the list is a \(table[0].role), with \(rows.count) rows read")
        for kind in Kind.allCases {
            let id = ids[kind]!
            let words = try present(list.accessibleWords(of: id), "the \(kind.rawValue) row isn't bound")
            let text = try present(list.text(of: id), "the \(kind.rawValue) row has no words")
            try require(words.label == text.label, "the \(kind.rawValue) row's label is “\(words.label)”")
            let row = try present(
                rows.first { $0.name == text.label },
                "no row on the bus is called “\(text.label)”: \(rows.map(\.line).joined(separator: " | "))")
            try require(
                row.description == words.description, "the \(kind.rawValue) row's description is \(row.description)")
            if kind == .encrypted || kind == .commented || kind == .failed {
                note("    \(row.role) “\(row.name)” (\(row.description))")
            }
        }
        let encrypted = try present(list.text(of: ids[.encrypted]!), "no encrypted row")
        try require(
            encrypted.label.components(separatedBy: "Encrypted connection").count == 2,
            "the encrypted connection's label says it more than once: \(encrypted.label)")
        let images = table.filter { $0.role == "image" || $0.role == "icon" }
        try require(images.isEmpty, "screen readers find \(images.count) icons in the list: \(images.map(\.line))")
        note("no icon in the list for screen readers; “Encrypted connection” said once")
    }

    /// Tab leaves the list from a row, and Shift+Tab comes back to it, in one stop each.
    private func checkTab(_ list: RequestList, _ id: ExchangeID) async throws {
        let window = window
        adw_navigation_split_view_set_show_content(window.inner, 0)
        list.select(id: id)
        try await until("the row to be selected", seconds: 3) { list.selected == id }
        list.focusSelection()
        try await until("the row to have the focus", seconds: 3) { self.listHasFocus }
        try FakeInput.press("Tab", in: window.window)
        try await until("Tab to leave the list", seconds: 3) { !self.listHasFocus }
        let left = focusType
        try FakeInput.press("Shift_L", "Tab", in: window.window)
        try await until("Shift+Tab to come back to the list", seconds: 3) { self.listHasFocus }
        let row = list.rowWidget(of: id)
        let isOnTheRow = row.map { row in focusWidget.map { window.isInside($0, row) } ?? false } ?? false
        note("Tab: from the row to the \(left) in one press; Shift+Tab back to \(isOnTheRow ? "the row" : focusType)")
        try require(isOnTheRow, "Shift+Tab came back to the \(focusType), not the row")
    }

    // MARK: - What the list's parts share

    /// Runs `body`, and fails if GTK, libadwaita or GLib warned meanwhile.
    func withoutWarnings(_ body: () async throws -> Void) async throws {
        let lines = try await standardError(during: body).lines
        let warnings = lines.filter { $0.contains("-WARNING") || $0.contains("-CRITICAL") }
        note("GTK's warnings meanwhile: \(warnings.isEmpty ? "none" : warnings.joined(separator: " | "))")
        try require(
            warnings.isEmpty, "GTK warned \(warnings.count) times: \(warnings.prefix(3).joined(separator: " | "))")
    }

    /// The server, the client, and the proxy's port, while Reqly captures.
    struct Traffic {
        var server: TestServer
        var client: ProxyClient
        var port: Int
    }

    /// Starts capturing, with a stand-in for your proxy setting, and a server to send requests to
    /// through Reqly.
    func startTraffic() async throws -> Traffic {
        _ = try await switchReady()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        if model.capture != .capturing {
            try await setCapture(on: true)
        }
        let port = try present(model.listeningPort, "capturing has no port")
        return Traffic(server: try TestServer(), client: ProxyClient(proxyPort: port), port: port)
    }

    func stopTraffic() async throws {
        if model.capture != .stopped {
            try await setCapture(on: false)
        }
    }

    /// The session with nothing in it, pinned requests too, the list with no rows, the details
    /// beside it or gone back, and the keyboard's focus on what shows, as the rows it may have
    /// been on have gone.
    @discardableResult
    func emptyTheList() async throws -> SessionHost {
        let session = try await session()
        let list = window.list
        await session.unpinAll()
        await session.clear()
        try await until("the list to be empty", seconds: 10) { list.total == 0 && list.count == 0 && list.isSettled }
        adw_navigation_split_view_set_show_content(window.inner, 0)
        await settle()
        window.focusContent()
        return session
    }

    /// An encrypted connection to the server through Reqly, which stays open until it's closed.
    func openTunnel(to server: TestServer, through port: Int) async throws -> Int32 {
        let tunnel = try await onOwnThread { Result { try Loopback.connect(to: port) } }.get()
        let origin = server.origin
        let answer = await onOwnThread {
            Loopback.write("CONNECT \(origin) HTTP/1.1\r\nHost: \(origin)\r\n\r\n", to: tunnel)
            return Loopback.read(from: tunnel) { $0.contains("\r\n\r\n") }
        }
        guard answer.hasPrefix("HTTP/1.1 200") else {
            close(tunnel)
            throw Failure("CONNECT got \(answer.prefix(100))")
        }
        return tunnel
    }

    /// Whether a request's row shows whole in the list, below its column titles.
    func rowShows(_ id: ExchangeID) -> Bool {
        let list = window.list
        guard let cell = list.cell(.status, of: id), gtk_widget_get_mapped(cell) != 0 else { return false }
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(cell, list.scroller, &bounds) != 0 else { return false }
        let height = Float(gtk_widget_get_height(list.scroller))
        return bounds.origin.y >= 0 && bounds.origin.y + bounds.size.height <= height + 0.5
    }

    /// The style the run asked for, as the window has it outside the parts that change it.
    var runsColorScheme: AdwColorScheme {
        switch app.options.theme {
        case .light: ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: ADW_COLOR_SCHEME_FORCE_DARK
        case nil: ADW_COLOR_SCHEME_DEFAULT
        }
    }

    /// Whether the keyboard's focus is in the list.
    var listHasFocus: Bool {
        focusWidget.map { window.isInside($0, window.list.view) } ?? false
    }

    var focusWidget: Widget? {
        gtk_root_get_focus(cast(window.window))
    }

    var focusType: String {
        focusWidget.map { typeName(raw($0)) } ?? "nothing"
    }

    /// A color as CSS writes it, such as `#0b9a83`.
    static func hex(_ color: GdkRGBA) -> String {
        "#" + [color.red, color.green, color.blue].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }
}
