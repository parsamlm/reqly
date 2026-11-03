import CGtk
import CGtkSource
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The self-check's own tools, which the window's parts check it with, and the binding's
    /// helpers they build on.
    static let toolParts: [Part] = [
        Part(name: "tools", seconds: 150) { try await $0.checkTools() }
    ]

    /// Each tool works: the binding's helpers, in a window of their own; a picture of the window
    /// at the screen's scale, and of the whole screen; the accessibility tree, with the window's
    /// title and what the helpers set; the thread watch's numbers; the traffic maker's server,
    /// one request at a time and in a burst of 500, all arriving as rows. Then, in copies of
    /// Reqly, a session limited to 300 requests keeps the newest 300, and the session the Mac
    /// saved opens with its 16 requests. In those copies, this part checks only that.
    func checkTools() async throws {
        if let limit = app.options.sessionLimit {
            try await checkTheSessionLimit(limit)
            return
        }
        if app.options.smokeSession != nil {
            try await checkTheSavedSession()
            return
        }
        let tools = try await ToolsWindow.open(over: window.window)
        defer { tools.close() }
        try await checkTheBinding(tools)
        try await checkPictures()
        try await checkTheAccessibilityTree(tools)
        tools.close()
        try await checkTheTrafficMaker()

        let limited = try await runInCopy(
            ["tools"], options: ["--session-limit", "300", "--starts-capturing", "yes"], seconds: 90)
        for line in limited where !line.hasSuffix("parts passed") {
            note("copy limited to 300: \(line.trimmingCharacters(in: .whitespaces))")
        }
        let saved = try await runInCopy(
            ["tools"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"])
        for line in saved where !line.hasSuffix("parts passed") {
            note("copy with the Mac's session: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    // MARK: - The binding

    /// The helpers that test build B had, on a window of their own.
    private func checkTheBinding(_ tools: ToolsWindow) async throws {
        // A signal emitted as a click would, and a handler that lasts only while another object does.
        emit(raw(tools.button), "clicked")
        try require(tools.counts.clicks == 1, "emitting clicked ran its handler \(tools.counts.clicks) times")
        let watched = g_object_ref_sink(raw(gtk_label_new("Gone soon")))
        let counts = tools.counts
        connect(raw(tools.button), "clicked", whileAlive: watched) { counts.whileAlive += 1 }
        emit(raw(tools.button), "clicked")
        g_object_unref(watched)
        emit(raw(tools.button), "clicked")
        try require(
            counts.clicks == 3 && counts.whileAlive == 1,
            "of 3 clicks, the handler ran \(counts.clicks) times, and the one while the label lived "
                + "\(counts.whileAlive)")
        note("signals: emit ran the handler; one connected while a label lived ran once, then not once it went")

        // Bound both ways.
        bind(raw(tools.toggle), "active", to: raw(tools.revealer), "reveal-child")
        gtk_toggle_button_set_active(cast(tools.toggle), 1)
        let revealed = boolProperty(raw(tools.revealer), "reveal-child")
        gtk_revealer_set_reveal_child(cast(tools.revealer), 0)
        let toggled = gtk_toggle_button_get_active(cast(tools.toggle)) != 0
        try require(revealed && !toggled, "the bound revealer showed \(revealed), and the toggle then \(toggled)")
        note("bind: the revealer followed the toggle, and the toggle the revealer")

        // GValues of an object, an int64 and a variant.
        let child = gtk_label_new("Child")!
        set(raw(tools.valued), "child", .object(raw(child)))
        let big = Int64(1) << 40
        let int64 = Value.int64(big).with { g_value_get_int64($0) }
        let variant = Value.variant(g_variant_new_string("Tehran")).with {
            string(g_variant_get_string(g_value_get_variant($0), nil))
        }
        try require(gtk_button_get_child(cast(tools.valued)) == child, "the button's child isn't the label set")
        try require(int64 == big && variant == "Tehran", "the values held \(int64) and \(variant ?? "nothing")")
        note("values: an object set as a button's child, \(int64) as an int64, “Tehran” in a variant")

        // A tree whose rows' children come as they open.
        let tree = withCStrings(["Forecast", "Cities"]) { names in
            treeListModel(gtk_string_list_new(names)) { item in
                guard string(gtk_string_object_get_string(cast(item))) == "Forecast" else { return nil }
                return withCStrings(["Today", "Tomorrow"]) { gtk_string_list_new($0) }
            }
        }
        defer { g_object_unref(raw(tree)) }
        let closed = g_list_model_get_n_items(tree)
        let row = gtk_tree_list_model_get_row(tree, 0)
        gtk_tree_list_row_set_expanded(row, 1)
        g_object_unref(raw(row))
        let opened = g_list_model_get_n_items(tree)
        try require(closed == 2 && opened == 4, "the tree had \(closed) rows, then \(opened) with Forecast open")
        note("tree: 2 rows, then 4 once Forecast opened")

        // A draw function, a tick with the frame clock, and GtkSourceView's own version.
        try await until("the drawing area to draw, and a frame's time", seconds: 5) {
            counts.draws > 0 && counts.frameTime > 0
        }
        let buffer = gtk_text_view_get_buffer(cast(tools.code))
        let lines = gtk_text_buffer_get_line_count(buffer)
        note(
            "drawing: drawn \(counts.draws) times; tick: a frame at \(counts.frameTime) µs; "
                + "GtkSourceView \(LibraryVersion.sourceView), \(lines) lines")
        try require(LibraryVersion.sourceView >= LibraryVersion(major: 5, minor: 12), "GtkSourceView is before 5.12")
    }

    // MARK: - Pictures

    /// The window's own picture, at the screen's scale, and the X screen's.
    private func checkPictures() async throws {
        await settle()
        let file = try picture("tools-window.png")
        let size = try Pictures.own(window.window, to: file)
        let surface = gtk_native_get_surface(cast(window.window))
        let scale = surface.map { gdk_surface_get_scale($0) } ?? 1
        let expected = Pictures.Size(
            width: Int((Double(gtk_widget_get_width(window.window)) * scale).rounded()),
            height: Int((Double(gtk_widget_get_height(window.window)) * scale).rounded()))
        let saved = try Pictures.size(of: file)
        note("window's picture: \(size) pixels at a scale of \(scale), in \(file.lastPathComponent)")
        try require(size == expected && saved == size, "the window's picture is \(saved), not \(expected)")

        let screenFile = try picture("tools-screen.png")
        let screen = try await Pictures.screen(to: screenFile)
        let monitors = gdk_display_get_monitors(gdk_display_get_default())
        let monitor: OpaquePointer? = cast(g_list_model_get_item(monitors, 0))
        defer { g_object_unref(raw(monitor)) }
        var geometry = GdkRectangle()
        gdk_monitor_get_geometry(monitor, &geometry)
        let factor = Int(gdk_monitor_get_scale_factor(monitor))
        let whole = Pictures.Size(width: Int(geometry.width) * factor, height: Int(geometry.height) * factor)
        note("screen's picture: \(screen) pixels, in \(screenFile.lastPathComponent)")
        try require(screen == whole, "the screen's picture is \(screen), not the screen's \(whole)")
    }

    // MARK: - The accessibility tree

    /// The tree through AT-SPI has the window, by its title, and what the helpers set on the
    /// tools' window: a button labelled by a label, its description, and an icon screen readers
    /// skip. An announcement reaches the bus.
    private func checkTheAccessibilityTree(_ tools: ToolsWindow) async throws {
        await settle()
        let tree = try await AccessibilityTree.read(depth: 12, children: 30)
        let title = string(gtk_window_get_title(cast(window.window))) ?? ""
        let frame = try present(
            tree.nodes.first { $0.role == "frame" && $0.name == title }, "the tree has no window called \(title)")
        let frameLine = frame.line.trimmingCharacters(in: .whitespaces)
        note("accessibility tree: \(tree.nodes.count) elements; the window: \(frameLine)")

        let own = tree.subtree { $0.role == "frame" && $0.name == ToolsWindow.title }
        try require(!own.isEmpty, "the tree has no window called \(ToolsWindow.title)")
        let button = try present(
            own.first { $0.role == "button" || $0.role == "push button" },
            "the tools' window has no button: \(own.map(\.line).joined(separator: " | "))")
        note("its button: \(button.line.trimmingCharacters(in: .whitespaces)), labelled by \(button.relations)")
        try require(button.name == ToolsWindow.label, "the button's name is “\(button.name)”, not its label's")
        try require(
            button.relations["labelled-by"] == [ToolsWindow.label],
            "the button's labelled-by is \(button.relations["labelled-by"] ?? [])")
        try require(button.description == ToolsWindow.description, "the button's description is \(button.description)")
        let images = own.filter { $0.role == "image" || $0.role == "icon" }
        try require(images.isEmpty, "the icon screen readers should skip is there: \(images.map(\.line))")
        note("its icon: hidden from screen readers")

        let words = "The tools' window says hello."
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 4) {
            // The reader takes a moment to start listening.
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(600))
                announce(tools.button, words)
            }
        }
        let said = heard.filter { $0.detail == words }
        note("announcements: \(said.count) of 5 heard, from the \(said.first?.role ?? "nothing"): “\(words)”")
        try require(!said.isEmpty, "no announcement reached the accessibility bus: \(heard.map(\.type))")
    }

    // MARK: - The traffic maker

    /// The server's paths through Reqly's proxy, one at a time, then a burst of 500 of them, all
    /// arriving as rows, while the thread watch measures the window's waits.
    private func checkTheTrafficMaker() async throws {
        let session = try await session()
        let server = try TestServer()
        defer { server.stop() }
        _ = try await switchReady()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        try await setCapture(on: true)
        do {
            let port = try present(model.listeningPort, "capturing has no port")
            try await sendThroughTheProxy(ProxyClient(proxyPort: port), to: server, session: session)
        } catch {
            try? await setCapture(on: false)
            throw error
        }
        try await setCapture(on: false)
    }

    private func sendThroughTheProxy(_ client: ProxyClient, to server: TestServer, session: SessionHost) async throws {
        let start = window.list.count
        let json = try await client.send(server.url(.json))
        let type = HTTPWire.value("Content-Type", in: json.headers) ?? ""
        try require(json.status == 200 && type == "application/json", "JSON came back \(json.status), \(type)")
        let packed = try await client.send(server.url(.gzip))
        try require(packed.body == TestServer.packedJSON, "the gzip body came back changed, \(packed.body.count) bytes")
        let signedIn = try await client.send(server.url(.me), headers: [("Authorization", "Bearer self-check")])
        let anonymous = try await client.send(server.url(.me))
        try require(
            signedIn.status == 200 && anonymous.status == 401, "/me answered \(signedIn.status), \(anonymous.status)")
        let asked = monotonicMicroseconds()
        let slow = try await client.send(server.url(.slow, "ms=300"))
        let waited = (monotonicMicroseconds() - asked) / 1000
        try require(slow.status == 200 && waited >= 300, "the slow one answered \(slow.status) after \(waited) ms")
        let failed = try await client.send(server.url(.fail))
        try require(failed.status >= 500, "the failed one answered \(failed.status)")
        let missing = try await client.send(server.url(.ok, "status=404"))
        try require(missing.status == 404, "status=404 answered \(missing.status)")
        note("through Reqly: JSON, gzip as it came, /me with and without Authorization, slow after \(waited) ms")
        let said = failed.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        note("    the failed one: Reqly answered \(failed.status) “\(said)”")
        try await until("the 7 requests' rows") { window.list.count >= start + 7 }

        let watch = ThreadWatch()
        watch.start()
        defer { watch.stop() }
        let before = window.list.count
        let paths: [TestServer.Path] = [
            .json, .xml, .html, .text, .form, .multipart, .image, .gzip, .cookies, .me, .ok,
        ]
        let urls = (0..<500).map { server.url(paths[$0 % paths.count], "n=\($0)") }
        let started = monotonicMicroseconds()
        let burst = await client.burst(urls)
        note("burst: \(burst)")
        try require(burst.answered == 500, "of 500, \(burst.answered) were answered: \(burst.problems)")
        try await until("the burst's 500 rows", seconds: 20) { window.list.count >= before + 500 }
        let shown = (monotonicMicroseconds() - started) / 1000
        let ids = await session.rowIDs().ids
        try require(
            window.list.count == before + 500 && ids.count == window.list.count,
            "the list shows \(window.list.count) rows, and the session has \(ids.count)")
        let waits = watch.waits(from: started)
        note("    all 500 rows in \(shown) ms; the window's thread meanwhile: \(waits)")
        try require(waits.ticks > 0, "the thread watch didn't tick")

        // The watch sees the thread held up.
        let held = monotonicMicroseconds()
        usleep(150_000)
        try await Task.sleep(for: .milliseconds(50))
        let heldUp = watch.waits(from: held)
        note("thread watch: held for 150 ms, it saw \(heldUp)")
        try require(heldUp.longest >= 120 && heldUp.over100 >= 1, "held up for 150 ms, the watch saw \(heldUp)")
    }

    // MARK: - In copies of Reqly

    /// In a copy with `--session-limit`: a burst fills the session to its limit, and a burst of 100
    /// more leaves the newest, the rows events past the limit taking out as many rows as they put
    /// in, and the list shows them.
    private func checkTheSessionLimit(_ limit: Int) async throws {
        let session = try await session()
        try await until("capturing to start") { model.capture == .capturing || model.problem != nil }
        let port = try present(model.listeningPort, model.problem ?? "capturing didn't start")
        let server = try TestServer()
        defer { server.stop() }
        let moves = RowMoves()
        model.listen { event in
            guard moves.isListening, case .rows(_, let total, _, let steps) = event else { return }
            var inserted = 0
            var removed = 0
            for step in steps {
                switch step {
                case .inserted(let rows): inserted += rows.count
                case .removed(let rows): removed += rows.count
                case .changed, .reset: break
                }
            }
            if total == limit, inserted > 0, inserted == removed {
                moves.balanced += 1
            }
        }
        defer { moves.isListening = false }

        let client = ProxyClient(proxyPort: port)
        let filled = await client.burst((0..<limit).map { server.url(.ok, "n=\($0)") })
        try require(filled.answered == limit, "of \(limit), \(filled.answered) were answered: \(filled.problems)")
        try await until("the session to fill", seconds: 10) { window.list.count == limit }
        let oldest = await session.rowIDs().ids.first?.rawValue ?? 0
        let sent = limit + 100
        let burst = await client.burst((limit..<sent).map { server.url(.ok, "n=\($0)") })
        try require(burst.answered == 100, "of 100 more, \(burst.answered) were answered: \(burst.problems)")
        // Once the oldest 100 have gone, and the newest has its row.
        var ids: [ExchangeID] = []
        var newest: ExchangeID?
        let deadline = monotonicMicroseconds() + 15_000_000
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            ids = await session.rowIDs().ids
            newest = await session.trafficSummary().newest?.id
        } while (ids.count != limit || ids.first?.rawValue != oldest + 100 || ids.last != newest
            || window.list.count != limit) && monotonicMicroseconds() < deadline
        let total = await session.trafficSummary().total
        let first = ids.first?.rawValue ?? 0
        let isNewest = ids.map(\.rawValue) == Array(first..<first + UInt64(ids.count)) && ids.last == newest
        note("filled: \(filled); then \(burst)")
        let last = ids.last?.rawValue ?? 0
        note("kept: \(ids.count) of \(sent), #\(first) to #\(last); the list shows \(window.list.count)")
        note("rows events that took out as many rows as they put in: \(moves.balanced)")
        try require(
            ids.count == limit && total == limit, "the session keeps \(ids.count) rows of \(total), not \(limit)")
        try require(isNewest, "the rows kept aren't the newest \(limit)")
        try require(window.list.count == limit, "the list shows \(window.list.count) rows, not \(limit)")
        try require(moves.balanced > 0, "no rows event took out as many rows as it put in")
    }

    /// In a copy with `--smoke-session` and the Mac's session: its 16 requests, among them JSON,
    /// a picture, a gzip body, a secret Authorization header, a WebSocket and an encrypted
    /// connection.
    private func checkTheSavedSession() async throws {
        let session = try await session()
        try await until("the saved session's rows", seconds: 10) { window.list.count > 0 }
        await settle()
        let ids = await session.rowIDs().ids
        var kinds: [String] = []
        for id in ids {
            let details = try await session.details(id)
            let exchange = details.exchange
            let type = exchange.response?.headers["Content-Type"] ?? ""
            if type.hasPrefix("application/json") { kinds.append("JSON") }
            if type == "image/png" { kinds.append("a PNG") }
            if exchange.response?.headers["Content-Encoding"] == "gzip" { kinds.append("gzip") }
            if exchange.request.headers.fields.contains(where: { $0.name == "Authorization" && $0.isSecret }) {
                kinds.append("a secret Authorization header")
            }
            if details.isWebSocket { kinds.append("a WebSocket of \(exchange.messageCount) messages") }
            if details.decryption == .encryptedTunnel { kinds.append("an encrypted connection") }
        }
        let found = Set(kinds)
        note("\(ids.count) requests, the list showing \(window.list.count): \(found.sorted().joined(separator: ", "))")
        try require(
            ids.count == 16 && window.list.count == 16, "the Mac's session showed \(ids.count) requests, not 16")
        for kind in ["JSON", "a PNG", "gzip", "a secret Authorization header", "an encrypted connection"] {
            try require(found.contains(kind), "the Mac's session has no \(kind)")
        }
        try require(found.contains("a WebSocket of 3 messages"), "the Mac's session has no WebSocket of 3 messages")
    }
}

/// The rows events the session limit's copy saw that took out as many rows as they put in.
@MainActor
private final class RowMoves {
    var balanced = 0
    var isListening = true
}

/// A window of the tools part's own, over the main one, with a widget for each of the binding's
/// helpers to work on, and what they've done so far.
@MainActor
private final class ToolsWindow {
    static let title = "Self-check Tools"
    static let label = "Check the tools"
    static let description = "A button no text of its own names"

    /// What the helpers did.
    @MainActor
    final class Counts {
        var clicks = 0
        var whileAlive = 0
        var draws = 0
        var frameTime: Int64 = 0
    }

    let window: Widget
    /// A button with no text of its own, labelled by a label beside it.
    let button: Widget
    let toggle: Widget
    let revealer: Widget
    /// A button for `.object` to set the child of.
    let valued: Widget
    let code: Widget
    let counts = Counts()
    private var isOpen = true

    private init(over parent: Widget) {
        window = gtk_window_new()
        gtk_window_set_title(cast(window), Self.title)
        gtk_window_set_transient_for(cast(window), cast(parent))
        gtk_window_set_default_size(cast(window), 480, 360)
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
        let label = gtk_label_new(Self.label)!
        button = gtk_button_new()
        setAccessibleRelation(button, GTK_ACCESSIBLE_RELATION_LABELLED_BY, [label])
        setAccessibleDescription(button, Self.description)
        let icon = gtk_image_new_from_icon_name("channel-secure-symbolic")!
        setAccessibleHidden(icon, true)
        toggle = gtk_toggle_button_new_with_label("Show")
        revealer = gtk_revealer_new()
        gtk_revealer_set_child(cast(revealer), gtk_label_new("Shown"))
        valued = gtk_button_new()
        code = gtk_source_view_new()
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(cast(code)), "{\n  \"city\": \"Tehran\"\n}", -1)
        let area = gtk_drawing_area_new()!
        gtk_drawing_area_set_content_width(cast(area), 64)
        gtk_drawing_area_set_content_height(cast(area), 32)
        for child in [label, button, icon, toggle, revealer, valued, code, area] {
            gtk_box_append(cast(box), child)
        }
        gtk_window_set_child(cast(window), box)
        let counts = counts
        connect(raw(button), "clicked") { counts.clicks += 1 }
        setDraw(area) { cairo, _, _ in
            counts.draws += 1
            // Reqly's teal.
            cairo_set_source_rgb(cairo, 0.04, 0.60, 0.51)
            cairo_paint(cairo)
        }
    }

    /// Opens it, and waits for it to show.
    static func open(over parent: Widget) async throws -> ToolsWindow {
        let tools = ToolsWindow(over: parent)
        gtk_window_present(cast(tools.window))
        let deadline = monotonicMicroseconds() + 5_000_000
        while gtk_widget_get_mapped(tools.window) == 0 {
            guard monotonicMicroseconds() < deadline else { throw SelfCheck.Failure("the tools' window didn't show") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let counts = tools.counts
        tick(tools.window) { clock in
            counts.frameTime = Int64(gdk_frame_clock_get_frame_time(clock))
            return false
        }
        return tools
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        gtk_window_destroy(cast(window))
    }
}
