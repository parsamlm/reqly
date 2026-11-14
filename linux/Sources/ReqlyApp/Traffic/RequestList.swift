import CGtk
import CoreInterface
import Foundation
import GtkBinding
import ReqlyModel

/// The request list: a GtkColumnView over a GtkStringList of exchange IDs, kept in step with the
/// session's rows by its `rows` events, through ``RowMirror``, as the Windows app's list is. Its
/// columns are the Mac's: Status, Method, Request, App, Time, Duration and Size, with their widths
/// in sp, so they grow with the text, and Request taking what's left. Until there's traffic, a
/// status page says how to start. While none of the session's requests show, the window shows its
/// no-matches page in the list's place.
///
/// It keeps up with bursts: each event's changes go into the view a few milliseconds' worth at a
/// time, with the window drawing between, through ``RowFeed``; and a row's contents are asked
/// for as GTK binds it, a frame's rows together, through ``SummaryCache``, rather than for every
/// row that arrives. A list that shows its last row follows new traffic, as on the Mac, past the
/// store's limit too, through ``Following``.
///
/// One row is selected at a time, kept by its request through bursts, filters and trimming: a
/// request a filter hides stays selected, though no row shows it, until it leaves the session.
/// The window shows it in the details, through ``onSelection``. Enter, a double click or a click on
/// a row opens it, through ``onActivate``, so the window shows the details over the list when they
/// don't fit beside it; choosing a row with the arrow keys doesn't. ``onRows`` tells the window
/// the counts its header bar shows.
///
/// Tab goes into the list and out of it in one stop, the row with the focus, since its cells take
/// none, and screen readers hear each row as its cells' words and where it is, "Request 3 of
/// 10,000". A row's menu, ``RowMenu``, pins it, marks it with a color, opens its comment through
/// ``onComment``, and decrypts its host.
@MainActor
final class RequestList {
    enum Column: String, CaseIterable {
        case status, method, request, app, time, duration, size

        var title: String {
            switch self {
            case .status: "Status"
            case .method: "Method"
            case .request: "Request"
            case .app: "App"
            case .time: "Time"
            case .duration: "Duration"
            case .size: "Size"
            }
        }

        /// Its width at first, in sp. The Request column's is the least it has, as it takes what
        /// the others leave.
        var width: Double {
            switch self {
            case .status: 70
            case .method: 64
            case .request: 120
            case .app: 96
            case .time: 70
            case .duration: 70
            case .size: 64
            }
        }

        /// Words its cells show that should fit, and the room its symbols take beside them, in
        /// pixels.
        var widest: (words: [String], beside: Int32) {
            switch self {
            // Failed and Paused, after a symbol and the space before them.
            case .status: (["Failed", "Paused", "000"], 20)
            case .method: (["CONNECT", "OPTIONS"], 0)
            case .time: (Self.times.map { Format.time($0) }, 0)
            case .duration: (["888 ms", "88.88 s"], 0)
            case .size: (["888 KB", "88.8 MB"], 0)
            case .request, .app: ([], 0)
            }
        }

        /// The widest times of day: before noon and after, in wide figures.
        private static let times = [10, 22].compactMap {
            Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: $0, minute: 58, second: 58))
        }
    }

    /// The list, or a status page in its place.
    let widget: Widget
    let view: Widget
    /// The view's scroller.
    let scroller: Widget
    /// The menu on a row.
    let menu: RowMenu
    let icons = AppIcons()
    /// How many requests the session has, once the list shows them.
    private(set) var total = 0
    /// The selected row's request, which may be one a filter hides.
    private(set) var selected: ExchangeID?

    /// The request of the row GTK shows selected: ``selected``, unless no row shows it.
    var shownSelection: ExchangeID? {
        gtk_single_selection_get_selected_item(selection).map(Self.id(of:))
    }
    /// Runs when the selected row's request changes: as you choose a row, or once its request has
    /// left the session, with `nil`.
    var onSelection: ((ExchangeID?) -> Void)?
    /// Runs when you open a row's request, with Enter, a double click or a click.
    var onActivate: ((ExchangeID) -> Void)?
    /// Runs after each change to the rows, or to the session's count.
    var onRows: (() -> Void)?
    /// Runs when the rows changed while the keyboard's focus was on one, and now none has it, as
    /// when Clear takes the row that had it, so the window can give the focus to what shows.
    var onFocusLost: (() -> Void)?
    /// Runs when you choose Add or Edit Comment… in a row's menu, with its request, which the
    /// window then shows on the details' Overview, where its comment is written.
    var onComment: ((ExchangeID) -> Void)?
    /// One of the Request menu's commands, chosen in a row's menu, on that row's request.
    var onCommand: ((RequestCommand, ExchangeSummary) -> Void)?
    /// How many times the list has brought its newest row into view, following new traffic.
    private(set) var reveals = 0
    /// When the newest row is to come into view, once the time between reveals has gone, in
    /// monotonic microseconds, or `nil` while none waits.
    private(set) var revealDue: Int?
    /// The least time between two reveals, in microseconds: 100 ms, unless the self-check holds
    /// the newest row back longer.
    var timeBetweenReveals: Int {
        get { following.between }
        set { following.between = newValue }
    }
    private let model: SessionModel
    private let selection: OpaquePointer
    private let empty: Widget
    /// The rows' exchange IDs, as text, which the view shows.
    private let items: OpaquePointer
    private var mirror = RowMirror()
    private var feed = RowFeed()
    private var following = Following()
    private var cache = SummaryCache()
    /// The exchanges of the view's rows, as the feed has put them in so far, behind the mirror
    /// while pieces wait.
    private var shown: [ExchangeID] = []
    /// The session's count as the latest event had it, which ``total`` becomes once the list
    /// shows its rows.
    private var latestTotal = 0
    private var isReadingRows = false
    private var isFeeding = false
    /// Whether the list is changing its rows, or their selection, itself, so GTK's changes to the
    /// selection meanwhile aren't yours.
    private var isSplicing = false
    private var isFetching = false
    private var isCheckingSelected = false
    private var revealTimer: UInt32?
    /// The list going to its very end, frame after frame, once the newest row has been laid out.
    private var ending = GoingToTheEnd()
    private var describeTimer: UInt32?
    /// The cells GTK has bound, by list item, and the list items showing each exchange, so a
    /// changed exchange's cells are filled in again where they are.
    private var bound: [UnsafeMutableRawPointer: (id: ExchangeID, column: Column)] = [:]
    private var itemsByID: [ExchangeID: [UnsafeMutableRawPointer]] = [:]
    /// The rows GTK has bound, GtkColumnViewRows, by their exchange, and the description each
    /// has, which screen readers hear.
    private var rows: [ExchangeID: UnsafeMutableRawPointer] = [:]
    private var descriptions: [UnsafeMutableRawPointer: String] = [:]
    /// The words each row's label was made from, and the label a row with the keyboard's focus
    /// waits to have, as only its times or sizes changed, until the focus leaves it.
    private var spoken: [UnsafeMutableRawPointer: RowText] = [:]
    private var held: [UnsafeMutableRawPointer: RowText] = [:]
    private var columns: [Column: OpaquePointer] = [:]
    /// Each column's width in sp, as it starts or as you left it.
    private var widths: [Column: Double] = [:]
    private var isSizing = false
    /// The row the right button was pressed on, and where, whose menu opens as it's let go.
    private var menuPress: (id: ExchangeID, x: Double, y: Double)?
    /// The request to select once its row shows, the request selected as it was asked for, and
    /// who hears whether it was selected; and the timer that gives up on it.
    private var awaited: (id: ExchangeID, selectedBefore: ExchangeID?, then: (@MainActor (Bool) -> Void)?)?
    private var awaitTimer: UInt32?
    /// The row the keyboard's focus was on as the window last said it moved.
    private var lastFocusedRow: UnsafeMutableRawPointer?
    /// Whether the list is giving a row the keyboard's focus itself, in view, rather than Tab.
    private var isGivingFocus = false
    /// Whether a button or a finger is down on the list: GTK gives the row under it the keyboard's
    /// focus as it goes down, and selects the row as it comes up.
    private var isPressed = false
    /// Whether every row was put in again since the rows were last described, as a search does.
    private var rowsWereReset = false
    /// Whether the list's window has closed, though the list may live on a moment, as a task that
    /// waits on the session holds it: see ``windowClosed()``.
    private(set) var isGone = false
    /// The list's listener and observer of its session, which go as its window closes.
    private var listener: Int?
    private var observer: Int?
    /// The request of the row the keyboard's focus last came to, and its description then, as
    /// screen readers heard it, for the self-check.
    private(set) var focusArrival: (id: ExchangeID, description: String)?

    init(model: SessionModel) {
        self.model = model
        ListStyles.install()
        items = gtk_string_list_new(nil)
        selection = gtk_single_selection_new(cast(items))
        gtk_single_selection_set_autoselect(selection, 0)
        gtk_single_selection_set_can_unselect(selection, 1)
        view = gtk_column_view_new(cast(selection))
        // The selection takes the list's reference, and the view the selection's, and both go
        // with the window: the list keeps its own until it goes, as a task may keep it a moment
        // after its window.
        g_object_ref(raw(items))
        g_object_ref(raw(selection))
        gtk_widget_add_css_class(view, "data-table")
        gtk_widget_add_css_class(view, "requests")
        gtk_column_view_set_reorderable(cast(view), 0)
        // One Tab stop, the row with the focus, and the arrow keys between rows.
        gtk_column_view_set_tab_behavior(cast(view), GTK_LIST_TAB_ITEM)
        setAccessibleLabel(view, "Requests")
        menu = RowMenu(on: view)
        scroller = namedScroller("Requests")
        gtk_scrolled_window_set_child(cast(scroller), view)
        empty = namedStatusPage("Requests")
        adw_status_page_set_icon_name(cast(empty), "network-transmit-receive-symbolic")
        widget = gtk_stack_new()
        gtk_stack_add_named(cast(widget), empty, "empty")
        gtk_stack_add_named(cast(widget), scroller, "list")
        for column in Column.allCases {
            widths[column] = column.width
            add(column)
        }
        setUpRows()
        size()
        // The columns' widths are in sp, so they grow as the text does. GTK's settings outlive a
        // file's window, so the handler goes with the view.
        connect(raw(gtk_settings_get_default()), "notify::gtk-xft-dpi", whileAlive: raw(view)) { [weak self] in
            self?.size()
        }
        // The method's font is the desktop's monospace one from libadwaita 1.7.
        Styles.whenMonospaceFontChanges(whileAlive: raw(view)) { [weak self] in self?.size() }
        icons.onFound = { [weak self] key in self?.iconFound(key) }
        connect(selection, "notify::selected") { [weak self] in self?.selectionChanged() }
        connect(view, "activate") { [weak self] (arguments: Arguments) in
            self?.activated(at: Int(arguments.uint(1)))
        }
        // A click on a row, once the row has been selected. A click on the column titles never
        // gets here.
        let click = gtk_gesture_click_new()!
        connect(click, "released") { [weak self] (arguments: Arguments) in
            if arguments.int(1) == 1 {
                self?.clicked(x: arguments.double(2), y: arguments.double(3))
            }
        }
        gtk_widget_add_controller(view, cast(click))
        setUpMenu()
        watchYourScrolling()
        // Tab into the list, from the filter bar or the details.
        let focus = gtk_event_controller_focus_new()!
        connect(focus, "enter") { [weak self] in self?.focusCameIn() }
        gtk_widget_add_controller(view, focus)
        // Before the rows' own handlers, which give a row the focus as the button goes down.
        let presses = gtk_event_controller_legacy_new()!
        gtk_event_controller_set_propagation_phase(presses, GTK_PHASE_CAPTURE)
        connect(presses, "event") { [weak self] (arguments: Arguments) in
            guard let self, let event: OpaquePointer = cast(arguments.pointer(1)) else { return }
            switch gdk_event_get_event_type(event) {
            case GDK_BUTTON_PRESS, GDK_TOUCH_BEGIN: isPressed = true
            case GDK_BUTTON_RELEASE, GDK_TOUCH_END, GDK_TOUCH_CANCEL, GDK_KEY_PRESS: isPressed = false
            default: break
            }
        }
        gtk_widget_add_controller(view, presses)
        connect(view, "destroy") { [weak self] in self?.isGone = true }
        listener = model.listen { [weak self] event in
            guard let self, !isGone else { return }
            switch event {
            case .rows(let version, let total, _, let steps):
                latestTotal = total
                if let change = mirror.receive(version: version, steps: steps) {
                    take(change)
                } else if !isFeeding {
                    self.total = total
                    onRows?()
                }
                if mirror.isWaitingForRows {
                    readEveryRow()
                }
            case .counts(let total, _, _): counted(total)
            case .sidebar(let sidebar): counted(sidebar.total)
            default: break
            }
        }
        observer = model.observe { [weak self] in self?.showState() }
        showState()
    }

    isolated deinit {
        g_object_unref(raw(selection))
        g_object_unref(raw(items))
    }

    /// Its window has closed, and the window's widgets, the list's among them, go with it: the
    /// list hears its session no more, drops what it waited to do, and a task that keeps it a
    /// moment longer does nothing with them.
    func windowClosed() {
        guard !isGone else { return }
        isGone = true
        if let listener {
            model.stopListening(listener)
        }
        if let observer {
            model.stopObserving(observer)
        }
        finishAwaiting(selecting: false)
        for timer in [revealTimer, describeTimer].compactMap({ $0 }) {
            g_source_remove(timer)
        }
        (revealTimer, describeTimer) = (nil, nil)
    }

    /// How many rows the list shows.
    var count: Int { shown.count }

    /// The exchange a row shows, and its contents once they're in.
    func summary(at row: Int) -> ExchangeSummary? {
        shown.indices.contains(row) ? cache[shown[row]]?.summary : nil
    }

    /// The exchange a row shows.
    func exchange(at row: Int) -> ExchangeID? {
        shown.indices.contains(row) ? shown[row] : nil
    }

    /// What a request's row says, while GTK has it bound and its contents are in.
    func text(of id: ExchangeID) -> RowText? {
        itemsByID[id] == nil ? nil : cache[id]?.text
    }

    /// The widget a column's cell shows an exchange with, while GTK has one bound.
    func cell(_ column: Column, of id: ExchangeID) -> Widget? {
        let item = itemsByID[id]?.first { bound[$0]?.column == column }
        return item.flatMap { gtk_list_item_get_child(cast($0)) }
    }

    /// The row's widget showing an exchange, while GTK has one bound.
    func rowWidget(of id: ExchangeID) -> Widget? {
        cell(.status, of: id).flatMap(RequestCells.row(of:))
    }

    /// What screen readers hear of an exchange's row, while GTK has one bound: its label and its
    /// description.
    func accessibleWords(of id: ExchangeID) -> (label: String, description: String)? {
        guard let row = rows[id] else { return nil }
        return (stringProperty(row, "accessible-label") ?? "", stringProperty(row, "accessible-description") ?? "")
    }

    /// Whether every change is in the view, with the contents of the rows it shows, and the list
    /// is done going to its end.
    var isSettled: Bool { rowsAreIn && !ending.isGoing }

    /// Whether every change is in the view, with the contents of the rows it shows.
    private var rowsAreIn: Bool {
        feed.isEmpty && !mirror.isWaitingForRows && !isReadingRows && !isFetching && !cache.hasWanted
    }

    // MARK: - The selection

    /// Selects the row showing `id`'s request, and scrolls to it, or selects none. A request the
    /// list doesn't show, as a filter hides it, is selected with no row.
    func select(id: ExchangeID?) {
        guard let id else {
            gtk_single_selection_set_selected(selection, UInt32.max)
            if selected != nil {
                selected = nil
                onSelection?(nil)
            }
            return
        }
        if let row = shown.firstIndex(of: id) {
            gtk_column_view_scroll_to(cast(view), UInt32(row), nil, GTK_LIST_SCROLL_SELECT, nil)
        } else if selected != id {
            isSplicing = true
            gtk_single_selection_set_selected(selection, UInt32.max)
            isSplicing = false
            selected = id
            onSelection?(id)
        }
    }

    /// Gives the keyboard's focus to the selected row, or to the list when none is, and says
    /// whether it could: not while the list is empty, and its status page shows.
    @discardableResult
    func focusSelection() -> Bool {
        guard gtk_widget_get_mapped(view) != 0 else { return false }
        let row = gtk_single_selection_get_selected(selection)
        // GTK 4.14 gives the list's focus to the row it scrolled to, and 4.18 and later to the
        // row that had it before, moving it as it scrolls only while the list has the focus: so it
        // scrolls before the list takes the focus, and again after.
        guard row != UInt32.max else { return gtk_widget_grab_focus(view) != 0 }
        // Where it is now, as screen readers hear it as it takes the focus.
        if let id = exchange(at: Int(row)), let bound = rows[id] {
            describe(bound)
        }
        isGivingFocus = true
        defer { isGivingFocus = false }
        gtk_column_view_scroll_to(cast(view), row, nil, GTK_LIST_SCROLL_FOCUS, nil)
        let took = gtk_widget_grab_focus(view) != 0
        gtk_column_view_scroll_to(cast(view), row, nil, GTK_LIST_SCROLL_FOCUS, nil)
        return took
    }

    /// Selects `id`'s row once the list shows it, as for the request Resend sent, or one a
    /// breakpoint holds, whose row comes a moment after: at once when it shows already, and
    /// otherwise as it comes, for up to `seconds`. With the keyboard's focus on a row, the focus
    /// goes to it too. If its row never shows, as when a filter hides it, it's selected with no
    /// row once the time is up, while the session still has it. Either way, only while the
    /// selection is still the one it was as this was asked: one you chose meanwhile stays. `then`
    /// hears whether it was selected. A later call takes the place of one that still waits, which
    /// hears it wasn't.
    func selectOnceShown(_ id: ExchangeID, within seconds: Int = 10, then: (@MainActor (Bool) -> Void)? = nil) {
        finishAwaiting(selecting: false)
        guard !isGone else {
            then?(false)
            return
        }
        awaited = (id, selected, then)
        if shown.contains(id) {
            finishAwaiting(selecting: true)
            return
        }
        awaitTimer = timeout(UInt32(seconds * 1000)) { [weak self] in
            self?.awaitTimer = nil
            self?.giveUpAwaiting()
            return false
        }
    }

    /// Whether a request waits to be selected once its row shows.
    var isAwaitingARow: Bool { awaited != nil }

    /// After a change to the rows: the request that waits is selected once its row shows.
    private func selectAwaited() {
        if let awaited, shown.contains(awaited.id) {
            finishAwaiting(selecting: true)
        }
    }

    /// Stops waiting, and selects the request that waited, when `selecting` and the selection is
    /// still the one it was, then says whether it did.
    private func finishAwaiting(selecting: Bool) {
        guard let awaited else { return }
        self.awaited = nil
        if let awaitTimer {
            g_source_remove(awaitTimer)
            self.awaitTimer = nil
        }
        let selects = selecting && !isGone && selected == awaited.selectedBefore
        if selects {
            select(id: awaited.id, focuses: rowHasFocus)
        }
        awaited.then?(selects)
    }

    /// The time's up, and the request's row never showed: it's selected with no row, while the
    /// session has it, as a request a filter hides is.
    private func giveUpAwaiting() {
        guard let awaited, let session = model.session else {
            finishAwaiting(selecting: false)
            return
        }
        Task {
            let isThere = !(await session.rows([awaited.id])).isEmpty
            guard self.awaited?.id == awaited.id else { return }
            finishAwaiting(selecting: isThere)
        }
    }

    /// Selects `id`'s row, as ``select(id:)`` does, and gives it the keyboard's focus too when
    /// `focuses`, once it shows.
    private func select(id: ExchangeID, focuses: Bool) {
        guard focuses, let row = shown.firstIndex(of: id) else {
            select(id: id)
            return
        }
        if let bound = rows[id] {
            describe(bound)
        }
        let flags = GtkListScrollFlags(rawValue: GTK_LIST_SCROLL_SELECT.rawValue | GTK_LIST_SCROLL_FOCUS.rawValue)
        isGivingFocus = true
        defer { isGivingFocus = false }
        gtk_column_view_scroll_to(cast(view), UInt32(row), nil, flags, nil)
    }

    /// Whether `id`'s row shows whole in the list's scroller.
    func rowIsInView(_ id: ExchangeID) -> Bool {
        guard let cell = cell(.status, of: id), gtk_widget_get_mapped(cell) != 0 else { return false }
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(cell, scroller, &bounds) != 0 else { return false }
        let height = Float(gtk_widget_get_height(scroller))
        return bounds.origin.y >= 0 && bounds.origin.y + bounds.size.height <= height + 0.5
    }

    /// The keyboard's focus came into the list, as Tab brings it from the filter bar or the
    /// details: GTK gives it to the row that had it last, which may be out of view, as the list
    /// followed new traffic meanwhile, and then screen readers say nothing of it; or it may not be
    /// the selected row, as when Reqly selected a request itself. Once GTK is done, the selected
    /// row has the focus, or the row GTK gave it to when none is, in view: one out of view comes
    /// into view first, then takes the focus there. A click that brought it, or a touch, is left
    /// alone: GTK gives the row under it the focus as the button goes down, then selects it as it
    /// comes up, so the row clicked has both.
    private func focusCameIn() {
        guard !isGivingFocus, !isPressed else { return }
        idle { [weak self] in
            if let self, !isGone {
                bringTheFocusIntoView()
            }
            return false
        }
    }

    private func bringTheFocusIntoView() {
        guard let focused = focusedRow, let focusedID = focusedExchange else { return }
        let selectedRow = gtk_single_selection_get_selected(selection)
        let target = selectedRow != UInt32.max ? Int(selectedRow) : Int(gtk_column_view_row_get_position(cast(focused)))
        guard let targetID = exchange(at: target) else { return }
        if targetID == focusedID, rowIsInView(targetID) {
            return
        }
        if rowIsInView(targetID) {
            select(id: targetID, focuses: true)
            return
        }
        gtk_column_view_scroll_to(cast(view), UInt32(target), nil, GTK_LIST_SCROLL_NONE, nil)
        var frames = 0
        tick(view) { [weak self] in
            guard let self, !isGone, focusedExchange == focusedID else { return false }
            frames += 1
            guard rowIsInView(targetID) || frames > 10, let place = shown.firstIndex(of: targetID) else { return true }
            // Taken away and given back, the focus is heard on the row in view.
            if targetID == focusedID {
                gtk_root_set_focus(gtk_widget_get_root(view), nil)
            }
            if let bound = rows[targetID] {
                describe(bound)
            }
            isGivingFocus = true
            gtk_column_view_scroll_to(cast(view), UInt32(place), nil, GTK_LIST_SCROLL_FOCUS, nil)
            isGivingFocus = false
            return false
        }
    }

    private func selectionChanged() {
        guard !isSplicing else { return }
        let id = gtk_single_selection_get_selected_item(selection).map(Self.id(of:))
        guard id != selected else { return }
        selected = id
        if let id, let row = rows[id] {
            describe(row)
        }
        onSelection?(id)
    }

    /// After a change to the rows: the selected request's row is selected again where it is now,
    /// as GTK lets go of a row that goes, even one that comes back. A request no row shows stays
    /// selected while it's in the session.
    private func keepSelection() {
        guard let selected else { return }
        let current = gtk_single_selection_get_selected_item(selection).map(Self.id(of:))
        guard current != selected else { return }
        if let row = shown.firstIndex(of: selected) {
            isSplicing = true
            gtk_single_selection_set_selected(selection, UInt32(row))
            isSplicing = false
        } else if feed.isEmpty {
            forgetSelectionIfGone()
        }
    }

    /// Lets go of the selection once its request has left the session, as Clear or the store's
    /// limit take requests out, rather than a filter.
    private func forgetSelectionIfGone() {
        guard let id = selected, !isCheckingSelected, let session = model.session else { return }
        isCheckingSelected = true
        Task {
            let isThere = !(await session.rows([id])).isEmpty
            isCheckingSelected = false
            if !isGone, !isThere, selected == id, !shown.contains(id) {
                selected = nil
                onSelection?(nil)
            }
        }
    }

    /// The session's count, which the sidebar's events give after every change, as rows events
    /// don't for one that changes no row: Clear, or the store's limit, taking requests none of the
    /// rows show. Once the rows are in, the list goes by it, and lets go of a selected request no
    /// row shows, if it went.
    private func counted(_ total: Int) {
        latestTotal = total
        guard feed.isEmpty, !mirror.isWaitingForRows else { return }
        if let selected, !shown.contains(selected) {
            forgetSelectionIfGone()
        }
        guard total != self.total else { return }
        self.total = total
        showState()
        onRows?()
    }

    private func activated(at row: Int) {
        if shown.indices.contains(row) {
            onActivate?(shown[row])
        }
    }

    /// Opens the request of the row at the point clicked, in the view's own coordinates.
    private func clicked(x: Double, y: Double) {
        if let id = id(at: x, y) {
            onActivate?(id)
        }
    }

    /// The request of the row at a point in the view: the row whose cell has the widget there.
    private func id(at x: Double, _ y: Double) -> ExchangeID? {
        var widget = gtk_widget_pick(view, x, y, GTK_PICK_DEFAULT)
        while let found = widget, found != view {
            if let cell = bound.first(where: { gtk_list_item_get_child(cast($0.key)) == found }) {
                return cell.value.id
            }
            widget = gtk_widget_get_parent(found)
        }
        return nil
    }

    /// The exchange a row's item shows: its ID, as text.
    private static func id(of item: UnsafeMutableRawPointer) -> ExchangeID {
        ExchangeID(rawValue: strtoull(gtk_string_object_get_string(cast(item)), nil, 10))
    }

    // MARK: - The rows

    /// Takes in a change to the session's rows: the contents it makes old are forgotten, or asked
    /// for again, and its splices wait their turn to go into the view.
    private func take(_ change: RowMirror.Change) {
        guard !isGone else { return }
        if change.isReset {
            cache.forgetAll()
            rowsWereReset = true
        } else {
            cache.inserted(change.inserted)
        }
        cache.changed(change.changed) { itemsByID[$0] != nil }
        if cache.hasWanted {
            fetchSoon()
        }
        feed.append(change, shown: shown.count)
        if !isFeeding {
            feedSome()
        }
    }

    /// Puts pieces of the waiting changes into the view for up to 8 ms, then lets the window
    /// draw before the next pieces. Whether the list follows them is decided before.
    private func feedSome() {
        guard !isGone else {
            isFeeding = false
            return
        }
        isFeeding = true
        // A row, not the view: a row's menu, which is the view's child, takes the focus too.
        let hadFocus = rowHasFocus
        let started = monotonicMicroseconds()
        following.begin(showsEnd: ending.isGoing || showsEnd())
        var inserted = 0
        isSplicing = true
        while let piece = feed.next() {
            splice(piece)
            inserted += piece.inserting.count
            if monotonicMicroseconds() - started >= 8_000 {
                break
            }
        }
        isSplicing = false
        keepSelection()
        selectAwaited()
        let now = monotonicMicroseconds()
        respond(to: following.end(inserted: inserted, isDone: feed.isEmpty, isResetting: feed.isResetting, now: now))
        if feed.isEmpty {
            total = latestTotal
        }
        showState()
        if rowsWereReset, feed.isEmpty {
            describeAll()
        } else {
            describeSoon()
        }
        onRows?()
        if hadFocus, !rowHasFocus {
            onFocusLost?()
        }
        guard !feed.isEmpty else {
            isFeeding = false
            return
        }
        idle { [weak self] in
            self?.feedSome()
            return false
        }
    }

    /// A piece of a change, into the view and its rows' exchanges.
    private func splice(_ piece: RowFeed.Piece) {
        Self.withIDStrings(piece.inserting) {
            gtk_string_list_splice(items, UInt32(piece.position), UInt32(piece.removing), $0)
        }
        shown.replaceSubrange(piece.position..<piece.position + piece.removing, with: piece.inserting)
    }

    /// Brings the newest row into view, now or once it's time.
    private func respond(to reveal: Following.Reveal) {
        switch reveal {
        case .none:
            break
        case .now:
            cancelReveal()
            showNewest()
        case .after(let milliseconds):
            guard revealTimer == nil else { return }
            revealDue = monotonicMicroseconds() + milliseconds * 1000
            revealTimer = timeout(UInt32(milliseconds)) { [weak self] in
                guard let self else { return false }
                revealTimer = nil
                revealDue = nil
                let now = monotonicMicroseconds()
                respond(to: following.reveal(isDone: feed.isEmpty, isResetting: feed.isResetting, now: now))
                return false
            }
        }
    }

    /// Your own scrolling up, with the wheel or a touchpad, the keys that go up, or the
    /// scrollbar, stops the list following at once, before a newest row still to show takes it
    /// back to its end. Back at its end, it follows the next change.
    private func watchYourScrolling() {
        let wheel = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL)!
        gtk_event_controller_set_propagation_phase(wheel, GTK_PHASE_CAPTURE)
        connect(wheel, "scroll") { [weak self] (arguments: Arguments) in
            if arguments.double(2) < 0 {
                self?.scrolledUp()
            }
            arguments.returns(false)
        }
        gtk_widget_add_controller(scroller, wheel)
        let up = [GDK_KEY_Up, GDK_KEY_KP_Up, GDK_KEY_Page_Up, GDK_KEY_KP_Page_Up, GDK_KEY_Home, GDK_KEY_KP_Home]
            .map { UInt32($0) }
        let keys = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed") { [weak self] (arguments: Arguments) in
            if up.contains(arguments.uint(1)) {
                self?.scrolledUp()
            }
            arguments.returns(false)
        }
        gtk_widget_add_controller(view, keys)
        if let bar = gtk_scrolled_window_get_vscrollbar(cast(scroller)) {
            let press = gtk_gesture_click_new()!
            gtk_event_controller_set_propagation_phase(cast(press), GTK_PHASE_CAPTURE)
            connect(press, "pressed") { [weak self] in self?.scrolledUp() }
            gtk_widget_add_controller(bar, cast(press))
        }
    }

    private func scrolledUp() {
        following.stop()
        cancelReveal()
        // Nor does it go on to its very end, as the newest row it showed is laid out.
        ending.stop()
    }

    /// Forgets the newest row that was to show once it's time.
    private func cancelReveal() {
        if let revealTimer {
            g_source_remove(revealTimer)
            self.revealTimer = nil
            revealDue = nil
        }
    }

    private func showNewest() {
        guard count > 0 else { return }
        reveals += 1
        gtk_column_view_scroll_to(cast(view), UInt32(count - 1), nil, GTK_LIST_SCROLL_NONE, nil)
        // GTK places rows it hasn't laid out yet by how tall it guesses they are, and may leave
        // the last one below the edge, so once a frame has laid them out, the list goes to its
        // very end, frame after frame, until a frame leaves it there with everything in, unless
        // you scroll meanwhile, as `scrolledUp()` hears, or up from where it went, as a
        // touchscreen does. GTK goes to the row in the frame after it's asked to, which isn't you
        // scrolling, and may move the list then, as when the list first shows rows, or when it's
        // asked again before the list is done. Until then it's at its end, for whether it follows.
        guard ending.ask(now: monotonicMicroseconds()) else { return }
        let round = ending.round
        tick(view) { [weak self] in
            guard let self, ending.round == round else { return false }
            guard let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller)) else {
                ending.stop()
                return false
            }
            let value = gtk_adjustment_get_value(adjustment)
            let end = gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            let step = ending.frame(
                value: value, end: end, isFollowing: following.isFollowing, hasNewRows: following.hasUnrevealed,
                isSettled: rowsAreIn, now: monotonicMicroseconds())
            switch step {
            case .wait:
                return true
            case .move(let end):
                gtk_adjustment_set_value(adjustment, end)
                return true
            case .stop:
                return false
            }
        }
    }

    /// Asks the session for every row, when an event was missing, and goes on from there.
    private func readEveryRow() {
        guard !isReadingRows, let session = model.session else { return }
        isReadingRows = true
        Task {
            let rows = await session.rowIDs()
            isReadingRows = false
            guard !isGone else { return }
            take(mirror.reset(version: rows.version, ids: rows.ids))
            if mirror.isWaitingForRows {
                readEveryRow()
            }
        }
    }

    /// Asks for the contents of the rows bound without them, once the frame that bound them is
    /// over, all of them together, then fills in their cells.
    private func fetchSoon() {
        guard !isFetching else { return }
        isFetching = true
        idle { [weak self] in
            self?.fetch()
            return false
        }
    }

    private func fetch() {
        let wanted = cache.takeWanted()
        guard !wanted.isEmpty, !isGone, let session = model.session else {
            isFetching = false
            return
        }
        Task {
            let summaries = await session.rows(wanted)
            guard !isGone else {
                isFetching = false
                return
            }
            for entry in cache.received(summaries, isBound: { itemsByID[$0] != nil }) {
                refill(entry)
            }
            isFetching = false
            if cache.hasWanted {
                fetchSoon()
            }
        }
    }

    /// The status page while there's no traffic, saying how to start, and the list after, which
    /// the window's no-matches page covers while none of the session's requests show.
    private func showState() {
        guard !isGone else { return }
        guard count == 0, total == 0 else {
            gtk_stack_set_visible_child(cast(widget), scroller)
            return
        }
        gtk_stack_set_visible_child(cast(widget), empty)
        let title: String
        let description: String
        if let name = model.fileName {
            // A file's window, as on the Mac.
            adw_status_page_set_title(cast(empty), "No Requests")
            // Its description is markup, which a file's name may look like.
            let words = takeString(g_markup_escape_text("“\(name)” has no requests in it.", -1))
            adw_status_page_set_description(cast(empty), words)
            return
        }
        switch (model.isCapturing, model.options.setsSystemProxy) {
        case (true, true):
            title = "Waiting for Traffic"
            description = "Use an app that goes online, such as Firefox. Its requests show up here."
        case (true, false):
            title = "Waiting for Traffic"
            description =
                "Reqly isn't setting your desktop's proxy, so point apps at 127.0.0.1, port \(model.port), or use "
                + "Open Terminal."
        case (false, true):
            title = "No Traffic Yet"
            description =
                "Turn on Capture to see what your apps send and receive. While capturing, Reqly is your desktop's "
                + "proxy, and your settings come back when you stop."
        case (false, false):
            title = "No Traffic Yet"
            description = "Turn on Capture to see what your apps send and receive."
        }
        adw_status_page_set_title(cast(empty), title)
        adw_status_page_set_description(cast(empty), description)
    }

    /// Whether the list shows its last row, or nearly: then it follows new traffic.
    func showsEnd() -> Bool {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller)) else { return true }
        return Following.showsEnd(
            rows: count, value: gtk_adjustment_get_value(adjustment), page: gtk_adjustment_get_page_size(adjustment),
            upper: gtk_adjustment_get_upper(adjustment))
    }

    /// IDs as the C strings a GtkStringList takes, written into one buffer.
    private static func withIDStrings<R>(
        _ ids: ArraySlice<ExchangeID>, _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R
    ) -> R {
        var text: [CChar] = []
        text.reserveCapacity(ids.count * 8)
        var starts: [Int] = []
        starts.reserveCapacity(ids.count)
        for id in ids {
            starts.append(text.count)
            text.append(contentsOf: String(id.rawValue).utf8CString)
        }
        return text.withUnsafeBufferPointer { buffer in
            var pointers: [UnsafePointer<CChar>?] = starts.map { buffer.baseAddress! + $0 }
            pointers.append(nil)
            return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
    }

    // MARK: - Columns and cells

    private func add(_ column: Column) {
        let factory = gtk_signal_list_item_factory_new()
        connect(factory, "setup") { (arguments: Arguments) in
            let item = arguments.object(1)!
            // The row takes the focus, not its cells.
            gtk_column_view_cell_set_focusable(cast(item), 0)
            gtk_list_item_set_child(cast(item), RequestCells.make(column))
        }
        connect(factory, "bind") { [weak self] (arguments: Arguments) in
            self?.bind(arguments.object(1)!, column)
        }
        connect(factory, "unbind") { [weak self] (arguments: Arguments) in
            self?.unbind(arguments.object(1)!)
        }
        let viewColumn = gtk_column_view_column_new(column.title, factory)!
        gtk_column_view_column_set_id(viewColumn, column.rawValue)
        if column == .request {
            gtk_column_view_column_set_expand(viewColumn, 1)
        } else {
            gtk_column_view_column_set_resizable(viewColumn, 1)
            connect(viewColumn, "notify::fixed-width") { [weak self] in self?.resized(column) }
        }
        gtk_column_view_append_column(cast(view), viewColumn)
        columns[column] = viewColumn
        g_object_unref(raw(viewColumn))
    }

    /// Sets each column's width: its width in sp, at the text's size now, and at least room for
    /// its widest words, in the window's font.
    /// The Request column has at least 120 sp, or less when the others take more of the list's
    /// narrowest pane, 560 sp, with GTK's padding in their cells, so the list never scrolls
    /// sideways beside the details. It has 64 sp at the least.
    private func size() {
        let sp = adw_length_unit_to_px(ADW_LENGTH_UNIT_SP, 1, gtk_widget_get_settings(view))
        isSizing = true
        defer { isSizing = false }
        var others: Int32 = 0
        for column in Column.allCases where column != .request {
            let width = max(Int32(((widths[column] ?? column.width) * sp).rounded()), fitting(column))
            gtk_column_view_column_set_fixed_width(columns[column], width)
            others += width
        }
        let narrowest = Int32((Self.narrowestList * sp).rounded()) - others
        let request = max(Int32((64 * sp).rounded()), min(Int32((Column.request.width * sp).rounded()), narrowest))
        gtk_column_view_column_set_fixed_width(columns[.request], request)
    }

    /// The narrowest the list's pane is beside the details, in sp, as the window has it.
    static let narrowestList = 560.0

    /// You made a column wider or narrower: it keeps its width in sp, for when the text's size
    /// changes.
    private func resized(_ column: Column) {
        guard !isSizing, let viewColumn = columns[column] else { return }
        let sp = adw_length_unit_to_px(ADW_LENGTH_UNIT_SP, 1, gtk_widget_get_settings(view))
        widths[column] = Double(gtk_column_view_column_get_fixed_width(viewColumn)) / sp
    }

    /// The room a column's widest words take in the window's font, or for the methods, in the
    /// font libadwaita's monospace class gives them, which is the desktop's monospace font from
    /// 1.7, and the title's, with the cell's padding, libadwaita's 6 pixels at each side, and a
    /// pixel at each for rounding.
    private func fitting(_ column: Column) -> Int32 {
        let (words, beside) = column.widest
        let font = Styles.monospaceFont(for: view)
        defer { pango_font_description_free(font) }
        var widest: Int32 = 0
        for text in words + [column.title] {
            guard let layout = gtk_widget_create_pango_layout(view, text) else { continue }
            if column == .method, text != column.title {
                pango_layout_set_font_description(layout, font)
            }
            var width: Int32 = 0
            pango_layout_get_pixel_size(layout, &width, nil)
            g_object_unref(raw(layout))
            widest = max(widest, width + (text == column.title ? 0 : beside))
        }
        return widest + 14
    }

    /// A column's width, in pixels.
    func width(of column: Column) -> Int32 {
        gtk_column_view_column_get_fixed_width(columns[column])
    }

    /// A column's GtkColumnViewColumn, such as App's, which the window hides while the details
    /// beside the list leave Request little room.
    func viewColumn(_ column: Column) -> OpaquePointer? {
        columns[column]
    }

    /// Whether `column` shows.
    func shows(_ column: Column) -> Bool {
        gtk_column_view_column_get_visible(columns[column]) != 0
    }

    private func bind(_ item: UnsafeMutableRawPointer, _ column: Column) {
        guard let object = gtk_list_item_get_item(cast(item)) else { return }
        let id = Self.id(of: object)
        bound[item] = (id, column)
        itemsByID[id, default: []].append(item)
        let entry = cache.bound(id)
        fill(item, column, entry)
        if entry == nil {
            fetchSoon()
        }
    }

    private func unbind(_ item: UnsafeMutableRawPointer) {
        guard let (id, _) = bound.removeValue(forKey: item) else { return }
        itemsByID[id]?.removeAll { $0 == item }
        if itemsByID[id]?.isEmpty == true {
            itemsByID[id] = nil
        }
    }

    /// Fills in the cells and the row showing an exchange again, with its new contents.
    private func refill(_ entry: SummaryCache.Entry) {
        guard !isGone else { return }
        let id = entry.summary.id
        for item in itemsByID[id] ?? [] {
            if let column = bound[item]?.column {
                fill(item, column, entry)
            }
        }
        if let row = rows[id] {
            label(row, of: id, entry.text)
        }
    }

    /// Shows the icon of an app found since its rows were filled in.
    private func iconFound(_ key: String) {
        guard !isGone else { return }
        for (item, cell) in bound where cell.column == .app {
            if let entry = cache[cell.id], let source = entry.summary.source, AppIcons.key(of: source) == key {
                fill(item, .app, entry)
            }
        }
    }

    private func fill(_ item: UnsafeMutableRawPointer, _ column: Column, _ entry: SummaryCache.Entry?) {
        guard let cell = gtk_list_item_get_child(cast(item)) else { return }
        let icon = column == .app ? entry?.summary.source.flatMap { icons.icon(for: $0) } : nil
        RequestCells.fill(cell, column, entry?.text, icon: icon)
    }

    // MARK: - Rows for screen readers

    /// Each row's label, its cells' words, and its description, where it is in the list, set as
    /// GTK binds the row.
    private func setUpRows() {
        let factory = gtk_signal_list_item_factory_new()
        connect(factory, "bind") { [weak self] (arguments: Arguments) in
            self?.bindRow(arguments.object(1)!)
        }
        connect(factory, "unbind") { [weak self] (arguments: Arguments) in
            self?.unbindRow(arguments.object(1)!)
        }
        gtk_column_view_set_row_factory(cast(view), factory)
        g_object_unref(raw(factory))
    }

    private func bindRow(_ row: UnsafeMutableRawPointer) {
        guard let object = gtk_column_view_row_get_item(cast(row)) else { return }
        let id = Self.id(of: object)
        rows[id] = row
        spoken[row] = nil
        held[row] = nil
        label(row, of: id, cache[id]?.text)
        descriptions[row] = nil
        describe(row)
        if descriptions[row] == nil {
            describeSoon()
        }
    }

    private func unbindRow(_ row: UnsafeMutableRawPointer) {
        descriptions[row] = nil
        spoken[row] = nil
        held[row] = nil
        if let id = rows.first(where: { $0.value == row })?.key {
            rows[id] = nil
        }
    }

    /// A row's label, `text`'s words. Orca says the row with the keyboard's focus again whenever
    /// its words change, so while it has the focus, a change to only its times, sizes or app,
    /// as a live request's are, waits until the focus leaves it; one to its status or its marks
    /// is said at once.
    private func label(_ row: UnsafeMutableRawPointer, of id: ExchangeID, _ text: RowText?) {
        if let text, let said = spoken[row], Self.saysTheSame(said, text), hasFocus(id) {
            held[row] = said.label == text.label ? nil : text
            return
        }
        held[row] = nil
        spoken[row] = text
        gtk_column_view_row_set_accessible_label(cast(row), text?.label ?? "")
    }

    /// Whether two of a row's words say the same request, status and marks, whatever their times
    /// and sizes.
    private static func saysTheSame(_ one: RowText, _ other: RowText) -> Bool {
        one.look == other.look && one.status == other.status && one.statusDescription == other.statusDescription
            && one.method == other.method && one.host == other.host && one.path == other.path
            && one.isPinned == other.isPinned && one.color == other.color && one.comment == other.comment
    }

    /// Whether the row showing `id` has the keyboard's focus.
    private func hasFocus(_ id: ExchangeID) -> Bool {
        guard let focus = gtk_widget_get_root(view).flatMap({ gtk_root_get_focus($0) }), let widget = rowWidget(of: id)
        else { return false }
        return focus == widget || gtk_widget_is_ancestor(focus, widget) != 0
    }

    /// Whether one of the rows has the keyboard's focus.
    var rowHasFocus: Bool { focusedRow != nil }

    /// The row with the keyboard's focus, a GtkColumnViewRow, or `nil` while none has it.
    private var focusedRow: UnsafeMutableRawPointer? {
        focusedExchange.flatMap { rows[$0] }
    }

    /// The request of the row with the keyboard's focus, or `nil` while none has it.
    var focusedExchange: ExchangeID? {
        guard let focus = gtk_widget_get_root(view).flatMap({ gtk_root_get_focus($0) }),
            gtk_widget_is_ancestor(focus, view) != 0
        else { return nil }
        return rows.first { hasFocus($0.key) }?.key
    }

    /// The keyboard's focus moved, as the window hears: a row it left has the words it waited
    /// for, and says where it is now, and so does a row it came to, whose words may be from before
    /// the rows last moved, as when a search ends.
    func focusMoved() {
        let focused = focusedRow
        if let focused, focused != lastFocusedRow {
            describe(focused)
            if let id = focusedExchange {
                focusArrival = (id, descriptions[focused] ?? "")
            }
        }
        lastFocusedRow = focused
        for row in rows.values where row != focused {
            if let text = held.removeValue(forKey: row) {
                spoken[row] = text
                gtk_column_view_row_set_accessible_label(cast(row), text.label)
            }
            describe(row)
        }
    }

    /// A row's description, "Request 3 of 10,000", when it's changed.
    private func describe(_ row: UnsafeMutableRawPointer) {
        let position = Int(gtk_column_view_row_get_position(cast(row)))
        guard position < count else { return }
        let description = RowText.position(position, of: count)
        if descriptions[row] != description {
            descriptions[row] = description
            gtk_column_view_row_set_accessible_description(cast(row), description)
        }
    }

    /// Every bound row's description at once, the row with the keyboard's focus too, once every row
    /// was put in again, as when a search starts or ends: that's not new traffic, and the row
    /// with the focus is in another place among other rows, as screen readers hear it.
    private func describeAll() {
        rowsWereReset = false
        if let describeTimer {
            g_source_remove(describeTimer)
            self.describeTimer = nil
        }
        for row in rows.values {
            describe(row)
        }
    }

    /// The bound rows' descriptions, once rows have moved: at most three times a second while
    /// traffic comes, as each new row changes every row's. The row with the keyboard's focus
    /// keeps its own until the focus leaves it, as Orca would say it at each change, once it has
    /// one: a row bound before the list counted it has none yet.
    private func describeSoon() {
        guard describeTimer == nil else { return }
        describeTimer = timeout(300) { [weak self] in
            guard let self else { return false }
            describeTimer = nil
            let focused = focusedRow
            for row in rows.values where row != focused || descriptions[row] == nil {
                describe(row)
            }
            return false
        }
    }

    // MARK: - The row's menu

    private func setUpMenu() {
        menu.onPin = { [weak self] summary in
            self?.annotate(summary.id, isPinned: !summary.annotation.isPinned)
        }
        menu.onColor = { [weak self] summary, color in
            self?.annotate(summary.id, color: color.map { .set($0) } ?? .remove)
        }
        menu.onComment = { [weak self] summary in self?.onComment?(summary.id) }
        menu.onCommand = { [weak self] command, summary in self?.onCommand?(command, summary) }
        menu.decrypts = { [weak self] host in
            guard let self, !model.isSaved else { return nil }
            return model.https.decrypts(host)
        }
        menu.onDecrypt = { [weak self] host, isOn in
            guard let https = self?.model.https else { return }
            Task { await https.setDecrypts(isOn, host: host) }
        }
        // A click with the right button, on the row it's pressed on, which it doesn't choose. The
        // menu opens as the button's let go, not while it's down: a menu takes the pointer as it
        // opens, and GTK 4.14 loses count of what the press made active once the pointer moves
        // onto the menu before the button's let go, as a hand does, and warns.
        let press = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(cast(press), UInt32(GDK_BUTTON_SECONDARY))
        connect(press, "pressed") { [weak self] (arguments: Arguments) in
            let x = arguments.double(2)
            let y = arguments.double(3)
            guard let self else { return }
            menuPress = id(at: x, y).map { ($0, x, y) }
            if menuPress != nil {
                gtk_gesture_set_state(cast(press), GTK_EVENT_SEQUENCE_CLAIMED)
            }
        }
        connect(press, "released") { [weak self] in
            guard let self, let (id, x, y) = menuPress else { return }
            menuPress = nil
            openMenu(for: id, at: GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1))
        }
        gtk_widget_add_controller(view, cast(press))
        // Shift+F10 or the Menu key, on the row with the focus.
        let keys = gtk_event_controller_key_new()!
        connect(keys, "key-pressed") { [weak self] (arguments: Arguments) in
            let key = arguments.uint(1)
            let shortcut = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue
            let modifiers = arguments.flags(3) & shortcut
            let isMenuKey = key == UInt32(GDK_KEY_Menu) && modifiers == 0
            let isShiftF10 = key == UInt32(GDK_KEY_F10) && modifiers == GDK_SHIFT_MASK.rawValue
            guard let self, isMenuKey || isShiftF10 else { return }
            arguments.returns(openMenuOnFocus())
        }
        gtk_widget_add_controller(view, keys)
    }

    /// Opens the menu of the row with the keyboard's focus, under its Request cell, and says
    /// whether there was one.
    @discardableResult
    func openMenuOnFocus() -> Bool {
        guard let focus = gtk_root_get_focus(gtk_widget_get_root(view)) else { return false }
        let id = rows.keys.first { id in
            rowWidget(of: id).map { focus == $0 || gtk_widget_is_ancestor(focus, $0) != 0 } ?? false
        }
        guard let id, let cell = cell(.request, of: id) else { return false }
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(cell, view, &bounds) != 0 else { return false }
        let rect = GdkRectangle(
            x: Int32(bounds.origin.x), y: Int32(bounds.origin.y), width: Int32(min(bounds.size.width, 120)),
            height: Int32(bounds.size.height))
        openMenu(for: id, at: rect)
        return true
    }

    private func openMenu(for id: ExchangeID, at rect: GdkRectangle) {
        guard let summary = cache[id]?.summary else { return }
        menu.open(for: summary, at: rect)
    }

    /// Pins a request or marks it with a color: its row shows it at once, then the session keeps
    /// it.
    private func annotate(_ id: ExchangeID, isPinned: Bool? = nil, color: ValueChange<MarkColor>? = nil) {
        guard let session = model.session else { return }
        let entry = cache.update(id) { summary in
            if let isPinned {
                summary.annotation.isPinned = isPinned
            }
            switch color {
            case .set(let color): summary.annotation.color = color
            case .remove: summary.annotation.color = nil
            case nil: break
            }
        }
        if let entry {
            refill(entry)
        }
        Task {
            do throws(Problem) {
                try await session.annotate(id, isPinned: isPinned, color: color)
            } catch {
                AppLog.write("couldn't mark request \(id.rawValue): \(error.message)")
            }
        }
    }
}
