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
    /// details, Ctrl+3 its response, and the response's body in its view, formatted; Alt+Left goes
    /// back from its code, and right to left, Alt+Right does; Tree, chosen with its button, stays
    /// for the next request's body, and Escape in its empty filter goes back. Add Comment…, from
    /// the row's menu, puts the keyboard's focus in the comment's field, where Enter saves what you
    /// type, and the row shows it. Back, then Enter on a request with no comment, the focus is on a
    /// widget that shows, not in the hidden field. At 700 pixels, Alt+Left in the sidebar over the
    /// details leaves them be. GTK warns of nothing meanwhile.
    func checkInspecting() async throws {
        // A body opens in its first mode, whatever the parts before chose, and Tree, chosen here,
        // isn't for the parts after.
        BodyView.chosen = [:]
        defer { BodyView.chosen = [:] }
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
        try await giveTheWindowTheKeyboard()
        try FakeInput.press("Return", in: window.window)
        try await until("Enter to show the request over the list", seconds: 3) {
            window.detailsAreOver && details.shown == ids[0]
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

        // Alt+← goes back from the body's code too, which would take it to move by words.
        let codeView = try present(view.codeView?.view, "the body has no code view")
        gtk_widget_grab_focus(codeView)
        try await until("the body's code to have the focus", seconds: 3) {
            self.focusWidget.map { window.isInside($0, codeView) } == true
        }
        try FakeInput.press("Alt_L", "Left", in: window.window)
        try await until("Alt+Left in the body's code to go back to the row", seconds: 3) { !window.detailsAreOver }
        await settle()
        try await focusRow(ids[0])
        try FakeInput.press("Return", in: window.window)
        try await until("Enter to show the response's body again", seconds: 5) {
            window.detailsAreOver && details.page == .response && details.bodies[.response]?.mode == .formatted
        }
        await settle()
        note("Alt+Left in the body's code: back to the row")
        try await checkBackRightToLeft(ids[0])

        let tree = try present(modeButton("Tree", of: view), "the body has no Tree button")
        emit(raw(tree), "clicked")
        try await until("Tree to show", seconds: 5) { view.mode == .tree }
        // Escape in the tree's filter, while it's empty, goes back too.
        let filter = try present((view.views[.tree] as? TreeView)?.filter, "the tree has no filter")
        await settle()
        gtk_widget_grab_focus(filter)
        try await until("the tree's filter to have the focus", seconds: 3) {
            self.focusWidget.map { window.isInside($0, filter) } == true
        }
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape in the tree's empty filter to go back to the row", seconds: 3) {
            !window.detailsAreOver
        }
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
        try await checkBackUnderTheSidebar(ids[0])
    }

    /// Right to left, as in Hebrew or Arabic, Alt+Right goes back from the details over the list,
    /// from a body's code, which would take it to move by words, and from a tab, where libadwaita's
    /// own Alt+Right does, and Alt+Left goes back from neither. Then the details show the response's
    /// body over the list again, left to right.
    private func checkBackRightToLeft(_ id: ExchangeID) async throws {
        let window = window
        let details = window.details
        let code = try present(details.bodies[.response]?.codeView?.view, "the body has no code view")
        try await rightToLeft {
            gtk_widget_grab_focus(code)
            try await until("the body's code to have the focus, right to left", seconds: 3) {
                self.focusWidget.map { window.isInside($0, code) } == true
            }
            try await requireBackRightToLeft(from: "the body's code")
            try await focusRow(id)
            try FakeInput.press("Return", in: window.window)
            try await until("Enter to show the details again, right to left, with a tab focused", seconds: 5) {
                window.detailsAreOver
                    && self.focusWidget.map {
                        window.isInside($0, details.switcher) || window.isInside($0, details.switcherBar)
                    } == true
            }
            await settle()
            try await requireBackRightToLeft(from: "a tab")
        }
        await settle()
        try await focusRow(id)
        try FakeInput.press("Return", in: window.window)
        try await until("Enter to show the response's body again", seconds: 5) {
            window.detailsAreOver && details.page == .response && details.bodies[.response]?.mode == .formatted
        }
        await settle()
        note("right to left, Alt+Right in the body's code and on a tab: back to the row; Alt+Left: not")
    }

    /// Runs `body` with the window right to left, then as it was.
    private func rightToLeft(_ body: () async throws -> Void) async throws {
        let before = gtk_widget_get_default_direction()
        gtk_widget_set_default_direction(GTK_TEXT_DIR_RTL)
        defer { gtk_widget_set_default_direction(before) }
        await settle()
        try require(gtk_widget_get_direction(window.window) == GTK_TEXT_DIR_RTL, "the window isn't right to left")
        try await body()
    }

    /// Right to left, with the details over the list and `what` focused in them: Alt+Left leaves
    /// them there, and Alt+Right goes back.
    private func requireBackRightToLeft(from what: String) async throws {
        let window = window
        try FakeInput.press("Alt_L", "Left", in: window.window)
        await settle()
        try require(window.detailsAreOver, "right to left, Alt+Left in \(what) went back, from the \(focusType)")
        try FakeInput.press("Alt_L", "Right", in: window.window)
        try await until("Alt+Right in \(what) to go back, right to left", seconds: 3) { !window.detailsAreOver }
        await settle()
    }

    /// At 700 pixels, with the sidebar shown over the details over the list: Alt+Left in the sidebar
    /// leaves the details under it, and Escape puts the sidebar away, then goes back.
    private func checkBackUnderTheSidebar(_ id: ExchangeID) async throws {
        let window = window
        try await resize(to: 700)
        try await focusRow(id)
        try FakeInput.press("Return", in: window.window)
        try await until("Enter to show the details over the list at 700 px", seconds: 3) { window.detailsAreOver }
        await settle()
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to show the sidebar over the details, with the focus", seconds: 3) {
            window.sidebarIsOver && self.focusWidget.map { window.isInside($0, window.sidebarPane) } == true
        }
        await settle()
        try FakeInput.press("Alt_L", "Left", in: window.window)
        await settle()
        try require(window.sidebarIsOver, "Alt+Left in the sidebar over the details put it away")
        try require(window.detailsAreOver, "Alt+Left in the sidebar went back from the details under it")
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to put the sidebar away", seconds: 3) { !window.sidebarIsOver }
        await settle()
        try require(window.detailsAreOver, "once Escape put the sidebar away, the details don't show")
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape again to go back from the details", seconds: 3) { !window.detailsAreOver }
        await settle()
        note("at 700 px, Alt+Left in the sidebar over the details: both stay; Escape: the sidebar goes, then them")
    }

    // MARK: - The keyboard

    /// The keyboard through the panes. At 1280 pixels, Tab goes from the sidebar to the list's
    /// header bar, the search bar and the filter bar, the list in one stop, the details' header bar
    /// and the request's heading, then the page and its tabs, which are under it in a pane this
    /// narrow. A click on the capture switch gives it the focus, as it starts and stops capturing.
    /// At 1000 pixels, Enter on a row shows the details over the list, screen readers hear
    /// "Details", and the page's tab has the focus. At 1280 pixels, a body fits the details in each
    /// of its modes, and every scroller, and every button, has a name for screen readers; with a
    /// request shown, Ctrl+1 to Ctrl+5 choose its pages, which screen readers hear. The focus stays
    /// on what shows as the panes fold and the hex lines narrow. Ctrl+K leaves it on the pinned row
    /// that's left, Clear's button on the capture switch, and Tab from the sidebar still reaches
    /// the list's header bar. Then three copies of Reqly: with an empty session, the first focus is
    /// the capture switch, and with capturing on launch too, once it has started; with the session
    /// the Mac saved, the list, once its requests show. In a copy, this part checks only that.
    func checkKeyboard() async throws {
        if app.options.startsCapturing != nil {
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
                try await self.checkThePageKeys(ids)
                try await self.checkTheFocusAsPanesChange(ids)
                try await self.checkTabAfterClear(ids)
            }
        } catch {
            await putTheWindowBack(size)
            try? await stopTraffic()
            throw error
        }
        await putTheWindowBack(size)
        try await emptyTheList()

        let empty = try await runInCopy(["keyboard"], options: ["--starts-capturing", "no"])
        let capturing = try await runInCopy(["keyboard"], options: ["--starts-capturing", "yes"])
        let saved = try await runInCopy(
            ["keyboard"], options: ["--smoke-session", Self.macSession().path, "--starts-capturing", "no"])
        for line in (empty + capturing + saved) where !line.hasSuffix("parts passed") {
            note("copy: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// The keyboard's first focus, in a copy of Reqly: the capture switch, while the session is
    /// empty, once it can be used, as Start Capturing on launch has it wait; or the list, once the
    /// requests of the session it opened show.
    private func checkTheFirstFocus() async throws {
        let window = window
        _ = try await session()
        if app.options.smokeSession != nil {
            try await until("the saved session's rows to show, with the first focus", seconds: 10) {
                window.list.count > 0 && self.focusWidget.map { window.isInside($0, window.list.view) } == true
            }
            note("the first focus, with a saved session: the list, \(window.list.count) rows")
        } else {
            let starts = app.options.startsCapturing == true
            try await until("the capture switch to have the first focus", seconds: 10) {
                self.focusWidget == window.captureSwitch && (!starts || self.model.capture == .capturing)
            }
            await settle()
            try require(
                focusWidget == window.captureSwitch, "once capturing started, the first focus is on the \(focusType)")
            note("the first focus, with an empty session\(starts ? ", capturing on launch" : ""): the capture switch")
            if starts {
                try await setCapture(on: false)
            }
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
        var moves: [String] = []
        let watch = connect(window.window, "notify::focus-widget") { [weak self] in
            guard let self else { return }
            let tip = self.focusWidget.flatMap { string(gtk_widget_get_tooltip_text($0)) } ?? ""
            moves.append("\(self.focusType) “\(tip)” in the \(self.pane(of: self.focusWidget))")
        }
        defer { g_signal_handler_disconnect(raw(window.window), watch) }
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 5) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            try? FakeInput.press("Return", in: window.window)
            try? await Task.sleep(for: .milliseconds(1000))
        }
        try require(window.detailsAreOver, "Enter didn't show the details over the list")
        let said = heard.map(\.detail)
        try require(said.contains("Details"), "as the details showed, screen readers heard \(said)")
        // The tab of the page that shows has the focus, whatever had it in the details before.
        let isOnTab = focusWidget.map {
            window.isInside($0, window.details.switcher) || window.isInside($0, window.details.switcherBar)
        }
        try require(
            isOnTab == true,
            "once the details showed over the list, the focus is on the \(focusType) in the \(pane(of: focusWidget)), "
                + "having gone to \(moves)")
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
        try await until("the response's body", seconds: 10) {
            window.details.shown == ids[0] && window.details.bodies[.response]?.body != nil
        }
        // Formatted, whatever a part before chose.
        window.details.bodies[.response]?.show(mode: .formatted)
        try await until("the response's body to show, formatted", seconds: 10) {
            window.details.bodies[.response]?.codeView?.isFilled == true
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
        // AT-SPI names a button's role "push button" or "button", as its version has it.
        let buttons = tree.nodes.filter { ["button", "push button", "toggle button"].contains($0.role) }
        let nameless = buttons.filter { $0.name.isEmpty }.map { $0.line.trimmingCharacters(in: .whitespaces) }
        try require(
            nameless.isEmpty, "\(nameless.count) of \(buttons.count) buttons have no name: \(nameless.prefix(5))")
        note("buttons: all \(buttons.count) named")
        window.details.show(page: .overview)
    }

    /// At 1280 pixels, with a request shown: Ctrl+1 to Ctrl+5 choose the details' pages, screen
    /// readers hear each, and each counts as a key you pressed.
    private func checkThePageKeys(_ ids: [ExchangeID]) async throws {
        let window = window
        try await focusRow(ids[0])
        var chosen: [String] = []
        let before = window.inputs
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 6) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            for (index, page) in DetailsPane.Page.allCases.enumerated() {
                try? FakeInput.press("Control_L", "\(index + 1)", in: window.window)
                for _ in 0..<50 where window.details.page != page {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                chosen.append(window.details.page.title)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        let titles = DetailsPane.Page.allCases.map(\.title)
        let said = titles.filter { title in heard.contains { $0.detail == title } }
        note("Ctrl+1 to Ctrl+5: \(chosen.joined(separator: ", ")); heard \(said.joined(separator: ", "))")
        try require(chosen == titles, "Ctrl+1 to Ctrl+5 chose \(chosen), not \(titles)")
        try require(said == titles, "screen readers heard only \(said) of \(titles)")
        let counted = window.inputs - before
        try require(counted >= titles.count, "of Ctrl+1 to Ctrl+5, \(counted) counted as pressed")
        window.details.show(page: .overview)
    }

    /// The keyboard's focus as the window's breakpoints, and the details' own, change the panes:
    /// through the folds, as checkTheFocusThroughFolds() has it; Copy Headers beside the list at
    /// 1280 pixels gives it to the list's pane as the details fold away under it at 1000; a tab of
    /// the details over the list, as the tabs move under the pages at 500, gives it to the tab
    /// there, and back at 700 to the tab in the header bar, and so does one beside the list, as
    /// checkTheTabsMovingBeside() has it; and a hex line, as the lines go from 16 bytes to 8 at
    /// 800, to the line that has its first byte.
    private func checkTheFocusAsPanesChange(_ ids: [ExchangeID]) async throws {
        let window = window
        let details = window.details
        var seen = try await checkTheFocusThroughFolds(ids)
        var moves: [String] = []
        let watch = connect(window.window, "notify::focus-widget") { [weak self] in
            guard let self else { return }
            let tip = self.focusWidget.flatMap { string(gtk_widget_get_tooltip_text($0)) } ?? ""
            moves.append("\(self.focusType) “\(tip)” in the \(self.pane(of: self.focusWidget))")
        }
        defer { g_signal_handler_disconnect(raw(window.window), watch) }

        try await resize(to: 1280)
        details.show(page: .response)
        try await until("the Response page", seconds: 5) { details.isBuilt(.response) }
        await settle()
        let page = try present(details.contents[.response], "the Response page has no box")
        let copy = try present(
            Self.widgets(under: page).first {
                typeName(raw($0)) == "GtkButton" && stringProperty(raw($0), "tooltip-text") == "Copy Headers"
            }, "the Response page has no Copy Headers")
        gtk_widget_grab_focus(copy)
        try await until("Copy Headers to have the focus", seconds: 3) { self.focusWidget == copy }
        moves = []
        try await resize(to: 1000)
        try await until("the focus to leave the details folded away at 1000 px: \(moves)", seconds: 3) {
            self.focusWidget.map { gtk_widget_get_mapped($0) != 0 && window.isInside($0, window.listPane) } == true
        }
        seen.append("Copy Headers beside the list, as the details fold away: the \(pane(of: focusWidget))")

        window.openDetails()
        try await until("the details over the list", seconds: 3) { window.detailsAreOver }
        await settle()
        try require(details.focusTab(), "the details' tab doesn't take the focus")
        try await until("a tab in the header bar to have the focus", seconds: 3) {
            self.focusWidget.map { window.isInside($0, details.headerBar) } == true
        }
        moves = []
        try await resize(to: 500)
        let isOnTabBelow = {
            self.focusWidget.map { window.isInside($0, details.switcherBar) && gtk_widget_get_mapped($0) != 0 } == true
        }
        try await until(
            "the tab under the pages to have the focus at 500 px, not the \(focusType): \(moves)", seconds: 3,
            isOnTabBelow)
        seen.append("a tab of the details over the list, as the tabs go under the pages: the tab there")

        // And back into the header bar at 700 px, where no pane folds, whose looks would give the
        // tab the focus too: the sidebar stays folded away, and the details over the list.
        moves = []
        try await resize(to: 700)
        try require(
            window.detailsAreOver && adw_overlay_split_view_get_collapsed(window.outer) != 0,
            "at 700 px, the details aren't over the list, or the sidebar doesn't fold away")
        let isOnTabAbove = {
            self.focusWidget.map { window.isInside($0, details.switcher) && gtk_widget_get_mapped($0) != 0 } == true
        }
        let above = "the tab in the header bar to have the focus at 700 px"
        try await until("\(above), not the \(focusType): \(moves)", seconds: 3, isOnTabAbove)
        try await Task.sleep(for: .milliseconds(500))
        try require(isOnTabAbove(), "500 ms later, the \(focusType) has the focus, not the tab: \(moves)")
        seen.append("and as they go back into the header bar at 700 px: the tab there")

        try await resize(to: 1000)
        let view = try present(details.bodies[.response], "the Response page has no body")
        view.show(mode: .hex)
        let hex = try present(view.views[.hex] as? HexView, "the body shows no hex")
        // 16 bytes fit at 1000 px in GTK 4.14's monospace font. Newer GTKs' fonts are wider, so
        // the window widens, with the details still over the list, until they fit.
        var width: Int32 = 1000
        while true {
            do {
                try await until("16 bytes a line at \(width) px", seconds: 3) { hex.perLine == HexLines.wide }
                break
            } catch {
                guard width < 1090 else { throw error }
                width += 45
                try await resize(to: width)
                try require(window.detailsAreOver, "at \(width) px, the details aren't over the list")
            }
        }
        await settle()
        gtk_widget_grab_focus(hex.list)
        gtk_list_view_scroll_to(cast(hex.list), 2, GTK_LIST_SCROLL_FOCUS, nil)
        try await until("the hex's third line to have the focus, not the \(focusType)", seconds: 3) {
            hex.focusedLine == 2
        }
        // Narrower, with the details still over the list and the sidebar beside them: no pane folds.
        moves = []
        try await resize(to: 800)
        try await until("8 bytes a line", seconds: 5) { hex.perLine == HexLines.narrow }
        await settle()
        try require(
            hex.focusedLine == 4,
            "with 8 bytes a line, line \(hex.focusedLine.map(String.init) ?? "none") has the focus, not 4, which "
                + "has byte 32: the \(focusType) in the \(pane(of: focusWidget)), having gone to \(moves)")
        seen.append("a hex line, as the lines narrow at 800 px: the line with its first byte")
        view.show(mode: .formatted)
        details.show(page: .overview)
        adw_navigation_split_view_set_show_content(window.inner, 0)
        // Once they've gone back: libadwaita warns of a shadow it draws as they go, with no size.
        try await until("the details to go back", seconds: 3) { !window.detailsAreOver }
        await settle()
        seen.append(try await checkTheTabsMovingBeside(ids))
        await settle()
        try await resize(to: 1280)
        note("the focus as the panes change: \(seen.joined(separator: "; "))")
    }

    /// Beside the list, at 1280 pixels with the sidebar hidden and the text at three quarters, the
    /// details are wide enough for their tabs in their header bar: with one of them focused, as the
    /// window narrows to 1000 and the tabs go under the pages, the chosen page's tab there has the
    /// keyboard's focus. (With the sidebar beside them, the details beside the list have room for
    /// the tabs above only on a screen wider than the self-check's.) What it saw, for the notes.
    private func checkTheTabsMovingBeside(_ ids: [ExchangeID]) async throws -> String {
        let window = window
        let details = window.details
        let settings = gtk_settings_get_default()
        // As they were after, the text first, then the sidebar, a frame apart: both in one frame
        // squeeze the details beside the list, before they fold away under it.
        var isBack = false
        defer {
            if !isBack {
                gtk_settings_reset_property(settings, "gtk-xft-dpi")
                adw_overlay_split_view_set_show_sidebar(window.outer, 1)
            }
        }
        adw_overlay_split_view_set_show_sidebar(window.outer, 0)
        await settle()
        set(raw(settings), "gtk-xft-dpi", .int(96 * 1024 * 3 / 4))
        try await resize(to: 1280)
        window.list.select(id: ids[0])
        try await until("the details beside the list, with their tabs in their header bar", seconds: 5) {
            details.shown == ids[0] && !window.detailsAreOver && gtk_widget_get_mapped(details.switcher) != 0
        }
        await settle()
        try require(details.focusTab(), "the details' tab doesn't take the focus")
        try await until("a tab in the details' header bar to have the focus", seconds: 3) {
            self.focusWidget.map { window.isInside($0, details.switcher) } == true
        }
        try await resize(to: 1000)
        try require(!window.detailsAreOver, "at 1000 px, with the text at three quarters, the details are over")
        let what = "the tab under the pages to have the focus beside the list at 1000 px"
        try await until("\(what), not the \(focusType) in the \(pane(of: focusWidget))", seconds: 3) {
            self.focusWidget.map { window.isInside($0, details.switcherBar) && gtk_widget_get_mapped($0) != 0 } == true
        }
        isBack = true
        gtk_settings_reset_property(settings, "gtk-xft-dpi")
        await settle()
        adw_overlay_split_view_set_show_sidebar(window.outer, 1)
        await settle()
        return "a tab of the details beside the list, as the tabs go under the pages at 1000 px: the tab there"
    }

    /// The keyboard's focus as the window's breakpoints fold the panes away and back, each time once
    /// the fold's later look, 400 ms on, has been too: a row keeps it from 1280 pixels to 1000 and
    /// 700, and so does the search's field from 1000 to 700, from the capture switch, where
    /// libadwaita 1.7 and later give it on the way, as 1.5 does here too; so does the field opened
    /// with Ctrl+F just before a fold's later look, as its bar shows, with Ctrl+F and Escape counted
    /// as pressed; and from 700 to 1000, so does the sidebar's chosen scope, clicked as the sidebar
    /// comes back. What it saw, for the notes.
    private func checkTheFocusThroughFolds(_ ids: [ExchangeID]) async throws -> [String] {
        let window = window
        let search = window.search
        let rowFocused = {
            window.list.rowWidget(of: ids[0]).map { row in self.focusWidget.map { window.isInside($0, row) } } == true
        }
        let fieldFocused = { self.focusWidget.map { window.isInside($0, search.entry) } == true }
        var seen: [String] = []
        var moves: [String] = []
        var folded = 0
        let watched = [raw(window.outer), raw(window.inner)].map { pane in
            (pane, connect(pane, "notify::collapsed") { folded = monotonicMicroseconds() })
        }
        let watch = connect(window.window, "notify::focus-widget") { [weak self] in
            guard let self else { return }
            let tip = self.focusWidget.flatMap { string(gtk_widget_get_tooltip_text($0)) } ?? ""
            moves.append("\(self.focusType) “\(tip)” in the \(self.pane(of: self.focusWidget))")
        }
        defer {
            g_signal_handler_disconnect(raw(window.window), watch)
            for (pane, handler) in watched {
                g_signal_handler_disconnect(pane, handler)
            }
        }
        // A fold's later look comes 400 ms on: `what` still has the focus once it has been.
        func afterTheLook(_ what: String, _ hasIt: () -> Bool) async throws {
            let wait = folded + 500_000 - monotonicMicroseconds()
            if wait > 0 {
                try await Task.sleep(for: .microseconds(wait))
            }
            try require(
                hasIt(), "once the fold's later look had been, the \(focusType) had the focus, not \(what): \(moves)")
        }

        try await resize(to: 1280)
        try await focusRow(ids[0])
        for width: Int32 in [1000, 700] {
            try await resize(to: width)
            try await until("the row to keep the focus at \(width) px, not the \(focusType): \(moves)", seconds: 3) {
                rowFocused()
            }
            try await afterTheLook("the row, at \(width) px", rowFocused)
        }
        seen.append("a row keeps it from 1280 px to 1000 and 700")

        // The search opens once the unfold's later look has been, and its bar shows before the fold:
        // a field whose bar doesn't show yet is a focus that's lost, to the look, which then gave the
        // row the focus back just as the fold came, sooner than anyone could.
        try await resize(to: 1000)
        try await Task.sleep(for: .milliseconds(500))
        search.open()
        gtk_widget_grab_focus(search.entry)
        try await until("the search's field to show, with the focus", seconds: 3) {
            gtk_widget_get_mapped(search.entry) != 0 && fieldFocused()
        }
        moves = []
        // libadwaita 1.7 and later move the focus on from the toggle themselves, and would move it on
        // again from the switch.
        let movesOn = !LibraryVersion.adwaita(atLeast: 7)
        var wentOn = false
        let onToTheSwitch = connect(window.window, "notify::focus-widget") { [weak self] in
            guard let self, !wentOn else { return }
            if self.focusWidget == window.captureSwitch {
                wentOn = true
            } else if movesOn, self.focusWidget == window.sidebarToggle {
                wentOn = true
                gtk_widget_grab_focus(window.captureSwitch)
            }
        }
        do {
            defer { g_signal_handler_disconnect(raw(window.window), onToTheSwitch) }
            try await resize(to: 700)
        }
        try require(wentOn, "as the sidebar folded away, the focus didn't go to the capture switch: \(moves)")
        try await until("the search's field to keep the focus at 700 px, not the \(focusType): \(moves)", seconds: 3) {
            fieldFocused()
        }
        try await afterTheLook("the search's field, at 700 px", fieldFocused)
        search.close()
        seen.append("the search's field keeps it from 1000 px to 700, from the capture switch")

        // Ctrl+F just before a fold's later look, which comes as the search's bar opens, a frame
        // before it shows: the field keeps the focus. Ctrl+F counts as a key you pressed, and so
        // does Escape, though the window's shortcuts and its own keys have them first. No key here
        // can be pressed in the frame before the look, so the look comes once Ctrl+F's work is
        // done, as after a fold with the keys pressed since.
        try await focusRow(ids[0])
        let unpressed = window.inputs
        try FakeInput.press("Control_L", "f", in: window.window)
        try await until("Ctrl+F to open the search, with the focus", seconds: 3) {
            gtk_widget_get_mapped(search.entry) != 0 && fieldFocused()
        }
        let pressed = window.inputs
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the search", seconds: 3) { !search.isOpen }
        let missed = [("Ctrl+F", unpressed, pressed), ("Escape", pressed, window.inputs)].filter { $0.1 == $0.2 }
        try require(missed.isEmpty, "\(missed.map(\.0).joined(separator: " and ")) didn't count as pressed")
        try await focusRow(ids[0])
        let row = try present(focusWidget, "the row has no focus")
        window.openSearch()
        let showed = gtk_widget_get_mapped(search.entry) != 0
        try require(!showed && fieldFocused(), "Ctrl+F's field \(showed ? "showed at once" : "hasn't the focus")")
        window.lookAfterFold(keeping: row, in: window.listPane, since: unpressed)
        try await Task.sleep(for: .milliseconds(200))
        try require(fieldFocused(), "with Ctrl+F just before a fold's later look, the \(focusType) has the focus")
        search.close()
        seen.append("so does the field Ctrl+F opened just before a fold's later look")

        // A click on the sidebar's chosen scope as the sidebar comes back, before the fold's later
        // look, which leaves the focus where you moved it.
        try await focusRow(ids[0])
        moves = []
        let before = folded
        gtk_window_set_default_size(cast(window.window), 1000, 760)
        try await until("the sidebar to come back at 1000 px", seconds: 5) { folded != before }
        let soon = folded + 150_000 - monotonicMicroseconds()
        if soon > 0 {
            try await Task.sleep(for: .microseconds(soon))
        }
        let scope = try present(chosenScopeRow(), "the sidebar shows no chosen scope")
        try FakeInput.click(scope)
        let scopeFocused = { self.focusWidget.map { window.isInside($0, scope) } == true }
        try await until("the click to give the chosen scope's row the focus: \(moves)", seconds: 3) { scopeFocused() }
        try await afterTheLook("the chosen scope's row, clicked as the sidebar came back", scopeFocused)
        await settle()
        seen.append("a click on the chosen scope as the sidebar comes back at 1000 px keeps it")
        return seen
    }

    /// The sidebar's row that shows as chosen.
    private func chosenScopeRow() -> Widget? {
        var child = gtk_widget_get_first_child(window.sidebar.view)
        while let row = child {
            if gtk_widget_get_state_flags(row).rawValue & GTK_STATE_FLAG_SELECTED.rawValue != 0 {
                return row
            }
            child = gtk_widget_get_next_sibling(row)
        }
        return nil
    }

    /// With the keyboard's focus on a row, Ctrl+K clears the list, and the pinned row that's left
    /// has the focus; with nothing pinned, Clear's button clears it, and the capture switch has the
    /// focus. Tab from the sidebar then still reaches the list's header bar next.
    private func checkTabAfterClear(_ ids: [ExchangeID]) async throws {
        let window = window
        let session = try await session()
        try await session.annotate(ids[1], isPinned: true)
        try await focusRow(ids[0])
        try FakeInput.press("Control_L", "k", in: window.window)
        try await until("Ctrl+K to clear the list but for the pinned row", seconds: 5) {
            window.list.count == 1 && window.list.exchange(at: 0) == ids[1]
        }
        try await until("the pinned row to have the focus the cleared one had", seconds: 3) {
            window.list.rowWidget(of: ids[1]).map { row in self.focusWidget.map { window.isInside($0, row) } } == true
        }
        note("Ctrl+K with a row focused: the pinned row that's left has the focus")
        try await session.annotate(ids[1], isPinned: false)
        try await until("Clear to be on", seconds: 3) { gtk_widget_get_sensitive(window.clearButton) != 0 }
        gtk_widget_grab_focus(window.clearButton)
        try FakeInput.press("space", in: window.window)
        try await until("Clear's button to clear the list", seconds: 5) { window.list.count == 0 }
        try await until("the capture switch to have the focus Clear's button had", seconds: 3) {
            self.focusWidget == window.captureSwitch
        }
        note("Clear's button, with nothing pinned: the capture switch has the focus")
        await settle()
        try require(window.sidebar.focus(), "the sidebar doesn't take the focus")
        await settle()
        try FakeInput.press("Tab", in: window.window)
        try await until("Tab to leave the sidebar", seconds: 3) {
            self.focusWidget.map { !window.isInside($0, window.sidebarPane) } ?? false
        }
        try require(
            pane(of: focusWidget) == "list's header bar",
            "after the list was cleared, Tab from the sidebar went to the \(pane(of: focusWidget))")
        note("Ctrl+K with a row focused, then Tab from the sidebar: the list's header bar")
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

    /// Gives the window X's keyboard, and waits until it hears a key: the part before may have
    /// closed a window of its own, which had it, and a key pressed as X gives it back can be lost.
    private func giveTheWindowTheKeyboard() async throws {
        let window = window.window
        var heard = 0
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(cast(keys), GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed") { heard += 1 }
        gtk_widget_add_controller(window, cast(keys))
        defer { gtk_widget_remove_controller(window, cast(keys)) }
        for _ in 0..<16 where heard == 0 {
            // Shift on its own does nothing in the window.
            try FakeInput.press("Shift_L", in: window)
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard heard == 0 else { return }
        var windows: [String] = []
        let toplevels = gtk_window_get_toplevels()!
        for index in 0..<g_list_model_get_n_items(toplevels) {
            guard let item = g_list_model_get_item(toplevels, index) else { continue }
            let widget: Widget = cast(item)
            // A message dialog's title is its text.
            let title = string(gtk_window_get_title(cast(widget))) ?? stringProperty(raw(widget), "text") ?? ""
            let state = [
                gtk_widget_get_mapped(widget) != 0 ? "shows" : "hidden",
                gtk_window_get_modal(cast(widget)) != 0 ? "modal" : nil,
                gtk_window_is_active(cast(widget)) != 0 ? "active" : nil,
            ]
            windows.append("\(typeName(raw(widget))) “\(title)”, \(state.compactMap { $0 }.joined(separator: ", "))")
            g_object_unref(item)
        }
        throw Failure("the window hears no keys; the windows: \(windows.joined(separator: "; "))")
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
