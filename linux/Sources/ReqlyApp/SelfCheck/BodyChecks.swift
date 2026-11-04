import BodyKit
import CGtk
import CGtkSource
import CoreInterface
import Foundation
import GtkBinding
import Presentation
import ReqlyModel

extension SelfCheck {
    /// The body views' parts: every mode of every kind of body, and big bodies.
    static let bodyParts: [Part] = [
        Part(name: "bodies", seconds: 240) { try await $0.checkBodies() },
        Part(name: "big-body", seconds: 240) { try await $0.checkBigBodies() },
    ]

    /// Every mode of a body of each kind, from the traffic maker through Reqly's proxy, in body
    /// views on a page of their own, as the details' pages hold them: JSON, XML, HTML, text, a
    /// form, a multipart form, a picture, gzip, bytes and JSON that isn't valid. For each, what
    /// the line over it says, the modes it offers, and what each shows: the text and its colors,
    /// in high contrast too, the tree's first rows, its filter and its keys, the form's fields,
    /// the picture's words and Save Image…'s dialog, and the hex's first lines, as AT-SPI reads
    /// them too; Copy Body, Copy Path and Value, Copy as Hex and Ctrl+C; the mode chosen staying
    /// for the next body; 8 bytes a hex line when it's narrow; and pictures of each mode in light
    /// and dark. Then, in a copy of Reqly, every mode of each body of the session the Mac saved.
    /// In that copy, this part checks only those.
    func checkBodies() async throws {
        if app.options.smokeSession != nil {
            try await checkTheMacsBodies()
            return
        }
        BodyView.chosen = [:]
        let sent = try await sendBodies()
        let page = try await BodyPage.open(over: window.window)
        defer { page.close() }
        func id(_ name: String) throws -> ExchangeID { try present(sent[name], "the \(name) request has no exchange") }

        try await checkAToastsWords(try id("image"), on: page)
        try await checkJSONBody(try id("json"), on: page)
        try await checkTextBodies(sent, on: page)
        try await checkForms(try id("form"), try id("multipart"), on: page)
        try await checkPicture(try id("image"), on: page)
        try await checkPackedAndBroken(packed: try id("gzip"), broken: try id("broken"), on: page)
        try await checkBytes(try id("binary"), on: page)
        try await checkChosenModes(sent, on: page)
        for (name, part) in [
            ("json", MessagePart.response), ("xml", .response), ("html", .response), ("text", .response),
            ("form", .response), ("multipart", .response), ("image", .response), ("gzip", .response),
            ("broken", .request), ("binary", .request),
        ] {
            let view = try await show(try id(name), part, on: page)
            note("every mode of \(name): \(try await checkEveryMode(view).joined(separator: "; "))")
        }
        page.close()

        let saved = try await runInCopy(
            ["bodies"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"], seconds: 90)
        for line in saved where !line.hasSuffix("parts passed") {
            note("copy with the Mac's session: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// The test server's JSON, as it answers.
    private static let forecast =
        #"{"city":"Tehran","days":[{"sky":"clear","high":31},{"sky":"rain","high":24}],"updated":true,"note":null}"#

    /// 1,024 bytes, 0 to 255 four times over.
    private static let binary = (0..<1_024).map { UInt8($0 % 256) }

    /// Sends a request for each kind of body, captured, and gives each one's exchange, by name,
    /// once it's done.
    private func sendBodies() async throws -> [String: ExchangeID] {
        let paths: [(String, TestServer.Path)] = [
            ("json", .json), ("xml", .xml), ("html", .html), ("text", .text), ("form", .form),
            ("multipart", .multipart), ("image", .image), ("gzip", .gzip),
        ]
        return try await capturing(paths.map(\.0) + ["broken", "binary"]) { client, server in
            for (name, path) in paths {
                _ = try await client.send(server.url(path, "body=\(name)"))
            }
            _ = try await client.send(
                server.url(.ok, "body=broken"), method: "POST", headers: [("Content-Type", "application/json")],
                body: Array(#"{"city": "Tehran", "days": [1, 2"#.utf8))
            _ = try await client.send(
                server.url(.ok, "body=binary"), method: "POST",
                headers: [("Content-Type", "application/octet-stream")], body: Self.binary)
        }
    }

    /// Captures while `send` sends through Reqly's proxy to a test server of its own, then gives
    /// the exchange of each request whose query's `body=` is one of `names`, once each is done.
    private func capturing(
        _ names: [String], _ send: (ProxyClient, TestServer) async throws -> Void
    ) async throws -> [String: ExchangeID] {
        let session = try await session()
        let before = await session.trafficSummary().newest?.id.rawValue ?? 0
        let server = try TestServer()
        defer { server.stop() }
        _ = try await switchReady()
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        try await setCapture(on: true)
        do {
            let port = try present(model.listeningPort, "capturing has no port")
            try await send(ProxyClient(proxyPort: port), server)
        } catch {
            try? await setCapture(on: false)
            throw error
        }
        var found: [String: ExchangeID] = [:]
        let deadline = monotonicMicroseconds() + 15_000_000
        repeat {
            let candidates = (before + 1...before + UInt64(names.count) * 2 + 10).map { ExchangeID(rawValue: $0) }
            for summary in await session.rows(candidates) where summary.state == .completed {
                let query = summary.target.split(separator: "?").last ?? ""
                if let name = query.split(separator: "&").first(where: { $0.hasPrefix("body=") })?.dropFirst(5) {
                    found[String(name)] = summary.id
                }
            }
            guard found.count < names.count else { break }
            try await Task.sleep(for: .milliseconds(50))
        } while monotonicMicroseconds() < deadline
        try await setCapture(on: false)
        let missing = names.filter { found[$0] == nil }
        try require(missing.isEmpty, "no finished exchange for \(missing.joined(separator: ", "))")
        return found
    }

    // MARK: - Showing a body

    /// `id`'s body of `part`, as the session presents it, in a new view on the page, once its
    /// first mode shows.
    private func show(_ id: ExchangeID, _ part: MessagePart, on page: BodyPage) async throws -> BodyView {
        let session = try await session()
        let presented = try await session.presentBody(id, part: part == .request ? .request : .response)
        let view = BodyView(model: model, id: id, part: part)
        page.show(view)
        view.show(presented)
        try await shows(view)
        return view
    }

    /// Waits for the mode that shows to be ready: code in its buffer and colored, a picture read,
    /// hex lines with their bytes.
    private func shows(_ view: BodyView, seconds: Int = 20) async throws {
        try await until("the body's \(view.mode.map { "\($0)" } ?? "") view", seconds: seconds) {
            Self.isReady(view)
        }
        await settlePage()
    }

    /// Waits for the bodies' page to settle, or the window, when it's closed.
    private func settlePage() async {
        if let page = BodyPage.showing {
            await page.settle()
        } else {
            await settle()
        }
    }

    private static func isReady(_ view: BodyView) -> Bool {
        guard let mode = view.mode, let made = view.views[mode] else { return view.mode == nil }
        switch made {
        case let holder as CodeHolder: return holder.code?.isFilled == true
        case let preview as PreviewView: return preview.isRead
        case let hex as HexView: return !hex.shownLines.isEmpty && !hex.isReading
        default: return true
        }
    }

    /// The modes the switch offers, by their buttons' words, or its label's for one mode.
    private func modes(of view: BodyView) -> [String] {
        var words: [String] = []
        var child = gtk_widget_get_first_child(view.modeSwitch)
        while let widget = child {
            if typeName(raw(widget)) == "GtkLabel" {
                words.append(string(gtk_label_get_label(cast(widget))) ?? "")
            } else {
                words.append(string(gtk_button_get_label(cast(widget))) ?? "")
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return words
    }

    /// The button for a mode, by its words.
    private func button(_ title: String, of view: BodyView) throws -> Widget {
        var child = gtk_widget_get_first_child(view.modeSwitch)
        while let widget = child {
            if typeName(raw(widget)) == "GtkToggleButton", string(gtk_button_get_label(cast(widget))) == title {
                return widget
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        throw Failure("the body has no \(title) button: it offers \(modes(of: view))")
    }

    /// Chooses a mode with its button, as a click does, and waits for it to show.
    private func choose(_ title: String, of view: BodyView) async throws {
        emit(raw(try button(title, of: view)), "clicked")
        try await shows(view)
    }

    /// The line over the body, and the modes offered, as expected.
    private func expect(_ view: BodyView, says summary: String, offers modes: [String], _ name: String) throws {
        let said = string(gtk_label_get_text(cast(view.summary))) ?? ""
        let offered = self.modes(of: view)
        note("\(name): “\(said)”, \(offered.joined(separator: ", "))")
        try require(said == summary, "\(name)'s line says “\(said)”, not “\(summary)”")
        try require(offered == modes, "\(name) offers \(offered), not \(modes)")
    }

    private func code(_ view: BodyView) throws -> CodeView {
        try present(view.codeView, "the \(view.mode.map { "\($0)" } ?? "") mode shows no code")
    }

    /// The text Reqly last put on the clipboard.
    private func copiedText() -> String? {
        guard let display = gdk_display_get_default(),
            let content = gdk_clipboard_get_content(gdk_display_get_clipboard(display))
        else { return nil }
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        defer { g_value_unset(&value) }
        guard gdk_content_provider_get_value(content, &value, nil) != 0 else { return nil }
        return string(g_value_get_string(&value))
    }

    /// The picture Reqly last put on the clipboard: its width and height.
    private func copiedPicture() -> (width: Int, height: Int)? {
        guard let display = gdk_display_get_default(),
            let content = gdk_clipboard_get_content(gdk_display_get_clipboard(display))
        else { return nil }
        var value = GValue()
        g_value_init(&value, gdk_texture_get_type())
        defer { g_value_unset(&value) }
        guard gdk_content_provider_get_value(content, &value, nil) != 0, let texture = g_value_get_object(&value)
        else { return nil }
        return (Int(gdk_texture_get_width(cast(texture))), Int(gdk_texture_get_height(cast(texture))))
    }

    /// Pictures of the page in light and dark, as `name`-light.png and `name`-dark.png, or of only
    /// `widget` on it.
    private func pictures(of page: BodyPage, _ name: String, only widget: Widget? = nil) async throws -> String {
        let manager = adw_style_manager_get_default()
        let scheme = adw_style_manager_get_color_scheme(manager)
        defer { adw_style_manager_set_color_scheme(manager, scheme) }
        var files: [String] = []
        for (style, forced) in [("light", ADW_COLOR_SCHEME_FORCE_LIGHT), ("dark", ADW_COLOR_SCHEME_FORCE_DARK)] {
            adw_style_manager_set_color_scheme(manager, forced)
            await settlePage()
            let file = try picture("body-\(name)-\(style).png")
            let size = try await ownPicture(widget ?? page.window, to: file)
            files.append("\(file.lastPathComponent) (\(size))")
        }
        return files.joined(separator: ", ")
    }

    /// The character offset where `piece` first starts in `text`.
    private func offset(of piece: String, in text: String) throws -> Int {
        let range = try present(text.range(of: piece), "the text has no \(piece)")
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
    }

    /// Shows `view`'s body in each mode it offers, with its button, and checks each shows it:
    /// code its text, as the session laid it out, a tree its rows, a form its fields, a preview
    /// its picture, and hex its first line, from the session's bytes. Gives what each showed.
    private func checkEveryMode(_ view: BodyView) async throws -> [String] {
        let presented = try present(view.body?.body, "the view has no body")
        var shown: [String] = []
        for mode in presented.modes {
            let title = BodyWords.title(of: mode, in: presented)
            if presented.modes.count > 1 {
                try await choose(title, of: view)
            }
            try require(view.mode == mode, "choosing \(title) shows \(view.mode.map { "\($0)" } ?? "nothing")")
            switch view.views[mode] {
            case let holder as CodeHolder:
                let text = try present(holder.code, "\(title) shows no code").shownText
                let expected =
                    mode == .formatted ? presented.formatted?.text ?? presented.raw?.text : presented.raw?.text
                try require(
                    !text.isEmpty && expected?.hasPrefix(text) == true, "\(title) shows “\(text.prefix(60))”")
                shown.append("\(title), \(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
            case let tree as TreeView:
                try require(tree.rowCount > 0, "\(title) shows no rows")
                shown.append("\(title), \(tree.rowCount) rows")
            case let form as FormView:
                shown.append("\(title), \(form.rows.count) fields")
            case let preview as PreviewView:
                try require(preview.texture != nil, "\(title) shows no picture")
                shown.append("\(title), \(preview.facts.map(\.value).joined(separator: ", "))")
            case let hex as HexView:
                let first = HexLines.line(
                    at: 0, presented.content.prefix(hex.perLine), perLine: hex.perLine, size: presented.content.count)
                try require(hex.shownLines.first == first, "\(title)'s first line is “\(hex.shownLines.first ?? "")”")
                shown.append("\(title), \(HexLines.count(size: hex.size, perLine: hex.perLine)) lines")
            default:
                throw Failure("\(title) shows nothing")
            }
        }
        return shown
    }

    // MARK: - JSON

    /// JSON in each of its modes: colored code, the tree with its filter and path, the text as it
    /// came, and hex, with what each copies, and pictures of each.
    private func checkJSONBody(_ id: ExchangeID, on page: BodyPage) async throws {
        let view = try await show(id, .response, on: page)
        try expect(view, says: "JSON · 104 B", offers: ["Formatted", "Tree", "Raw", "Hex"], "JSON")
        let presented = try present(view.body?.body, "the JSON view has no body")

        // Formatted: the core's layout, colored by its tokens, read only, with line numbers and a
        // caret, and the style scheme the style is.
        let formatted = try code(view)
        let text = formatted.shownText
        try require(text == presented.formatted?.text, "Formatted shows “\(text.prefix(80))”")
        try require(text.contains(#""city": "Tehran""#), "Formatted doesn't lay the JSON out: \(text.prefix(80))")
        let colors = try [#""city""#, #""Tehran""#, "31", "true", "null", "{"].map {
            (piece: $0, color: formatted.color(at: try offset(of: $0, in: text)))
        }
        note(
            "    Formatted: \(text.split(separator: "\n").count) lines; "
                + colors.map { "\($0.piece) \($0.color)" }.joined(separator: ", "))
        try require(
            colors.map(\.color) == ["key", "string", "number", "literal", "literal", "punctuation"],
            "Formatted's colors are \(colors)")
        let source: OpaquePointer = cast(formatted.buffer)
        let scheme = gtk_source_buffer_get_style_scheme(cast(source)).map {
            string(gtk_source_style_scheme_get_id($0)) ?? ""
        }
        let isDark = adw_style_manager_get_dark(adw_style_manager_get_default()) != 0
        try require(
            gtk_text_view_get_editable(cast(formatted.view)) == 0
                && gtk_text_view_get_cursor_visible(cast(formatted.view)) != 0
                && gtk_source_view_get_show_line_numbers(cast(formatted.view)) != 0
                && gtk_source_buffer_get_highlight_syntax(cast(source)) == 0
                && gtk_text_view_get_wrap_mode(cast(formatted.view)) == GTK_WRAP_NONE,
            "the code view isn't read only with a caret, line numbers, its own highlighter off and no wrapping")
        try require(
            scheme == (isDark ? "Adwaita-dark" : "Adwaita"), "the code view's style scheme is \(scheme ?? "none")")
        note("    a caret, line numbers, no wrapping, GtkSourceView's highlighter off, \(scheme ?? "")")
        try await checkHighContrast(formatted, on: page)
        emit(raw(view.copyButton), "clicked")
        try require(copiedText() == text, "Copy Body copied “\(copiedText()?.prefix(40) ?? "nothing")”")
        note("    Copy Body: the formatted text; pictures: \(try await pictures(of: page, "json-formatted"))")

        // Tree: the root and its children open, the filter, and the path of a row chosen.
        try await choose("Tree", of: view)
        let tree = try present(view.views[.tree] as? TreeView, "Tree shows no tree")
        let rows = tree.firstRows(10)
        note("    Tree: \(rows.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " | "))")
        let labels = (0..<tree.rowCount).compactMap { tree.node(at: $0) }.map { presented.tree?.node($0).label ?? "" }
        try require(
            labels == ["Response", "city", "days", "0", "1", "updated", "note"], "the tree's rows are \(labels)")
        try require(rows.first == "Response, 4 keys, object", "the tree's first row says “\(rows.first ?? "")”")
        try require(
            rows.dropFirst().first == #"  city, "Tehran", string"#, "the city row says \(rows.dropFirst().first ?? "")")
        let treeRead = try await AccessibilityTree.read(depth: 40, children: 40)
        let cityRow = treeRead.subtree { $0.role == "frame" && $0.name == BodyPage.title }.first {
            $0.name == #"city, "Tehran", string"#
        }
        try require(cityRow != nil, "AT-SPI doesn't read the city row as one")
        note("    AT-SPI reads a row as one: a \(cityRow?.role ?? "") “\(cityRow?.name ?? "")”")
        tree.setFilter("rain")
        try await until("the filter to keep 4 rows") { tree.kept != nil && tree.rowCount == 4 }
        let kept = (0..<tree.rowCount).compactMap { tree.node(at: $0) }.map { presented.tree?.node($0).label ?? "" }
        try require(kept == ["Response", "days", "1", "sky"], "filtering for rain keeps \(kept)")
        tree.setFilter("nothing-has-this")
        try await until("the filter to keep none") { tree.kept?.isEmpty == true }
        tree.setFilter("")
        try await until("the tree's rows back") { tree.kept == nil && tree.rowCount == 7 }
        note("    filter: “rain” keeps \(kept.joined(separator: ", ")); one that matches nothing keeps none")
        // The arrow keys close and open the row chosen, and from a closed one go to the row above.
        tree.choose(at: 2)
        gtk_widget_grab_focus(tree.list)
        try FakeInput.press("Left", in: page.window)
        try await until("Left to close days", seconds: 5) { tree.rowCount == 5 }
        try FakeInput.press("Right", in: page.window)
        try await until("Right to open days", seconds: 5) { tree.rowCount == 7 }
        tree.choose(at: 3)
        try FakeInput.press("Left", in: page.window)
        try await until("Left on a closed row to choose days", seconds: 5) { tree.chosen?.node == tree.node(at: 2) }
        note("    keys: Left closes days and Right opens it; Left on a row that's closed chooses days, above it")
        // Once the list has moved its focus to days, which chooses it again.
        await settlePage()
        tree.choose(at: 3)
        try await until("the path of the row chosen") { tree.chosen?.node == tree.node(at: 3) }
        let chosen = try present(tree.chosen, "nothing's chosen")
        let path = string(gtk_label_get_text(cast(tree.pathLabel))) ?? ""
        try require(path == "days[0]" && chosen.value.contains(#""sky": "clear""#), "the row's path is \(path)")
        try require(gtk_widget_get_visible(tree.pathBar) != 0, "the path bar doesn't show")
        var child = gtk_widget_get_first_child(tree.pathBar)
        var copied: [String] = []
        while let widget = child {
            if typeName(raw(widget)) == "GtkButton" {
                emit(raw(widget), "clicked")
                copied.append(copiedText() ?? "")
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        try require(copied == ["days[0]", chosen.value], "Copy Path and Copy Value copied \(copied)")
        note("    path bar: \(path); Copy Path and Copy Value copy it and \(chosen.value.count) characters")
        note("    pictures: \(try await pictures(of: page, "json-tree"))")

        // Raw: the text as it came.
        try await choose("Raw", of: view)
        let asSent = try code(view).shownText
        try require(asSent == Self.forecast, "Raw shows “\(asSent.prefix(60))”")
        note("    Raw: the text as it came; pictures: \(try await pictures(of: page, "json-raw"))")

        // Hex: its first lines, as AT-SPI reads them too, and what it copies.
        try await choose("Hex", of: view)
        let hex = try present(view.views[.hex] as? HexView, "Hex shows no hex")
        let first = "000000  7B 22 63 69 74 79 22 3A  22 54 65 68 72 61 6E 22  {\"city\":\"Tehran\""
        try require(hex.shownLines.first == first, "hex's first line is “\(hex.shownLines.first ?? "")”")
        try require(hex.shownLines.count == 7, "hex shows \(hex.shownLines.count) lines of 104 bytes")
        note("    Hex: \(hex.shownLines.count) lines from \(hex.pagesRead) page; the first “\(first)”")
        let allHex = Array(Self.forecast.utf8).map { String(format: "%02X", $0) }.joined(separator: " ")
        emit(raw(view.copyButton), "clicked")
        try await until("Copy Body to copy the hex") { copiedText() == allHex }
        hex.select(0..<16)
        let selected =
            string(gtk_label_get_text(cast(gtk_widget_get_first_child(gtk_widget_get_last_child(hex.widget))))) ?? ""
        try require(selected == "16 bytes selected at offset 0", "the hex view says “\(selected)”")
        emit(raw(view.copyButton), "clicked")
        try await until("Copy Body to copy the line chosen") { copiedText() == String(allHex.prefix(47)) }
        note("    copies all 104 bytes as hex, or the line chosen: “\(selected)”")
        // Ctrl+C in the list, as keys, copies the lines chosen.
        gtk_selection_model_unselect_all(gtk_list_view_get_model(cast(hex.list)))
        hex.select(16..<32)
        gtk_widget_grab_focus(hex.list)
        try FakeInput.press("Control_L", "c", in: page.window)
        let second = String(allHex.dropFirst(48).prefix(47))
        try await until("Ctrl+C to copy the second line", seconds: 5) { copiedText() == second }
        note("    Ctrl+C in the list copies the second line: “\(second)”")
        let tree11y = try await AccessibilityTree.read(depth: 40, children: 40, text: true)
        let own = tree11y.subtree { $0.role == "frame" && $0.name == BodyPage.title }
        let named = own.first { $0.name == first }
        let read = own.first { $0.text == first }
        note(
            "    AT-SPI: a \(named?.role ?? "nothing") named the first line, and a \(read?.role ?? "nothing") whose text it is"
        )
        try require(
            named != nil && read != nil, "AT-SPI doesn't read the first hex line: \(own.prefix(60).map(\.line))")
        note("    pictures: \(try await pictures(of: page, "json-hex"))")

        // Narrow, a line has 8 bytes.
        page.resize(width: 400)
        try await until("hex lines of 8 bytes", seconds: 5) { hex.perLine == 8 && !hex.isReading }
        await settlePage()
        let narrow = hex.shownLines.first ?? ""
        try require(narrow == "000000  7B 22 63 69 74 79 22 3A  {\"city\":", "a narrow first line is “\(narrow)”")
        note("    400 pixels wide: “\(narrow)”; pictures: \(try await pictures(of: page, "json-hex-narrow"))")
        page.resize(width: BodyPage.width)
        try await until("hex lines of 16 bytes", seconds: 5) { hex.perLine == 16 }

        // A request with no body.
        let none = try await show(id, .request, on: page)
        try expect(none, says: "This request has no body.", offers: [], "no body")
        try require(gtk_widget_get_visible(none.copyButton) == 0, "Copy Body shows for no body")
    }

    /// With GNOME's high contrast on, code takes the Mac's high-contrast colors, and goes back
    /// once it's off.
    private func checkHighContrast(_ code: CodeView, on page: BodyPage) async throws {
        let manager = adw_style_manager_get_default()
        let settings = g_settings_new("org.gnome.desktop.a11y.interface")!
        defer { g_object_unref(raw(settings)) }
        let before = [code.shade(of: .key), code.shade(of: .string)]
        g_settings_set_boolean(settings, "high-contrast", 1)
        defer { g_settings_set_boolean(settings, "high-contrast", 0) }
        try await until("high contrast", seconds: 5) { adw_style_manager_get_high_contrast(manager) != 0 }
        await settlePage()
        let isDark = adw_style_manager_get_dark(manager) != 0
        let high = [code.shade(of: .key), code.shade(of: .string)]
        let expected = isDark ? ["#FFFFFF", "#FFC6A1"] : ["#000000", "#843300"]
        note("    high contrast: keys \(before[0]) to \(high[0]), strings \(before[1]) to \(high[1])")
        try require(high == expected, "with high contrast, keys and strings are \(high), not \(expected)")
        note("    pictures: \(try await pictures(of: page, "json-formatted-high-contrast"))")
        g_settings_set_boolean(settings, "high-contrast", 0)
        try await until("high contrast to end", seconds: 5) { adw_style_manager_get_high_contrast(manager) == 0 }
        let after = [code.shade(of: .key), code.shade(of: .string)]
        try require(after == before, "without high contrast, keys and strings are \(after), not \(before)")
    }

    /// Save Image… asks where to save, as GTK's file dialog does, suggesting the picture's name.
    private func checkSaveDialog(_ view: BodyView) async throws {
        let save = try present(
            descendants(of: view.widget).first {
                typeName(raw($0)) == "GtkButton" && string(gtk_button_get_label(cast($0))) == "Save Image…"
            }, "the picture has no Save Image…")
        let before = Set(toplevels())
        emit(raw(save), "clicked")
        var dialog: Widget?
        try await until("the file dialog", seconds: 10) {
            dialog = toplevels().first { !before.contains($0) && gtk_widget_get_mapped($0) != 0 }
            return dialog != nil
        }
        let found = try present(dialog, "no file dialog")
        let title = string(gtk_window_get_title(cast(found))) ?? ""
        let name = takeString(gtk_file_chooser_get_current_name(cast(found))) ?? ""
        note("    Save Image… opens “\(title)”, a \(typeName(raw(found))), with the name \(name)")
        try require(title == "Save Image" && name == "image.png", "Save Image… opened “\(title)” for \(name)")
        // Once it has read the folder: GTK 4.14 says it couldn't, in a dialog of its own that
        // stops the window hearing keys, when the dialog closes first.
        try? await Task.sleep(for: .milliseconds(500))
        gtk_dialog_response(cast(found), GTK_RESPONSE_CANCEL.rawValue)
        // Closed, it goes.
        try await until("the file dialog to close", seconds: 5) { !toplevels().contains(found) }
        try? await Task.sleep(for: .milliseconds(300))
        for left in toplevels() where typeName(raw(left)) == "GtkMessageDialog" {
            let words = [stringProperty(raw(left), "text"), stringProperty(raw(left), "secondary-text")]
            let said = words.compactMap { $0 }.joined(separator: " ")
            note("    GTK said “\(said)” as the file dialog closed; closed it")
            gtk_window_destroy(cast(left))
        }
    }

    /// A toast says a path you chose as it is, though its & and < would be Pango markup's. First,
    /// as one toast shows at a time, and the others wait.
    private func checkAToastsWords(_ id: ExchangeID, on page: BodyPage) async throws {
        let view = try await show(id, .response, on: page)
        let preview = try present(view.views[.preview] as? PreviewView, "Preview shows no picture")
        let words = "Reqly couldn't save the image to /tmp/R&D <draft>/map.png."
        let lines = try await standardError {
            preview.onSay?(words)
            await page.settle()
        }.lines
        let said = descendants(of: page.window).filter { typeName(raw($0)) == "AdwToastWidget" }
            .flatMap { descendants(of: $0) }.filter { typeName(raw($0)) == "GtkLabel" }
            .compactMap { string(gtk_label_get_text(cast($0))) }
        let warnings = lines.filter { $0.contains("-WARNING") || $0.contains("-CRITICAL") }
        try require(
            said.contains(words) && warnings.isEmpty,
            "the toast says \(said), and GTK warned \(warnings.prefix(2).joined(separator: " | "))")
        note("a toast says “\(words)” as it is")
    }

    /// The windows that show now.
    private func toplevels() -> [Widget] {
        let windows = gtk_window_get_toplevels()
        return (0..<g_list_model_get_n_items(windows)).compactMap { index in
            guard let window = g_list_model_get_item(windows, index) else { return nil }
            g_object_unref(window)
            return cast(window)
        }
    }

    /// Every widget under `root`, depth first.
    private func descendants(of root: Widget) -> [Widget] {
        var found: [Widget] = []
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            found.append(widget)
            found += descendants(of: widget)
            child = gtk_widget_get_next_sibling(widget)
        }
        return found
    }

    // MARK: - XML, HTML and text

    private func checkTextBodies(_ sent: [String: ExchangeID], on page: BodyPage) async throws {
        BodyView.chosen = [:]
        let xml = try await show(try present(sent["xml"], "no XML"), .response, on: page)
        try expect(xml, says: "XML · 128 B", offers: ["Formatted", "Raw", "Hex"], "XML")
        let laidOut = try code(xml)
        let text = laidOut.shownText
        try require(
            text == xml.body?.body.formatted?.text && text.contains("\n"), "XML's Formatted shows \(text.prefix(80))")
        let tag = laidOut.color(at: try offset(of: "forecast", in: text))
        let value = laidOut.color(at: try offset(of: #""Tehran""#, in: text))
        try require(tag == "number" && value == "string", "XML's tag is \(tag) and its attribute's value \(value)")
        note("    Formatted: \(text.split(separator: "\n").count) lines, its tags \(tag), values \(value)")

        let html = try await show(try present(sent["html"], "no HTML"), .response, on: page)
        try expect(html, says: "HTML · 109 B", offers: ["Raw", "Hex"], "HTML")
        try require(try code(html).shownText.hasPrefix("<!doctype html>"), "HTML's Raw shows something else")

        let plain = try await show(try present(sent["text"], "no text"), .response, on: page)
        try expect(plain, says: "Text · 40 B", offers: ["Text", "Hex"], "text")
        let words = try code(plain)
        try require(
            words.shownText == "Clear skies over Tehran.\nRain tomorrow.\n"
                && gtk_text_view_get_wrap_mode(cast(words.view)) == GTK_WRAP_WORD_CHAR
                && words.color(at: 0) == "plain",
            "text shows “\(words.shownText)”, wrapping \(gtk_text_view_get_wrap_mode(cast(words.view)).rawValue)")
        note("    text wraps, in its own color; pictures: \(try await pictures(of: page, "text"))")
    }

    // MARK: - Forms

    private func checkForms(_ form: ExchangeID, _ multipart: ExchangeID, on page: BodyPage) async throws {
        let fields = try await show(form, .response, on: page)
        try expect(fields, says: "Form · 31 B", offers: ["Form", "Raw", "Hex"], "form")
        let rows = try present(fields.views[.form] as? FormView, "Form shows no form").rows
        try require(
            rows.map { "\($0.name)=\($0.value)" } == ["city=Tehran", "days=3", "units=metric"],
            "the form's rows are \(rows)")
        note(
            "    \(rows.map { "\($0.name): \($0.value)" }.joined(separator: ", ")); pictures: \(try await pictures(of: page, "form"))"
        )

        let parts = try await show(multipart, .response, on: page)
        let size = 210 + TestServer.png.count
        try expect(
            parts, says: "Multipart form · \(ByteCount.text(Int64(size)))", offers: ["Form", "Hex"], "multipart")
        let partRows = try present(parts.views[.form] as? FormView, "Form shows no form").rows
        let file = "map.png · image/png · \(TestServer.png.count) B"
        try require(
            partRows.map(\.name) == ["city", "map"] && partRows.map(\.value) == ["Tehran", file],
            "the multipart form's rows are \(partRows)")
        note("    \(partRows.map { "\($0.name): \($0.value)" }.joined(separator: ", "))")
    }

    // MARK: - A picture

    private func checkPicture(_ id: ExchangeID, on page: BodyPage) async throws {
        let view = try await show(id, .response, on: page)
        let bytes = TestServer.png.count
        try expect(view, says: "PNG · \(bytes) B", offers: ["Preview", "Hex"], "picture")
        let preview = try present(view.views[.preview] as? PreviewView, "Preview shows no picture")
        let facts = preview.facts.map { "\($0.name): \($0.value)" }
        try require(
            facts == ["Format: PNG, with transparency", "Dimensions: 16 × 12 pixels", "Size: \(bytes) B"],
            "the picture's rows say \(facts)")
        try require(preview.texture != nil, "GTK didn't read the picture")
        note("    \(facts.joined(separator: ", "))")
        emit(raw(view.copyButton), "clicked")
        let copied = copiedPicture()
        try require(copied?.width == 16 && copied?.height == 12, "Copy Body copied \(String(describing: copied))")
        let saved = try scratchFolder("saved").appending(path: "map.png")
        preview.save(to: saved)
        let opened = try await preview.fileToOpen()
        try require(
            (try? Data(contentsOf: saved)) == Data(TestServer.png)
                && (try? Data(contentsOf: opened)) == Data(TestServer.png)
                && opened.lastPathComponent == "image.png",
            "the picture saved, or written to open, isn't its bytes, or is called \(opened.lastPathComponent)")
        // In Reqly's folder in the runtime folder, which only you can open.
        let runtime = try present(
            ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], "the run has no runtime folder")
        try require(
            opened.path == runtime + "/net.reqly.Reqly/images/image.png", "the picture to open is at \(opened.path)")
        note("    Copy Body copies the picture, 16 × 12; it saves, and is written as \(opened.path) to open")
        try await checkSaveDialog(view)
        note("    pictures: \(try await pictures(of: page, "picture"))")
        try await choose("Hex", of: view)
        let hex = try present(view.views[.hex] as? HexView, "the picture shows no hex")
        try require(
            hex.shownLines.first?.hasPrefix("000000  89 50 4E 47") == true,
            "the picture's hex starts \(hex.shownLines.first ?? "")")
        // Copy Body copies the picture in Hex too, as on the Mac.
        gdk_clipboard_set_text(gtk_widget_get_clipboard(page.window), "")
        emit(raw(view.copyButton), "clicked")
        try require(copiedPicture() != nil, "Copy Body in Hex didn't copy the picture")
    }

    // MARK: - Packed and broken

    private func checkPackedAndBroken(packed: ExchangeID, broken: ExchangeID, on page: BodyPage) async throws {
        BodyView.chosen = [:]
        let view = try await show(packed, .response, on: page)
        let size = TestServer.packedJSON.count
        try expect(view, says: "JSON · \(size) B", offers: ["Formatted", "Tree", "Raw", "Hex"], "gzip")
        let unpacked = try present(view.body?.body.content, "gzip has no body").count
        let footnote = "Unpacked from gzip: \(size) B became \(unpacked) B."
        let notes = labels(in: view.footnotes)
        try require(notes == [footnote], "gzip's footnotes say \(notes)")
        try require(try code(view).shownText.contains(#""packed": true"#), "gzip's Formatted doesn't show it unpacked")
        try await choose("Hex", of: view)
        let hex = try present(view.views[.hex] as? HexView, "gzip shows no hex")
        let first = "000000  7B 22 63 69 74 79 22 3A  22 54 65 68 72 61 6E 22  {\"city\":\"Tehran\""
        try require(hex.shownLines.first == first, "gzip's hex isn't unpacked: \(hex.shownLines.first ?? "")")
        note("    “\(footnote)”; Formatted and Hex show it unpacked")

        BodyView.chosen = [:]
        let invalid = try await show(broken, .request, on: page)
        try expect(invalid, says: "JSON · 32 B", offers: ["Raw", "Hex"], "broken JSON")
        let said = labels(in: invalid.note).joined()
        try require(
            gtk_widget_get_visible(invalid.note) != 0 && said.hasPrefix("This isn't valid JSON"),
            "broken JSON's note says “\(said)”")
        try require(
            try code(invalid).shownText == #"{"city": "Tehran", "days": [1, 2"#,
            "broken JSON's Raw shows something else")
        note("    broken JSON's note: “\(said)”; pictures: \(try await pictures(of: page, "broken-json"))")
    }

    /// The words of the labels in `box`.
    private func labels(in box: Widget) -> [String] {
        var words: [String] = []
        var child = gtk_widget_get_first_child(box)
        while let widget = child {
            if typeName(raw(widget)) == "GtkLabel" {
                words.append(string(gtk_label_get_text(cast(widget))) ?? "")
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return words
    }

    // MARK: - Bytes

    private func checkBytes(_ id: ExchangeID, on page: BodyPage) async throws {
        let view = try await show(id, .request, on: page)
        try expect(view, says: "Binary · 1.0 KB", offers: ["Hex"], "bytes")
        let hex = try present(view.views[.hex] as? HexView, "bytes show no hex")
        let lines = hex.shownLines
        try require(
            lines.first == "000000  00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F  ................"
                && lines.dropFirst(2).first
                    == "000020  20 21 22 23 24 25 26 27  28 29 2A 2B 2C 2D 2E 2F   !\"#$%&'()*+,-./",
            "the bytes' lines are \(lines.prefix(3))")
        let tree = try await AccessibilityTree.read(depth: 40, children: 80, text: true)
        let own = tree.subtree { $0.role == "frame" && $0.name == BodyPage.title }
        let list = own.first { $0.name == "Hex, 1,024 bytes" }
        let read = own.compactMap(\.text).filter { $0.hasPrefix("0000") }
        note(
            "    AT-SPI: a \(list?.role ?? "nothing") “\(list?.name ?? "")” of \(list?.children ?? 0) lines; its first: \(read.prefix(3).map { "“\($0)”" }.joined(separator: ", "))"
        )
        try require(read.prefix(3) == lines.prefix(3), "AT-SPI reads the hex lines as \(read.prefix(3))")
        note("    pictures: \(try await pictures(of: page, "bytes"))")
    }

    // MARK: - The mode chosen

    /// The mode you choose stays for the next body of the part that has it, and one that hasn't
    /// it shows its first.
    private func checkChosenModes(_ sent: [String: ExchangeID], on page: BodyPage) async throws {
        BodyView.chosen = [:]
        let json = try await show(try present(sent["json"], "no JSON"), .response, on: page)
        try await choose("Hex", of: json)
        let xml = try await show(try present(sent["xml"], "no XML"), .response, on: page)
        let xmlMode = xml.mode
        try await choose("Formatted", of: xml)
        let html = try await show(try present(sent["html"], "no HTML"), .response, on: page)
        let again = try await show(try present(sent["json"], "no JSON"), .response, on: page)
        let shown = [xmlMode, html.mode, again.mode].map { $0.map { "\($0)" } ?? "none" }
        try require(shown == ["hex", "raw", "formatted"], "after Hex, then Formatted, the modes shown are \(shown)")
        note("chosen modes: Hex on JSON, then XML shows hex; Formatted there, HTML shows raw, JSON formatted")
        BodyView.chosen = [:]
    }

    // MARK: - The Mac's session

    /// In a copy with the Mac's session: each body it has, in a body view, among them JSON, a
    /// form with Persian in it, gzip, a picture and gRPC.
    private func checkTheMacsBodies() async throws {
        let session = try await session()
        try await until("the saved session's rows", seconds: 10) { window.list.count > 0 }
        let page = try await BodyPage.open(over: window.window)
        defer { page.close() }
        var found: Set<String> = []
        for id in await session.rowIDs().ids {
            let exchange = try await session.exchange(id)
            for part in [MessagePart.request, .response] {
                let data = part == .request ? exchange.requestBody : exchange.responseBody
                guard !data.isEmpty else { continue }
                // Each in its own first mode, rather than the last one the sweep below chose.
                BodyView.chosen = [:]
                let view = try await show(id, part, on: page)
                let said = string(gtk_label_get_text(cast(view.summary))) ?? ""
                let mode = view.mode.map { "\($0)" } ?? "none"
                note("#\(id.rawValue) \(part): “\(said)”, \(modes(of: view).joined(separator: ", ")), showing \(mode)")
                if said.hasPrefix("JSON"), let code = view.codeView, code.shownText.contains("\n  ") {
                    found.insert("JSON")
                }
                if said.hasPrefix("Form"),
                    (view.views[.form] as? FormView)?.rows.contains(where: { $0.value == "تهران" }) == true
                {
                    found.insert("a form with Persian")
                }
                if labels(in: view.footnotes).contains(where: { $0.hasPrefix("Unpacked from gzip") }) {
                    found.insert("gzip")
                }
                if (view.views[.preview] as? PreviewView)?.texture != nil { found.insert("a picture") }
                if said.hasPrefix("gRPC · 1 message") { found.insert("gRPC") }
                note("    \(try await checkEveryMode(view).joined(separator: "; "))")
            }
        }
        for kind in ["JSON", "a form with Persian", "gzip", "a picture", "gRPC"] {
            try require(found.contains(kind), "the Mac's session showed no \(kind)")
        }
    }

    // MARK: - Big bodies

    /// A 2 MB JSON body, sent on one line, and 520 KB on one line, as JSON and as text, in each
    /// of their modes: the window's longest wait stays under 200 ms at each step, the run's first
    /// code view, which loads GtkSourceView, measured apart; the page shows the start of what's
    /// long, and keeps the caret in view as it moves down it; and Show Whole Body opens all of it
    /// in a view of its own, a long line in pieces, which scrolls to the end.
    func checkBigBodies() async throws {
        let big = Self.bigJSON(bytes: 2 << 20)
        let line = Self.bigJSON(bytes: 520 << 10)
        let text = Array(String(repeating: "Clear skies over Tehran, rain tomorrow. ", count: 520 * 1024 / 40).utf8)
        let sent = try await capturing(["small", "big", "line", "text"]) { client, server in
            for (name, type, body) in [
                ("small", "application/json", Self.bigJSON(bytes: 74 << 10)),
                ("big", "application/json", big), ("line", "application/json", line), ("text", "text/plain", text),
            ] {
                _ = try await client.send(
                    server.url(.ok, "body=\(name)"), method: "POST", headers: [("Content-Type", type)], body: body)
            }
        }
        let page = try await BodyPage.open(over: window.window)
        defer { page.close() }
        let watch = ThreadWatch()
        watch.start()
        defer { watch.stop() }
        var steps: [String] = []
        /// Runs `step`, then waits for the window to settle, and fails if the window waited 200 ms
        /// or more meanwhile.
        func measure(_ name: String, _ step: () async throws -> Void) async throws {
            let start = monotonicMicroseconds()
            try await step()
            await settlePage()
            let waits = watch.waits(from: start)
            let took = (monotonicMicroseconds() - start) / 1000
            note("    \(name): \(took) ms, \(waits)")
            steps.append(name)
            try require(waits.longest < 200, "\(name) kept the window waiting \(Int(waits.longest)) ms")
        }

        BodyView.chosen = [:]
        var view: BodyView?
        // GtkSourceView and the monospace font load with the first code view a run shows.
        try await measure("the run's first code view, 74 KB of JSON") {
            _ = try await show(try present(sent["small"], "no small body"), .request, on: page)
        }
        try await measure("2 MB of JSON, Formatted") {
            view = try await show(try present(sent["big"], "no big body"), .request, on: page)
        }
        let bigView = try present(view, "no view")
        let formatted = try code(bigView)
        try require(
            formatted.text.isCut && formatted.text.shownLines == CodeText.lineLimit
                && gtk_widget_get_visible(bigView.startLine) != 0,
            "the page shows \(formatted.text.shownLines) of \(formatted.text.lines) lines")
        note("    shows “\(labels(in: bigView.startLine).joined())”")
        try await checkCaretFollows(formatted, on: page)
        try await measure("its Raw, one line") { try await choose("Raw", of: bigView) }
        try await measure("its Tree") { try await choose("Tree", of: bigView) }
        let tree = try present(bigView.views[.tree] as? TreeView, "no tree")
        try await measure("its tree filtered for “item 12”") {
            tree.setFilter("item 12")
            try await until("the filter to keep rows", seconds: 20) { tree.kept != nil && tree.rowCount > 0 }
        }
        note("    the filter keeps \(tree.kept?.count ?? 0) nodes")
        try await measure("its Hex, to the end") {
            try await choose("Hex", of: bigView)
            let hex = try present(bigView.views[.hex] as? HexView, "no hex")
            let last = HexLines.count(size: hex.size, perLine: hex.perLine) - 1
            gtk_list_view_scroll_to(cast(hex.list), UInt32(last), GTK_LIST_SCROLL_NONE, nil)
            try await until("the last hex line", seconds: 10) {
                !hex.isReading && hex.shownLines.last?.hasPrefix(String(format: "%06X", last * hex.perLine)) == true
            }
            note("    the last hex line: “\(hex.shownLines.last ?? "")”, after \(hex.pagesRead) pages")
        }
        try await choose("Formatted", of: bigView)
        try await measure("Show Whole Body, scrolled to the end") {
            try await showWhole(bigView)
        }
        try await choose("Raw", of: bigView)
        try await measure("its Raw's Show Whole Body, 2 MB on one line") {
            try await showWhole(bigView)
        }

        for (name, title) in [("line", "Raw"), ("text", "Text")] {
            try await measure("520 KB on one line, \(title)") {
                view = try await show(try present(sent[name], "no \(name)"), .request, on: page)
                if title == "Raw" {
                    try await choose("Raw", of: try present(view, "no view"))
                }
            }
            let shown = try present(view, "no view")
            let code = try self.code(shown)
            try require(code.text.isCut && code.text.lines == 1, "the long line shows \(code.text.shownBytes) bytes")
            note("    shows “\(labels(in: shown.startLine).joined())”")
            try await measure("its Show Whole Body") { try await showWhole(shown) }
        }
        try require(steps.count == 12, "only \(steps.count) steps ran")
        // Pictures of the dialog alone: drawing the whole window into a picture, with 256 KB of
        // text on the page under it, sometimes makes GTK's GL renderer say its queue is too large
        // and leave some out, though drawing it on screen never has.
        let last = try present(view, "no view")
        emit(raw(last.showWhole), "clicked")
        try await until("the whole body", seconds: 30) { last.whole?.code.isFilled == true }
        let dialog = try present(last.whole?.dialog, "no whole body")
        note("    pictures: \(try await pictures(of: page, "whole-body", only: dialog))")
        last.whole?.close()
        try await until("Show Whole Body to close") { last.whole == nil }
    }

    /// The caret, moved down a code view taller than the page, as the arrow keys move it, keeps
    /// the page scrolled to it, as the view can't scroll itself.
    private func checkCaretFollows(_ code: CodeView, on page: BodyPage) async throws {
        let adjustment = gtk_scrolled_window_get_vadjustment(cast(page.scroller))
        gtk_adjustment_set_value(adjustment, 0)
        gtk_widget_grab_focus(code.view)
        await settlePage()
        var place = GtkTextIter()
        gtk_text_buffer_get_iter_at_line(code.buffer, &place, 3_000)
        gtk_text_buffer_place_cursor(code.buffer, &place)
        try await until("the page to scroll to the caret", seconds: 5) { gtk_adjustment_get_value(adjustment) > 0 }
        await settlePage()
        var caret = GdkRectangle()
        gtk_text_view_get_iter_location(cast(code.view), &place, &caret)
        var x: Int32 = 0
        var y: Int32 = 0
        gtk_text_view_buffer_to_window_coords(cast(code.view), GTK_TEXT_WINDOW_WIDGET, caret.x, caret.y, &x, &y)
        var point = graphene_point_t(x: Float(x), y: Float(y))
        var found = graphene_point_t()
        _ = gtk_widget_compute_point(code.view, page.scroller, &point, &found)
        let height = Float(gtk_widget_get_height(page.scroller))
        let top = Int(gtk_adjustment_get_value(adjustment))
        note(
            "    the caret on line 3,001 scrolls the page to \(top) px, the caret \(Int(found.y)) px down its \(Int(height))"
        )
        try require(
            found.y >= 0 && found.y + Float(caret.height) <= height, "the caret is at \(found.y) px, off the page")
    }

    /// Opens Show Whole Body, checks the whole text is there, scrolls it to its end and closes it.
    private func showWhole(_ view: BodyView) async throws {
        let presented = try present(view.body?.body, "no body")
        let code = try present(
            view.mode == .formatted ? presented.formatted ?? presented.raw : presented.raw, "the body has no text")
        emit(raw(view.showWhole), "clicked")
        try await until("the whole body", seconds: 30) { view.whole?.code.isFilled == true }
        let whole = try present(view.whole, "Show Whole Body opened nothing")
        // All of it, with a line break between the pieces of a line too long to show whole.
        let characters = gtk_text_buffer_get_char_count(whole.code.buffer)
        let shown = whole.code.text
        try require(
            !shown.isCut && shown.bytes == code.text.utf8.count
                && Int(characters) == shown.text.unicodeScalars.count,
            "the whole body has \(characters) characters of \(code.text.unicodeScalars.count)")
        if shown.isSplit {
            note("    in pieces, wrapped: \(gtk_text_view_get_wrap_mode(cast(whole.code.view)) == GTK_WRAP_WORD_CHAR)")
        }
        let adjustment = gtk_scrolled_window_get_vadjustment(cast(whole.code.widget))
        await settlePage()
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
        await settlePage()
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_upper(adjustment))
        await settlePage()
        note(
            "    the whole body: \(characters) characters, \(gtk_text_buffer_get_line_count(whole.code.buffer)) lines, scrolled to \(Int(gtk_adjustment_get_value(adjustment))) px"
        )
        whole.close()
        try await until("Show Whole Body to close") { view.whole == nil }
    }

    /// JSON of about `bytes`, on one line, as an API sends it: an array of forecasts.
    private static func bigJSON(bytes: Int) -> [UInt8] {
        var text = "["
        var item = 0
        while text.utf8.count < bytes - 120 {
            if item > 0 {
                text += ","
            }
            text +=
                #"{"id":\#(item),"name":"item \#(item)","sky":"clear","high":\#(item % 40),"rain":false,"wind":null}"#
            item += 1
        }
        return Array((text + "]").utf8)
    }
}

/// A window of the body parts' own, over the main one, holding body views as the details' pages
/// do: a scroller, a clamp and a box, in a toast overlay.
@MainActor
final class BodyPage {
    static let title = "Self-check Bodies"
    /// Wide enough for hex lines of 16 bytes in any monospace font: 760 pixels were too few for
    /// some, as in the Debian 13 and Ubuntu 26.04 images.
    static let width: Int32 = 1_000

    let window: Widget
    let box: Widget
    let scroller: Widget
    /// The page that shows now.
    private(set) static weak var showing: BodyPage?
    private var view: BodyView?
    private var isOpen = true
    /// How many frames it has painted, and when it painted the latest.
    private var paints = 0
    private var lastPaint = 0

    private init(over parent: Widget) {
        window = adw_window_new()
        gtk_window_set_title(cast(window), Self.title)
        gtk_window_set_transient_for(cast(window), cast(parent))
        gtk_window_set_default_size(cast(window), Self.width, 740)
        box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18)
        gtk_widget_set_margin_top(box, 18)
        gtk_widget_set_margin_bottom(box, 18)
        gtk_widget_set_margin_start(box, 12)
        gtk_widget_set_margin_end(box, 12)
        let clamp = adw_clamp_new()!
        adw_clamp_set_maximum_size(cast(clamp), 900)
        adw_clamp_set_child(cast(clamp), box)
        scroller = gtk_scrolled_window_new()
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), clamp)
        setAccessibleLabel(scroller, "Body page")
        let toasts = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(cast(toasts), scroller)
        adw_window_set_content(cast(window), toasts)
    }

    /// Opens it, and waits for it to show.
    static func open(over parent: Widget) async throws -> BodyPage {
        let page = BodyPage(over: parent)
        gtk_window_present(cast(page.window))
        let deadline = monotonicMicroseconds() + 5_000_000
        while gtk_widget_get_mapped(page.window) == 0 {
            guard monotonicMicroseconds() < deadline else { throw SelfCheck.Failure("the bodies' window didn't show") }
            try await Task.sleep(for: .milliseconds(10))
        }
        if let clock = gtk_widget_get_frame_clock(page.window) {
            connect(raw(clock), "after-paint", whileAlive: raw(page.window)) { [weak page] in
                page?.paints += 1
                page?.lastPaint = monotonicMicroseconds()
            }
        }
        showing = page
        return page
    }

    /// Shows `view` on the page, in place of the one before.
    func show(_ view: BodyView) {
        if let shown = self.view {
            gtk_box_remove(cast(box), shown.widget)
        }
        self.view = view
        gtk_box_append(cast(box), view.widget)
    }

    func resize(width: Int32) {
        gtk_window_set_default_size(cast(window), width, 740)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        view = nil
        if Self.showing === self {
            Self.showing = nil
        }
        gtk_window_destroy(cast(window))
    }

    /// Waits for the page to settle, as ``SelfCheck/settle()`` waits for the window: for its next
    /// frame, then for 150 ms with none. At most 5 s.
    func settle() async {
        let start = monotonicMicroseconds()
        let paintsBefore = paints
        while monotonicMicroseconds() - start < 5_000_000 {
            let now = monotonicMicroseconds()
            if paints > paintsBefore || now - start > 1_000_000, now - lastPaint >= 150_000 {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
