import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

extension SelfCheck {
    /// The window's shortcuts, as GTK has them for its actions.
    private static let shortcuts: [(action: String, keys: String)] =
        [
            ("win.toggle-sidebar", "F9"), ("win.search", "<Control>f"), ("win.clear", "<Control>k"),
            ("win.toggle-capture", "<Control>r"),
        ] + DetailsPane.Page.allCases.enumerated().map { ("win.page::\($1.rawValue)", "<Control>\($0 + 1)") }

    /// The window's panes at 1280, 1000 and 700 pixels wide, and at 1280 with the text at 1.25, as
    /// the window's breakpoints have them: the details beside the list or over it, the sidebar
    /// beside them or folded away, and the main menu's button that shows, with pictures in light
    /// and dark, while the window is empty. The shortcuts, pressed as keys: F9, F10, Ctrl+R, which
    /// screen readers hear, Ctrl+F, and Ctrl+1 to Ctrl+5, which do nothing with no request; Escape,
    /// in its order; Enter and a click on a row, which open the details over the list, and Escape
    /// and Alt+←, after which the row has the focus again; Ctrl+3 from a row, which opens them on
    /// Response, its tab focused; and Ctrl+K, after which the capture switch has the focus the row
    /// had. GTK warns of nothing meanwhile. The app's icon is found by its name.
    func checkLayout() async throws {
        let window = window
        try await until("the window to show") { gtk_widget_get_mapped(window.window) != 0 }
        _ = try await session()
        await settle()
        try checkAppIcon()
        try checkShortcuts()
        var width: Int32 = 0
        var height: Int32 = 0
        gtk_window_get_default_size(cast(window.window), &width, &height)
        let lines: [String]
        do {
            lines = try await standardError {
                try await checkWidths()
                try await checkKeysBeside()
                try await checkKeysFolded()
                try await checkRows()
            }.lines
        } catch {
            await restoreLayout(width: width, height: height)
            throw error
        }
        await restoreLayout(width: width, height: height)
        let warnings = lines.filter { $0.contains("-WARNING") || $0.contains("-CRITICAL") }
        note("GTK's warnings meanwhile: \(warnings.isEmpty ? "none" : warnings.joined(separator: " | "))")
        try require(
            warnings.isEmpty, "GTK warned \(warnings.count) times: \(warnings.prefix(3).joined(separator: " | "))")
    }

    // MARK: - The icon and the shortcuts

    /// The icon theme has the app's icon, from linux/packaging/icons, as the window and About ask
    /// for it.
    private func checkAppIcon() throws {
        let theme = try present(gtk_icon_theme_get_for_display(gdk_display_get_default()), "there's no icon theme")
        try require(gtk_icon_theme_has_icon(theme, App.id) != 0, "the icon theme has no \(App.id)")
        for size: Int32 in [16, 48, 128, 512] {
            let icon = gtk_icon_theme_lookup_icon(
                theme, App.id, nil, size, 1, GTK_TEXT_DIR_LTR, GtkIconLookupFlags(rawValue: 0))
            defer { g_object_unref(raw(icon)) }
            let file = gtk_icon_paintable_get_file(icon)
            defer { g_object_unref(raw(file)) }
            let path = takeString(g_file_get_path(file)) ?? ""
            try require(
                path.hasSuffix("/hicolor/\(size)x\(size)/apps/\(App.id).png"), "at \(size) pixels, the icon is \(path)")
        }
        let name = string(gtk_window_get_icon_name(cast(window.window))) ?? ""
        try require(name == App.id, "the window's icon is \(name)")
        note("app icon: \(App.id), at 16, 48, 128 and 512 pixels from \(Icons.builtFrom.path)/hicolor")
    }

    /// Each shortcut has its action, on the window.
    private func checkShortcuts() throws {
        for (action, keys) in Self.shortcuts {
            let name = String(action.dropFirst(4).prefix { $0 != ":" })
            try require(g_action_group_has_action(cast(window.window), name) != 0, "the window has no \(action)")
            var given: [String] = []
            if let accels = gtk_application_get_accels_for_action(cast(app.application), action) {
                var index = 0
                while let accel = accels[index] {
                    given.append(String(cString: accel))
                    index += 1
                }
                g_strfreev(accels)
            }
            try require(given == [keys], "\(action)'s shortcut is \(given), not \(keys)")
        }
        note("shortcuts: \(Self.shortcuts.map { "\($0.keys) \($0.action)" }.joined(separator: ", "))")
    }

    // MARK: - Widths

    /// What the window shows at one width, with its text at one size.
    private struct Layout {
        var width: Int32
        var text = 1.0
        /// Whether the details show over the list, and whether the sidebar folds away too.
        var detailsOver = false
        var sidebarFolds = false

        var name: String { text == 1 ? "\(width)" : "\(width)-text-\(text)" }
    }

    private static let layouts = [
        Layout(width: 1280), Layout(width: 1000, detailsOver: true),
        Layout(width: 700, detailsOver: true, sidebarFolds: true), Layout(width: 1280, text: 1.25, detailsOver: true),
    ]

    /// Each layout: which breakpoint applies, the panes and the menus, and a picture in light and
    /// in dark.
    private func checkWidths() async throws {
        let window = window
        let manager = adw_style_manager_get_default()
        for layout in Self.layouts {
            try await resize(to: layout)
            let width = gtk_widget_get_width(window.window)
            let detailsOver = adw_navigation_split_view_get_collapsed(window.inner) != 0
            let sidebarFolds = adw_overlay_split_view_get_collapsed(window.outer) != 0
            // Every layout's width is under 1400 sp, where the list's App column goes while the
            // details are beside it.
            let expected =
                layout.sidebarFolds ? window.sidebarFolds : layout.detailsOver ? window.detailsOver : window.listNarrows
            let current = adw_application_window_get_current_breakpoint(cast(window.window))
            let shown = layout.sidebarFolds ? window.listMenuButton : window.menuButton
            let hidden = layout.sidebarFolds ? window.menuButton : window.listMenuButton
            let tabsUnder =
                adw_breakpoint_bin_get_current_breakpoint(cast(window.details.widget)) == window.details.narrow
            let beside =
                detailsOver
                ? ""
                : ", \(gtk_widget_get_width(window.details.widget)) px, their tabs \(tabsUnder ? "under" : "above") them"
            note(
                "\(layout.name): \(width) px; the details \(detailsOver ? "over" : "beside") the list\(beside); the "
                    + "sidebar \(sidebarFolds ? "folded away" : "beside them"), and the main menu in the "
                    + "\(layout.sidebarFolds ? "list's" : "sidebar's") header bar")
            try require(
                detailsOver == layout.detailsOver && sidebarFolds == layout.sidebarFolds && current == expected,
                "at \(layout.name), the details are \(detailsOver ? "over" : "beside") the list and the sidebar "
                    + "\(sidebarFolds ? "folded" : "beside")")
            try require(
                window.list.shows(.app) == layout.detailsOver,
                "at \(layout.name), the list's App column \(window.list.shows(.app) ? "shows" : "doesn't show")")
            try require(
                gtk_widget_get_mapped(shown) != 0 && gtk_menu_button_get_primary(cast(shown)) != 0
                    && gtk_widget_get_visible(hidden) == 0 && gtk_menu_button_get_primary(cast(hidden)) == 0,
                "at \(layout.name), the main menu that shows isn't the one F10 opens")
            try require(
                (gtk_widget_get_visible(window.sidebarToggle) != 0) == layout.sidebarFolds,
                "at \(layout.name), the sidebar's toggle \(layout.sidebarFolds ? "doesn't show" : "shows")")
            var pictures: [String] = []
            for (scheme, style) in [(ADW_COLOR_SCHEME_FORCE_LIGHT, "light"), (ADW_COLOR_SCHEME_FORCE_DARK, "dark")] {
                adw_style_manager_set_color_scheme(manager, scheme)
                await settle()
                let file = try picture("layout-\(layout.name)-\(style).png")
                let size = try await ownPicture(window.window, to: file)
                pictures.append("\(file.lastPathComponent) (\(size))")
            }
            note("    pictures: \(pictures.joined(separator: ", "))")
        }
        adw_style_manager_set_color_scheme(manager, colorScheme)
    }

    /// The window at `layout`'s width, with the text at its size, once it has settled.
    private func resize(to layout: Layout) async throws {
        let window = window
        let settings = gtk_settings_get_default()
        if layout.text == 1 {
            gtk_settings_reset_property(settings, "gtk-xft-dpi")
        } else {
            set(raw(settings), "gtk-xft-dpi", .int(Int32(96 * 1024 * layout.text)))
        }
        gtk_window_set_default_size(cast(window.window), layout.width, 760)
        // GTK keeps the window on the screen, inside the shadow's margin.
        try await until("the window to be \(layout.width) pixels wide", seconds: 5) {
            let width = gtk_widget_get_width(window.window)
            return width <= layout.width && width > layout.width - 20
        }
        await settle()
    }

    /// The style the run asked for, as the window had it before.
    private var colorScheme: AdwColorScheme {
        switch app.options.theme {
        case .light: ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: ADW_COLOR_SCHEME_FORCE_DARK
        case nil: ADW_COLOR_SCHEME_DEFAULT
        }
    }

    /// The window as it was: its size, its text, its style, the sidebar beside the list, the
    /// search bar closed and the details beside the list.
    private func restoreLayout(width: Int32, height: Int32) async {
        let window = window
        if model.capture != .stopped {
            try? await setCapture(on: false)
        }
        gtk_settings_reset_property(gtk_settings_get_default(), "gtk-xft-dpi")
        adw_style_manager_set_color_scheme(adw_style_manager_get_default(), colorScheme)
        window.search.close()
        adw_navigation_split_view_set_show_content(window.inner, 0)
        gtk_window_set_default_size(cast(window.window), width, height)
        await settle()
        adw_overlay_split_view_set_show_sidebar(
            window.outer, cBool(adw_overlay_split_view_get_collapsed(window.outer) == 0))
        await settle()
    }

    // MARK: - Keys

    /// At 1280 pixels: F9 hides and shows the sidebar; F10 opens the sidebar's main menu, and
    /// Escape closes only that, and with the sidebar hidden, the list's; Ctrl+R starts and stops
    /// capturing, and the list's title says so, as screen readers hear; Ctrl+F opens the search
    /// bar, and Escape closes it; with no request, Ctrl+1 to Ctrl+5 do nothing.
    private func checkKeysBeside() async throws {
        let window = window
        try await resize(to: Self.layouts[0])
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to hide the sidebar", seconds: 3) {
            adw_overlay_split_view_get_show_sidebar(window.outer) == 0
        }
        try require(
            gtk_widget_get_visible(window.sidebarToggle) != 0, "the sidebar's toggle doesn't show once it's hidden")
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to show it again", seconds: 3) {
            adw_overlay_split_view_get_show_sidebar(window.outer) != 0
        }
        try require(gtk_widget_get_visible(window.sidebarToggle) == 0, "the sidebar's toggle shows beside the sidebar")
        note("F9: hides the sidebar, and the toggle shows, then shows it again, and the toggle goes")

        try await checkMenuKey(window.menuButton, "the sidebar's")
        // With the sidebar hidden, its main menu can't be reached, so the list's shows instead.
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to hide the sidebar", seconds: 3) {
            adw_overlay_split_view_get_show_sidebar(window.outer) == 0
        }
        await settle()
        try await checkMenuKey(window.listMenuButton, "the list's, with the sidebar hidden,")
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to show it again", seconds: 3) {
            adw_overlay_split_view_get_show_sidebar(window.outer) != 0
        }
        await settle()
        let listsShows = gtk_widget_get_visible(window.listMenuButton) != 0
        let sidebarsOpens = gtk_menu_button_get_primary(cast(window.menuButton)) != 0
        try require(
            !listsShows && sidebarsOpens,
            "with the sidebar back, the list's main menu still shows, or F10 doesn't open the sidebar's")

        try JSONEncoder().encode(Self.yourProxySettings).write(to: try standInFile())
        _ = try await switchReady()
        var capturing = ""
        var stopped = ""
        var statuses: [String] = []
        let saidCapturing = try await AccessibilityTree.events(["object:announcement"], seconds: 8) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            try? FakeInput.press("Control_L", "r", in: window.window)
            for _ in 0..<500 where !model.isCapturing {
                try? await Task.sleep(for: .milliseconds(10))
            }
            capturing = subtitle
            statuses.append(model.statusText)
            try? await Task.sleep(for: .milliseconds(500))
            try? FakeInput.press("Control_L", "r", in: window.window)
            for _ in 0..<500 where model.capture != .stopped {
                try? await Task.sleep(for: .milliseconds(10))
            }
            stopped = subtitle
            statuses.append(model.statusText)
            try? await Task.sleep(for: .milliseconds(500))
        }
        note("Ctrl+R: starts capturing, the list's title saying “\(capturing)”, then stops, saying “\(stopped)”")
        try require(
            capturing == "Waiting for traffic" && stopped == "Not capturing",
            "the list's title said “\(capturing)”, then “\(stopped)”")
        // With the focus away from the switch, screen readers hear what the status line says.
        let heardCapturing = saidCapturing.compactMap(\.detail)
        try require(
            statuses.allSatisfy { heardCapturing.contains($0) }, "after Ctrl+R, screen readers heard \(heardCapturing)")
        note("    screen readers heard “\(statuses.joined(separator: "”, then “"))”")

        try FakeInput.press("Control_L", "f", in: window.window)
        try await until("Ctrl+F to open the search bar, its field focused", seconds: 3) {
            window.search.isOpen && focus.map { window.isInside($0, window.search.entry) } == true
        }
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the search bar", seconds: 3) { !window.search.isOpen }
        await settle()
        try require(
            focus.map { gtk_widget_get_mapped($0) != 0 && !window.isInside($0, window.search.widget) } == true,
            "once the search bar closed, the focus is on \(focusName)")
        note("Ctrl+F: the search bar, its field focused; Escape closes it, and the focus goes to the \(focusName)")

        // With no request, as on the Mac, Ctrl+1 to Ctrl+5 do nothing, and say nothing.
        let page = window.details.page
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 4) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            try? FakeInput.press("Control_L", "3", in: window.window)
            try? await Task.sleep(for: .milliseconds(500))
        }
        let said = heard.compactMap(\.detail)
        try require(
            window.details.page == page && said.isEmpty,
            "with no request, Ctrl+3 chose \(window.details.page.title), and screen readers heard \(said)")
        note("Ctrl+3, with no request: nothing, as on the Mac")
    }

    /// F10 opens the main menu `button` has, which shows, and Escape closes the menu, and no more.
    private func checkMenuKey(_ button: Widget, _ whose: String) async throws {
        let window = window
        let popover = try present(gtk_menu_button_get_popover(cast(button)), "the main menu has no popover")
        let sidebarShows = adw_overlay_split_view_get_show_sidebar(window.outer)
        try FakeInput.press("F10", in: window.window)
        try await until("F10 to open \(whose) main menu", seconds: 3) { gtk_widget_get_mapped(cast(popover)) != 0 }
        await settle()
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the main menu", seconds: 3) { gtk_widget_get_mapped(cast(popover)) == 0 }
        await settle()
        try require(
            adw_overlay_split_view_get_show_sidebar(window.outer) == sidebarShows && !window.detailsAreOver,
            "Escape closed more than the main menu")
        note("F10: opens the main menu in \(whose) header bar; Escape closes the menu, and nothing else")
    }

    /// At 700 pixels, with the sidebar folded away: F10 opens the list's main menu. Escape closes
    /// the search bar before the sidebar shown over the list, and the sidebar before the details
    /// over the list. Ctrl+F over the details goes back to the list's search bar.
    private func checkKeysFolded() async throws {
        let window = window
        try await resize(to: Self.layouts[2])
        try await checkMenuKey(window.listMenuButton, "the list's")

        try FakeInput.press("Control_L", "f", in: window.window)
        try await until("Ctrl+F to open the search bar", seconds: 3) { window.search.isOpen }
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to show the sidebar over the list, with the focus", seconds: 3) {
            window.sidebarIsOver && focus.map { window.isInside($0, window.sidebarPane) } == true
        }
        var order: [String] = []
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the search bar first", seconds: 3) { !window.search.isOpen }
        await settle()
        try require(window.sidebarIsOver, "Escape closed the sidebar with the search bar")
        order.append("the search bar")
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the sidebar next", seconds: 3) { !window.sidebarIsOver }
        await settle()
        try require(
            focus.map { window.isInside($0, window.listPane) } == true,
            "once the sidebar went, the focus is on \(focusName)")
        order.append("the sidebar, the focus going to the \(focusName)")

        window.openDetails()
        try await until("the details to show over the list", seconds: 3) { window.detailsAreOver }
        await settle()
        try FakeInput.press("F9", in: window.window)
        try await until("F9 to show the sidebar over the details", seconds: 3) { window.sidebarIsOver }
        await settle()
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to close the sidebar before the details", seconds: 3) { !window.sidebarIsOver }
        await settle()
        try require(window.detailsAreOver, "Escape went back from the details with the sidebar")
        order.append("the sidebar over the details")
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to go back from the details", seconds: 3) { !window.detailsAreOver }
        await settle()
        order.append("the details")
        note("Escape, at 700 px: closes \(order.joined(separator: ", then "))")

        window.openDetails()
        try await until("the details to show over the list", seconds: 3) { window.detailsAreOver }
        await settle()
        try FakeInput.press("Control_L", "f", in: window.window)
        try await until("Ctrl+F to go back to the list's search bar", seconds: 3) {
            !window.detailsAreOver && window.search.isOpen
        }
        await settle()
        try require(
            focus.map { window.isInside($0, window.search.entry) } == true,
            "after Ctrl+F over the details, the focus is on \(focusName)")
        window.search.close()
        note("Ctrl+F over the details: back to the list, its search bar open, its field focused")
    }

    // MARK: - Rows

    /// At 1000 pixels, with the details over the list: the arrow keys choose a row, and the details
    /// show it, still beside the list; Enter opens them over the list, and Escape goes back, the
    /// row having the focus again; a click on another row opens it, and Alt+← goes back.
    private func checkRows() async throws {
        let window = window
        let list = window.list
        try await resize(to: Self.layouts[1])
        let session = try await session()
        let before = list.count
        // Nothing listens on port 9, so each request fails at once, without leaving the computer.
        for number in 1...3 {
            _ = try await session.send(RequestDraft(url: "http://127.0.0.1:9/layout/\(number)"))
        }
        try await until("the 3 requests' rows", seconds: 5) { list.count >= before + 3 }
        await settle()
        let ids = await session.rowIDs().ids.suffix(3)
        try require(ids.count == 3, "the session has \(ids.count) requests, not 3")
        let first = ids[ids.startIndex]
        let second = ids[ids.startIndex + 1]
        list.select(id: first)
        try await until("the row to be selected", seconds: 3) {
            list.selected == first && window.details.shown == first
        }
        list.focusSelection()
        try? await until("the row to have the focus", seconds: 3) { self.rowHasFocus(first) }
        try require(rowHasFocus(first), "the selected row doesn't have the focus; \(focusPath) does")
        try FakeInput.press("Down", in: window.window)
        try await until("Down to choose the next row", seconds: 3) { list.selected == second }
        await settle()
        try require(!window.detailsAreOver, "choosing a row with the arrow keys showed the details over the list")
        try require(window.details.shown == second, "the details show \(String(describing: window.details.shown))")
        try FakeInput.press("Up", in: window.window)
        try await until("Up to choose the row again", seconds: 3) { list.selected == first }

        try FakeInput.press("Return", in: window.window)
        try await until("Enter to show the details over the list", seconds: 3) { window.detailsAreOver }
        await settle()
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to go back to the row, with the focus", seconds: 3) {
            !window.detailsAreOver && self.rowHasFocus(first)
        }
        note(
            "rows, at 1000 px: the arrow keys choose a row, which the details show, without opening over the "
                + "list; Enter opens them over it, and Escape goes back, the row focused")

        // Once the details have gone, as the list takes no clicks meanwhile.
        await settle()
        let cell = try present(list.cell(.method, of: second), "the second row has no cell")
        let point = try FakeInput.click(cell)
        try await until("a click at \(point.x), \(point.y) to choose the row and show it over the list", seconds: 3) {
            list.selected == second && window.detailsAreOver
        }
        await settle()
        try FakeInput.press("Alt_L", "Left", in: window.window)
        try await until("Alt+Left to go back to the row, with the focus", seconds: 3) {
            !window.detailsAreOver && self.rowHasFocus(second)
        }
        note("a click on a row opens it over the list; Alt+Left goes back, the row focused")

        // Ctrl+3 from the row: the details come over the list, on Response, which screen readers
        // hear, rather than "Details", and its tab has the focus.
        let heard = try await AccessibilityTree.events(["object:announcement"], seconds: 4) {
            // The reader takes a moment to start listening.
            try? await Task.sleep(for: .milliseconds(1500))
            try? FakeInput.press("Control_L", "3", in: window.window)
            try? await Task.sleep(for: .milliseconds(1000))
        }
        let said = heard.compactMap(\.detail)
        try require(
            window.detailsAreOver && window.details.page == .response && said == ["Response"],
            "Ctrl+3 from a row: the details \(window.detailsAreOver ? "over" : "under") the list, on "
                + "\(window.details.page.title), and screen readers heard \(said)")
        await settle()
        // The tab that's on, Response's, has the focus.
        let isChosenTab = focus.map {
            (window.isInside($0, window.details.switcher) || window.isInside($0, window.details.switcherBar))
                && gtk_widget_get_state_flags($0).rawValue & GTK_STATE_FLAG_CHECKED.rawValue != 0
        }
        try require(isChosenTab == true, "after Ctrl+3 from a row, the focus is on \(focusName), not Response's tab")
        try FakeInput.press("Escape", in: window.window)
        try await until("Escape to go back to the row", seconds: 3) {
            !window.detailsAreOver && self.rowHasFocus(second)
        }
        window.details.show(page: .overview)
        note("Ctrl+3 from a row: the details over the list, on Response, which screen readers hear, its tab focused")

        let counted = subtitle
        try require(
            counted == ListTitle.requests(list.total), "with \(list.total) requests, the list's title says \(counted)")
        try require(
            g_action_group_get_action_enabled(cast(window.window), "clear") != 0
                && gtk_widget_get_sensitive(window.clearButton) != 0,
            "Clear is off, with \(list.total) requests to clear")
        try FakeInput.press("Control_L", "k", in: window.window)
        try await until("Ctrl+K to clear the list", seconds: 5) { list.total == 0 && list.count == 0 }
        try await until("the details to have nothing to show", seconds: 3) {
            list.selected == nil && window.details.shown == nil
        }
        await settle()
        try require(gtk_widget_get_sensitive(window.clearButton) == 0, "Clear is still on, with nothing to clear")
        // The row that had the keyboard's focus went, and the capture switch has it.
        try await until("the capture switch to have the focus the row had", seconds: 3) {
            self.focus == window.captureSwitch
        }
        note(
            "Ctrl+K: with the list's title saying “\(counted)”, clears the list, the details showing nothing, and Clear goes off"
        )
        note("    the focus then on the capture switch, as the row that had it went")
    }

    /// Whether `id`'s row has the keyboard's focus, or one of its cells: the row that has the cell
    /// showing its method, the cell's own parent's parent.
    private func rowHasFocus(_ id: ExchangeID) -> Bool {
        guard let focus, let cell = window.list.cell(.method, of: id),
            let row = gtk_widget_get_parent(gtk_widget_get_parent(cell))
        else { return false }
        return window.isInside(focus, row)
    }

    /// What the list's title says under it.
    private var subtitle: String {
        string(adw_window_title_get_subtitle(cast(window.listTitle))) ?? ""
    }

    /// What has the window's focus, and what it's in, by their types.
    private var focusPath: String {
        var names: [String] = []
        var next = focus
        while let found = next, names.count < 6 {
            names.append(typeName(raw(found)))
            next = gtk_widget_get_parent(found)
        }
        return names.isEmpty ? "nothing" : names.joined(separator: " in ")
    }

    /// The widget with the window's focus.
    private var focus: Widget? {
        gtk_root_get_focus(cast(window.window))
    }

    /// What has the window's focus, by its type.
    private var focusName: String {
        focus.map { typeName(raw($0)) } ?? "nothing"
    }
}
