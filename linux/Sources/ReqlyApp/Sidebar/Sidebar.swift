import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

/// The sidebar: the scopes the list can show, from the session's sidebar events, each with its
/// count, as ``SidebarRows`` lays them out: All Traffic, Pinned while something is, the apps or
/// the devices, and the hosts. The window puts ``widget`` under the sidebar's header bar, shows the
/// chosen scope's title and count in the list's header bar, and hides the sidebar once you've
/// chosen one, when it shows over the list.
///
/// It's a GtkListView with the navigation-sidebar style, over a GtkFlattenListModel of one list of
/// keys for each section, so a section changes only its own rows. Each section starts with its
/// title, which a click, Enter, ← or → folds away and back, and your settings remember which are
/// folded. Tab goes in and out in one stop, and screen readers hear each row's name, its count and
/// its section. Pinned's menu, from the right button, the Menu key or Shift+F10, unpins every
/// request.
///
/// Choosing a scope tells the session with ``SessionHost/setScope(_:)``, then the window, through
/// ``onScope``, once you're done choosing, with a click or Enter: the arrow keys show each scope
/// they go through, and leave a sidebar shown over the list where it is. A scope whose row goes, as
/// a host's does when Clear takes its traffic, stays chosen, and its row is chosen again once it's
/// back.
///
/// The session's own value for the sidebar's rows is `CoreInterface.Sidebar` here, since this
/// type has its name.
@MainActor
final class Sidebar {
    /// A scope the list can show: its key, as the session's sidebar events name it, and what the
    /// list's header bar calls it.
    struct Scope: Equatable, Sendable {
        var key: String
        var title: String

        static let all = Scope(key: "all", title: "All Traffic")
    }

    /// The rows, in their scroller, and Pinned's menu.
    let widget: Widget
    /// The rows' list, which takes the keyboard's focus.
    let view: Widget
    /// Pinned's menu, with Unpin All Requests.
    let menu: Widget
    /// The scope the list shows.
    private(set) var scope = Scope.all
    /// How many requests the chosen scope has, before search and filters, once the session has
    /// said.
    private(set) var count: Int?
    /// How many requests the session has, as its sidebar events count them: they come after every
    /// change, even one that leaves the list as it was, as filtered traffic does.
    private(set) var total = 0
    /// The rows as they show now.
    private(set) var rows = SidebarRows.empty
    /// Runs once you've chosen a scope, and the session shows it.
    var onScope: ((Scope) -> Void)?
    /// Runs when the chosen scope's count changes, or its title, or the session's count, as when
    /// the arrow keys choose another scope.
    var onCount: (() -> Void)?
    private let model: AppModel
    private let icons = AppIcons()
    /// Each section's row keys, as text, which the view shows, and what they hold.
    private let sections: [OpaquePointer]
    private var shownKeys: [[String]] = SidebarRows.Section.allCases.map { _ in [] }
    private let selection: OpaquePointer
    private let unpinAll: OpaquePointer
    /// The session's latest sidebar, and each row's count since, by key.
    private var latest = CoreInterface.Sidebar(
        total: 0, pinned: 0, apps: [], hosts: [], devices: [], methods: [], sources: [])
    private var counts: [String: Int] = [:]
    /// The key of the row chosen last, which the session may not show yet.
    private var chosen = Scope.all.key
    private var folded: Set<SidebarRows.Section> = []
    /// The rows GTK has bound, by list item, with the key each shows.
    private var bound: [UnsafeMutableRawPointer: String] = [:]
    /// Whether the rows are being shown, rather than chosen by you.
    private var isShowing = false
    /// The latest change of scope. The next one waits for it, so the session gets them in order.
    private var scopeChange: Task<Void, Never>?
    /// Whether you're done with the latest choice, as a click or Enter says, rather than going
    /// through the rows with the arrow keys, and whether the arrow keys are moving now.
    private var isDone = true
    private var isMoving = false

    init(model: AppModel) {
        self.model = model
        let settings = model.settings
        let shown: [(SidebarRows.Section, Bool)] = [
            (.apps, settings.sidebarShowsApps), (.devices, settings.sidebarShowsDevices),
            (.hosts, settings.sidebarShowsHosts),
        ]
        folded = Set(shown.filter { !$0.1 }.map(\.0))
        sections = SidebarRows.Section.allCases.map { _ in gtk_string_list_new(nil) }
        let store = g_list_store_new(g_list_model_get_type())!
        for section in sections {
            g_list_store_append(store, raw(section))
        }
        selection = gtk_single_selection_new(cast(gtk_flatten_list_model_new(cast(store))))
        gtk_single_selection_set_autoselect(selection, 0)
        let factory = gtk_signal_list_item_factory_new()
        view = gtk_list_view_new(cast(selection), factory)
        gtk_widget_add_css_class(view, "navigation-sidebar")
        // Tab leaves the list, rather than going through every row.
        gtk_list_view_set_tab_behavior(cast(view), GTK_LIST_TAB_ITEM)
        setAccessibleLabel(view, "Sidebar")
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), view)
        gtk_widget_set_vexpand(scroller, 1)
        // A box, whose layout places the menu as it opens, as a scroller's doesn't.
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_box_append(cast(widget), scroller)

        let actions = g_simple_action_group_new()!
        unpinAll = g_simple_action_new("unpin-all", nil)
        g_action_map_add_action(cast(actions), cast(unpinAll))
        gtk_widget_insert_action_group(widget, "sidebar", cast(actions))
        g_object_unref(raw(actions))
        let entries = g_menu_new()!
        g_menu_append(entries, "Unpin All Requests", "sidebar.unpin-all")
        menu = gtk_popover_menu_new_from_model(cast(entries))
        g_object_unref(raw(entries))
        gtk_popover_set_position(cast(menu), GTK_POS_BOTTOM)
        gtk_widget_set_parent(menu, widget)

        connect(factory, "setup") { [weak self] (arguments: Arguments) in
            self?.setUp(arguments.object(1)!)
        }
        connect(factory, "bind") { [weak self] (arguments: Arguments) in
            self?.bind(arguments.object(1)!)
        }
        connect(factory, "unbind") { [weak self] (arguments: Arguments) in
            _ = self?.bound.removeValue(forKey: arguments.object(1)!)
        }
        connect(selection, "notify::selected") { [weak self] in self?.selectionChanged() }
        // Enter or a double click: a section's title folds, and another row is chosen for good.
        connect(view, "activate") { [weak self] (arguments: Arguments) in
            self?.activated(at: Int(arguments.uint(1)))
        }
        connect(unpinAll, "activate") { [weak self] in self?.unpinEveryRequest() }
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed") { [weak self] (arguments: Arguments) in
            arguments.returns(self?.pressed(arguments.uint(1), modifiers: arguments.flags(3)) ?? false)
        }
        gtk_widget_add_controller(view, keys)
        icons.onFound = { [weak self] key in self?.iconFound(key) }
        model.listen { [weak self] event in
            switch event {
            case .sidebar(let sidebar): self?.received(sidebar)
            case .counts(let total, let pinned, let counts): self?.counted(total: total, pinned: pinned, counts)
            default: break
            }
        }
        show()
    }

    /// Gives the keyboard's focus to the chosen row, or to the first while none is, and says
    /// whether it could.
    @discardableResult
    func focus() -> Bool {
        let position = rows.position(of: chosen) ?? 0
        // GTK moves the focus to the row itself only while the list has it, so the list then
        // gives it to the row.
        gtk_list_view_scroll_to(cast(view), UInt32(position), GTK_LIST_SCROLL_FOCUS, nil)
        return gtk_widget_grab_focus(view) != 0
    }

    /// Narrows the list to the row with `key`, as choosing it does, while it shows. Once you're
    /// `done`, as with a click or Enter, the window hears of it through ``onScope``, and puts the
    /// sidebar away when it shows over the list; while the arrow keys go through the rows, it hears
    /// only of the new title and count, through ``onCount``, and the sidebar stays.
    func choose(_ key: String, done: Bool = true) {
        guard let row = rows.row(key), row.isScope, let session = model.session else { return }
        guard key != chosen else {
            // Enter or a click on the row chosen already, as the arrow keys chose it.
            if done {
                isDone = true
                if scope.key == key {
                    onScope?(scope)
                }
            }
            return
        }
        chosen = key
        isDone = done
        showChosen()
        let previous = scopeChange
        scopeChange = Task {
            await previous?.value
            await narrow(to: row, in: session)
        }
    }

    private func narrow(to row: SidebarRows.Row, in session: SessionHost) async {
        do {
            try await session.setScope(row.key)
        } catch {
            AppLog.write("couldn't narrow the list to \(row.heading): \(error.message)")
            if chosen == row.key {
                chosen = scope.key
                show()
            }
            return
        }
        // Another was chosen meanwhile, and the session shows it next.
        guard chosen == row.key else { return }
        scope = Scope(key: row.key, title: row.heading)
        count = counts[row.key]
        // Pinned shows while it's chosen, and goes when it isn't, with nothing pinned.
        show()
        if isDone {
            onScope?(scope)
        } else {
            onCount?()
        }
    }

    /// Folds a section away, or back, and remembers it in your settings.
    func fold(_ section: SidebarRows.Section, _ isFolded: Bool) {
        guard section != .scopes, folded.contains(section) != isFolded else { return }
        if isFolded {
            folded.insert(section)
        } else {
            folded.remove(section)
        }
        show()
        do {
            try model.changeSettings { settings in
                switch section {
                case .apps: settings.sidebarShowsApps = !isFolded
                case .devices: settings.sidebarShowsDevices = !isFolded
                case .hosts: settings.sidebarShowsHosts = !isFolded
                case .scopes: break
                }
            }
        } catch {
            AppLog.write("couldn't save whether the sidebar's \(section.title ?? "") show: \(error)")
        }
    }

    /// Whether a section is folded away.
    func isFolded(_ section: SidebarRows.Section) -> Bool {
        folded.contains(section)
    }

    // MARK: - The session's rows

    private func received(_ sidebar: CoreInterface.Sidebar) {
        latest = sidebar
        counts = SidebarRows.counts(of: sidebar)
        show()
    }

    private func counted(total: Int, pinned: Int, _ changed: [String: Int]) {
        let pinnedComesOrGoes = ((counts["pinned"] ?? 0) > 0) != (pinned > 0)
        counts["all"] = total
        counts["pinned"] = pinned
        counts.merge(changed) { _, new in new }
        guard !pinnedComesOrGoes else {
            show()
            return
        }
        let before = rows
        rows = SidebarRows(latest, counts: counts, chosen: chosen, folded: folded)
        refill { before.row($0) != rows.row($0) }
        showCount()
    }

    /// Lays the rows out again, with the latest names and counts, changing only the keys that
    /// changed in each section, so the rows that stay keep their place and the chosen one stays
    /// chosen.
    private func show() {
        let before = rows
        rows = SidebarRows(latest, counts: counts, chosen: chosen, folded: folded)
        isShowing = true
        for (index, list) in sections.enumerated() {
            let old = shownKeys[index]
            let new = rows.sections[index].map(\.key)
            guard old != new else { continue }
            shownKeys[index] = new
            let start = zip(old, new).prefix { $0 == $1 }.count
            let end = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count
            let kept = min(end, min(old.count, new.count) - start)
            withCStrings(Array(new[start..<(new.count - kept)])) {
                gtk_string_list_splice(list, UInt32(start), UInt32(old.count - kept - start), $0)
            }
        }
        isShowing = false
        refill { before.row($0) != rows.row($0) }
        showChosen()
        g_simple_action_set_enabled(unpinAll, cBool((counts["pinned"] ?? 0) > 0))
        showCount()
    }

    /// Chooses the chosen scope's row, while it shows, or none.
    private func showChosen() {
        let position = rows.position(of: chosen).map(UInt32.init) ?? UInt32.max
        guard gtk_single_selection_get_selected(selection) != position else { return }
        isShowing = true
        gtk_single_selection_set_selected(selection, position)
        isShowing = false
    }

    /// The chosen scope's count, and its title, which a device's new name changes, and the
    /// session's count.
    private func showCount() {
        let latest = counts[scope.key] ?? 0
        let title = rows.row(scope.key)?.heading ?? scope.title
        let total = counts["all"] ?? 0
        guard latest != count || title != scope.title || total != self.total else { return }
        count = latest
        scope.title = title
        self.total = total
        onCount?()
    }

    // MARK: - Choosing

    private func selectionChanged() {
        guard !isShowing, let item = gtk_single_selection_get_selected_item(selection),
            let key = string(gtk_string_object_get_string(cast(item)))
        else { return }
        choose(key, done: !isMoving)
    }

    /// Enter on a section's title folds it, or shows it again, and on another row, says you're
    /// done choosing it.
    private func activated(at position: Int) {
        let all = rows.all
        guard all.indices.contains(position) else { return }
        let row = all[position]
        if row.kind == .title {
            fold(row.section, !folded.contains(row.section))
        } else {
            choose(row.key)
        }
    }

    /// ← folds the section whose title has the focus, and → shows it again; the Menu key and
    /// Shift+F10 open Pinned's menu while Pinned has the focus. The arrow keys and the keys that
    /// go further, which choose the rows they go to, are noted, so the sidebar stays meanwhile.
    private func pressed(_ key: UInt32, modifiers: UInt32) -> Bool {
        let moves = [
            GDK_KEY_Up, GDK_KEY_Down, GDK_KEY_KP_Up, GDK_KEY_KP_Down, GDK_KEY_Home, GDK_KEY_End, GDK_KEY_Page_Up,
            GDK_KEY_Page_Down,
        ]
        if moves.contains(where: { key == UInt32($0) }) {
            isMoving = true
            idle { [weak self] in
                self?.isMoving = false
                return false
            }
            return false
        }
        guard let (item, row) = focusedRow() else { return false }
        let shift = modifiers & GDK_SHIFT_MASK.rawValue != 0
        let others = modifiers & (GDK_CONTROL_MASK.rawValue | GDK_ALT_MASK.rawValue) != 0
        if row.kind == .title, !others, key == UInt32(GDK_KEY_Left) || key == UInt32(GDK_KEY_Right) {
            fold(row.section, key == UInt32(GDK_KEY_Left))
            return true
        }
        if row.kind == .pinned, !others, key == UInt32(GDK_KEY_Menu) || (shift && key == UInt32(GDK_KEY_F10)) {
            openMenu(at: gtk_list_item_get_child(cast(item)))
            return true
        }
        return false
    }

    /// The row with the keyboard's focus, and its list item.
    private func focusedRow() -> (UnsafeMutableRawPointer, SidebarRows.Row)? {
        guard let root = gtk_widget_get_root(view), let focus = gtk_root_get_focus(root) else { return nil }
        for (item, key) in bound {
            if let child = gtk_list_item_get_child(cast(item)), gtk_widget_get_parent(child) == focus,
                let row = rows.row(key)
            {
                return (item, row)
            }
        }
        return nil
    }

    private func unpinEveryRequest() {
        guard let session = model.session else { return }
        Task { await session.unpinAll() }
    }

    /// Opens Pinned's menu, pointing at its row.
    func openMenu(at row: Widget?) {
        var bounds = graphene_rect_t()
        if let row, gtk_widget_compute_bounds(row, widget, &bounds) != 0 {
            var area = GdkRectangle(
                x: Int32(bounds.origin.x), y: Int32(bounds.origin.y), width: Int32(bounds.size.width),
                height: Int32(bounds.size.height))
            gtk_popover_set_pointing_to(cast(menu), &area)
        }
        gtk_popover_popup(cast(menu))
    }

    // MARK: - Rows

    /// A row's widgets: its icon, its name, and its count, or for a section's title, an arrow that
    /// says whether it's folded. A click on a title folds it, and the right button on Pinned opens
    /// its menu.
    private func setUp(_ item: UnsafeMutableRawPointer) {
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let icon = gtk_image_new()!
        let name = gtk_label_new(nil)!
        gtk_label_set_xalign(cast(name), 0)
        gtk_widget_set_hexpand(name, 1)
        let count = gtk_label_new(nil)!
        gtk_widget_add_css_class(count, "dim-label")
        gtk_widget_add_css_class(count, "numeric")
        let arrow = gtk_image_new()!
        gtk_widget_add_css_class(arrow, "dim-label")
        for child in [icon, name, count, arrow] {
            gtk_box_append(cast(row), child)
            // The row's own label says what they say.
            setAccessibleHidden(child, true)
        }
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(click), 0)
        connect(click, "pressed") { [weak self] in self?.clickPressed(item, click) }
        connect(click, "released") { [weak self] in self?.clickReleased(item, click) }
        gtk_widget_add_controller(row, cast(click))
        gtk_list_item_set_child(cast(item), row)
    }

    /// A press on a title, or the right button's on Pinned, is the row's own: the list neither
    /// chooses nor opens it.
    private func clickPressed(_ item: UnsafeMutableRawPointer, _ click: OpaquePointer) {
        guard let row = bound[item].flatMap(rows.row) else { return }
        let button = gtk_gesture_single_get_current_button(cast(click))
        if row.kind == .title, button == 1 {
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            if let child = gtk_list_item_get_child(cast(item)), let listRow = gtk_widget_get_parent(child) {
                gtk_widget_grab_focus(listRow)
            }
        } else if row.kind == .pinned, button == 3 {
            gtk_gesture_set_state(cast(click), GTK_EVENT_SEQUENCE_CLAIMED)
            openMenu(at: gtk_list_item_get_child(cast(item)))
        }
    }

    /// A click on a title folds it, or shows it again. One on the row chosen already, which leaves
    /// the list's selection as it is, says you're done choosing it.
    private func clickReleased(_ item: UnsafeMutableRawPointer, _ click: OpaquePointer) {
        guard let row = bound[item].flatMap(rows.row), gtk_gesture_single_get_current_button(cast(click)) == 1
        else { return }
        if row.kind == .title {
            fold(row.section, !folded.contains(row.section))
        } else if row.isScope, row.key == chosen {
            choose(row.key)
        }
    }

    private func bind(_ item: UnsafeMutableRawPointer) {
        guard let object = gtk_list_item_get_item(cast(item)),
            let key = string(gtk_string_object_get_string(cast(object)))
        else { return }
        bound[item] = key
        fill(item)
    }

    /// Fills in again the rows GTK has bound whose keys `changed` says changed.
    private func refill(_ changed: (String) -> Bool) {
        for (item, key) in bound where changed(key) {
            fill(item)
        }
    }

    /// Shows the icon of an app found since its row was filled in.
    private func iconFound(_ key: String) {
        refill { rows.row($0)?.source.map(AppIcons.key(of:)) == key }
    }

    private func fill(_ item: UnsafeMutableRawPointer) {
        guard let key = bound[item], let row = rows.row(key), let cell = gtk_list_item_get_child(cast(item)),
            let icon = gtk_widget_get_first_child(cell), let name = gtk_widget_get_next_sibling(icon),
            let count = gtk_widget_get_next_sibling(name), let arrow = gtk_widget_get_next_sibling(count)
        else { return }
        let isTitle = row.kind == .title
        let isHint = row.kind == .hint
        gtk_list_item_set_selectable(cast(item), cBool(row.isScope))
        gtk_list_item_set_activatable(cast(item), cBool(!isHint))
        gtk_widget_set_margin_start(cell, row.isIndented ? 22 : 0)
        gtk_widget_set_margin_top(cell, isTitle ? 6 : 0)

        gtk_label_set_text(cast(name), row.name)
        gtk_label_set_wrap(cast(name), cBool(isHint))
        gtk_label_set_ellipsize(cast(name), isHint ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
        for (style, isOn) in [("heading", isTitle), ("dim-label", isTitle || isHint), ("caption", isHint)] {
            if isOn {
                gtk_widget_add_css_class(name, style)
            } else {
                gtk_widget_remove_css_class(name, style)
            }
        }
        gtk_label_set_text(cast(count), row.badge())
        gtk_widget_set_visible(count, cBool(row.isScope))
        gtk_image_set_from_icon_name(cast(arrow), row.isFolded ? "pan-end-symbolic" : "pan-down-symbolic")
        gtk_widget_set_visible(arrow, cBool(isTitle))
        showIcon(of: row, in: icon)

        gtk_list_item_set_accessible_label(cast(item), row.spoken())
        gtk_list_item_set_accessible_description(cast(item), row.section.title ?? "")
        // A title says whether its section shows, as an expander does.
        if let listRow = gtk_widget_get_parent(cell) {
            if isTitle {
                // A state that may be undefined takes a number, rather than a yes or no.
                setAccessibleState(listRow, GTK_ACCESSIBLE_STATE_EXPANDED, .int(row.isFolded ? 0 : 1))
            } else {
                gtk_accessible_reset_state(cast(listRow), GTK_ACCESSIBLE_STATE_EXPANDED)
            }
        }
    }

    /// A row's icon: the app's own, or one for the kind of row.
    private func showIcon(of row: SidebarRows.Row, in icon: Widget) {
        let name: String? =
            switch row.kind {
            case .all: "network-transmit-receive-symbolic"
            case .pinned: Icons.pin
            case .host: "network-server-symbolic"
            case .device(nil): "computer-symbolic"
            case .device: "phone-symbolic"
            case .app, .title, .hint: nil
            }
        if let name {
            gtk_image_set_from_icon_name(cast(icon), name)
            gtk_widget_set_visible(icon, 1)
        } else if row.kind == .app {
            let found = icons.icon(for: row.source ?? Source(name: row.name))
            if let found {
                gtk_image_set_from_gicon(cast(icon), found)
            }
            gtk_widget_set_visible(icon, cBool(found != nil))
        } else {
            gtk_widget_set_visible(icon, 0)
        }
    }
}
