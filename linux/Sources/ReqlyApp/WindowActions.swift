import CGtk
import GtkBinding

extension MainWindow {
    /// The window's actions, `win.<name>`, each with its keyboard shortcut, as GNOME's apps have
    /// them, and the Mac's where GNOME has none: F9 shows and hides the sidebar; Ctrl+F searches;
    /// Ctrl+1 to Ctrl+5 choose the details' pages, `win.page::overview` to `win.page::timing`;
    /// Ctrl+K clears the traffic, but for pinned requests; Ctrl+R starts or stops capturing. F10
    /// opens the main menu that shows, as its button is GTK's primary menu, and Escape goes back,
    /// in its own order: see ``escape()``. While a dialog shows over the window, they wait.
    func addActions() {
        add("toggle-sidebar", accelerator: "F9") { [weak self] in self?.toggleSidebar() }
        add("search", accelerator: "<Control>f") { [weak self] in self?.openSearch() }
        clearAction = add("clear", accelerator: "<Control>k") { [weak self] in self?.clear() }
        add("toggle-capture", accelerator: "<Control>r") { [weak self] in self?.toggleCapture() }

        let pageType = g_variant_type_new("s")
        let pageAction = g_simple_action_new("page", pageType)!
        g_variant_type_free(pageType)
        connect(pageAction, "activate") { [weak self] (arguments: Arguments) in
            guard let name = arguments.variant(1).flatMap({ string(g_variant_get_string($0, nil)) }),
                let chosen = DetailsPane.Page(rawValue: name)
            else { return }
            self?.choose(chosen)
        }
        g_action_map_add_action(cast(window), cast(pageAction))
        g_object_unref(raw(pageAction))
        for (index, page) in DetailsPane.Page.allCases.enumerated() {
            withCStrings(["<Control>\(index + 1)"]) {
                gtk_application_set_accels_for_action(cast(app.application), "win.page::\(page.rawValue)", $0)
            }
        }

        // Before the widgets in the window, which would take Escape for themselves first.
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed") { [weak self] (arguments: Arguments) in
            let modifiers = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
            guard let self, arguments.uint(1) == UInt32(GDK_KEY_Escape), arguments.flags(3) & modifiers == 0 else {
                return
            }
            arguments.returns(self.escape())
        }
        gtk_widget_add_controller(window, keys)
    }

    /// F9: shows the sidebar, or hides it, at any width.
    func toggleSidebar() {
        guard visibleDialog(over: window) == nil else { return }
        if adw_overlay_split_view_get_show_sidebar(outer) != 0 {
            hideSidebar()
        } else {
            adw_overlay_split_view_set_show_sidebar(outer, 1)
        }
    }

    /// Ctrl+F: the search bar, with the keyboard's focus in its field. Over the details, it's the
    /// list's again first.
    func openSearch() {
        guard visibleDialog(over: window) == nil else { return }
        if detailsAreOver {
            adw_navigation_split_view_set_show_content(inner, 0)
        }
        search.open()
    }

    /// Ctrl+K: Clear Traffic, which keeps pinned requests.
    func clear() {
        guard visibleDialog(over: window) == nil, let session = model.session else { return }
        Task { await session.clear() }
    }

    /// Ctrl+R: starts or stops capturing, as the switch does, when it can.
    func toggleCapture() {
        guard visibleDialog(over: window) == nil, gtk_widget_get_sensitive(captureSwitch) != 0 else { return }
        gtk_switch_set_active(cast(captureSwitch), cBool(gtk_switch_get_active(cast(captureSwitch)) == 0))
    }

    /// Ctrl+1 to Ctrl+5: the details' page, which screen readers then say, since only the tabs
    /// show it.
    func choose(_ page: DetailsPane.Page) {
        guard visibleDialog(over: window) == nil else { return }
        details.show(page: page)
        announce(window, page.title)
    }

    /// Escape, before the window's own widgets: it closes the search bar while it shows, then the
    /// sidebar shown over the list, then goes back from the details over the list, one at a time,
    /// and the keyboard's focus goes back to the pane that shows. A search left open under the
    /// details closes once they've gone. A dialog, a menu that's open, and a search field of the
    /// details' own close themselves. Whether Escape did something.
    func escape() -> Bool {
        let focus = gtk_root_get_focus(cast(window))
        if visibleDialog(over: window) != nil {
            return false
        }
        if let focus, gtk_widget_get_ancestor(focus, gtk_popover_get_type()) != nil {
            return false
        }
        if let field = focus.flatMap({ gtk_widget_get_ancestor($0, gtk_search_entry_get_type()) }),
            field != search.entry
        {
            return false
        }
        if search.isOpen, !detailsAreOver {
            search.close()
            return true
        }
        if sidebarIsOver {
            hideSidebar()
            return true
        }
        if detailsAreOver {
            adw_navigation_split_view_set_show_content(inner, 0)
            return true
        }
        return false
    }

    /// Adds the action `win.<name>`, which runs `body`, with its keyboard shortcut, and gives it.
    @discardableResult
    private func add(_ name: String, accelerator: String, _ body: @escaping @MainActor () -> Void) -> OpaquePointer {
        let action = g_simple_action_new(name, nil)!
        connect(action, "activate") { body() }
        g_action_map_add_action(cast(window), cast(action))
        g_object_unref(raw(action))
        withCStrings([accelerator]) { gtk_application_set_accels_for_action(cast(app.application), "win.\(name)", $0) }
        return action
    }
}
