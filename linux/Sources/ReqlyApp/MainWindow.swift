import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

/// The window: three panes, each under a header bar of its own, after libadwaita's triple-pane
/// layout, in a toast overlay. An overlay split view has the sidebar, beside a navigation split
/// view of the request list and the details:
///
/// - the sidebar, under a header bar with Reqly's name and the main menu;
/// - the list, under a header bar with the sidebar's toggle, the capture switch, what the list
///   shows and how many, Clear, the search button, the Rules button, and the main menu once the
///   sidebar has folded away; then the banners, the search bar and the filter bar, and the status
///   line under the list;
/// - the details, under a header bar of their own.
///
/// Up to 1100 sp wide, the details open over the list, with Enter or a click on a row, and go back
/// with Escape, Alt+← or the back button. Up to 760 sp, the sidebar folds away too, and shows over
/// the list, and the main menu moves into the list's header bar. Narrower still, the list's columns
/// go, least needed first, so it never scrolls sideways: App and Time up to 640 sp, Duration up to
/// 520, and Size up to 400. Up to 520 sp, search, Clear and Rules move to a bar under the list, and
/// the capture switch loses its word, so the header bar fits GNOME's narrowest window, 360 pixels,
/// with the window's three buttons and the text at 1.25. F9 shows and hides the sidebar at any
/// width. The panes' widths are in sp, so they grow with the text, and libadwaita works them out
/// again when its size changes.
///
/// What the panes hold belongs to the features, each in its own folder: the sidebar in `Sidebar/`,
/// search and filters in `Find/`, the list in `Traffic/`, the details in `Details/` and the bodies
/// in `Bodies/`; capturing in `Capture/`, the terminal in `Terminal/` and HTTPS in `HTTPS/`. This
/// file puts them in place and tells each what another did. App.swift registers the menu's actions,
/// and WindowActions.swift the window's own, with their shortcuts.
///
/// The live window shows the live session, which the app keeps; a file's window shows a saved
/// session or HAR file, in a session of its own, with the file's name as its title, and no capture
/// switch or Rules button. Closing a file's window closes it alone; closing the live window hides
/// it: see ``App``.
@MainActor
final class MainWindow {
    unowned let app: App
    /// The window's session: the live one, or a file's.
    let model: SessionModel
    let window: Widget
    /// The sidebar's split view, around the list's and the details'.
    let outer: OpaquePointer
    /// The list's and the details' split view.
    let inner: OpaquePointer
    let sidebarHeader: Widget
    /// The list's header bar, with the capture switch.
    let listHeader: Widget
    /// "Capture" and its switch, which a file's window hides.
    let captureBox: Widget
    let captureLabel: Widget
    let captureSwitch: Widget
    /// The Rules menu's button, at the end of the list's header bar, in the live window only.
    let rulesButton: Widget
    /// Shows and hides the sidebar, in the list's header bar, while the sidebar is folded away or
    /// hidden.
    let sidebarToggle: Widget
    /// What the list shows, and how many, as the header bar's title.
    let listTitle: Widget
    let clearButton: Widget
    let searchButton: Widget
    /// Under the list, up to 520 sp: search, Clear and Rules, in place of the header bar's.
    let narrowBar: Widget
    let narrowSearchButton: Widget
    let narrowClearButton: Widget
    let narrowRulesButton: Widget
    /// The main menu's button, in the sidebar's header bar.
    let menuButton: Widget
    /// The main menu's button in the list's header bar, while the sidebar is folded away.
    let listMenuButton: Widget
    /// The main menu's model, a GMenu of sections.
    let menu: OpaquePointer
    /// Under the list's header bar, in the live window: a request a breakpoint holds, while the
    /// details don't show it, and a device that waits to be let in.
    let pausedBanner = Banner()
    let deviceBanner = Banner()
    let sidebar: Sidebar
    let search: SearchBar
    let filters: FilterBar
    let list: RequestList
    /// What shows in the list's place while there's traffic, but none of it shows.
    let noMatches: NoMatchesPage
    let details: DetailsPane
    /// The sidebar's pane and the list's, each a toolbar view under its header bar.
    let sidebarPane: Widget
    let listPane: Widget
    let statusLine: Widget
    let statusLabel: Widget
    /// How many of the session's requests the list shows, at the status line's end.
    let statusCount: Widget
    /// The window's breakpoints: up to 1100 sp, the details go over the list, and up to 760 sp, the
    /// sidebar folds away too. A third, up to 1400 sp, hides the list's App column while the details
    /// are beside it.
    let detailsOver: OpaquePointer
    let sidebarFolds: OpaquePointer
    let listNarrows: OpaquePointer
    /// Narrower than the sidebar's fold: up to 640, 520 and 400 sp, the list's columns go, and the
    /// header bar's buttons move under the list from 520.
    let columnsGo: OpaquePointer
    let headerNarrows: OpaquePointer
    let sizeGoes: OpaquePointer
    private let statusDot: Widget
    private let toasts: Widget
    /// The panes, or, in a file's window, what shows while the file opens or once it couldn't,
    /// each under a header bar of its own, as the panes' don't show meanwhile.
    private let content: Widget
    private var opening: Widget?
    private var failed: Widget?
    /// The main menu's buttons in the opening and failed pages' header bars.
    private var pageMenuButtons: [Widget] = []
    /// The list, or the no-matches page in its place.
    private let listContent: Widget
    /// Whether the switch is being set to the model's state, rather than by you.
    private var isShowingCapture = false
    /// How many of the session's requests are pinned, which Clear keeps.
    private var pinned = 0
    /// Whether the keyboard's first focus waits for the session to open.
    private var isFirstFocusDue = true
    /// Counts the folds that kept a widget's focus, and the first focus: only the latest one's
    /// looks give the focus back.
    private var focusTurn = 0
    /// Counts your key presses and clicks, which a later look after a fold leaves alone.
    private(set) var inputs = 0
    /// What has had the keyboard's focus since the first focus gave it to the capture switch, as
    /// the session had no requests, until the list first shows some.
    private var firstFocus: Widget?
    /// Clear's action, which is on while there's something to clear.
    var clearAction: OpaquePointer?
    /// Save Session… and Export as HAR…, which are on while the session has requests.
    var saveAction: OpaquePointer?
    var exportAction: OpaquePointer?
    /// Copy URL and Copy as cURL, Shift+Ctrl+C and Ctrl+Alt+C, on while the details show a
    /// request.
    var copyURLAction: OpaquePointer?
    var copyCurlAction: OpaquePointer?
    /// The details' pages' action, Ctrl+1 to Ctrl+5, which is on while the details show a
    /// request, as on the Mac.
    var pageAction: OpaquePointer?
    /// Whether screen readers hear what capturing does once Ctrl+R's start or stop is done, as
    /// the switch it turns may not have the focus.
    var saysCapturing = false
    /// When screen readers hear what a search or the filters found, the words they heard last, and
    /// the timer that says them.
    private var found = FoundWords()
    private var foundSaid: String?
    private var findingTimer: UInt32?
    /// Settings and Set Up HTTPS…, each made the first time it opens and kept, as they keep
    /// their pages.
    private(set) var settings: SettingsDialog?
    private(set) var setUp: SetUpDialog?
    private(set) var about: Widget?
    /// Whether the window has shown, once or more.
    private(set) var hasShown = false
    /// Whether Reqly has closed the window, though this object may live on a moment: the work
    /// that waited on the main loop then does nothing. See ``closed()``.
    private(set) var isClosed = false
    /// The window's observer and listener of its session, which go as it closes.
    private var observer: Int?
    private var listener: Int?
    /// What the status line says now.
    private(set) var statusWords: StatusLine?

    /// The app's model: capturing, settings, HTTPS and the rest, which every window shares.
    var appModel: AppModel { app.model }

    init(app: App, model: SessionModel) {
        self.app = app
        self.model = model
        window = adw_application_window_new(cast(app.application))
        // Held until the window object goes, as its work waiting on the main loop may still look at
        // it once it's closed.
        g_object_ref(raw(window))
        gtk_window_set_title(cast(window), model.fileName ?? "Reqly")
        gtk_window_set_icon_name(cast(window), App.id)
        let size = Self.openingSize(within: Self.workArea())
        gtk_window_set_default_size(cast(window), Int32(size.width), Int32(size.height))
        // The smallest size GNOME's adaptive windows design for.
        gtk_widget_set_size_request(window, 360, 294)

        menu = Self.mainMenu(isLive: model.isLive)

        // The sidebar's pane: Reqly's name and the main menu, which F10 opens while it shows.
        sidebar = Sidebar(model: model)
        menuButton = Self.mainMenuButton(menu)
        gtk_menu_button_set_primary(cast(menuButton), 1)
        sidebarHeader = adw_header_bar_new()
        adw_header_bar_set_title_widget(cast(sidebarHeader), adw_window_title_new("Reqly", nil))
        adw_header_bar_pack_end(cast(sidebarHeader), menuButton)
        sidebarPane = adw_toolbar_view_new()
        adw_toolbar_view_add_top_bar(cast(sidebarPane), sidebarHeader)
        adw_toolbar_view_set_content(cast(sidebarPane), sidebar.widget)

        // The list's header bar: the sidebar's toggle and the capture switch at the start, what
        // the list shows in the middle, and at the end Clear, search, and the main menu, which
        // shows once the sidebar has folded away.
        listHeader = adw_header_bar_new()
        sidebarToggle = gtk_toggle_button_new()
        gtk_button_set_icon_name(cast(sidebarToggle), "sidebar-show-symbolic")
        gtk_widget_set_tooltip_text(sidebarToggle, "Show Sidebar")
        setAccessibleLabel(sidebarToggle, "Show Sidebar")
        adw_header_bar_pack_start(cast(listHeader), sidebarToggle)
        captureBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        captureLabel = gtk_label_new("Capture")!
        captureSwitch = gtk_switch_new()
        gtk_widget_set_valign(captureSwitch, GTK_ALIGN_CENTER)
        setAccessibleLabel(captureSwitch, "Capture Traffic")
        // Its word goes in a narrow window.
        gtk_widget_set_tooltip_text(captureSwitch, "Capture Traffic")
        gtk_box_append(cast(captureBox), captureLabel)
        gtk_box_append(cast(captureBox), captureSwitch)
        gtk_widget_set_margin_start(captureBox, 6)
        // A file's window shows what was saved: it captures nothing.
        gtk_widget_set_visible(captureBox, cBool(model.isLive))
        adw_header_bar_pack_start(cast(listHeader), captureBox)
        listTitle = adw_window_title_new(Sidebar.Scope.all.title, nil)
        Self.letTitleShrink(listTitle)
        adw_header_bar_set_title_widget(cast(listHeader), listTitle)
        listMenuButton = Self.mainMenuButton(menu)
        gtk_widget_set_visible(listMenuButton, 0)
        adw_header_bar_pack_end(cast(listHeader), listMenuButton)
        // The rules act on the live session, so a file's window has no Rules button.
        rulesButton = RulesMenu.button()
        gtk_widget_set_visible(rulesButton, cBool(model.isLive))
        adw_header_bar_pack_end(cast(listHeader), rulesButton)
        searchButton = gtk_toggle_button_new()
        gtk_button_set_icon_name(cast(searchButton), "system-search-symbolic")
        gtk_widget_set_tooltip_text(searchButton, "Search")
        setAccessibleLabel(searchButton, "Search")
        adw_header_bar_pack_end(cast(listHeader), searchButton)
        clearButton = gtk_button_new_from_icon_name("user-trash-symbolic")
        gtk_widget_set_tooltip_text(clearButton, "Clear Traffic. Pinned requests stay.")
        setAccessibleLabel(clearButton, "Clear Traffic")
        gtk_actionable_set_action_name(cast(clearButton), "win.clear")
        adw_header_bar_pack_end(cast(listHeader), clearButton)

        // The same, under the list, in a narrow window.
        narrowSearchButton = gtk_toggle_button_new()
        gtk_button_set_icon_name(cast(narrowSearchButton), "system-search-symbolic")
        gtk_widget_set_tooltip_text(narrowSearchButton, "Search")
        setAccessibleLabel(narrowSearchButton, "Search")
        narrowClearButton = gtk_button_new_from_icon_name("user-trash-symbolic")
        gtk_widget_set_tooltip_text(narrowClearButton, "Clear Traffic. Pinned requests stay.")
        setAccessibleLabel(narrowClearButton, "Clear Traffic")
        gtk_actionable_set_action_name(cast(narrowClearButton), "win.clear")
        narrowRulesButton = RulesMenu.button()
        gtk_widget_set_visible(narrowRulesButton, cBool(model.isLive))
        narrowBar = gtk_action_bar_new()
        gtk_action_bar_pack_start(cast(narrowBar), narrowSearchButton)
        gtk_action_bar_pack_start(cast(narrowBar), narrowClearButton)
        gtk_action_bar_pack_end(cast(narrowBar), narrowRulesButton)
        gtk_action_bar_set_revealed(cast(narrowBar), 0)

        // The status line: a dot that shows while Reqly captures, and what it's doing.
        statusLine = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        gtk_widget_add_css_class(statusLine, "status-line")
        statusDot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(statusDot, "status-dot")
        gtk_widget_set_valign(statusDot, GTK_ALIGN_CENTER)
        statusLabel = gtk_label_new(nil)
        gtk_label_set_xalign(cast(statusLabel), 0)
        gtk_label_set_ellipsize(cast(statusLabel), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(statusLabel, 1)
        statusCount = gtk_label_new(nil)
        gtk_widget_add_css_class(statusCount, "numeric")
        gtk_box_append(cast(statusLine), statusDot)
        gtk_box_append(cast(statusLine), statusLabel)
        gtk_box_append(cast(statusLine), statusCount)

        // The list's pane: the header bar, the search bar and the filter bar, then the list, and
        // the status line under it.
        search = SearchBar(model: model)
        filters = FilterBar(model: model)
        list = RequestList(model: model)
        noMatches = NoMatchesPage()
        listContent = gtk_stack_new()
        gtk_stack_add_named(cast(listContent), list.widget, "list")
        gtk_stack_add_named(cast(listContent), noMatches.widget, "no-matches")
        listPane = adw_toolbar_view_new()
        adw_toolbar_view_add_top_bar(cast(listPane), listHeader)
        let banners = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(banners), pausedBanner.widget)
        gtk_box_append(cast(banners), deviceBanner.widget)
        adw_toolbar_view_add_top_bar(cast(listPane), banners)
        adw_toolbar_view_add_top_bar(cast(listPane), search.widget)
        adw_toolbar_view_add_top_bar(cast(listPane), filters.widget)
        adw_toolbar_view_set_content(cast(listPane), listContent)
        adw_toolbar_view_add_bottom_bar(cast(listPane), narrowBar)
        adw_toolbar_view_add_bottom_bar(cast(listPane), statusLine)
        search.captureTyping(in: listPane)

        details = DetailsPane(model: model)

        // The list and the details side by side, the list taking three fifths, or the details
        // over the list.
        let listPage = adw_navigation_page_new(listPane, "Requests")!
        adw_navigation_page_set_tag(listPage, "list")
        let detailsPage = adw_navigation_page_new(details.widget, "Details")!
        adw_navigation_page_set_tag(detailsPage, "details")
        inner = cast(adw_navigation_split_view_new())
        adw_navigation_split_view_set_sidebar(inner, listPage)
        adw_navigation_split_view_set_content(inner, detailsPage)
        adw_navigation_split_view_set_sidebar_width_unit(inner, ADW_LENGTH_UNIT_SP)
        adw_navigation_split_view_set_min_sidebar_width(inner, 560)
        // No limit: the details have what's left.
        adw_navigation_split_view_set_max_sidebar_width(inner, 10_000)
        adw_navigation_split_view_set_sidebar_width_fraction(inner, 0.6)

        // The sidebar beside them, a fifth of the window, from 200 to 280 sp.
        outer = cast(adw_overlay_split_view_new())
        adw_overlay_split_view_set_sidebar(outer, sidebarPane)
        adw_overlay_split_view_set_content(outer, cast(inner))
        adw_overlay_split_view_set_sidebar_width_unit(outer, ADW_LENGTH_UNIT_SP)
        adw_overlay_split_view_set_min_sidebar_width(outer, 200)
        adw_overlay_split_view_set_max_sidebar_width(outer, 280)
        adw_overlay_split_view_set_sidebar_width_fraction(outer, 0.2)

        toasts = adw_toast_overlay_new()
        content = gtk_stack_new()
        gtk_stack_add_named(cast(content), cast(outer), "session")
        adw_toast_overlay_set_child(cast(toasts), content)
        adw_application_window_set_content(cast(window), toasts)

        // The list needs 560 sp and the details 320, beside a sidebar of up to 280, and the list
        // 560 beside the narrowest sidebar, 200. Of the breakpoints that fit, the last one added
        // applies, so the second says all the first says.
        let detailsOver = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 1100sp"))!
        let sidebarFolds = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 760sp"))!
        // The main menu's buttons follow the sidebar: see showSidebarToggle().
        let collapsed: [(OpaquePointer, UnsafeMutableRawPointer?, String, Bool)] = [
            (detailsOver, raw(inner), "collapsed", true),
            (sidebarFolds, raw(inner), "collapsed", true), (sidebarFolds, raw(outer), "collapsed", true),
        ]
        for (breakpoint, object, property, value) in collapsed {
            Value.bool(value).with { adw_breakpoint_add_setter(breakpoint, cast(object), property, $0) }
        }
        // Up to 1400 sp, the details beside the list leave its Request column little room, so the
        // App column goes, as the sidebar and Overview name the app. Added first, it applies only
        // while the details are beside the list.
        let listNarrows = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 1400sp"))!
        let appColumn = list.viewColumn(.app)
        Value.bool(false).with { adw_breakpoint_add_setter(listNarrows, cast(appColumn), "visible", $0) }
        // Narrower than the sidebar's fold, each says all the one before says too. The list's
        // columns go, with GTK's padding in each, so it fits: what's left takes 388 sp up to 640,
        // 318 up to 520, and 254 up to 400, which is 318 pixels at 360 with the text at 1.25.
        // The header bar, its buttons moved, takes about 320 pixels, its window buttons with it.
        let columnsGo = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 640sp"))!
        let headerNarrows = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 520sp"))!
        let sizeGoes = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 400sp"))!
        let gone: [(OpaquePointer, [RequestList.Column])] = [
            (columnsGo, [.app, .time]), (headerNarrows, [.app, .time, .duration]),
            (sizeGoes, [.app, .time, .duration, .size]),
        ]
        let (innerView, outerView, bar) = (inner, outer, narrowBar)
        for (breakpoint, columns) in gone {
            Value.bool(true).with {
                adw_breakpoint_add_setter(breakpoint, cast(innerView), "collapsed", $0)
                adw_breakpoint_add_setter(breakpoint, cast(outerView), "collapsed", $0)
            }
            for column in columns {
                let viewColumn = list.viewColumn(column)
                Value.bool(false).with { adw_breakpoint_add_setter(breakpoint, cast(viewColumn), "visible", $0) }
            }
            guard breakpoint != columnsGo else { continue }
            Value.bool(true).with { adw_breakpoint_add_setter(breakpoint, cast(bar), "revealed", $0) }
            for hidden in [captureLabel, clearButton, searchButton, rulesButton] {
                Value.bool(false).with { adw_breakpoint_add_setter(breakpoint, cast(hidden), "visible", $0) }
            }
        }
        adw_application_window_add_breakpoint(cast(window), listNarrows)
        adw_application_window_add_breakpoint(cast(window), detailsOver)
        adw_application_window_add_breakpoint(cast(window), sidebarFolds)
        for breakpoint in [columnsGo, headerNarrows, sizeGoes] {
            adw_application_window_add_breakpoint(cast(window), breakpoint)
        }
        self.detailsOver = detailsOver
        self.sidebarFolds = sidebarFolds
        self.listNarrows = listNarrows
        self.columnsGo = columnsGo
        self.headerNarrows = headerNarrows
        self.sizeGoes = sizeGoes

        bind(raw(outer), "show-sidebar", to: raw(sidebarToggle), "active")
        bind(raw(search.widget), "search-mode-enabled", to: raw(searchButton), "active")
        bind(raw(search.widget), "search-mode-enabled", to: raw(narrowSearchButton), "active")
        connect(outer, "notify::show-sidebar") { [weak self] in self?.sidebarChanged() }
        // As a breakpoint folds a pane away or back, libadwaita may take the focus with it.
        connect(outer, "notify::collapsed") { [weak self] in
            self?.showSidebarToggle()
            self?.keepFocusThroughFold()
        }
        connect(inner, "notify::collapsed") { [weak self] in self?.keepFocusThroughFold() }
        for signal in ["apply", "unapply"] {
            connect(details.narrow, signal) { [weak self] in self?.tabsMoved() }
        }
        connect(inner, "notify::show-content") { [weak self] in self?.detailsChanged() }
        connect(raw(search.widget), "notify::search-mode-enabled") { [weak self] in self?.searchChanged() }
        connect(window, "notify::focus-widget") { [weak self] in
            self?.forgetOldFocus()
            self?.leaveDetailsThatDontShow()
            self?.list.focusMoved()
            self?.sidebar.focusMoved()
            self?.details.focusMoved()
        }
        list.onSelection = { [weak self] id in self?.showDetails(id) }
        list.onActivate = { [weak self] _ in self?.openDetails() }
        list.onRows = { [weak self] in self?.rowsChanged() }
        list.onFocusLost = { [weak self] in self?.focusWhatShowsSoon() }
        list.onComment = { [weak self] id in self?.editComment(id) }
        list.onCommand = { [weak self] command, summary in self?.run(command, on: summary) }
        details.onCommand = { [weak self] command, summary in self?.run(command, on: summary) }
        sidebar.onScope = { [weak self] _ in self?.scopeChosen() }
        sidebar.onCount = { [weak self] in self?.showTitle() }
        search.onSearch = { [weak self] in
            self?.showTitle()
            self?.sayWhatsFoundSoon()
        }
        filters.onFilter = { [weak self] in
            self?.showTitle()
            self?.sayWhatsFoundSoon()
        }
        noMatches.onClear = { [weak self] in self?.filters.clear() }
        connect(captureSwitch, "notify::active") { [weak self] in
            guard let self, !self.isShowingCapture else { return }
            self.captureSwitched(on: gtk_switch_get_active(cast(self.captureSwitch)) != 0)
        }
        // A file's window closes alone; the live one hides, once capturing has stopped. The app
        // quits once no window shows.
        connect(window, "close-request") { [weak self] (arguments: Arguments) in
            if let self {
                app.closeWindow(self)
            }
            arguments.returns(true)
        }
        observer = model.observe { [weak self] in
            if self?.isClosed == false {
                self?.update()
            }
        }
        listener = model.listen { [weak self] event in
            guard self?.isClosed == false else { return }
            switch event {
            case .storageProblem(let problem?): self?.toast(problem)
            case .sidebar(let sidebar): self?.counted(pinned: sidebar.pinned)
            case .counts(_, let pinned, _): self?.counted(pinned: pinned)
            default: break
            }
        }
        addActions()
        focusCaptureSwitchOnClick()
        countInputs()
        showSidebarToggle()
        update()
        showRulesButton()
        // The events that came while the window was made, or before, as a file's session hands
        // over its rows as it opens.
        model.startEvents()
    }

    /// Shows the window, or brings it to the front. The live window's first showing starts
    /// capturing, when you asked for that as Reqly opens, and opens the connections.
    func present() {
        gtk_window_present(cast(window))
        hasShown = true
        if model.isLive {
            appModel.liveWindowShown()
        }
    }

    isolated deinit {
        g_object_unref(raw(window))
        // The main menu's buttons hold their own references.
        g_object_unref(raw(menu))
    }

    /// Reqly closes the window, and destroys it next: from now on, what the window left waiting on
    /// the main loop does nothing, and its panes hear their session no more, nor do what their
    /// tasks waited for. GTK 4 doesn't free a destroyed window while this object holds it, and
    /// says "destroy" only as it frees it, once this object goes, so nothing else tells them. Its
    /// panes' widgets go with this object, though a pane's task may keep the pane a moment longer.
    func closed() {
        guard !isClosed else { return }
        isClosed = true
        if let observer {
            model.stopObserving(observer)
        }
        if let listener {
            model.stopListening(listener)
        }
        if let findingTimer {
            g_source_remove(findingTimer)
            self.findingTimer = nil
        }
        list.windowClosed()
        sidebar.windowClosed()
        filters.windowClosed()
        details.windowClosed()
    }

    /// Whether the window shows: the live window hides once it's closed.
    var isShowing: Bool { gtk_widget_get_visible(window) != 0 }

    /// The main menu, in three sections: New Request, Open…, Save Session… and Export as HAR…,
    /// with Show Live Traffic in a file's window; Devices, Set Up HTTPS…, Open Terminal and Copy
    /// Terminal Setup; Settings, Keyboard Shortcuts, Welcome to Reqly, About Reqly and Quit.
    private static func mainMenu(isLive: Bool) -> OpaquePointer {
        let menu = g_menu_new()!
        let files = g_menu_new()!
        g_menu_append(files, "New Request", "app.new-request")
        g_menu_append(files, "Open…", "app.open")
        g_menu_append(files, "Save Session…", "win.save-session")
        g_menu_append(files, "Export as HAR…", "win.export-har")
        if !isLive {
            g_menu_append(files, "Show Live Traffic", "app.show-live-traffic")
        }
        let tools = g_menu_new()!
        g_menu_append(tools, "Devices", "app.devices")
        g_menu_append(tools, "Set Up HTTPS…", "app.set-up-https")
        g_menu_append(tools, "Open Terminal", "app.open-terminal")
        g_menu_append(tools, "Copy Terminal Setup", "app.copy-terminal-setup")
        let general = g_menu_new()!
        g_menu_append(general, "Settings", "app.settings")
        g_menu_append(general, "Keyboard Shortcuts", "app.shortcuts")
        g_menu_append(general, "Welcome to Reqly", "app.welcome")
        g_menu_append(general, "About Reqly", "app.about")
        g_menu_append(general, "Quit", "app.quit")
        for section in [files, tools, general] {
            g_menu_append_section(menu, nil, cast(section))
            g_object_unref(raw(section))
        }
        return menu
    }

    /// Shows a short message at the bottom of the window, which goes by itself, and screen readers
    /// hear it: see ``DetailsBlocks/toast(_:from:button:isUrgent:onButton:)``.
    func toast(
        _ text: String, button: String? = nil, isUrgent: Bool = false, onButton: (@MainActor () -> Void)? = nil
    ) {
        guard !isClosed else { return }
        DetailsBlocks.toast(text, from: toasts, button: button, isUrgent: isUrgent, onButton: onButton)
    }

    /// AdwWindowTitle keeps room for 5 characters of its title and subtitle at the least, which a
    /// narrow window's header bar doesn't have with the text at 1.25: its labels ellipsize down to
    /// "…" instead.
    private static func letTitleShrink(_ title: Widget) {
        var child = gtk_widget_get_first_child(title)
        while let widget = child {
            if g_type_check_instance_is_a(cast(widget), gtk_label_get_type()) != 0 {
                gtk_label_set_width_chars(cast(widget), -1)
            }
            letTitleShrink(widget)
            child = gtk_widget_get_next_sibling(widget)
        }
    }

    /// A button that opens the main menu, `menu`.
    private static func mainMenuButton(_ menu: OpaquePointer) -> Widget {
        let button = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(cast(button), "open-menu-symbolic")
        gtk_widget_set_tooltip_text(button, "Main Menu")
        setAccessibleLabel(button, "Main Menu")
        gtk_menu_button_set_menu_model(cast(button), cast(menu))
        return button
    }

    /// Shows the switch, the status line and the list's title as they are now, and in a file's
    /// window, whether the file is still opening, or couldn't be.
    private func update() {
        let appModel = appModel
        let isOn = appModel.capture == .starting || appModel.capture == .capturing
        isShowingCapture = true
        gtk_switch_set_active(cast(captureSwitch), cBool(isOn))
        isShowingCapture = false
        // It waits for a start or a stop, and for the session.
        let canSwitch = model.session != nil && (appModel.capture == .stopped || appModel.capture == .capturing)
        gtk_widget_set_sensitive(captureSwitch, cBool(model.isLive && canSwitch))
        showOpening()
        // Once the session has opened, and capturing has started when it starts as Reqly opens,
        // which turns the switch off meanwhile.
        let isOpen = model.isLive ? model.session != nil && !appModel.isOpening : model.session != nil
        if isFirstFocusDue, isOpen {
            isFirstFocusDue = false
            giveFirstFocus()
        }
        let line =
            model.fileName.map { StatusLine(status: $0) }
            ?? StatusLine(status: appModel.statusText, notes: appModel.statusNotes)
        if line != statusWords {
            statusWords = line
            gtk_label_set_text(cast(statusLabel), line.text)
            // The line may be cut short, advice and all, in a narrow window.
            gtk_widget_set_tooltip_text(statusLabel, line.tooltip)
            setAccessibleDescription(statusLabel, line.description)
        }
        if model.isCapturing {
            gtk_widget_add_css_class(statusDot, "capturing")
        } else {
            gtk_widget_remove_css_class(statusDot, "capturing")
        }
        showTitle()
    }

    /// A file's window, while its file opens: "Opening “name”…", with a spinner; once it couldn't,
    /// why, in the core's words, which screen readers hear as it shows; then the panes. Each page
    /// has a header bar of its own, with the file's name, the main menu, which F10 opens, and the
    /// window's buttons.
    private func showOpening() {
        guard let name = model.fileName else { return }
        let shown = gtk_stack_get_visible_child(cast(content))
        if model.isOpening {
            if opening == nil {
                let page = namedStatusPage(name)
                adw_status_page_set_title(cast(page), "Opening “\(name)”…")
                adw_status_page_set_child(cast(page), HTTPSWidgets.spinner())
                opening = withHeaderBar(page, name: name)
                gtk_stack_add_named(cast(content), opening, "opening")
            }
            gtk_stack_set_visible_child_name(cast(content), "opening")
        } else if let problem = model.problem {
            let title = "Reqly Couldn't Open “\(name)”"
            if failed == nil {
                let page = namedStatusPage(name)
                adw_status_page_set_icon_name(cast(page), "dialog-warning-symbolic")
                adw_status_page_set_title(cast(page), title)
                // Its description is markup, which a path in the problem may look like.
                adw_status_page_set_description(cast(page), takeString(g_markup_escape_text(problem, -1)))
                failed = withHeaderBar(page, name: name)
                gtk_stack_add_named(cast(content), failed, "failed")
            }
            gtk_stack_set_visible_child_name(cast(content), "failed")
            if shown != failed {
                announce(window, "\(title). \(problem)")
            }
        } else {
            gtk_stack_set_visible_child_name(cast(content), "session")
        }
        if gtk_stack_get_visible_child(cast(content)) != shown {
            showSidebarToggle()
        }
    }

    /// `page`, for a file's window while its file opens or once it couldn't, under a header bar of
    /// its own, with the file's name, the main menu and the window's buttons.
    private func withHeaderBar(_ page: Widget, name: String) -> Widget {
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(cast(header), adw_window_title_new(name, nil))
        let menuButton = Self.mainMenuButton(menu)
        adw_header_bar_pack_end(cast(header), menuButton)
        pageMenuButtons.append(menuButton)
        let view = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(view), header)
        adw_toolbar_view_set_content(cast(view), page)
        return view
    }

    /// Whether the window shows what its file couldn't be opened for.
    var showsProblem: Bool {
        failed != nil && gtk_stack_get_visible_child(cast(content)) == failed
    }

    /// The main menu's button that shows now, in a file's window while its file opens or once it
    /// couldn't, in place of the panes'.
    var pageMenuButton: Widget? {
        pageMenuButtons.first { gtk_widget_get_mapped($0) != 0 }
    }

    /// The list's title, by the scope you chose, and its count, and the session's at the status
    /// line's end; whether there's anything to clear; and the no-matches page in the list's place
    /// while there's traffic, but none of it shows.
    private func showTitle() {
        guard !isClosed else { return }
        // The list goes by the session's count once a burst's rows are in, and the sidebar hears
        // it a moment after the rows, so the window goes by the larger, and likewise for the
        // scope's.
        let total = max(list.total, sidebar.total)
        let title = ListTitle(
            scope: sidebar.scope.title, shown: list.count, inScope: max(sidebar.count ?? total, list.count),
            total: total, isCapturing: model.isCapturing, isSaved: model.isSaved)
        adw_window_title_set_title(cast(listTitle), title.title)
        adw_window_title_set_subtitle(cast(listTitle), title.subtitle)
        gtk_label_set_text(cast(statusCount), ListTitle.sessionCount(shown: list.count, total: total))
        let canClear = model.session != nil && total > pinned
        // Clear's button, turning off with the keyboard's focus, as it does once it's cleared,
        // would leave the focus on nothing.
        if !canClear, let focus = gtk_root_get_focus(cast(window)),
            focus == clearButton || focus == narrowClearButton
        {
            focusWhatShowsSoon()
        }
        g_simple_action_set_enabled(clearAction, cBool(canClear))
        // Saving and exporting need something to save, as on the Mac.
        for action in [saveAction, exportAction] {
            g_simple_action_set_enabled(action, cBool(model.session != nil && total > 0))
        }
        let nothingMatches = total > 0 && list.count == 0
        if nothingMatches {
            let words = NoMatches(query: search.query, filtersAreSet: filters.isActive)
            // Clear Filters goes from the page as you choose it, when the search still matches
            // nothing: the search's field has the focus instead, rather than nothing.
            if !words.clearsFilters, let focus = gtk_root_get_focus(cast(window)), focus == noMatches.clearButton {
                if search.isOpen {
                    gtk_widget_grab_focus(search.entry)
                } else {
                    focusWhatShowsSoon()
                }
            }
            noMatches.show(words)
        }
        gtk_stack_set_visible_child(cast(listContent), nothingMatches ? noMatches.widget : list.widget)
    }

    private func counted(pinned: Int) {
        self.pinned = pinned
        showTitle()
    }

    /// The list's rows changed: its title says so, and the first rows of a session that opened
    /// with requests in it, as a saved one does, take the keyboard's first focus, unless it has
    /// moved since.
    private func rowsChanged() {
        showTitle()
        found.rowsChanged(count: list.count, at: monotonicMicroseconds())
        lookForWhatsFound()
        guard let first = firstFocus, list.count > 0 else { return }
        firstFocus = nil
        if gtk_root_get_focus(cast(window)) == first, !model.isCapturing {
            list.focusSelection()
        }
    }

    /// The keyboard's first focus, once the session has opened, and capturing has started when it
    /// starts as Reqly opens: the list, or while the session has no requests, the capture switch,
    /// from which typing still starts a search. Not the search's field: its bar is hidden until
    /// it's asked for, and an empty list asks you to turn on capture.
    private func giveFirstFocus() {
        idle { [weak self] in
            guard let self, !isClosed, visibleDialog(over: window) == nil else { return false }
            // As a fold's looks would take it back.
            focusTurn += 1
            focusContent()
            firstFocus = list.count == 0 ? gtk_root_get_focus(cast(window)) : nil
            return false
        }
    }

    // MARK: - The panes

    /// Whether the details show over the list.
    var detailsAreOver: Bool {
        adw_navigation_split_view_get_collapsed(inner) != 0 && adw_navigation_split_view_get_show_content(inner) != 0
    }

    /// Whether the sidebar shows over the list.
    var sidebarIsOver: Bool {
        adw_overlay_split_view_get_collapsed(outer) != 0 && adw_overlay_split_view_get_show_sidebar(outer) != 0
    }

    /// Shows the details over the list, when they don't fit beside it, as a row's Enter or click
    /// asks, and screen readers hear `words`, "Details" or the page Ctrl+1 to Ctrl+5 chose. Choosing
    /// a row with the arrow keys doesn't. The tab of the page that shows has the keyboard's focus,
    /// rather than whatever libadwaita gives it back to, which varies, and may not show any more,
    /// such as another request's comment field; Add Comment… gives the comment's field the focus
    /// itself. Whether the details went over the list.
    @discardableResult
    func openDetails(saying words: String = "Details", focusesTab: Bool = true) -> Bool {
        guard adw_navigation_split_view_get_collapsed(inner) != 0,
            adw_navigation_split_view_get_show_content(inner) == 0
        else { return false }
        adw_navigation_split_view_set_show_content(inner, 1)
        announce(window, words)
        idle { [weak self] in
            guard let self, !isClosed, detailsAreOver else { return false }
            if focusesTab, details.focusTab() {
                return false
            }
            if let focus = gtk_root_get_focus(cast(window)), gtk_widget_is_visible(focus) == 0 {
                gtk_root_set_focus(cast(window), nil)
                focusContent()
            }
            return false
        }
        return true
    }

    /// Shows `id`'s request in the details, or none, and Ctrl+1 to Ctrl+5 choose its pages only
    /// while there's one.
    private func showDetails(_ id: ExchangeID?) {
        details.show(id)
        for action in [pageAction, copyURLAction, copyCurlAction] {
            g_simple_action_set_enabled(action, cBool(details.shown != nil))
        }
    }

    /// The Rules button's icon, tooltip and name, which say which rule kinds are on, as the live
    /// session's rules are.
    func showRulesButton() {
        let kindsOn = appModel.rules?.set.kindsOn ?? []
        let name = RulesMenu.name(kindsOn: kindsOn)
        for button in [rulesButton, narrowRulesButton] {
            gtk_menu_button_set_icon_name(cast(button), kindsOn.isEmpty ? RulesMenu.icon : RulesMenu.onIcon)
            gtk_widget_set_tooltip_text(button, name)
            setAccessibleLabel(button, name)
        }
    }

    /// Add or Edit Comment…, from a row's menu: its request, selected, on the details' Overview,
    /// over the list when the details don't fit beside it, with the comment's field showing and
    /// the keyboard's focus in it.
    private func editComment(_ id: ExchangeID) {
        list.select(id: id)
        // A request a filter hides is selected with no row, and the details show it all the same.
        showDetails(id)
        openDetails(focusesTab: false)
        details.editComment()
    }

    /// The details went over the list, or back. Back, libadwaita gives the keyboard's focus back to
    /// what had it in the list's pane, such as the row that opened them, and when it doesn't, the
    /// selected row has it. The list's pane may not show yet, so the search field, which Ctrl+F
    /// gave it to, keeps it.
    private func detailsChanged() {
        guard adw_navigation_split_view_get_show_content(inner) == 0 else { return }
        idle { [weak self] in
            guard let self, !isClosed else { return false }
            let focus = gtk_root_get_focus(cast(window))
            if focus.map({ isInside($0, details.widget) }) ?? true {
                focusContent()
            }
            return false
        }
    }

    /// The sidebar was shown or hidden. Shown over the list, or with the toggle, which goes as it
    /// shows, the sidebar has the keyboard's focus; hidden, the pane that shows has it. As a
    /// breakpoint changes the panes, what has the focus may not show for a moment, so only nothing
    /// or the toggle having it counts as the focus gone. A breakpoint folding the sidebar away or
    /// back keeps the focus where it was: see keepFocusThroughFold().
    private func sidebarChanged() {
        showSidebarToggle()
        let focus = gtk_root_get_focus(cast(window))
        let isInSidebar = focus.map { isInside($0, sidebarPane) } ?? false
        let isLost = focus.map { $0 == sidebarToggle } ?? true
        if adw_overlay_split_view_get_show_sidebar(outer) != 0 {
            if !isInSidebar, sidebarIsOver || isLost, !sidebar.focus() {
                gtk_widget_child_focus(sidebarPane, GTK_DIR_TAB_FORWARD)
            }
            if sidebarIsOver {
                focusTheChosenScope()
                idle { [weak self] in
                    self?.focusTheChosenScope()
                    return false
                }
            }
        } else if isInSidebar || isLost {
            focusContent()
        }
    }

    /// Forgets where the keyboard's focus was in each pane it has left. GTK keeps that while the
    /// widget that had it stays, and when that widget goes, as a row does when the list is
    /// cleared, Tab into the pane starts after where it was, so the list's header bar couldn't be
    /// reached from the sidebar.
    private func forgetOldFocus() {
        let focus = gtk_root_get_focus(cast(window))
        for pane in [sidebarPane, listPane, details.widget] where !(focus.map { isInside($0, pane) } ?? false) {
            var widget: Widget? = pane
            while let current = widget, let child = gtk_widget_get_focus_child(current) {
                gtk_widget_set_focus_child(current, nil)
                widget = child
            }
        }
    }

    /// libadwaita 1.7 and later give a sidebar that shows over the list the keyboard's focus
    /// themselves, as it shows or just after, on the main menu's button or the row the sidebar's
    /// list had before: the chosen scope's row has it instead, as with libadwaita 1.5.
    private func focusTheChosenScope() {
        if !isClosed, sidebarIsOver {
            sidebar.focus()
        }
    }

    /// libadwaita 1.7 and later can give the keyboard's focus to the details while they don't
    /// show, folded away under the list, as the sidebar goes from over it: once that's done, the
    /// pane that shows has it. A push of the details, which gives them the focus, shows them by
    /// then.
    private func leaveDetailsThatDontShow() {
        guard isInHiddenDetails else { return }
        idle { [weak self] in
            if let self, !isClosed, isInHiddenDetails {
                focusContent()
            }
            return false
        }
    }

    /// Whether the keyboard's focus is in the details while they're folded away under the list.
    private var isInHiddenDetails: Bool {
        guard let focus = gtk_root_get_focus(cast(window)), isInside(focus, details.widget) else { return false }
        let isFolded = adw_navigation_split_view_get_collapsed(inner) != 0
        return isFolded && adw_navigation_split_view_get_show_content(inner) == 0
    }

    /// The sidebar's toggle shows while the sidebar is folded away, or hidden with F9, and so
    /// does the list's main menu. F10 opens the sidebar's while the sidebar shows, and the list's
    /// while it doesn't, as the sidebar's can't be reached then.
    private func showSidebarToggle() {
        let isDocked = adw_overlay_split_view_get_collapsed(outer) == 0
        let shows = adw_overlay_split_view_get_show_sidebar(outer) != 0
        gtk_widget_set_visible(sidebarToggle, cBool(!(isDocked && shows)))
        gtk_widget_set_visible(listMenuButton, cBool(!(isDocked && shows)))
        gtk_widget_set_visible(menuButton, cBool(shows))
        // A file's window, while its file opens or once it couldn't, shows a page in the panes'
        // place, with the main menu's button of its own.
        let page = gtk_stack_get_visible_child(cast(content)).flatMap { $0 == (cast(outer) as Widget) ? nil : $0 }
        gtk_menu_button_set_primary(cast(menuButton), cBool(page == nil && shows))
        gtk_menu_button_set_primary(cast(listMenuButton), cBool(page == nil && !shows))
        for button in pageMenuButtons {
            gtk_menu_button_set_primary(cast(button), cBool(page.map { isInside(button, $0) } ?? false))
        }
    }

    /// The search bar opened or closed. Closed, the list has the keyboard's focus, when the bar
    /// had it, once the session has the search cleared and the list has its rows again: given it at
    /// once, a row would be heard where it was among the requests found, then where it is, as on
    /// GTK's next frame.
    private func searchChanged() {
        guard !search.isOpen else { return }
        let isLost = { [weak self] () -> Bool in
            guard let self else { return false }
            let focus = gtk_root_get_focus(cast(window))
            return focus.map { self.isInside($0, self.search.widget) || gtk_widget_get_mapped($0) == 0 } ?? true
        }
        guard isLost() else { return }
        // Once the bar has cleared its field, which starts the search's end.
        idle { [weak self] in
            self?.search.afterSearching { [weak self] in
                self?.whenListSettles(tries: 50) {
                    if isLost() {
                        self?.focusContent()
                    }
                }
            }
            return false
        }
    }

    /// Runs `body` once the list has every change in, looking every 20 ms, `tries` times, and then
    /// runs it anyway.
    private func whenListSettles(tries: Int, _ body: @escaping @MainActor () -> Void) {
        guard !isClosed else { return }
        if list.isSettled || tries == 0 {
            body()
            return
        }
        timeout(20) { [weak self] in
            self?.whenListSettles(tries: tries - 1, body)
            return false
        }
    }

    /// You chose a scope in the sidebar: it shows in the list's header bar, and the sidebar goes,
    /// when it showed over the list.
    private func scopeChosen() {
        showTitle()
        if sidebarIsOver {
            hideSidebar()
        }
    }

    /// Puts the sidebar away. Over the list, with the keyboard's focus in it, the pane under it has
    /// the focus first: libadwaita 1.7 and later would give it to a widget that doesn't show, such
    /// as the details' back button.
    func hideSidebar() {
        if sidebarIsOver, gtk_root_get_focus(cast(window)).map({ isInside($0, sidebarPane) }) ?? false {
            focusContent()
        }
        adw_overlay_split_view_set_show_sidebar(outer, 0)
    }

    /// Once GTK and libadwaita have done with a change that took the keyboard's focus with it, the
    /// pane that shows has it, unless it has gone somewhere that shows meanwhile: as Clear takes the
    /// list's row that had it, a button that had it goes or turns off, or a breakpoint folds away
    /// the pane that had it, or hides a tab that had it.
    func focusWhatShowsSoon() {
        focusWhatShows(after: 0, tries: 25, keeping: nil, in: nil)
    }

    /// The details' tabs moved, under the pages as the details narrowed, or back into their header
    /// bar. A tab that had the keyboard's focus goes, and GTK gives the focus to the window's first
    /// widget, such as the sidebar's: the chosen page's tab, where the tabs are now, has it instead,
    /// once it shows, unless you press a key or click meanwhile. Any other focus that's lost goes to
    /// the pane that shows.
    private func tabsMoved() {
        guard let focus = gtk_root_get_focus(cast(window)),
            isInside(focus, details.switcher) || isInside(focus, details.switcherBar)
        else {
            focusWhatShowsSoon()
            return
        }
        focusTab(tries: 25, since: inputs)
    }

    /// Gives the details' chosen tab the keyboard's focus once it shows, looking every 20 ms,
    /// `tries` times more, while you've pressed no key and clicked nowhere since `before`, and no
    /// dialog shows; or if it never shows, the pane that shows has the focus, when it's lost.
    private func focusTab(tries: Int, since before: Int) {
        timeout(20) { [weak self] in
            guard let self, !isClosed, inputs == before, visibleDialog(over: window) == nil, !details.focusTab() else {
                return false
            }
            if tries > 0 {
                focusTab(tries: tries - 1, since: before)
            } else {
                focusWhatShowsSoon()
            }
            return false
        }
    }

    /// A breakpoint folded the sidebar or the details away, or back. libadwaita puts the panes in
    /// place again, which takes the keyboard's focus from what had it: GTK then gives it to the
    /// sidebar, and libadwaita to the sidebar's toggle as the sidebar goes, and from libadwaita 1.7
    /// on to the capture switch beside it. What had it has it again once the panes show, and once
    /// libadwaita's done, if it still shows, or else the pane that shows, such as the list for a
    /// button in the details as they fold away. The later look leaves the focus where you moved it
    /// meanwhile, with a key or a click, and only a newer fold's looks, or the first focus, count.
    private func keepFocusThroughFold() {
        guard let focus = gtk_root_get_focus(cast(window)) else {
            focusWhatShowsSoon()
            return
        }
        focusTurn += 1
        let pane = [sidebarPane, listPane, details.widget].first { isInside(focus, $0) }
        focusWhatShows(after: 0, tries: 25, keeping: focus, in: pane, fold: (focusTurn, nil))
        lookLater(after: 400, keeping: focus, in: pane, since: inputs)
    }

    /// A fold's later look, now, as when a fold kept `kept`'s focus in `pane` once you'd pressed
    /// keys and clicked `before` times: for the self-check, which can't press a key in the frame
    /// before the look comes.
    func lookAfterFold(keeping kept: Widget, in pane: Widget, since before: Int) {
        focusTurn += 1
        lookLater(after: nil, keeping: kept, in: pane, since: before)
    }

    /// The latest fold's later look, `milliseconds` on, or now: the same for the app and the
    /// self-check. With one try, a widget you gave the focus that doesn't show yet has 50 ms more.
    private func lookLater(after milliseconds: UInt32?, keeping kept: Widget, in pane: Widget?, since before: Int) {
        let tries = 1
        let fold: Fold = (focusTurn, before)
        if let milliseconds {
            focusWhatShows(after: milliseconds, tries: tries, keeping: kept, in: pane, fold: fold)
        } else {
            focusWhatShows(tries: tries, keeping: kept, in: pane, fold: fold)
        }
    }

    /// Counts your key presses, but for Shift, Ctrl and the like on their own, and your clicks,
    /// before the window's widgets have them. GTK runs the window's newest controller first, so
    /// this one, added last, sees the keys its shortcuts and addActions()' own keys take too.
    private func countInputs() {
        let events = gtk_event_controller_legacy_new()!
        gtk_event_controller_set_propagation_phase(events, GTK_PHASE_CAPTURE)
        connect(events, "event") { [weak self] (arguments: Arguments) in
            guard let self, let event: OpaquePointer = cast(arguments.pointer(1)) else { return }
            let type = gdk_event_get_event_type(event)
            if type == GDK_BUTTON_PRESS || type == GDK_TOUCH_BEGIN
                || (type == GDK_KEY_PRESS && gdk_key_event_is_modifier(event) == 0)
            {
                inputs += 1
            }
        }
        gtk_widget_add_controller(window, events)
    }

    /// focusWhatShows(tries:keeping:in:fold:) once nothing more urgent waits, for 0
    /// `milliseconds`, or after them, holding `kept` until then.
    private func focusWhatShows(
        after milliseconds: UInt32, tries: Int, keeping kept: Widget?, in pane: Widget?, fold: Fold? = nil
    ) {
        if let kept {
            g_object_ref(raw(kept))
        }
        let look: @MainActor () -> Bool = { [weak self] in
            self?.focusWhatShows(tries: tries, keeping: kept, in: pane, fold: fold)
            if let kept {
                g_object_unref(raw(kept))
            }
            return false
        }
        if milliseconds == 0 {
            idle(look)
        } else {
            timeout(milliseconds, look)
        }
    }

    /// A fold's turn, which a newer fold or the first focus takes, and for its later look, how many
    /// of your key presses and clicks there had been.
    private typealias Fold = (turn: Int, inputs: Int?)

    /// When the keyboard's focus has been lost, or has gone out of `pane`, the one `kept` was in,
    /// as GTK gives it to the sidebar, or to the sidebar's toggle, as libadwaita does, `kept`, which
    /// had it, has it again while it shows, or else the pane that shows. From libadwaita 1.7, the
    /// focus goes on from the toggle to the capture switch beside it, which then counts as the
    /// toggle for what was in the list's pane. Otherwise a widget that took the focus in the same
    /// pane meanwhile, such as a hex line made again, or the switch as the first focus, keeps it,
    /// and so does a menu that's open. For a `fold`, only its turn's looks count, and once you've
    /// pressed a key or clicked since `inputs`, only a focus that's lost: a widget you gave it that
    /// doesn't show yet, as the search's field as Ctrl+F opens its bar, has 50 ms more, `tries`
    /// times. As a breakpoint folds a pane away, libadwaita 1.5 maps the panes again a moment
    /// after, so until either the list's pane or the details show, it looks again every 20 ms,
    /// `tries` times, and then gives up.
    private func focusWhatShows(tries: Int, keeping kept: Widget?, in pane: Widget?, fold: Fold?) {
        guard !isClosed, visibleDialog(over: window) == nil, fold.map({ $0.turn == focusTurn }) ?? true else { return }
        if gtk_widget_get_mapped(listPane) == 0, gtk_widget_get_mapped(details.widget) == 0 {
            if tries > 0 {
                focusWhatShows(after: 20, tries: tries - 1, keeping: kept, in: pane, fold: fold)
            }
            return
        }
        let focus = gtk_root_get_focus(cast(window))
        // A menu that's open keeps it, and gives it back as it closes.
        if let focus, gtk_widget_get_ancestor(focus, gtk_popover_get_type()) != nil {
            return
        }
        let isYours = fold?.inputs.map { $0 != inputs } ?? false
        if isYours, tries > 0, let focus, gtk_widget_get_mapped(focus) == 0, gtk_widget_is_visible(focus) != 0,
            gtk_widget_is_sensitive(focus) != 0
        {
            focusWhatShows(after: 50, tries: tries - 1, keeping: kept, in: pane, fold: fold)
            return
        }
        let isLost =
            focus.map {
                gtk_widget_get_mapped($0) == 0 || gtk_widget_is_visible($0) == 0 || gtk_widget_is_sensitive($0) == 0
                    || (isInside($0, list.view) && !list.rowHasFocus)
            } ?? true
        let hasLeftPane = !isYours && pane.map { pane in focus.map { !isInside($0, pane) } ?? true } ?? false
        let isOnToggle =
            !isYours
            && kept.map { kept in
                kept != focus && (focus == sidebarToggle || (focus == captureSwitch && isInside(kept, listPane)))
            } ?? false
        guard isLost || isInHiddenDetails || hasLeftPane || isOnToggle else { return }
        if let kept, focus != kept, gtk_widget_get_root(kept) == gtk_widget_get_root(window),
            gtk_widget_get_mapped(kept) != 0, gtk_widget_is_visible(kept) != 0, gtk_widget_is_sensitive(kept) != 0,
            !isInHiddenDetails(kept), gtk_widget_grab_focus(kept) != 0
        {
            return
        }
        gtk_root_set_focus(cast(window), nil)
        focusContent()
    }

    /// Whether `widget` is in the details while they're folded away under the list.
    private func isInHiddenDetails(_ widget: Widget) -> Bool {
        isInside(widget, details.widget) && adw_navigation_split_view_get_collapsed(inner) != 0
            && adw_navigation_split_view_get_show_content(inner) == 0
    }

    /// Once a search or the filters have settled, and the list's count with them, screen readers
    /// hear what they found while you're in the search's field or the filter bar: how many
    /// requests show, as the list's subtitle says, or that none do; and again if the count changes
    /// soon after, as when the store's matches come late. See FoundWords.
    private func sayWhatsFoundSoon() {
        found.changed(count: list.count, at: monotonicMicroseconds())
        foundSaid = nil
        lookForWhatsFound()
    }

    /// Looks again once what's found is due to be said, unless a look is on its way.
    private func lookForWhatsFound() {
        guard findingTimer == nil, let due = found.due else { return }
        let wait = max(0, due - monotonicMicroseconds()) / 1000
        findingTimer = timeout(UInt32(wait)) { [weak self] in
            guard let self, !isClosed else { return false }
            findingTimer = nil
            if found.isDue(at: monotonicMicroseconds(), settled: list.isSettled) {
                sayWhatsFound()
            }
            lookForWhatsFound()
            return false
        }
    }

    private func sayWhatsFound() {
        guard let focus = gtk_root_get_focus(cast(window)),
            isInside(focus, search.widget) || isInside(focus, filters.widget)
        else { return }
        let nothingMatches = gtk_stack_get_visible_child(cast(listContent)) == noMatches.widget
        let words = nothingMatches ? noMatches.words.title : string(adw_window_title_get_subtitle(cast(listTitle)))
        if let words, !words.isEmpty, words != foundSaid {
            foundSaid = words
            announce(window, words)
        }
    }

    /// Gives the keyboard's focus to the pane that shows: the details over the list, their chosen
    /// page's tab, or the list's selected row, or while the list is empty, the capture switch.
    func focusContent() {
        guard !isClosed else { return }
        if detailsAreOver {
            if details.focusTab() || gtk_widget_child_focus(details.widget, GTK_DIR_TAB_FORWARD) != 0 {
                return
            }
        } else if list.focusSelection() {
            return
        }
        if gtk_widget_get_sensitive(captureSwitch) == 0 || gtk_widget_grab_focus(captureSwitch) == 0 {
            gtk_widget_child_focus(listPane, GTK_DIR_TAB_FORWARD)
        }
    }

    /// Whether `widget` is `ancestor` or inside it.
    func isInside(_ widget: Widget, _ ancestor: Widget) -> Bool {
        widget == ancestor || gtk_widget_is_ancestor(widget, ancestor) != 0
    }

    // MARK: - Its size

    /// The monitor's work area, without the desktop's panels, where X11 says what it is, and the
    /// whole monitor elsewhere, as on Wayland: the first monitor's, since the window has none yet.
    private static func workArea() -> (width: Int, height: Int) {
        guard let display = gdk_display_get_default(), let monitors = gdk_display_get_monitors(display),
            let monitor = g_list_model_get_item(monitors, 0)
        else { return (1200, 760) }
        defer { g_object_unref(monitor) }
        var area = GdkRectangle()
        gdk_monitor_get_geometry(cast(monitor), &area)
        // GDK's X11 backend's own, which isn't in the headers the app is built against.
        typealias WorkArea = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GdkRectangle>?) -> Void
        if typeName(raw(display)) == "GdkX11Display",
            let workArea = Newer.lookup("gdk_x11_monitor_get_workarea", as: WorkArea.self)
        {
            workArea(monitor, &area)
        }
        return (Int(area.width), Int(area.height))
    }

    /// The window's size as it opens: 1200 by 760, but never more than `area`, the monitor's work
    /// area, nor more than three quarters of it, in the same shape, as GNOME's window manager
    /// maximizes a window that opens on most of it. At least GNOME's smallest, 360 by 294.
    nonisolated static func openingSize(within area: (width: Int, height: Int)) -> (width: Int, height: Int) {
        var width = min(1200, area.width)
        var height = min(760, area.height)
        let most = Double(area.width) * Double(area.height) * 3 / 4
        if Double(width * height) > most {
            let scale = (most / Double(width * height)).squareRoot()
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }
        return (max(360, width), max(294, height))
    }

    // MARK: - Dialogs

    /// Settings, over the window.
    func showSettings() {
        let settings = settings ?? makeSettings()
        guard !settings.isShowing else { return }
        settings.present(over: window)
    }

    /// Set Up HTTPS…, over the window.
    func showSetUp() {
        let setUp = setUp ?? makeSetUp()
        guard !setUp.isShowing else { return }
        setUp.present(over: window)
    }

    private func makeSettings() -> SettingsDialog {
        let settings = SettingsDialog(model: appModel)
        self.settings = settings
        connect(settings.dialog, "closed") { [weak self] in self?.keepFocusAfterDialog() }
        return settings
    }

    private func makeSetUp() -> SetUpDialog {
        let setUp = SetUpDialog(https: model.https)
        self.setUp = setUp
        connect(setUp.dialog, "closed") { [weak self] in self?.keepFocusAfterDialog() }
        return setUp
    }

    /// Once a dialog has closed and given the focus back, the window has a widget with it that
    /// shows: in the dialog still open under it, such as Settings under Set Up HTTPS…, or else
    /// the list or the switch. A widget that's gone, or one in the closed menu, would leave the
    /// window's shortcuts and Tab doing nothing, and Settings' Escape.
    func keepFocusAfterDialog() {
        idle { [weak self] in
            guard let self, !isClosed else { return false }
            if let dialog = visibleDialog(over: window) {
                if !hasFocus(inside: dialog) {
                    // From nothing: the dialog would take a hidden widget libadwaita gave the focus
                    // back to as its own, and give it the focus again.
                    gtk_root_set_focus(cast(window), nil)
                    gtk_widget_grab_focus(dialog)
                }
                return false
            }
            let focus = gtk_root_get_focus(cast(window))
            // The list takes it only while it shows: GTK gives an empty list's hidden rows the focus.
            if focus.map({ gtk_widget_get_mapped($0) == 0 }) ?? true, !list.focusSelection() {
                gtk_widget_grab_focus(captureSwitch)
            }
            return false
        }
    }

    /// About Reqly: its name, version, website and license, and Sponsor Reqly, as the Mac's Help
    /// menu has it.
    func showAbout() {
        let about: Widget = cast(adw_about_dialog_new())
        let dialog: OpaquePointer = cast(about)
        adw_about_dialog_set_application_name(dialog, "Reqly")
        adw_about_dialog_set_application_icon(dialog, App.id)
        adw_about_dialog_set_version(dialog, App.version)
        adw_about_dialog_set_developer_name(dialog, "The Reqly Authors")
        adw_about_dialog_set_comments(dialog, "An open-source inspector for what your apps send and receive.")
        adw_about_dialog_set_website(dialog, "https://reqly.net")
        adw_about_dialog_set_issue_url(dialog, "https://github.com/parsamlm/reqly/issues")
        adw_about_dialog_add_link(dialog, "Sponsor Reqly", App.sponsor)
        adw_about_dialog_set_copyright(dialog, "Copyright © 2026 The Reqly Authors")
        adw_about_dialog_set_license_type(dialog, GTK_LICENSE_MIT_X11)
        self.about = about
        connect(about, "closed") { [weak self] in
            self?.about = nil
            self?.keepFocusAfterDialog()
        }
        adw_dialog_present(cast(about), window)
    }
}
