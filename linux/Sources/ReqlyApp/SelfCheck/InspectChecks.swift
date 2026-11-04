import CGtk
import CoreInterface
import Foundation
import GtkBinding
import Presentation
import ReqlyModel

extension SelfCheck {
    /// The panes together: what the list chooses, the details show, with each body in its view, and
    /// Add Comment… opens the comment's field; and the keyboard through all of them.
    static let inspectParts: [Part] = [
        Part(name: "inspect", seconds: 120) { try await $0.checkInspecting() },
        Part(name: "keyboard", seconds: 180) { try await $0.checkKeyboard() },
    ]

    // MARK: - The list, the details and the bodies

    /// At 1000 pixels, with the details over the list: Enter on a row shows its request in the
    /// details, Ctrl+3 its response, and the response's body in its view, formatted; Tree, chosen
    /// with its button, stays for the next request's body. Add Comment…, from the row's menu, puts
    /// the keyboard's focus in the comment's field, where Enter saves what you type, and the row
    /// shows it. Back, then Enter on a request with no comment, the focus is on a widget that
    /// shows, not in the hidden field. GTK warns of nothing meanwhile.
    func checkInspecting() async throws {
        // Tree, chosen here, isn't for the parts after.
        defer { BodyView.chosen[.response] = nil }
        let session = try await emptyTheList()
        let traffic = try await startTraffic()
        defer { traffic.server.stop() }
        let size = defaultSize
        do {
            try await withoutWarnings { try await self.inspect(session, traffic) }
        } catch {
            await putTheWindowBack(size)
            try? await stopTraffic()
            throw error
        }
        await putTheWindowBack(size)
        try await stopTraffic()
        try await emptyTheList()
    }

    private func inspect(_ session: SessionHost, _ traffic: Traffic) async throws {
        let window = window
        let list = window.list
        let details = window.details
        let ids = try await sendJSON(2, session, traffic)
        try await resize(to: 1000)

        try await focusRow(ids[0])
        try FakeInput.press("Return", in: window.window)
        do {
            try await until("Enter to show the request over the list", seconds: 3) {
                window.detailsAreOver && details.shown == ids[0]
            }
        } catch {
            let shown = details.shown.map { "#\($0.rawValue)" } ?? "nothing"
            throw Failure(
                "Enter on #\(ids[0].rawValue)'s row: the details show \(shown), "
                    + (adw_navigation_split_view_get_collapsed(window.inner) != 0 ? "folded" : "beside the list")
                    + (window.detailsAreOver ? ", over the list" : "") + ", the focus in the \(pane(of: focusWidget)), "
                    + "the window \(gtk_window_is_active(cast(window.window)) != 0 ? "active" : "inactive")")
        }
        await settle()
        try FakeInput.press("Control_L", "3", in: window.window)
        try await until("Ctrl+3 to show the response's body, formatted", seconds: 10) {
            details.page == .response && details.bodies[.response]?.body != nil
                && details.bodies[.response]?.mode == .formatted
        }
        let view = try present(details.bodies[.response], "the Response page has no body view")
        let page = try present(details.contents[.response], "the Response page has no box")
        await settle()
        try require(
            gtk_widget_is_ancestor(view.widget, page) != 0 && gtk_widget_get_mapped(view.widget) != 0,
            "the response's body view doesn't show on the Response page")
        let summary = string(gtk_label_get_text(cast(view.summary))) ?? ""
        try require(summary == "JSON · 104 B", "the body's line says “\(summary)”")
        try await until("the body's code to show", seconds: 5) { view.codeView?.isFilled == true }
        let code = view.codeView?.shownText ?? ""
        try require(code.contains("\"city\": \"Tehran\""), "the formatted body shows “\(code.prefix(60))”")
        note("Enter on a row: its details over the list; Ctrl+3: its response, the body “\(summary)”, formatted")

        let tree = try present(modeButton("Tree", of: view), "the body has no Tree button")
        emit(raw(tree), "clicked")
        try await until("Tree to show", seconds: 5) { view.mode == .tree }
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to go back to the row", seconds: 3) { !window.detailsAreOver }
        await settle()
        try await focusRow(ids[0])
        try FakeInput.press("Down", in: window.window)
        try await until("Down to choose the next row", seconds: 3) {
            list.selected == ids[1] && details.shown == ids[1]
        }
        try FakeInput.press("Return", in: window.window)
        try await until("the next request's response body, in Tree", seconds: 10) {
            window.detailsAreOver && details.page == .response && details.bodies[.response]?.mode == .tree
        }
        note("Tree, chosen with its button, stays for the next request's body, which opens in it")

        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to go back to the row", seconds: 3) { !window.detailsAreOver }
        await settle()
        try await focusRow(ids[1])
        try FakeInput.press("Menu", in: window.window)
        try await until("the row's menu to open", seconds: 3) { list.menu.isOpen }
        await settle()
        let entry = try present(
            Self.widgets(under: list.menu.popover).first {
                typeName(raw($0)) == "GtkModelButton" && stringProperty(raw($0), "text") == "Add Comment…"
            }, "the row's menu has no Add Comment…")
        gtk_widget_activate(entry)
        try await until("Add Comment… to put the focus in the comment's field", seconds: 5) {
            window.detailsAreOver && details.page == .overview
                && self.focusWidget.map { window.isInside($0, details.commentField) } == true
        }
        // The menu closing gives the window back the keyboard, which doesn't take the field away.
        await settle()
        try require(
            focusWidget.map { window.isInside($0, details.commentField) } == true
                && gtk_widget_get_mapped(details.commentField) != 0,
            "once the menu closed, the focus is on the \(focusType), not in the comment's field")
        for key in ["o", "k", "Return"] {
            try FakeInput.press(key, in: window.window)
        }
        try await until("Enter to save the comment, which the row shows", seconds: 5) {
            list.text(of: ids[1])?.comment == "ok"
        }
        let saved = await session.rows([ids[1]]).first?.annotation.comment
        try require(saved == "ok", "the session's comment is \(saved.map { "“\($0)”" } ?? "none")")
        note(
            "Add Comment…, from the row's menu: the focus in the comment's field; “ok” and Enter save it, as the "
                + "row shows")

        // Back from the comment's field, and Enter on a request with no comment: libadwaita gives
        // the focus back to the field, which doesn't show for this one, so the details' first widget
        // has it instead.
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to go back from the comment's field", seconds: 3) { !window.detailsAreOver }
        await settle()
        try await focusRow(ids[0])
        try FakeInput.press("Return", in: window.window)
        try await until("Enter to show the request with no comment", seconds: 3) {
            window.detailsAreOver && details.shown == ids[0]
        }
        await settle()
        let focus = try present(focusWidget, "with the details over the list, nothing has the focus")
        try require(
            window.isInside(focus, details.widget) && gtk_widget_is_visible(focus) != 0
                && gtk_widget_get_visible(details.commentSection) == 0,
            "with the details of a request with no comment, the focus is on the \(focusType), which "
                + (gtk_widget_is_visible(focus) != 0 ? "shows" : "doesn't show"))
        note("Enter on a request with no comment, after the field had the focus: the focus in the \(pane(of: focus))")
        try await session.annotate(ids[1], comment: .remove)
    }

    // MARK: - The keyboard

    /// The keyboard through the panes. At 1280 pixels, Tab goes from the sidebar to the list's
    /// header bar, the search bar and the filter bar, the list in one stop, the details' header bar
    /// and the request's heading, then the page and its tabs, which are under it in a pane this
    /// narrow. A click on the capture switch gives it the focus, as it starts and stops capturing.
    /// At 1000 pixels, Enter on a row shows the details over the list, and screen readers hear
    /// "Details". At 1280 pixels, a body fits the details in each of its modes, and every scroller,
    /// and every button, has a name for screen readers. Then two copies of Reqly: with an empty
    /// session, the first focus is the capture switch; with the session the Mac saved, the list,
    /// once its requests show. In a copy, this part checks only that.
    func checkKeyboard() async throws {
        if app.options.startsCapturing == false {
            try await checkTheFirstFocus()
            return
        }
        let session = try await emptyTheList()
        let traffic = try await startTraffic()
        defer { traffic.server.stop() }
        let size = defaultSize
        do {
            try await withoutWarnings {
                let ids = try await self.sendJSON(2, session, traffic)
                try await self.stopTraffic()
                try await self.checkTabOrder(ids)
                try await self.checkTheCaptureSwitchsClick()
                try await self.checkTheDetailsHeard(ids)
                try await self.checkTheNames(ids)
            }
        } catch {
            await putTheWindowBack(size)
            try? await stopTraffic()
            throw error
        }
        await putTheWindowBack(size)
        try await emptyTheList()

        let empty = try await runInCopy(["keyboard"], options: ["--starts-capturing", "no"])
        let saved = try await runInCopy(
            ["keyboard"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"])
        for line in (empty + saved) where !line.hasSuffix("parts passed") {
            note("copy: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// The keyboard's first focus, in a copy of Reqly: the capture switch, while the session is
    /// empty, or the list, once the requests of the session it opened show.
    private func checkTheFirstFocus() async throws {
        let window = window
        _ = try await session()
        if app.options.smokeSession != nil {
            try await until("the saved session's rows to show, with the first focus", seconds: 10) {
                window.list.count > 0 && self.focusWidget.map { window.isInside($0, window.list.view) } == true
            }
            note("the first focus, with a saved session: the list, \(window.list.count) rows")
        } else {
            try await until("the capture switch to have the first focus", seconds: 10) {
                self.focusWidget == window.captureSwitch
            }
            note("the first focus, with an empty session: the capture switch")
        }
    }

    /// Tab, from the sidebar until it's back there, through each pane in order, the list in one
    /// stop.
    private func checkTabOrder(_ ids: [ExchangeID]) async throws {
        let window = window
        window.list.select(id: ids[0])
        await settle()
        try await resize(to: 1280)
        try await until("the details to show the request", seconds: 5) {
            window.details.shown == ids[0] && window.details.isBuilt(window.details.page)
        }
        await settle()
        window.search.open()
        try await until("the search bar to open", seconds: 3) { window.search.isOpen }
        await settle()
        try require(window.sidebar.focus(), "the sidebar doesn't take the focus")
        await settle()
        var stops: [String] = []
        for _ in 0..<100 {
            let before = focusWidget
            try FakeInput.press("Tab", in: window.window)
            try await until("Tab to move the focus on from the \(focusType)", seconds: 3) {
                self.focusWidget != before
            }
            let region = pane(of: focusWidget)
            stops.append(region)
            if region == "sidebar", stops.contains(where: { $0 != "sidebar" }) {
                break
            }
        }
        var order: [String] = []
        for stop in stops where stop != order.last {
            order.append(stop)
        }
        let listStops = stops.filter { $0 == "list" }.count
        note("Tab, at 1280 px: \(order.joined(separator: ", ")), in \(stops.count) presses")
        let expected = [
            "list's header bar", "search bar", "filter bar", "list", "details' header bar", "request's heading", "page",
            "details' tabs", "sidebar",
        ]
        try require(order == expected, "Tab goes through \(order), not \(expected)")
        try require(listStops == 1, "the list takes \(listStops) Tab stops, not 1")
        window.search.close()
        await settle()
    }

    /// The pane `widget` is in, by its name.
    private func pane(of widget: Widget?) -> String {
        guard let widget else { return "nothing" }
        let window = window
        let panes: [(String, Widget)] = [
            ("sidebar", window.sidebarPane), ("list's header bar", window.listHeader),
            ("search bar", window.search.widget), ("filter bar", window.filters.widget), ("list", window.list.view),
            ("details' header bar", window.details.headerBar), ("request's heading", window.details.heading),
            ("details' tabs", window.details.switcherBar), ("page", cast(window.details.stack)),
        ]
        return panes.first { window.isInside(widget, $0.1) }?.0 ?? typeName(raw(widget))
    }

    /// A click on the capture switch starts capturing, and another stops it, the switch having
    /// the keyboard's focus each time.
    private func checkTheCaptureSwitchsClick() async throws {
        let window = window
        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        _ = try await switchReady()
        for isOn in [true, false] {
            window.list.focusSelection()
            await settle()
            try FakeInput.click(window.captureSwitch)
            try await until("a click on the capture switch to \(isOn ? "start" : "stop") capturing", seconds: 5) {
                isOn ? self.model.capture == .capturing : self.model.capture == .stopped
            }
            await settle()
            try require(
                focusWidget == window.captureSwitch,
                "after a click on the capture switch, the focus is on the \(focusType)")
        }
        note("a click on the capture switch: starts capturing, then stops, the switch focused each time")
    }

    /// At 1000 pixels, Enter on a row shows the details over the list, and screen readers hear
    /// "Details".
    private func checkTheDetailsHeard(_ ids: [ExchangeID]) async throws {
        let window = window
        try await resize(to: 1000)
        try await focusRow(ids[0])
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 5) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            try? FakeInput.press("Return", in: window.window)
            try? await Task.sleep(for: .milliseconds(1000))
        }
        try require(window.detailsAreOver, "Enter didn't show the details over the list")
        let said = heard.map(\.detail)
        try require(said.contains("Details"), "as the details showed, screen readers heard \(said)")
        note(
            "Enter at 1000 px: the details over the list, screen readers hear “Details”, the focus in the "
                + "\(pane(of: focusWidget))")
        adw_navigation_split_view_set_show_content(window.inner, 0)
        await settle()
    }

    /// At 1280 pixels, with a body on the Response page: the body fits the details in each of its
    /// modes, and every scroller and every button has a name for screen readers.
    private func checkTheNames(_ ids: [ExchangeID]) async throws {
        let window = window
        try await resize(to: 1280)
        window.list.select(id: ids[0])
        window.details.show(page: .response)
        try await until("the response's body to show", seconds: 10) {
            window.details.shown == ids[0] && window.details.bodies[.response]?.codeView?.isFilled == true
        }
        await settle()
        // Each of the body's modes fits the details beside the list, so the page doesn't scroll
        // sideways, and GTK doesn't warn that the details are wider than their pane.
        let view = try present(window.details.bodies[.response], "the Response page has no body view")
        let scroller = try present(window.details.scrollers[.response], "the Response page has no scroller")
        let across = gtk_scrolled_window_get_hadjustment(cast(scroller))
        let modes = view.body?.body.modes ?? []
        for mode in modes {
            view.show(mode: mode)
            await settle()
            let over = gtk_adjustment_get_upper(across) - gtk_adjustment_get_page_size(across)
            try require(over < 1, "in \(mode), the Response page is \(Int(over)) px wider than the details")
        }
        view.show(mode: .formatted)
        note(
            "at 1280 px, the details \(gtk_widget_get_width(window.details.widget)) px wide: the response's body fits "
                + "in each of its \(modes.count) modes")
        await settle()
        let tree = try await AccessibilityTree.read()
        let scrollers = tree.nodes.filter { $0.role == "scroll pane" }
        let unnamed = scrollers.filter { $0.name.isEmpty }
        note("scrollers: \(scrollers.map { "“\($0.name)”" }.joined(separator: ", "))")
        try require(unnamed.isEmpty, "\(unnamed.count) of \(scrollers.count) scrollers have no name")
        let buttons = tree.nodes.filter { ["push button", "toggle button"].contains($0.role) }
        let nameless = buttons.filter { $0.name.isEmpty }.map { $0.line.trimmingCharacters(in: .whitespaces) }
        try require(
            nameless.isEmpty, "\(nameless.count) of \(buttons.count) buttons have no name: \(nameless.prefix(5))")
        note("buttons: all \(buttons.count) named")
        window.details.show(page: .overview)
    }

    // MARK: - What they share

    /// Sends `count` requests for JSON, and gives their IDs once their rows show and they've
    /// finished.
    private func sendJSON(_ count: Int, _ session: SessionHost, _ traffic: Traffic) async throws -> [ExchangeID] {
        let list = window.list
        for number in 1...count {
            let answer = try await traffic.client.send(traffic.server.url(.json, "inspect=\(number)"))
            try require(answer.status == 200, "/json answered \(answer.status)")
        }
        try await until("the \(count) requests' rows", seconds: 5) { list.count == count && list.isSettled }
        let ids = Array(await session.rowIDs().ids.suffix(count))
        for _ in 0..<300 {
            if await session.rows(ids).allSatisfy(\.state.isFinished) {
                return ids
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("the \(count) requests didn't finish")
    }

    /// `id`'s row, selected, with the keyboard's focus, and the details beside the list or gone back.
    private func focusRow(_ id: ExchangeID) async throws {
        let window = window
        let list = window.list
        adw_navigation_split_view_set_show_content(window.inner, 0)
        await settle()
        list.select(id: id)
        try await until("the row to be selected", seconds: 3) { list.selected == id }
        list.focusSelection()
        try await until("the row to have the focus", seconds: 3) {
            list.rowWidget(of: id).map { row in self.focusWidget.map { window.isInside($0, row) } ?? false } ?? false
        }
    }

    /// The button of the body's mode called `title`.
    private func modeButton(_ title: String, of view: BodyView) -> Widget? {
        var child = gtk_widget_get_first_child(view.modeSwitch)
        while let widget = child {
            if string(gtk_button_get_label(cast(widget))) == title {
                return widget
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return nil
    }

    /// The window's size as it opened, which the parts put back.
    private var defaultSize: (width: Int32, height: Int32) {
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        return (width, height)
    }

    /// The window `width` pixels wide, once it has settled.
    private func resize(to width: Int32) async throws {
        let window = window
        gtk_window_set_default_size(cast(window.window), width, 760)
        // GTK keeps the window on the screen, inside the shadow's margin.
        try await until("the window to be \(width) pixels wide", seconds: 5) {
            let shown = gtk_widget_get_width(window.window)
            return shown <= width && shown > width - 20
        }
        await settle()
    }

    /// The window as it was: its size, the search bar closed, the details beside the list or gone
    /// back, and the sidebar beside them.
    private func putTheWindowBack(_ size: (width: Int32, height: Int32)) async {
        let window = window
        window.search.close()
        adw_navigation_split_view_set_show_content(window.inner, 0)
        window.details.show(page: .overview)
        gtk_window_set_default_size(cast(window.window), size.width, size.height)
        await settle()
        adw_overlay_split_view_set_show_sidebar(
            window.outer, cBool(adw_overlay_split_view_get_collapsed(window.outer) == 0))
        await settle()
    }
}
