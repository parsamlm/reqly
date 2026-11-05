import CGtk
import CoreInterface
import GtkBinding
import Presentation
import ReqlyModel

/// The details pane: the selected request on five pages, Overview, Request, Response, Raw and
/// Timing, with their tabs in the pane's header bar, beside the details' menu, and "No Request
/// Selected" while there's none. When the pane is narrow, the tabs move under the pages, as
/// libadwaita's view switchers do. The window shows ``widget`` beside the list, or over it when the
/// window is narrow.
///
/// Each page is one scroller, holding a clamp and a box, ``pages``, which the page's own file
/// fills, through ``contents``, and where a body goes as a ``BodyView``. ``heading`` sits under the
/// header bar, above the pages, with the request's method and path, its Pin, Color and Comment
/// buttons, its host and its status. The details' menu, ``menu``, has the same, and Decrypt. The
/// chosen page stays for the next request.
///
/// The pane reads the request's details as you choose it, and again whenever its row changes, as
/// a live request's does, or each half second it's live and nothing else read it, as for one no
/// row shows, but not when only its pin, color or comment does: those come from the session's
/// list, whose copy is the latest. A page is built as it shows, and again only when
/// what it shows changes, keeping where it was scrolled to, and the focus; as a live request
/// changes, the page with the focus in it waits until the focus leaves it, or the request ends.
@MainActor
final class DetailsPane {
    /// The pages, in their tabs' order, which Ctrl+1 to Ctrl+5 follow.
    enum Page: String, CaseIterable {
        case overview, request, response, raw, timing

        var title: String {
            switch self {
            case .overview: "Overview"
            case .request: "Request"
            case .response: "Response"
            case .raw: "Raw"
            case .timing: "Timing"
            }
        }

        /// Its tab's icon, beside its title: what went up, what came down, the text, the clock.
        var icon: String {
            switch self {
            case .overview: "dialog-information-symbolic"
            case .request: "go-up-symbolic"
            case .response: "go-down-symbolic"
            case .raw: "text-x-generic-symbolic"
            case .timing: "preferences-system-time-symbolic"
            }
        }
    }

    /// The pane, in a breakpoint bin, which moves the tabs under the pages when it's narrow.
    let widget: Widget
    let headerBar: Widget
    /// The tabs: libadwaita 1.7's inline view switcher, or the view switcher before it.
    let switcher: Widget
    /// The tabs under the pages, while the pane is narrow.
    let switcherBar: Widget
    let menuButton: Widget
    /// The details' menu, a GMenu: Pin, Color and Comment, and Decrypt or Stop Decrypting the
    /// request's host.
    let menu: OpaquePointer
    /// Under the header bar, above the pages: the request's method and path, its marks, its host
    /// and its status. Hidden while there's no request.
    let heading: Widget
    let headingView: DetailsHeadingView
    /// The pages' AdwViewStack.
    let stack: OpaquePointer
    /// Each page's box, in its clamp, in its scroller.
    let pages: [Page: Widget]
    /// What each page's box holds, under Overview's comment, built again as what it shows
    /// changes.
    let contents: [Page: Widget]
    /// Each page's scroller, named by its title for screen readers.
    let scrollers: [Page: Widget]
    /// The request the pages show, or `nil` for none.
    private(set) var shown: ExchangeID?
    /// Its row, as the session's list last gave it, with the latest pin, color and comment.
    private(set) var summary: ExchangeSummary?
    /// Its details, once read.
    private(set) var details: ExchangeDetails?
    /// The pane's breakpoint: up to 550 sp wide, the tabs go under the pages.
    let narrow: OpaquePointer
    /// Overview's comment: its section, and the field you write in, which stay as the page is
    /// built again, so what you're writing does too.
    let commentSection: Widget
    let commentField: Widget
    /// The Request and Response pages' bodies, kept while the request shows.
    private(set) var bodies: [MessagePart: BodyView] = [:]
    /// How many times the pane has read a request's details, which the self-check counts.
    private(set) var reads = 0
    let model: AppModel
    /// The request's secrets you chose to show, which stay shown while it shows: each header, by
    /// its part and place; the cookies' values, by part; and the Raw page's.
    var shownHeaders: Set<String> = []
    var showsCookieValues: Set<MessagePart> = []
    var rawShowsSecrets = false
    /// "No Request Selected", or the pages.
    private let content: Widget
    private let none: Widget
    /// The details' actions, `details.<name>`, for the heading's buttons and the menu.
    private let actions: OpaquePointer
    private let colorAction: OpaquePointer
    /// The Color button's menu, and the details' menu's Color submenu: None and the seven colors.
    private let colors: OpaquePointer
    /// The details' menu's sections: Pin, Color and Comment; and Decrypt, while the session
    /// decrypts. Their entries change in place, as GTK adds a submenu twice when it's put in
    /// again.
    private let marksMenu: OpaquePointer
    private let httpsMenu: OpaquePointer
    /// The page you chose, which shows for each request that has it.
    private var chosen = Page.overview
    private var isChoosing = false
    /// What each page showed when it was built, so a page that would show the same stays.
    private var built: [Page: AnyHashable] = [:]
    /// The size of each body as the session last presented it, so a body that grows is presented
    /// again.
    private var presentedSizes: [MessagePart: Int] = [:]
    /// How many times each part's body was asked to be presented, so a presentation that lands
    /// after a later one, of a body that has grown since, is dropped.
    private var presentations: [MessagePart: Int] = [:]
    /// The request Add Comment asked to write a comment on, while you write it.
    private var writing: ExchangeID?
    /// Whether the comment field takes the focus once the request's row is read, as Add Comment
    /// asked before it was.
    private var focusesComment = false
    /// The request the comment field's words are about, and whether it has the focus.
    private var commentOf: ExchangeID?
    private var isInComment = false
    /// The menu's entries as they read now, so each changes only when its words do.
    private var menuEntries = ["Pin Request", "Add Comment…", ""]
    /// Each request shown counts up, so a read for one that's gone is dropped. One read at a time,
    /// and another after it when the row changed meanwhile.
    private var generation = 0
    private var isReading = false
    private var readsAgain = false
    /// When the pane last read the request, and the timer that reads a live request again while
    /// nothing else has for a while.
    private var lastRead = 0
    private var liveTimer: UInt32?
    /// The page a live request changed on while the keyboard's focus was in it, which is built
    /// again once the focus leaves it.
    private var waiting: Page?

    init(model: AppModel) {
        self.model = model
        DetailsStyles.install()
        stack = cast(adw_view_stack_new())
        var pages: [Page: Widget] = [:]
        var contents: [Page: Widget] = [:]
        var scrollers: [Page: Widget] = [:]
        for page in Page.allCases {
            let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18)!
            gtk_widget_set_margin_top(box, 18)
            gtk_widget_set_margin_bottom(box, 18)
            gtk_widget_set_margin_start(box, 12)
            gtk_widget_set_margin_end(box, 12)
            let filled = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18)!
            gtk_box_append(cast(box), filled)
            let clamp = adw_clamp_new()!
            adw_clamp_set_maximum_size(cast(clamp), 900)
            adw_clamp_set_child(cast(clamp), box)
            let scroller = DetailsBlocks.scroller(named: page.title)
            gtk_scrolled_window_set_child(cast(scroller), clamp)
            gtk_widget_set_vexpand(scroller, 1)
            adw_view_stack_add_titled_with_icon(stack, scroller, page.rawValue, page.title, page.icon)
            pages[page] = box
            contents[page] = filled
            scrollers[page] = scroller
        }
        self.pages = pages
        self.contents = contents
        self.scrollers = scrollers

        // libadwaita 1.7's inline switcher is a row of tabs, made for a header bar; the view
        // switcher before it is made for a window's own.
        typealias New = @convention(c) () -> Widget?
        typealias SetStack = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        if LibraryVersion.adwaita(atLeast: 7), let new = Newer.lookup("adw_inline_view_switcher_new", as: New.self),
            let setStack = Newer.lookup("adw_inline_view_switcher_set_stack", as: SetStack.self), let made = new()
        {
            switcher = made
            setStack(raw(made), raw(stack))
        } else {
            switcher = adw_view_switcher_new()
            adw_view_switcher_set_stack(cast(switcher), stack)
            adw_view_switcher_set_policy(cast(switcher), ADW_VIEW_SWITCHER_POLICY_WIDE)
        }
        colors = g_menu_new()
        menu = g_menu_new()
        marksMenu = g_menu_new()
        httpsMenu = g_menu_new()
        menuButton = gtk_menu_button_new()
        gtk_menu_button_set_icon_name(cast(menuButton), "view-more-symbolic")
        gtk_widget_set_tooltip_text(menuButton, "More")
        setAccessibleLabel(menuButton, "More")
        gtk_menu_button_set_menu_model(cast(menuButton), cast(menu))
        // The tabs, or the pane's title while they're under the pages: both stay in the header
        // bar, and the breakpoint shows one. GTK 4.14 warns as a widget that screen readers have
        // read is put in place again, which the tabs would be each time the pane widens.
        let title = adw_window_title_new("Details", nil)!
        gtk_widget_set_visible(title, 0)
        let titles = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_box_append(cast(titles), title)
        gtk_box_append(cast(titles), switcher)
        headerBar = adw_header_bar_new()
        adw_header_bar_set_title_widget(cast(headerBar), titles)
        adw_header_bar_pack_end(cast(headerBar), menuButton)

        heading = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
        gtk_widget_set_visible(heading, 0)
        headingView = DetailsHeadingView(heading, colors: colors)

        none = adw_status_page_new()
        adw_status_page_set_title(cast(none), "No Request Selected")
        adw_status_page_set_description(cast(none), "Select a request to see its details.")
        gtk_widget_add_css_class(none, "compact")
        content = gtk_stack_new()
        gtk_stack_add_named(cast(content), none, "none")
        gtk_stack_add_named(cast(content), cast(stack), "pages")

        switcherBar = adw_view_switcher_bar_new()
        adw_view_switcher_bar_set_stack(cast(switcherBar), stack)

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), headerBar)
        adw_toolbar_view_add_top_bar(cast(toolbar), heading)
        adw_toolbar_view_set_content(cast(toolbar), content)
        adw_toolbar_view_add_bottom_bar(cast(toolbar), switcherBar)
        widget = adw_breakpoint_bin_new()
        // The narrowest the details go, as on the Mac, and GNOME's shortest window.
        gtk_widget_set_size_request(widget, 320, 294)
        adw_breakpoint_bin_set_child(cast(widget), toolbar)

        // Five tabs, the details' menu and the window's buttons fit from about 515 pixels.
        let narrow = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 550sp"))!
        let setters: [(Widget, String, Bool)] = [
            (switcherBar, "reveal", true), (switcher, "visible", false), (title, "visible", true),
        ]
        for (object, property, value) in setters {
            Value.bool(value).with { adw_breakpoint_add_setter(narrow, cast(object), property, $0) }
        }
        adw_breakpoint_bin_add_breakpoint(cast(widget), narrow)
        self.narrow = narrow

        // Overview's comment, over what the page holds, shown once there's a comment or while you
        // write one.
        commentField = gtk_entry_new()
        gtk_entry_set_placeholder_text(cast(commentField), "Add a comment")
        setAccessibleLabel(commentField, "Comment")
        commentSection = DetailsBlocks.section("Comment", content: [commentField])
        g_object_ref_sink(raw(commentSection))
        gtk_widget_set_visible(commentSection, 0)
        gtk_box_prepend(cast(pages[.overview]), commentSection)

        actions = cast(g_simple_action_group_new())
        let stringType = g_variant_type_new("s")
        colorAction = g_simple_action_new_stateful("color", stringType, g_variant_new_string("none"))
        g_variant_type_free(stringType)
        gtk_widget_insert_action_group(widget, "details", cast(actions))
        addActions()
        makeMenus()

        connect(stack, "notify::visible-child-name") { [weak self] in self?.pageChanged() }
        connect(commentField, "activate") { [weak self] in self?.commentEntered() }
        let focus = gtk_event_controller_focus_new()!
        connect(focus, "enter") { [weak self] in self?.isInComment = true }
        connect(focus, "leave") { [weak self] in self?.commentLeft() }
        gtk_widget_add_controller(commentField, focus)
        for tabs in [switcher, switcherBar] {
            focusTabOnClick(tabs)
        }
        model.listen { [weak self] event in
            guard let self, let shown, case .rows(_, _, _, let steps) = event else { return }
            // A live request changes as it goes, and one a filter hides sends no change.
            if steps.contains(where: { Self.step($0, mentions: shown) }) || summary?.state.isFinished == false {
                read()
            }
        }
        model.https.observe { [weak self] in self?.httpsChanged() }
        show(nil)
    }

    /// The page that shows, or shows once there's a request: the one you chose.
    var page: Page { chosen }

    func show(page: Page) {
        chosen = page
        isChoosing = true
        adw_view_stack_set_visible_child_name(stack, chosen.rawValue)
        isChoosing = false
    }

    /// Whether `page` shows what it holds for the request shown, once its details are read.
    func isBuilt(_ page: Page) -> Bool {
        built[page] != nil && shown != nil && details?.exchange.id == shown
    }

    /// Shows `id`'s request, or "No Request Selected" for `nil`. A comment you were writing is
    /// saved first, on the request it was about.
    func show(_ id: ExchangeID?) {
        if id == shown, id != nil {
            return
        }
        saveComment()
        shown = id
        generation += 1
        if let liveTimer {
            g_source_remove(liveTimer)
            self.liveTimer = nil
        }
        summary = nil
        details = nil
        built = [:]
        waiting = nil
        presentedSizes = [:]
        shownHeaders = []
        showsCookieValues = []
        rawShowsSecrets = false
        writing = nil
        focusesComment = false
        commentOf = nil
        // The bodies' views go while their widgets are still there, which go with the pages'.
        let leaving = bodies.values.map(\.widget)
        for widget in leaving {
            g_object_ref(raw(widget))
        }
        bodies = [:]
        for box in contents.values {
            DetailsBlocks.empty(box)
        }
        for widget in leaving {
            g_object_unref(raw(widget))
        }
        gtk_widget_set_visible(commentSection, 0)
        let pagesView: Widget = cast(stack)
        gtk_stack_set_visible_child(cast(content), id == nil ? none : pagesView)
        adw_header_bar_set_show_title(cast(headerBar), cBool(id != nil))
        gtk_widget_set_visible(switcherBar, cBool(id != nil))
        gtk_widget_set_visible(heading, 0)
        gtk_widget_set_sensitive(menuButton, cBool(id != nil))
        updateActions()
        if id != nil {
            read()
        }
    }

    // MARK: - Reading the request

    /// Reads the request's row, and its details when anything but its pin, color or comment has
    /// changed since, then shows them.
    private func read() {
        guard let id = shown, let session = model.session else { return }
        guard !isReading else {
            readsAgain = true
            return
        }
        isReading = true
        readsAgain = false
        lastRead = monotonicMicroseconds()
        let generation = generation
        let before = details == nil ? nil : summary
        Task { [weak self] in
            let summary = await session.rows([id]).first
            var read: ExchangeDetails?
            if let summary, summary.differsInDetails(from: before) {
                self?.reads += 1
                read = try? await session.details(id)
            }
            guard let self else { return }
            isReading = false
            if generation == self.generation, let summary {
                apply(summary, read)
            }
            if readsAgain || generation != self.generation {
                self.read()
            }
        }
    }

    /// Shows the request's latest row, and its details, when they were read again.
    private func apply(_ summary: ExchangeSummary, _ read: ExchangeDetails?) {
        self.summary = summary
        if let read {
            details = read
        }
        followLive()
        guard let details else { return }
        headingView.show(
            DetailsHeading(summary, reason: details.exchange.response?.reason, grpc: details.grpc),
            annotation: summary.annotation)
        gtk_widget_set_visible(heading, 1)
        showComment()
        if focusesComment {
            focusesComment = false
            focusComment()
        }
        updateActions()
        refresh(visiblePage, waitsForFocus: true)
    }

    /// While the request is live, it's read again each half second nothing else has read it, as
    /// rows events say nothing of one no row shows, such as one the sidebar's scope or a search
    /// hides.
    private func followLive() {
        let isLive = summary?.state.isFinished == false
        if !isLive, let liveTimer {
            g_source_remove(liveTimer)
            self.liveTimer = nil
        }
        guard isLive, liveTimer == nil else { return }
        liveTimer = timeout(500) { [weak self] in
            guard let self else { return false }
            if monotonicMicroseconds() - lastRead >= 450_000 {
                read()
            }
            return true
        }
    }

    /// Whether a rows event's step is about `id`'s row.
    private static func step(_ step: RowStep, mentions id: ExchangeID) -> Bool {
        switch step {
        case .changed(let ids), .reset(let ids): ids.contains(id)
        case .inserted(let rows): rows.contains { $0.id == id }
        case .removed: false
        }
    }

    // MARK: - The pages

    /// The page that shows.
    private var visiblePage: Page {
        Page(rawValue: string(adw_view_stack_get_visible_child_name(stack)) ?? "") ?? .overview
    }

    /// You chose a tab, or a shortcut did.
    private func pageChanged() {
        if !isChoosing {
            chosen = visiblePage
        }
        refresh(visiblePage)
    }

    /// Builds `page` again if what it would show has changed since it was built. When it
    /// `waitsForFocus`, as for a live request that changed as it goes, the page with the keyboard's
    /// focus in it waits until the focus leaves it, or the request ends: built again, the widget
    /// that had the focus would go, and screen readers would say the one in its place each time.
    func refresh(_ page: Page, waitsForFocus: Bool = false) {
        guard let details, summary != nil, details.exchange.id == shown else { return }
        switch page {
        case .overview: rebuild(page, showing: overviewContent(details), buildOverview, waitsForFocus)
        case .request: rebuild(page, showing: messageContent(details, .request), buildMessage, waitsForFocus)
        case .response: rebuild(page, showing: messageContent(details, .response), buildMessage, waitsForFocus)
        case .raw: rebuild(page, showing: rawContent(details), buildRaw, waitsForFocus)
        case .timing: rebuild(page, showing: timingContent(details), buildTiming, waitsForFocus)
        }
    }

    /// The keyboard's focus moved, as the window hears: a page that waited for it to leave is built
    /// now.
    func focusMoved() {
        guard let page = waiting else { return }
        guard page == visiblePage, let box = contents[page] else {
            // Another page shows, which is built as it shows.
            waiting = nil
            return
        }
        let focus = gtk_widget_get_root(widget).flatMap { gtk_root_get_focus($0) }
        guard focus.map({ gtk_widget_is_ancestor($0, box) == 0 }) ?? true else { return }
        waiting = nil
        refresh(page)
    }

    /// Builds `page` with `build` from `what`, unless it showed `what` already, or unless it
    /// `waitsForFocus` while the live request it shows has the keyboard's focus in it. Built again
    /// for the same request, the page stays where it was scrolled to, and the widget in the place
    /// of the one that had the focus has it. A body's view stays as it was, as `build` puts it back.
    private func rebuild<What: Hashable>(
        _ page: Page, showing what: What, _ build: (What, Widget) -> Void, _ waitsForFocus: Bool
    ) {
        let key = AnyHashable(what)
        guard built[page] != key, let box = contents[page], let scroller = scrollers[page] else { return }
        let isSameRequest = built[page] != nil
        let focus = gtk_widget_get_root(widget).flatMap { gtk_root_get_focus($0) }
        if waitsForFocus, isSameRequest, summary?.state.isFinished == false,
            let focus, gtk_widget_is_ancestor(focus, box) != 0
        {
            waiting = page
            return
        }
        if waiting == page {
            waiting = nil
        }
        built[page] = key
        let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller))
        let scrolled = isSameRequest ? gtk_adjustment_get_value(adjustment) : 0
        let place = focus.flatMap { Self.focusables(in: box).firstIndex(of: $0) }
        // Held while the page is emptied, for `build` to put back.
        let kept = bodies.filter { gtk_widget_is_ancestor($0.value.widget, box) != 0 }
        for view in kept.values {
            g_object_ref(raw(view.widget))
            gtk_box_remove(cast(gtk_widget_get_parent(view.widget)), view.widget)
        }
        DetailsBlocks.empty(box)
        build(what, box)
        for (part, view) in kept {
            if gtk_widget_get_parent(view.widget) == nil {
                bodies[part] = nil
            }
            g_object_unref(raw(view.widget))
        }
        // Once the page is laid out again.
        idle {
            gtk_adjustment_set_value(adjustment, scrolled)
            if let place {
                let focusables = Self.focusables(in: box)
                if !focusables.isEmpty {
                    gtk_widget_grab_focus(focusables[min(place, focusables.count - 1)])
                }
            }
            return false
        }
    }

    /// The widgets in `root` that take the keyboard's focus, in the order Tab reaches them.
    static func focusables(in root: Widget) -> [Widget] {
        var found: [Widget] = []
        var child = gtk_widget_get_first_child(root)
        while let widget = child {
            if gtk_widget_get_visible(widget) != 0 {
                if gtk_widget_get_focusable(widget) != 0 {
                    found.append(widget)
                }
                found += focusables(in: widget)
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return found
    }

    /// The view of `part`'s body, made the first time, which the session presents the body to
    /// again whenever the body has grown since. It shows in the mode you chose last for the part's
    /// bodies, while the body has it, as the view keeps that.
    func bodyView(_ part: MessagePart, size: Int) -> BodyView? {
        guard let id = shown, let session = model.session else { return nil }
        let view = bodies[part] ?? BodyView(model: model, id: id, part: part)
        bodies[part] = view
        if presentedSizes[part] != size {
            presentedSizes[part] = size
            presentations[part, default: 0] += 1
            let generation = generation
            let asked = presentations[part]
            Task { [weak self, weak view] in
                let presented = try? await session.presentBody(id, part: part == .request ? .request : .response)
                // The latest asked for, as an older one can land after it.
                guard let self, let view, let presented, generation == self.generation,
                    asked == self.presentations[part]
                else { return }
                view.show(presented)
            }
        }
        return view
    }

    // MARK: - The comment

    /// Add Comment, from the heading, the details' menu or the list's: Overview, with the comment
    /// field shown, which has the focus once it shows. For a request whose row isn't read yet, as
    /// from the menu of a row that wasn't shown, the field waits for the row and its comment:
    /// empty, it would save that over the comment as you leave it.
    func editComment() {
        guard shown != nil else { return }
        writing = shown
        show(page: .overview)
        guard summary != nil else {
            focusesComment = true
            return
        }
        showComment()
        focusComment()
    }

    /// Gives the comment field the keyboard's focus, now or once it shows, while you write the
    /// comment.
    private func focusComment() {
        guard let id = writing else { return }
        let field = commentField
        if gtk_widget_get_mapped(field) != 0 {
            gtk_widget_grab_focus(field)
            return
        }
        let handler = HandlerID()
        handler.id = connect(field, "map") { [weak self] in
            g_signal_handler_disconnect(raw(field), handler.id)
            guard self?.writing == id else { return }
            idle {
                gtk_widget_grab_focus(field)
                return false
            }
        }
    }

    /// The comment section shows once the request has a comment, or while you write one, with the
    /// request's comment in it, unless you're in it. A comment removed elsewhere while you're in
    /// its field takes what the field says with it, and the Comment button has the focus, rather
    /// than the hidden field, which would save it again as you leave. The field is about the
    /// request once its row is read, and takes its comment then, even with the focus, which
    /// libadwaita may give it as the details open over the list.
    private func showComment() {
        let comment = summary?.annotation.comment
        let about = summary == nil ? nil : shown
        let shows = comment != nil || (writing != nil && writing == shown)
        if !shows, isInComment, commentOf != nil {
            isInComment = false
            gtk_editable_set_text(cast(commentField), "")
            commentOf = about
            gtk_widget_grab_focus(headingView.commentButton)
        }
        gtk_widget_set_visible(commentSection, cBool(shows))
        guard !isInComment || commentOf == nil else { return }
        gtk_editable_set_text(cast(commentField), comment ?? "")
        commentOf = about
    }

    /// Enter saves the comment. With nothing in it, the comment goes, and so does its section, and
    /// the Comment button has the focus.
    private func commentEntered() {
        saveComment()
        writing = nil
        if summary?.annotation.comment == nil {
            isInComment = false
            gtk_widget_grab_focus(headingView.commentButton)
        }
        showComment()
    }

    /// Leaving the field saves the comment. The window going inactive leaves the focus in the
    /// field, as while the menu Add Comment… came from closes, so you're still writing. So does
    /// leaving it before the request's row is read, as libadwaita gives it the focus it had in
    /// the details as they open over the list, and takes it away: you haven't written in it yet.
    private func commentLeft() {
        let focus = gtk_widget_get_root(commentField).flatMap { gtk_root_get_focus($0) }
        if let focus, focus == commentField || gtk_widget_is_ancestor(focus, commentField) != 0 {
            return
        }
        isInComment = false
        guard commentOf != nil else { return }
        saveComment()
        if writing == shown {
            writing = nil
        }
        showComment()
    }

    /// Saves what the field says as the comment of the request it's about, when that differs: an
    /// empty one removes it. The heading and the list show it at once.
    private func saveComment() {
        guard let id = commentOf, id == shown, let session = model.session else { return }
        let text = string(gtk_editable_get_text(cast(commentField))) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = trimmed.isEmpty ? nil : trimmed
        guard comment != summary?.annotation.comment else { return }
        summary?.annotation.comment = comment
        annotated()
        Task { try? await session.annotate(id, comment: .set(text)) }
    }

    // MARK: - Actions and the menu

    private func addActions() {
        add("pin") { [weak self] in self?.togglePin() }
        add("comment") { [weak self] in self?.editComment() }
        add("decrypt") { [weak self] in self?.toggleDecrypting() }
        connect(colorAction, "activate") { [weak self] (arguments: Arguments) in
            guard let name = arguments.variant(1).flatMap({ string(g_variant_get_string($0, nil)) }) else { return }
            self?.mark(MarkColor(rawValue: name))
        }
        g_action_map_add_action(cast(actions), cast(colorAction))
    }

    /// Adds the action `details.<name>`, which runs `body`.
    private func add(_ name: String, _ body: @escaping @MainActor () -> Void) {
        let action = g_simple_action_new(name, nil)!
        connect(action, "activate") { body() }
        g_action_map_add_action(cast(actions), cast(action))
        g_object_unref(raw(action))
    }

    private func action(_ name: String) -> OpaquePointer? {
        g_action_map_lookup_action(cast(actions), name)
    }

    /// The colors: None, then the seven. And the details' menu: Pin or Unpin Request, Color and
    /// Add or Edit Comment…, then Decrypt or Stop Decrypting the host.
    private func makeMenus() {
        g_menu_append(colors, "None", "details.color::none")
        let marks = g_menu_new()!
        for color in MarkColor.allCases {
            g_menu_append(marks, color.title, "details.color::\(color.rawValue)")
        }
        g_menu_append_section(colors, nil, cast(marks))
        g_object_unref(raw(marks))
        g_menu_append(marksMenu, "Pin Request", "details.pin")
        g_menu_append_submenu(marksMenu, "Color", cast(colors))
        g_menu_append(marksMenu, "Add Comment…", "details.comment")
        g_menu_append_section(menu, nil, cast(marksMenu))
        g_menu_append_section(menu, nil, cast(httpsMenu))
    }

    /// The actions on while there's a request, and Decrypt while this session decrypts and the
    /// request is HTTPS; and the menu's entries as they fit the request: Pin or Unpin Request,
    /// Color, Add or Edit Comment…, then Decrypt or Stop Decrypting its host.
    private func updateActions() {
        let annotation = summary?.annotation ?? Annotation()
        let host = details?.exchange.request.host ?? ""
        // HTTPS is all there is to decrypt, as in the row's menu.
        let isHTTPS = details?.exchange.request.scheme == "https"
        let decrypts = host.isEmpty || !isHTTPS ? nil : model.https.decrypts(host)
        // The menu reads an underscore as the next letter's shortcut.
        let shownHost = host.replacingOccurrences(of: "_", with: "__")
        let hasRequest = shown != nil && summary != nil
        for name in ["pin", "comment"] {
            g_simple_action_set_enabled(action(name), cBool(hasRequest))
        }
        g_simple_action_set_enabled(colorAction, cBool(hasRequest))
        g_simple_action_set_enabled(action("decrypt"), cBool(hasRequest && decrypts != nil))
        g_simple_action_set_state(colorAction, g_variant_new_string(annotation.color?.rawValue ?? "none"))
        let entries = [
            annotation.isPinned ? "Unpin Request" : "Pin Request",
            annotation.comment == nil ? "Add Comment…" : "Edit Comment…",
            decrypts.map { $0 ? "Stop Decrypting \(shownHost)" : "Decrypt \(shownHost)" } ?? "",
        ]
        // Pin's is the first of its section, and Comment's the third, after Color.
        for (index, place) in [(0, 0), (1, 2)] where entries[index] != menuEntries[index] {
            g_menu_remove(marksMenu, Int32(place))
            g_menu_insert(marksMenu, Int32(place), entries[index], index == 0 ? "details.pin" : "details.comment")
        }
        if entries[2] != menuEntries[2] {
            g_menu_remove_all(httpsMenu)
            if !entries[2].isEmpty {
                g_menu_append(httpsMenu, entries[2], "details.decrypt")
            }
        }
        menuEntries = entries
    }

    private func togglePin() {
        guard let id = shown, let isPinned = summary.map({ !$0.annotation.isPinned }), let session = model.session
        else { return }
        summary?.annotation.isPinned = isPinned
        annotated()
        Task { try? await session.annotate(id, isPinned: isPinned) }
    }

    private func mark(_ color: MarkColor?) {
        guard let id = shown, summary != nil, let session = model.session else { return }
        summary?.annotation.color = color
        annotated()
        let change: ValueChange<MarkColor> = color.map { .set($0) } ?? .remove
        Task { try? await session.annotate(id, color: change) }
    }

    /// Shows a pin, color or comment you just chose, before the list's row says so too.
    private func annotated() {
        if let summary {
            headingView.show(summary.annotation)
        }
        updateActions()
    }

    private func toggleDecrypting() {
        guard let host = details?.exchange.request.host, let decrypts = model.https.decrypts(host) else { return }
        decrypt(!decrypts, host)
    }

    /// Decrypts `host` from now on, or stops, as the menu and Overview's note do.
    func decrypt(_ isOn: Bool, _ host: String) {
        let https = model.https
        Task { await https.setDecrypts(isOn, host: host) }
    }

    /// The hosts to decrypt changed: the menu and Overview's note say what happens now.
    private func httpsChanged() {
        updateActions()
        refresh(visiblePage)
    }

    // MARK: - The tabs

    /// Gives the keyboard's focus to the tab of the page that shows, in the header bar or under the
    /// pages, whichever shows, and says whether it could.
    @discardableResult
    func focusTab() -> Bool {
        guard shown != nil else { return false }
        for tabs in [switcher, switcherBar] where gtk_widget_is_visible(tabs) != 0 {
            if let tab = Self.chosenTab(in: tabs), gtk_widget_grab_focus(tab) != 0 {
                return true
            }
        }
        return false
    }

    /// The tab that's on among `tabs`, the button that takes the focus and shows checked.
    private static func chosenTab(in tabs: Widget) -> Widget? {
        var child = gtk_widget_get_first_child(tabs)
        while let widget = child {
            let isChecked = gtk_widget_get_state_flags(widget).rawValue & GTK_STATE_FLAG_CHECKED.rawValue != 0
            if gtk_widget_get_focusable(widget) != 0, isChecked, gtk_widget_get_mapped(widget) != 0 {
                return widget
            }
            if let found = chosenTab(in: widget) {
                return found
            }
            child = gtk_widget_get_next_sibling(widget)
        }
        return nil
    }

    /// A click on a tab gives it the keyboard's focus, as a click on a button does, which
    /// libadwaita's tabs don't: the widget clicked that takes the focus has it, before the tab
    /// sees the click.
    private func focusTabOnClick(_ tabs: Widget) {
        let click = gtk_gesture_click_new()!
        gtk_event_controller_set_propagation_phase(cast(click), GTK_PHASE_CAPTURE)
        connect(click, "pressed") { (arguments: Arguments) in
            var picked = gtk_widget_pick(tabs, arguments.double(2), arguments.double(3), GTK_PICK_DEFAULT)
            while let found = picked, found != tabs {
                if gtk_widget_get_focusable(found) != 0 {
                    gtk_widget_grab_focus(found)
                    return
                }
                picked = gtk_widget_get_parent(found)
            }
        }
        gtk_widget_add_controller(tabs, cast(click))
    }
}

/// A signal handler's ID, for a handler that disconnects itself.
@MainActor
private final class HandlerID {
    var id: UInt = 0
}
