import CGtk
import GtkBinding

/// Settings: an AdwPreferencesDialog whose pages come from the features that own them, General
/// from capturing (`Capture/GeneralPage.swift`) and HTTPS from HTTPS decryption
/// (`HTTPS/HTTPSPage.swift`).
///
/// The window makes it once and presents it again each time, and each page shows things as they
/// are then. libadwaita never frees a page that has been in a dialog, so a new dialog each time
/// would keep every page made before, each still following the model.
@MainActor
final class SettingsDialog {
    let model: AppModel
    let dialog: Widget
    /// Settings › HTTPS.
    private(set) var httpsPage: HTTPSPage?
    /// The pages' titles, in order.
    private(set) var pageTitles: [String] = []
    /// Whether it's open, over the window.
    private(set) var isShowing = false
    /// What each page does as Settings opens.
    private var presenting: [@MainActor () -> Void] = []

    init(model: AppModel) {
        self.model = model
        dialog = cast(adw_preferences_dialog_new())
        // Kept for as long as the window is, rather than freed as it closes.
        g_object_ref_sink(raw(dialog))
        adw_dialog_set_title(cast(dialog), "Settings")
        add(generalPage())
        let https = HTTPSPage(settings: self, https: model.https)
        httpsPage = https
        add(https.page)
        connect(dialog, "closed") { [weak self] in self?.isShowing = false }
    }

    private func add(_ page: Widget) {
        adw_preferences_dialog_add(cast(dialog), cast(page))
        pageTitles.append(string(adw_preferences_page_get_title(cast(page))) ?? "")
    }

    /// Shows Settings over `window`, each page as things are now.
    func present(over window: Widget) {
        isShowing = true
        for body in presenting {
            body()
        }
        adw_dialog_present(cast(dialog), window)
    }

    /// Runs `body` each time Settings opens, such as to read what a page shows again.
    func whenPresented(_ body: @escaping @MainActor () -> Void) {
        presenting.append(body)
    }

    /// Shows a short message at the bottom of the dialog, which covers the window's own.
    func toast(_ text: String) {
        adw_preferences_dialog_add_toast(cast(dialog), adw_toast_new(text))
    }
}
