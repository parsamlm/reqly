import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

/// The filter bar, under the search bar, as the Mac's: the status buttons, All, 2xx to 5xx and
/// Failed, each with its dot, any of which may match, and All for every status; a token for each
/// other filter that's set, with a button that removes it, which fold into one, such as
/// "3 filters", when they don't fit; and Filters, whose popover has the App, Host and Method menus,
/// the content types, two to a row, Clear All, and how many requests the list shows. A menu keeps
/// a choice whose traffic has gone. The session does the filtering, through
/// ``SessionHost/setFilter(_:)``.
///
/// The bar is hidden while the session is empty, and it scrolls while the window is narrower than
/// its buttons. The window puts ``widget`` under the search bar.
@MainActor
final class FilterBar {
    /// The bar, in a scroller of its own.
    let widget: Widget
    /// All, which shows every status, then a button for each kind.
    let allButton: Widget
    private(set) var statusButtons: [StatusFilter: Widget] = [:]
    /// Filters, and its popover's menus, checks and Clear All, and how many requests show.
    let filtersButton: Widget
    let popover: Widget
    let appChoice: Widget
    let hostChoice: Widget
    let methodChoice: Widget
    private(set) var contentChecks: [ContentGroup: Widget] = [:]
    let clearAllButton: Widget
    let shownLabel: Widget
    /// The tokens, while they fit, and the one that stands for them all, while they don't.
    let tokensBox: Widget
    let foldedToken: Widget
    /// The filter the list shows.
    private(set) var filter = TrafficFilter()
    /// A token for each filter that's set, apart from the statuses.
    private(set) var tokens: [FilterToken] = []
    /// Whether the tokens are folded into one.
    private(set) var isFolded = false
    /// Runs once the session filters the list with a new filter.
    var onFilter: (() -> Void)?
    private let model: SessionModel
    /// The room the tokens have: an area that draws nothing, and says when its width changes.
    private let room: Widget
    /// What each menu offers, after its "Any": what the session has, and the choice, even when its
    /// traffic has gone.
    private var apps: [Source] = []
    private var hosts: [String] = []
    private var methods: [String] = []
    private var latest: CoreInterface.Sidebar?
    /// Whether the filter is being shown, rather than changed by you.
    private var isShowing = false
    private var isFitting = false
    /// The latest change of filter. The next one waits for it, so the session gets them in order.
    private var filtering: Task<Void, Never>?
    /// Whether the bar's window has closed, though the bar may live on a moment, as a change of
    /// filter that waits on the session holds it.
    private(set) var isGone = false
    /// The bar's listener of its session, which goes as its window closes.
    private var listener: Int?

    init(model: SessionModel) {
        self.model = model
        Self.addStyles()
        // The toolbar's style puts 6 pixels between its parts.
        let bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(bar, "toolbar")
        allButton = Self.statusButton("All", tip: "Show every status", mark: nil)
        gtk_box_append(cast(bar), allButton)
        for status in StatusFilter.allCases {
            let button = Self.statusButton(status.title, tip: status.tip, mark: Self.mark(for: status))
            statusButtons[status] = button
            gtk_box_append(cast(bar), button)
        }
        let separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL)!
        gtk_widget_set_margin_start(separator, 4)
        gtk_widget_set_margin_end(separator, 4)
        gtk_box_append(cast(bar), separator)

        // The tokens are the only part that shrinks, so they have all the room that's left.
        room = gtk_drawing_area_new()
        gtk_widget_set_hexpand(room, 1)
        // Screen readers would hear an image with no name.
        setAccessibleHidden(room, true)
        tokensBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        foldedToken = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        let tokenRoom = gtk_overlay_new()!
        gtk_overlay_set_child(cast(tokenRoom), room)
        for tokens in [tokensBox, foldedToken] {
            gtk_widget_set_halign(tokens, GTK_ALIGN_START)
            gtk_widget_set_valign(tokens, GTK_ALIGN_CENTER)
            gtk_widget_set_visible(tokens, 0)
            gtk_overlay_add_overlay(cast(tokenRoom), tokens)
            gtk_overlay_set_measure_overlay(cast(tokenRoom), tokens, 1)
            gtk_overlay_set_clip_overlay(cast(tokenRoom), tokens, 1)
        }
        gtk_box_append(cast(bar), tokenRoom)

        filtersButton = gtk_menu_button_new()
        gtk_menu_button_set_label(cast(filtersButton), "Filters")
        // Its own name, or GTK makes one from the open popover's words too.
        setAccessibleLabel(filtersButton, "Filters")
        gtk_widget_set_tooltip_text(filtersButton, "Filter by app, host, method or content type")
        gtk_box_append(cast(bar), filtersButton)

        // The popover: a menu each for the app, the host and the method, and the content types.
        appChoice = Self.choice("App")
        hostChoice = Self.choice("Host")
        methodChoice = Self.choice("Method")
        let grid = gtk_grid_new()!
        gtk_grid_set_column_spacing(cast(grid), 12)
        gtk_grid_set_row_spacing(cast(grid), 8)
        for (row, (title, choice)) in [("App", appChoice), ("Host", hostChoice), ("Method", methodChoice)].enumerated()
        {
            gtk_grid_attach(cast(grid), Self.rowTitle(title), 0, Int32(row), 1, 1)
            gtk_grid_attach(cast(grid), choice, 1, Int32(row), 1, 1)
        }
        let contentTitle = Self.rowTitle("Content type")
        gtk_widget_set_valign(contentTitle, GTK_ALIGN_START)
        gtk_grid_attach(cast(grid), contentTitle, 0, 3, 1, 1)
        let contents = gtk_grid_new()!
        gtk_grid_set_column_spacing(cast(contents), 12)
        gtk_grid_set_column_homogeneous(cast(contents), 1)
        for (index, group) in ContentGroup.allCases.enumerated() {
            let check = gtk_check_button_new_with_label(group.title)!
            contentChecks[group] = check
            gtk_grid_attach(cast(contents), check, Int32(index % 2), Int32(index / 2), 1, 1)
        }
        gtk_grid_attach(cast(grid), contents, 1, 3, 1, 1)
        clearAllButton = gtk_button_new_with_label("Clear All")
        gtk_widget_add_css_class(clearAllButton, "flat")
        shownLabel = gtk_label_new(nil)
        gtk_widget_add_css_class(shownLabel, "dim-label")
        gtk_widget_add_css_class(shownLabel, "numeric")
        gtk_widget_set_hexpand(shownLabel, 1)
        gtk_label_set_xalign(cast(shownLabel), 1)
        let bottom = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_box_append(cast(bottom), clearAllButton)
        gtk_box_append(cast(bottom), shownLabel)
        let heading = gtk_label_new("Filters")!
        gtk_widget_add_css_class(heading, "heading")
        gtk_label_set_xalign(cast(heading), 0)
        let content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        for part in [heading, grid, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!, bottom] {
            gtk_box_append(cast(content), part)
        }
        popover = gtk_popover_new()
        gtk_popover_set_child(cast(popover), content)
        gtk_menu_button_set_popover(cast(filtersButton), popover)

        widget = namedScroller("Filters")
        gtk_scrolled_window_set_policy(cast(widget), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        gtk_scrolled_window_set_propagate_natural_width(cast(widget), 1)
        gtk_scrolled_window_set_propagate_natural_height(cast(widget), 1)
        gtk_scrolled_window_set_child(cast(widget), bar)
        gtk_widget_set_visible(widget, 0)

        connect(allButton, "toggled") { [weak self] in self?.statusToggled(nil) }
        for (status, button) in statusButtons {
            connect(button, "toggled") { [weak self] in self?.statusToggled(status) }
        }
        for (group, check) in contentChecks {
            connect(check, "toggled") { [weak self] in self?.contentToggled(group) }
        }
        for choice in [appChoice, hostChoice, methodChoice] {
            connect(choice, "notify::selected") { [weak self] in self?.chose(in: choice) }
        }
        connect(clearAllButton, "clicked") { [weak self] in self?.clear() }
        connect(popover, "show") { [weak self] in self?.showChoices() }
        connect(room, "resize") { [weak self] in self?.roomChanged() }
        listener = model.listen { [weak self] event in
            switch event {
            case .rows(_, let total, let shown, _): self?.counted(total: total, shown: shown)
            case .sidebar(let sidebar): self?.received(sidebar)
            // After every change, even one the filter leaves out, which sends no rows.
            case .counts(let total, _, _): self?.counted(total: total)
            default: break
            }
        }
        showFilter()
    }

    /// Its window has closed, and the bar's widgets go with it: it hears its session no more, and
    /// tells the window nothing more.
    func windowClosed() {
        isGone = true
        onFilter = nil
        if let listener {
            model.stopListening(listener)
            self.listener = nil
        }
    }

    /// Whether any filter is set, the statuses too.
    var isActive: Bool { filter.isActive }

    /// Filters the list with `filter`, and shows it.
    func set(_ filter: TrafficFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        showFilter()
        guard let session = model.session else { return }
        let previous = filtering
        filtering = Task {
            await previous?.value
            await session.setFilter(filter)
            onFilter?()
        }
    }

    /// Takes every filter off, the statuses too, as Clear All and Clear Filters do.
    func clear() {
        set(TrafficFilter())
    }

    // MARK: - Changes

    private func statusToggled(_ status: StatusFilter?) {
        guard !isShowing else { return }
        var filter = self.filter
        if let status {
            filter.statuses.formSymmetricDifference([status])
        } else {
            filter.statuses = []
        }
        set(filter)
        // All stays on while it's what shows.
        showFilter()
    }

    private func contentToggled(_ group: ContentGroup) {
        guard !isShowing, let check = contentChecks[group] else { return }
        var filter = self.filter
        if gtk_check_button_get_active(cast(check)) != 0 {
            filter.contents.insert(group)
        } else {
            filter.contents.remove(group)
        }
        set(filter)
    }

    private func chose(in choice: Widget) {
        guard !isShowing else { return }
        // The first is "Any".
        let index = Int(gtk_drop_down_get_selected(cast(choice))) - 1
        var filter = self.filter
        if choice == appChoice {
            filter.source = apps.indices.contains(index) ? apps[index] : nil
        } else if choice == hostChoice {
            filter.host = hosts.indices.contains(index) ? hosts[index] : nil
        } else {
            filter.method = methods.indices.contains(index) ? methods[index] : nil
        }
        set(filter)
    }

    private func remove(_ tokens: [FilterToken]) {
        var filter = self.filter
        for token in tokens {
            token.clear(&filter)
        }
        set(filter)
        // Its button has gone.
        gtk_widget_grab_focus(filtersButton)
    }

    private func counted(total: Int, shown: Int? = nil) {
        gtk_widget_set_visible(widget, cBool(total > 0))
        if let shown {
            gtk_label_set_text(cast(shownLabel), ListTitle.requests(shown))
        }
    }

    private func received(_ sidebar: CoreInterface.Sidebar) {
        latest = sidebar
        counted(total: sidebar.total)
        if gtk_widget_get_visible(popover) != 0 {
            showChoices()
        }
    }

    // MARK: - Showing the filter

    private func showFilter() {
        isShowing = true
        gtk_toggle_button_set_active(cast(allButton), cBool(filter.statuses.isEmpty))
        for (status, button) in statusButtons {
            gtk_toggle_button_set_active(cast(button), cBool(filter.statuses.contains(status)))
        }
        for (group, check) in contentChecks {
            gtk_check_button_set_active(cast(check), cBool(filter.contents.contains(group)))
        }
        isShowing = false
        showChoices()
        gtk_widget_set_sensitive(clearAllButton, cBool(filter.isActive))
        showTokens()
    }

    /// Fills the menus: what the session has, and the choice, so it still shows after its traffic
    /// has gone.
    private func showChoices() {
        func keeping<Choice: Equatable>(_ available: [Choice], _ chosen: Choice?) -> [Choice] {
            guard let chosen, !available.contains(chosen) else { return available }
            return available + [chosen]
        }
        isShowing = true
        let newApps = keeping(latest?.sources ?? [], filter.source)
        let newHosts = keeping(latest?.hosts.map(\.name) ?? [], filter.host)
        let newMethods = keeping(latest?.methods ?? [], filter.method)
        Self.offer(appChoice, "Any app", newApps.map(\.name), changed: newApps != apps)
        Self.offer(hostChoice, "Any host", newHosts, changed: newHosts != hosts)
        Self.offer(methodChoice, "Any method", newMethods, changed: newMethods != methods)
        (apps, hosts, methods) = (newApps, newHosts, newMethods)
        let chosen = [
            (appChoice, filter.source.flatMap { apps.firstIndex(of: $0) }),
            (hostChoice, filter.host.flatMap { hosts.firstIndex(of: $0) }),
            (methodChoice, filter.method.flatMap { methods.firstIndex(of: $0) }),
        ]
        for (choice, index) in chosen {
            let selected = UInt32(index.map { $0 + 1 } ?? 0)
            if gtk_drop_down_get_selected(cast(choice)) != selected {
                gtk_drop_down_set_selected(cast(choice), selected)
            }
        }
        isShowing = false
    }

    /// A token for each filter set in the popover, or while they don't fit, one for them all.
    private func showTokens() {
        let tokens = FilterToken.tokens(for: filter)
        guard tokens != self.tokens || gtk_widget_get_first_child(tokensBox) == nil else { return }
        self.tokens = tokens
        for box in [tokensBox, foldedToken] {
            while let child = gtk_widget_get_first_child(box) {
                gtk_box_remove(cast(box), child)
            }
        }
        for token in tokens {
            let widget = Self.token(token.title, tip: token.tip, removal: token.removal, spoken: token.tip) {
                [weak self] in self?.remove([token])
            }
            gtk_box_append(cast(tokensBox), widget)
        }
        if !tokens.isEmpty {
            let folded = FoldedTokens(tokens: tokens)
            // Whole, as it says how many there are: the bar scrolls sideways before it's cut.
            let widget = Self.token(
                folded.title, tip: folded.tip, removal: folded.removal, spoken: folded.spoken, cuts: false
            ) { [weak self] in self?.remove(tokens) }
            gtk_box_append(cast(foldedToken), widget)
        }
        fitTokens()
    }

    /// The tokens' room changed: they fold, or unfold, once GTK has placed the bar, as showing one
    /// or the other places it again.
    private func roomChanged() {
        guard !isFitting else { return }
        isFitting = true
        idle { [weak self] in
            guard let self, !isGone else { return false }
            isFitting = false
            fitTokens()
            return false
        }
    }

    /// Shows a token for each filter while they all fit in their room, and one for them all while
    /// they don't.
    private func fitTokens() {
        var needed: Int32 = 0
        var child = gtk_widget_get_first_child(tokensBox)
        while let token = child {
            var natural: Int32 = 0
            gtk_widget_measure(token, GTK_ORIENTATION_HORIZONTAL, -1, nil, &natural, nil, nil)
            needed += natural + (needed > 0 ? 6 : 0)
            child = gtk_widget_get_next_sibling(token)
        }
        // Before the bar's first placing, there's no room to go by.
        let width = gtk_widget_get_width(room)
        let folds = !tokens.isEmpty && gtk_widget_get_mapped(room) != 0 && needed > width
        isFolded = folds
        gtk_widget_set_visible(tokensBox, cBool(!tokens.isEmpty && !folds))
        gtk_widget_set_visible(foldedToken, cBool(folds))
    }

    // MARK: - Parts

    /// A status button: its dot, or a warning for Failed, and its title.
    private static func statusButton(_ title: String, tip: String, mark: Widget?) -> Widget {
        let button = gtk_toggle_button_new()!
        // On, it has a background, and off, none, as the Mac's chips, and its sides are narrower
        // than a button's, so the bar fits the list's narrowest pane beside the details.
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_add_css_class(button, "filter-chip")
        let content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        if let mark {
            gtk_box_append(cast(content), mark)
            setAccessibleHidden(mark, true)
        }
        gtk_box_append(cast(content), gtk_label_new(title))
        gtk_button_set_child(cast(button), content)
        gtk_widget_set_tooltip_text(button, tip)
        setAccessibleLabel(button, title)
        return button
    }

    /// The status's dot, in the list's color for it, or a warning for Failed.
    private static func mark(for status: StatusFilter) -> Widget {
        let statusClass: StatusClass
        switch status {
        case .success: statusClass = .success
        case .redirection: statusClass = .redirection
        case .clientError: statusClass = .clientError
        case .serverError: statusClass = .serverError
        case .failed:
            let warning = gtk_image_new_from_icon_name(Icons.warning)!
            gtk_widget_add_css_class(warning, "error")
            return warning
        }
        let dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_add_css_class(dot, "request-dot")
        gtk_widget_add_css_class(dot, statusClass.styleClass)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        return dot
    }

    /// A row's title in the popover.
    private static func rowTitle(_ title: String) -> Widget {
        let label = gtk_label_new(title)!
        gtk_widget_add_css_class(label, "dim-label")
        gtk_label_set_xalign(cast(label), 0)
        return label
    }

    /// A menu of choices, which starts with "Any", named for screen readers. Typing in it finds a
    /// choice by how it starts, as on the Mac, so the 200th host is a few keys away.
    private static func choice(_ name: String) -> Widget {
        let choice = withCStrings([]) { gtk_drop_down_new_from_strings($0) }!
        // The menu takes its own reference to the expression its search goes by.
        let words = gtk_property_expression_new(gtk_string_object_get_type(), nil, "string")
        gtk_drop_down_set_expression(cast(choice), words)
        gtk_expression_unref(words)
        gtk_drop_down_set_enable_search(cast(choice), 1)
        gtk_widget_set_hexpand(choice, 1)
        setAccessibleLabel(choice, name)
        return choice
    }

    /// Offers `choices` in a menu, after `any`, when they changed.
    private static func offer(_ choice: Widget, _ any: String, _ choices: [String], changed: Bool) {
        let list: OpaquePointer = cast(gtk_drop_down_get_model(cast(choice)))
        let count = g_list_model_get_n_items(cast(list))
        guard changed || count == 0 else { return }
        withCStrings([any] + choices) { gtk_string_list_splice(list, 0, count, $0) }
    }

    /// A token: its title, cut short where there's no room if it `cuts`, and a button that removes
    /// its filter, named for screen readers, which then hear what the filter is.
    private static func token(
        _ title: String, tip: String, removal: String, spoken: String, cuts: Bool = true,
        remove: @escaping @MainActor () -> Void
    ) -> Widget {
        let token = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)!
        gtk_widget_add_css_class(token, "filter-token")
        gtk_widget_set_tooltip_text(token, tip)
        let label = gtk_label_new(title)!
        gtk_label_set_ellipsize(cast(label), cuts ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE)
        gtk_label_set_max_width_chars(cast(label), 24)
        gtk_label_set_single_line_mode(cast(label), 1)
        let button = gtk_button_new_from_icon_name("window-close-symbolic")!
        gtk_widget_add_css_class(button, "flat")
        gtk_widget_add_css_class(button, "circular")
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(button, "Remove this filter")
        setAccessibleLabel(button, removal)
        setAccessibleDescription(button, spoken)
        connect(button, "clicked") { remove() }
        gtk_box_append(cast(token), label)
        gtk_box_append(cast(token), button)
        return token
    }

    // MARK: - Styles

    private static var hasStyles = false

    /// The tokens, tinted with your accent; and the status buttons' dots, in the list's colors
    /// for each status class, which follow the style manager.
    private static func addStyles() {
        ListStyles.install()
        guard !hasStyles, let display = gdk_display_get_default() else { return }
        hasStyles = true
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            display, cast(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    private static let css = """
        .filter-token { border-radius: 9999px; padding-left: 10px; background-color: alpha(@accent_bg_color, 0.15); }
        .filter-token button { min-width: 24px; min-height: 24px; padding: 0; }
        .filter-chip { padding-left: 6px; padding-right: 6px; }
        """
}
