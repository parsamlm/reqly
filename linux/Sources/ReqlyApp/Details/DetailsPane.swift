import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

/// The details pane: the selected request on five pages, Overview, Request, Response, Raw and
/// Timing, with their tabs in the pane's header bar, beside the details' menu, and "No Request
/// Selected" while there's none. When the pane is narrow, the tabs move under the pages, as
/// libadwaita's view switchers do. The window shows ``widget`` beside the list, or over it when the
/// window is narrow.
///
/// Each page is one scroller, holding a clamp and a box, ``pages``, which the page's own file
/// fills, and where a body goes as a ``BodyView``. ``heading`` sits under the header bar, above the
/// pages, for the request's method and path, its marks, its host and its status. The details' menu
/// is ``menu``. The chosen page stays for the next request.
///
/// So far ``show(_:)`` shows the pages, empty, or "No Request Selected".
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
    }

    /// The pane, in a breakpoint bin, which moves the tabs under the pages when it's narrow.
    let widget: Widget
    let headerBar: Widget
    /// The tabs: libadwaita 1.7's inline view switcher, or the view switcher before it.
    let switcher: Widget
    /// The tabs under the pages, while the pane is narrow.
    let switcherBar: Widget
    let menuButton: Widget
    /// The details' menu, a GMenu, which the details fill.
    let menu: OpaquePointer
    /// Under the header bar, above the pages: the request's method and path, its marks, its host
    /// and its status. Hidden while there's nothing in it.
    let heading: Widget
    /// The pages' AdwViewStack.
    let stack: OpaquePointer
    /// Each page's box, in its clamp, in its scroller.
    let pages: [Page: Widget]
    /// Each page's scroller, named by its title for screen readers.
    let scrollers: [Page: Widget]
    /// The request the pages show, or `nil` for none.
    private(set) var shown: ExchangeID?
    /// The pane's breakpoint: up to 550 sp wide, the tabs go under the pages.
    let narrow: OpaquePointer
    private let model: AppModel
    /// "No Request Selected", or the pages.
    private let content: Widget
    private let none: Widget

    init(model: AppModel) {
        self.model = model
        stack = cast(adw_view_stack_new())
        var pages: [Page: Widget] = [:]
        var scrollers: [Page: Widget] = [:]
        for page in Page.allCases {
            let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 18)!
            gtk_widget_set_margin_top(box, 18)
            gtk_widget_set_margin_bottom(box, 18)
            gtk_widget_set_margin_start(box, 12)
            gtk_widget_set_margin_end(box, 12)
            let clamp = adw_clamp_new()!
            adw_clamp_set_maximum_size(cast(clamp), 900)
            adw_clamp_set_child(cast(clamp), box)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            gtk_scrolled_window_set_child(cast(scroller), clamp)
            gtk_widget_set_vexpand(scroller, 1)
            setAccessibleLabel(scroller, page.title)
            adw_view_stack_add_titled(stack, scroller, page.rawValue, page.title)
            pages[page] = box
            scrollers[page] = scroller
        }
        self.pages = pages
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
        // Kept for as long as the window is: the breakpoint takes it out of the header bar while
        // the pane is narrow.
        g_object_ref_sink(raw(switcher))

        menu = g_menu_new()
        menuButton = gtk_menu_button_new()
        gtk_menu_button_set_icon_name(cast(menuButton), "view-more-symbolic")
        gtk_widget_set_tooltip_text(menuButton, "More")
        setAccessibleLabel(menuButton, "More")
        gtk_menu_button_set_menu_model(cast(menuButton), cast(menu))
        headerBar = adw_header_bar_new()
        adw_header_bar_set_title_widget(cast(headerBar), switcher)
        adw_header_bar_pack_end(cast(headerBar), menuButton)

        heading = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)
        gtk_widget_set_visible(heading, 0)

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
        narrow = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 550sp"))
        Value.bool(true).with { adw_breakpoint_add_setter(narrow, cast(switcherBar), "reveal", $0) }
        var noTitle = GValue()
        g_value_init(&noTitle, gtk_widget_get_type())
        adw_breakpoint_add_setter(narrow, cast(headerBar), "title-widget", &noTitle)
        g_value_unset(&noTitle)
        adw_breakpoint_bin_add_breakpoint(cast(widget), narrow)
        show(nil)
    }

    /// The page that shows, or shows once there's a request.
    var page: Page {
        Page(rawValue: string(adw_view_stack_get_visible_child_name(stack)) ?? "") ?? .overview
    }

    func show(page: Page) {
        adw_view_stack_set_visible_child_name(stack, page.rawValue)
    }

    /// Shows `id`'s request, or "No Request Selected" for `nil`, without its tabs.
    func show(_ id: ExchangeID?) {
        shown = id
        let pagesView: Widget = cast(stack)
        gtk_stack_set_visible_child(cast(content), id == nil ? none : pagesView)
        adw_header_bar_set_show_title(cast(headerBar), cBool(id != nil))
        gtk_widget_set_visible(switcherBar, cBool(id != nil))
        gtk_widget_set_sensitive(menuButton, cBool(id != nil))
    }
}
