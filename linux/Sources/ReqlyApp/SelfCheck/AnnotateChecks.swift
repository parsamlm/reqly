import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// A row's menu, opened as you would: Shift+F10 and the Menu key on the row with the focus,
    /// and a click with the right button. Its entries pin a request and unpin it, mark it with
    /// each color and none, and open its comment on the details' Overview, as they say; for an
    /// encrypted connection, it decrypts the host and stops. Each shows on the row at once. Unpin
    /// All takes every pin away, and Clear keeps pinned requests, and the selection with them. A
    /// menu that's open keeps the keyboard's focus as traffic comes.
    func checkAnnotating() async throws {
        let session = try await emptyTheList()
        let traffic = try await startTraffic()
        defer { traffic.server.stop() }
        do {
            try await withoutWarnings { try await checkAnnotating(session, traffic) }
        } catch {
            try? await stopTraffic()
            throw error
        }
        try await stopTraffic()
        try await emptyTheList()
    }

    private func checkAnnotating(_ session: SessionHost, _ traffic: Traffic) async throws {
        let window = window
        let list = window.list
        let menu = list.menu
        for name in ["forecast", "radar", "warnings", "tides"] {
            _ = try await traffic.client.send(traffic.server.url(.ok, "for=\(name)"))
        }
        let tunnel = try await openTunnel(to: traffic.server, through: traffic.port)
        defer { close(tunnel) }
        try await until("the 5 rows", seconds: 10) { list.count == 5 && list.isSettled }
        await settle()
        let ids = (0..<5).compactMap { list.exchange(at: $0) }
        let (forecast, radar, warnings, tides, encrypted) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        try require(list.text(of: encrypted)?.isEncrypted == true, "the last row isn't the encrypted connection")

        // Shift+F10 on the row with the focus, then Escape.
        try await focus(forecast)
        try FakeInput.press("Shift_L", "F10", in: window.window)
        try await until("Shift+F10 to open the row's menu", seconds: 3) { menu.isOpen }
        await settle()
        try require(menu.target?.id == forecast, "the menu is for #\(menu.target?.id.rawValue ?? 0)")
        let entries = Self.entries(of: menu.menu)
        let colors = ["None"] + MarkColor.allCases.map(\.title)
        try require(
            entries == ["Pin Request", "Color"] + colors.map { "Color › \($0)" } + ["Add Comment…"],
            "the menu has \(entries)")
        note("Shift+F10: the row's menu, with \(entries.filter { !$0.hasPrefix("Color ›") }.joined(separator: ", "))")
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the menu", seconds: 3) { !menu.isOpen }
        await settle()
        try require(listHasFocus, "once the menu closed, the focus is on the \(focusType)")

        // The Menu key, and Pin Request, as its entry's chosen.
        try FakeInput.press("Menu", in: window.window)
        try await until("the Menu key to open the row's menu", seconds: 3) { menu.isOpen }
        await settle()
        try choose("Pin Request", in: menu)
        try await until("the row to show its pin", seconds: 3) {
            list.text(of: forecast)?.isPinned == true && self.pinShows(forecast)
        }
        var isPinned = false
        for _ in 0..<100 where !isPinned {
            isPinned = await session.rows([forecast]).first?.annotation.isPinned == true
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(isPinned, "the session didn't pin the request")
        let pinned = try present(list.accessibleWords(of: forecast), "the pinned row isn't bound").label
        try require(pinned.hasSuffix(", pinned"), "the pinned row's label is “\(pinned)”")
        note("the Menu key: Pin Request; the row shows its pin, and screen readers hear “…, pinned”")

        // A click with the right button on another row, and each color.
        let cell = try present(list.cell(.request, of: radar), "the second row has no cell")
        await settle()
        try FakeInput.click(cell, button: 3)
        try await until("a click with the right button to open the row's menu", seconds: 3) { menu.isOpen }
        try require(menu.target?.id == radar, "the menu is for #\(menu.target?.id.rawValue ?? 0), not the row clicked")
        try require(list.selected != radar, "the click with the right button chose the row")
        var marked: [String] = []
        for color in MarkColor.allCases.map(Optional.some) + [nil] {
            g_action_group_activate_action(cast(menu.actions), "color", g_variant_new_string(color?.rawValue ?? "none"))
            try await until("the row to be marked \(color?.title ?? "with none")", seconds: 3) {
                list.text(of: radar)?.color == color && self.mark(of: radar, list) == color
            }
            if color == .purple {
                await settle()
                let manager = adw_style_manager_get_default()
                for (scheme, name) in [(ADW_COLOR_SCHEME_FORCE_LIGHT, "light"), (ADW_COLOR_SCHEME_FORCE_DARK, "dark")] {
                    adw_style_manager_set_color_scheme(manager, scheme)
                    await settle()
                    _ = try await ownPicture(window.window, to: try picture("list-marked-\(name).png"))
                }
                adw_style_manager_set_color_scheme(manager, runsColorScheme)
            }
            let label = list.accessibleWords(of: radar)?.label ?? ""
            let words = color.map { "marked \($0.title.lowercased())" }
            try require(
                words.map { label.hasSuffix(", " + $0) } ?? !label.contains("marked"),
                "marked \(color?.title ?? "with none"), the row's label is “\(label)”")
            marked.append(color?.title ?? "None")
        }
        menu.close()
        try await until("the menu to close", seconds: 3) { !menu.isOpen }
        note("a click with the right button: the row's menu; Color marked it \(marked.joined(separator: ", "))")

        // Add Comment…, then the comment, and Edit Comment….
        try await focus(warnings)
        try FakeInput.press("Menu", in: window.window)
        try await until("the menu to open", seconds: 3) { menu.isOpen }
        await settle()
        try choose("Add Comment…", in: menu)
        try await until("the request's details to show on Overview", seconds: 3) {
            list.selected == warnings && window.details.shown == warnings && window.details.page == .overview
        }
        let over = window.detailsAreOver
        adw_navigation_split_view_set_show_content(window.inner, 0)
        let comment = "Check the storm warnings"
        try await session.annotate(warnings, comment: .set(comment))
        try await until("the row to show its comment", seconds: 3) {
            list.text(of: warnings)?.comment == comment && self.bubbleShows(warnings)
        }
        let tooltip = list.cell(.request, of: warnings).flatMap { string(gtk_widget_get_tooltip_text($0)) } ?? ""
        try require(tooltip == comment, "the comment's tooltip is “\(tooltip)”")
        await settle()
        try await focus(warnings)
        try FakeInput.press("Menu", in: window.window)
        try await until("the menu to open again", seconds: 3) { menu.isOpen }
        let again = Self.entries(of: menu.menu)
        try require(again.contains("Edit Comment…"), "with a comment, the menu has \(again)")
        menu.close()
        note(
            "Add Comment…: the request on the details' Overview\(over ? ", over the list" : ""); with its comment, "
                + "the row's bubble and tooltip, and Edit Comment…")
        try await until("the menu to close", seconds: 3) { !menu.isOpen }
        try await checkEditingAnotherComment(warnings, comment, while: radar, session: session)

        try await checkDecrypting(encrypted, list: list, menu: menu)

        // Unpin All, then Clear, which keeps pinned requests and the selection with them.
        try await until("the menu to close", seconds: 3) { !menu.isOpen }
        try await session.annotate(tides, isPinned: true)
        try await until("two pins", seconds: 3) { self.pinShows(forecast) && self.pinShows(tides) }
        await session.unpinAll()
        try await until("Unpin All to take every pin away", seconds: 3) {
            ids.allSatisfy { list.text(of: $0)?.isPinned == false && !self.pinShows($0) }
        }
        try await session.annotate(forecast, isPinned: true)
        try await session.annotate(warnings, isPinned: true)
        try await until("two pins again", seconds: 3) { self.pinShows(forecast) && self.pinShows(warnings) }
        list.select(id: radar)
        try await until("the row to be selected", seconds: 3) { list.selected == radar }
        try FakeInput.press("Control_L", "k", in: window.window)
        try await until("Ctrl+K to clear all but the pinned requests", seconds: 5) {
            list.total == 2 && list.count == 2 && list.isSettled && list.selected == nil
        }
        let kept = (0..<list.count).compactMap { list.exchange(at: $0) }
        try require(kept == [forecast, warnings], "Clear kept #\(kept.map(\.rawValue))")
        list.select(id: warnings)
        try await until("the pinned row to be selected", seconds: 3) { list.selected == warnings }
        await session.clear()
        try await until("Clear to keep the pinned requests", seconds: 3) { list.isSettled }
        try require(
            list.count == 2 && list.selected == warnings,
            "the second Clear kept \(list.count) rows, and \(list.selected == warnings ? "the" : "not the") selection")
        note(
            "Unpin All: no pins; Ctrl+K: the 2 pinned requests stay, and the selection with them, until it was one that went"
        )
        try await checkClearingWhatDoesntShow(session, traffic)
        try await checkTheMenuAsTrafficComes(traffic)
    }

    /// A row's menu, opened with a click with the right button while the list is scrolled up, away
    /// from the selected row, keeps the keyboard's focus as traffic comes, and the list stays where
    /// it is. Neither half of that may lean on the other: the list doesn't say its row lost the
    /// focus, and the window's look for a focus that shows, as after a fold, leaves the menu's.
    private func checkTheMenuAsTrafficComes(_ traffic: Traffic) async throws {
        let window = window
        let list = window.list
        let menu = list.menu
        for number in 1...40 {
            _ = try await traffic.client.send(traffic.server.url(.ok, "menu=\(number)"))
        }
        try await until("the 40 rows", seconds: 10) { list.count == 40 && list.isSettled }
        let last = try present(list.exchange(at: 39), "the list has no last row")
        list.select(id: last)
        try await until("the last row to be selected", seconds: 3) { list.selected == last }
        await settle()
        let adjustment = try present(gtk_scrolled_window_get_vadjustment(cast(list.scroller)), "no adjustment")
        gtk_adjustment_set_value(adjustment, 0)
        await settle()
        try require(!rowShows(last), "scrolled up, the selected row still shows")
        let second = try present(list.exchange(at: 1), "the list has no second row")
        let cell = try present(list.cell(.request, of: second), "the second row has no cell")
        try FakeInput.click(cell, button: 3)
        try await until("the row's menu to open, with the focus in it", seconds: 3) {
            menu.isOpen && self.focusWidget.map { window.isInside($0, menu.popover) } == true
        }
        await settle()
        let value = gtk_adjustment_get_value(adjustment)
        let onFocusLost = list.onFocusLost
        var lost = 0
        list.onFocusLost = {
            lost += 1
            onFocusLost?()
        }
        defer { list.onFocusLost = onFocusLost }
        for number in 41...45 {
            _ = try await traffic.client.send(traffic.server.url(.ok, "menu=\(number)"))
        }
        try await until("the 5 new rows", seconds: 5) { list.count == 45 && list.isSettled }
        await settle()
        let isInList = focusWidget.map { window.isInside($0, list.view) } == true
        let focus = "the \(focusType) in the \(isInList ? "list" : "window")"
        let isInMenu = menu.isOpen && focusWidget.map { window.isInside($0, menu.popover) } == true
        let now = gtk_adjustment_get_value(adjustment)
        window.focusWhatShowsSoon()
        await settle()
        let looked = "the \(focusType)"
        let staysAfterLook = menu.isOpen && focusWidget.map { window.isInside($0, menu.popover) } == true
        menu.close()
        try await until("the menu to close", seconds: 3) { !menu.isOpen }
        try require(isInMenu, "as traffic came, the focus left the open row's menu for \(focus)")
        try require(lost == 0, "as traffic came, the list said \(lost) times that its row lost the focus to the menu")
        try require(staysAfterLook, "a look for a focus that shows took it from the open row's menu for \(looked)")
        try require(abs(now - value) < 1, "as traffic came, the list scrolled from \(Int(value)) to \(Int(now)) px")
        note("a row's menu, open as 5 requests came: it keeps the focus, and the list stays where it is")
    }

    /// Clear while a search finds nothing, which takes requests no row shows, so no row changes:
    /// the session's count, Clear and the selection, of a request the search hid, follow all the
    /// same. Then, with nothing pinned or left in Pinned, the list says there's no traffic, not
    /// that none matches.
    private func checkClearingWhatDoesntShow(_ session: SessionHost, _ traffic: Traffic) async throws {
        let window = window
        let list = window.list
        let sidebar = window.sidebar
        let search = window.search
        _ = try await traffic.client.send(traffic.server.url(.ok, "for=hail"))
        try await until("the new row", seconds: 5) { list.count == 3 && list.isSettled }
        let hail = try present(list.exchange(at: 2), "the new request has no row")
        list.select(id: hail)
        try await until("the new row to be selected", seconds: 3) {
            list.selected == hail && window.details.shown == hail
        }
        search.open()
        gtk_editable_set_text(cast(search.entry), "zzqx")
        try await until("the search to find nothing", seconds: 5) {
            search.query == "zzqx" && list.count == 0 && list.isSettled
        }
        try require(list.selected == hail, "the search hid the selected request, and its selection with it")
        await session.clear()
        try await until("the sidebar to count the 2 pinned requests left", seconds: 5) { sidebar.total == 2 }
        await settle()
        let count = string(gtk_label_get_text(cast(window.statusCount))) ?? ""
        try require(count == "0 of 2 requests", "with the 2 pinned requests left, the status line says “\(count)”")
        try require(g_action_get_enabled(cast(window.clearAction)) == 0, "Clear is on with only pinned requests left")
        try await until("the selection to go with its request", seconds: 3) {
            list.selected == nil && window.details.shown == nil
        }
        search.close()
        sidebar.choose("pinned")
        try await until("Pinned to be chosen", seconds: 5) {
            sidebar.scope.key == "pinned" && list.count == 2 && list.isSettled
        }
        await session.unpinAll()
        try await until("Pinned to show no rows", seconds: 5) { list.count == 0 && list.isSettled }
        await session.clear()
        try await until("the sidebar to count no requests", seconds: 5) { sidebar.total == 0 }
        await settle()
        let subtitle = string(adw_window_title_get_subtitle(cast(window.listTitle))) ?? ""
        try require(
            gtk_widget_get_mapped(window.noMatches.widget) == 0 && subtitle == "Waiting for traffic",
            "with no requests, the list's subtitle is “\(subtitle)”, and its pane says \(window.noMatches.words.title)")
        sidebar.choose("all")
        note(
            "Clear while a search finds nothing: “0 of 2 requests”, Clear off, the hidden request's selection gone; "
                + "with nothing left in Pinned, “Waiting for traffic”")
    }

    /// Edit Comment… from the menu of a row that isn't the one the details show, with a click with
    /// the right button, which doesn't choose it: the field has the request's comment, which stays
    /// as you leave it for another request.
    private func checkEditingAnotherComment(
        _ id: ExchangeID, _ comment: String, while other: ExchangeID, session: SessionHost
    ) async throws {
        let window = window
        let list = window.list
        let menu = list.menu
        let details = window.details
        try await focus(other)
        try await until("the details to show the other request", seconds: 3) {
            details.shown == other && details.summary != nil
        }
        let cell = try present(list.cell(.request, of: id), "the commented row has no cell")
        try FakeInput.click(cell, button: 3)
        try await until("a click with the right button to open the commented row's menu", seconds: 3) {
            menu.isOpen && menu.target?.id == id
        }
        try choose("Edit Comment…", in: menu)
        let field = details.commentField
        var said = ""
        do {
            try await until("the comment field to have the focus, and the comment", seconds: 3) {
                said = string(gtk_editable_get_text(cast(field))) ?? ""
                return details.shown == id && said == comment
                    && self.focusWidget.map { window.isInside($0, field) } ?? false
            }
        } catch {
            throw Failure(
                "Edit Comment… on a row not shown: the field says “\(said)”, not “\(comment)”, the focus on the "
                    + "\(focusType)\(details.shown == id ? "" : ", another request shown")")
        }
        // Another request, as leaving the field saves it.
        try await focus(other)
        await settle()
        let kept = await session.rows([id]).first?.annotation.comment
        try require(kept == comment, "once the field was left, the comment is “\(kept ?? "gone")”")
        note("Edit Comment… on a row not shown: the field has its comment, which stays as you leave it")
    }

    /// For an encrypted connection: Decrypt 127.0.0.1, or Stop Decrypting 127.0.0.1 when Reqly
    /// decrypts every host already, then the other, and the hosts' list as it was.
    private func checkDecrypting(_ id: ExchangeID, list: RequestList, menu: RowMenu) async throws {
        let https = model.https
        let host = "127.0.0.1"
        let before = try present(https.state, "the session has no HTTPS").hosts
        let wasOn = before.decrypts(host)
        var chosen: [String] = []
        for isOn in [!wasOn, wasOn] {
            let entry = isOn ? "Decrypt \(host)" : "Stop Decrypting \(host)"
            try await focus(id)
            try FakeInput.press("Menu", in: window.window)
            try await until("the menu to open", seconds: 3) { menu.isOpen }
            let entries = Self.entries(of: menu.menu)
            try require(entries.last == entry, "the encrypted connection's menu has \(entries)")
            try choose(entry, in: menu)
            try await until("\(entry) to change the hosts", seconds: 5) { https.state?.hosts.decrypts(host) == isOn }
            chosen.append(entry)
        }
        if let pattern = HostPattern(rawValue: host), !before.entries.contains(where: { $0.pattern == pattern }) {
            await https.removeHost(pattern)
        }
        try require(https.state?.hosts == before, "the hosts to decrypt aren't as they were")
        note("an encrypted connection's menu: \(chosen.joined(separator: ", then ")); the hosts as they were")
    }

    // MARK: - What it uses

    /// Selects a request's row and gives it the keyboard's focus.
    private func focus(_ id: ExchangeID) async throws {
        let list = window.list
        adw_navigation_split_view_set_show_content(window.inner, 0)
        await settle()
        list.select(id: id)
        try await until("the row to be selected", seconds: 3) { list.selected == id }
        list.focusSelection()
        try await until("the row to have the focus", seconds: 3) {
            list.rowWidget(of: id).map { row in self.focusWidget.map { self.window.isInside($0, row) } ?? false }
                ?? false
        }
    }

    /// Chooses an entry of the open menu, as Enter on it does.
    private func choose(_ entry: String, in menu: RowMenu) throws {
        let item = try present(
            Self.widgets(under: menu.popover).first {
                typeName(raw($0)) == "GtkModelButton" && stringProperty(raw($0), "text") == entry
            }, "the menu has no \(entry)")
        gtk_widget_activate(item)
    }

    private func pinShows(_ id: ExchangeID) -> Bool {
        let request = window.list.cell(.request, of: id)
        let pin = request.flatMap { gtk_widget_get_next_sibling(gtk_widget_get_first_child($0)) }
        return pin.map { gtk_widget_get_visible($0) != 0 } ?? false
    }

    private func bubbleShows(_ id: ExchangeID) -> Bool {
        let bubble = window.list.cell(.request, of: id).flatMap { gtk_widget_get_last_child($0) }
        return bubble.map { gtk_widget_get_visible($0) != 0 } ?? false
    }

    /// The color a request's row is marked with, as its style classes say.
    private func mark(of id: ExchangeID, _ list: RequestList) -> MarkColor? {
        guard let row = list.rowWidget(of: id), gtk_widget_has_css_class(row, "marked") != 0 else { return nil }
        let marks = MarkColor.allCases.filter { gtk_widget_has_css_class(row, ListStyles.markClass($0)) != 0 }
        return marks.count == 1 ? marks[0] : nil
    }

    /// A menu's entries, in order, a submenu's after its own, as "Color › Red".
    static func entries(of menu: OpaquePointer) -> [String] {
        func entries(_ items: UnsafeMutablePointer<GMenuModel>, _ prefix: String) -> [String] {
            var found: [String] = []
            for index in 0..<g_menu_model_get_n_items(items) {
                if let section = g_menu_model_get_item_link(items, index, "section") {
                    found += entries(section, prefix)
                    g_object_unref(raw(section))
                    continue
                }
                let label = g_menu_model_get_item_attribute_value(items, index, "label", nil)
                let title = label.flatMap { string(g_variant_get_string($0, nil)) } ?? ""
                label.map { g_variant_unref($0) }
                found.append(prefix + title.replacingOccurrences(of: "__", with: "_"))
                if let submenu = g_menu_model_get_item_link(items, index, "submenu") {
                    found += entries(submenu, prefix + title + " › ")
                    g_object_unref(raw(submenu))
                }
            }
            return found
        }
        return entries(cast(menu), "")
    }

    /// Every widget under `root`, depth first.
    static func widgets(under root: Widget) -> [Widget] {
        var found: [Widget] = []
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            found.append(widget)
            found += widgets(under: widget)
            child = gtk_widget_get_next_sibling(widget)
        }
        return found
    }
}
