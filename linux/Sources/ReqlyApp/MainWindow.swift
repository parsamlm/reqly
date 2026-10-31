import CGtk
import CoreInterface
import Foundation
import GtkBinding

/// The window: an AdwApplicationWindow with a toast overlay around a toolbar view, with the header
/// bar, which holds the capture switch and the main menu; the request list; and the status line.
///
/// What the switch, the menu's entries and the list do belongs to the features, in their own
/// folders: capturing in `Capture/`, the terminal in `Terminal/`, HTTPS in `HTTPS/` and the list
/// in `Traffic/`. App.swift registers the menu's actions in one place.
@MainActor
final class MainWindow {
    unowned let app: App
    let model: AppModel
    let window: Widget
    let headerBar: Widget
    let captureSwitch: Widget
    let menuButton: Widget
    /// The main menu's model, a GMenu of sections.
    let menu: OpaquePointer
    let list: RequestList
    let statusLine: Widget
    let statusLabel: Widget
    private let statusDot: Widget
    private let toasts: Widget
    /// Whether the switch is being set to the model's state, rather than by you.
    private var isShowingCapture = false
    /// Settings and Set Up HTTPS…, each made the first time it opens and kept, as they keep
    /// their pages.
    private(set) var settings: SettingsDialog?
    private(set) var setUp: SetUpDialog?
    private(set) var about: Widget?

    init(app: App) {
        self.app = app
        model = app.model
        window = adw_application_window_new(cast(app.application))
        gtk_window_set_title(cast(window), "Reqly")
        gtk_window_set_icon_name(cast(window), App.id)
        gtk_window_set_default_size(cast(window), 1000, 700)
        // The smallest size GNOME's adaptive windows design for.
        gtk_widget_set_size_request(window, 360, 294)

        // The header bar: the capture switch at the start, the main menu at the end.
        headerBar = adw_header_bar_new()
        let capture = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let captureLabel = gtk_label_new("Capture")!
        captureSwitch = gtk_switch_new()
        gtk_widget_set_valign(captureSwitch, GTK_ALIGN_CENTER)
        setAccessibleLabel(captureSwitch, "Capture Traffic")
        gtk_box_append(cast(capture), captureLabel)
        gtk_box_append(cast(capture), captureSwitch)
        gtk_widget_set_margin_start(capture, 6)
        adw_header_bar_pack_start(cast(headerBar), capture)

        menu = g_menu_new()
        let tools = g_menu_new()!
        g_menu_append(tools, "Set Up HTTPS…", "app.set-up-https")
        g_menu_append(tools, "Open Terminal", "app.open-terminal")
        g_menu_append(tools, "Copy Terminal Setup", "app.copy-terminal-setup")
        let general = g_menu_new()!
        g_menu_append(general, "Settings", "app.settings")
        g_menu_append(general, "About Reqly", "app.about")
        g_menu_append(general, "Quit", "app.quit")
        for section in [tools, general] {
            g_menu_append_section(menu, nil, cast(section))
            g_object_unref(raw(section))
        }
        menuButton = gtk_menu_button_new()
        gtk_menu_button_set_icon_name(cast(menuButton), "open-menu-symbolic")
        gtk_widget_set_tooltip_text(menuButton, "Main Menu")
        // F10 opens it.
        gtk_menu_button_set_primary(cast(menuButton), 1)
        gtk_menu_button_set_menu_model(cast(menuButton), cast(menu))
        adw_header_bar_pack_end(cast(headerBar), menuButton)

        list = RequestList(model: model)

        // The status line: a dot that shows while Reqly captures, and what it's doing.
        statusLine = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)
        gtk_widget_add_css_class(statusLine, "status-line")
        statusDot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(statusDot, "status-dot")
        gtk_widget_set_valign(statusDot, GTK_ALIGN_CENTER)
        statusLabel = gtk_label_new(nil)
        gtk_label_set_xalign(cast(statusLabel), 0)
        gtk_label_set_ellipsize(cast(statusLabel), PANGO_ELLIPSIZE_END)
        gtk_box_append(cast(statusLine), statusDot)
        gtk_box_append(cast(statusLine), statusLabel)

        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), headerBar)
        adw_toolbar_view_set_content(cast(toolbar), list.widget)
        adw_toolbar_view_add_bottom_bar(cast(toolbar), statusLine)
        toasts = adw_toast_overlay_new()
        adw_toast_overlay_set_child(cast(toasts), toolbar)
        adw_application_window_set_content(cast(window), toasts)

        connect(captureSwitch, "notify::active") { [weak self] in
            guard let self, !self.isShowingCapture else { return }
            self.captureSwitched(on: gtk_switch_get_active(cast(self.captureSwitch)) != 0)
        }
        // Closing the window quits Reqly, once capturing has stopped.
        connect(window, "close-request") { [weak self] (arguments: Arguments) in
            self?.app.quit()
            arguments.returns(true)
        }
        model.observe { [weak self] in self?.update() }
        model.listen { [weak self] event in
            if case .storageProblem(let problem?) = event {
                self?.toast(problem)
            }
        }
        update()
    }

    func present() {
        gtk_window_present(cast(window))
    }

    /// Shows a short message at the bottom of the window, which goes by itself.
    func toast(_ text: String) {
        adw_toast_overlay_add_toast(cast(toasts), adw_toast_new(text))
    }

    /// Shows the switch and the status line as the model has them.
    private func update() {
        let isOn = model.capture == .starting || model.capture == .capturing
        isShowingCapture = true
        gtk_switch_set_active(cast(captureSwitch), cBool(isOn))
        isShowingCapture = false
        // It waits for a start or a stop, and for the session.
        let canSwitch = model.session != nil && (model.capture == .stopped || model.capture == .capturing)
        gtk_widget_set_sensitive(captureSwitch, cBool(canSwitch))
        let status = model.statusText
        gtk_label_set_text(cast(statusLabel), status)
        // The line may be cut short, advice and all, in a narrow window.
        gtk_widget_set_tooltip_text(statusLabel, status)
        if model.isCapturing {
            gtk_widget_add_css_class(statusDot, "capturing")
        } else {
            gtk_widget_remove_css_class(statusDot, "capturing")
        }
    }

    // MARK: - Dialogs

    /// Settings, over the window.
    func showSettings() {
        let settings = settings ?? SettingsDialog(model: model)
        self.settings = settings
        guard !settings.isShowing else { return }
        settings.present(over: window)
    }

    /// Set Up HTTPS…, over the window.
    func showSetUp() {
        let setUp = setUp ?? SetUpDialog(https: model.https)
        self.setUp = setUp
        guard !setUp.isShowing else { return }
        setUp.present(over: window)
    }

    /// About Reqly: its name, version, website and license.
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
        adw_about_dialog_set_copyright(dialog, "Copyright © 2026 The Reqly Authors")
        adw_about_dialog_set_license_type(dialog, GTK_LICENSE_MIT_X11)
        self.about = about
        connect(about, "closed") { [weak self] in self?.about = nil }
        adw_dialog_present(cast(about), window)
    }
}
