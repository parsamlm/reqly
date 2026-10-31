import CGtk
import GtkBinding

/// Settings: an AdwPreferencesDialog whose pages come from the features that own them, General
/// from capturing (`Capture/GeneralPage.swift`) and HTTPS from HTTPS decryption
/// (`HTTPS/HTTPSPage.swift`).
@MainActor
final class SettingsDialog {
    let model: AppModel
    let dialog: Widget
    /// The pages' titles, in order.
    private(set) var pageTitles: [String] = []

    init(model: AppModel) {
        self.model = model
        dialog = cast(adw_preferences_dialog_new())
        adw_dialog_set_title(cast(dialog), "Settings")
        add(generalPage())
        add(httpsPage())
    }

    private func add(_ page: Widget) {
        adw_preferences_dialog_add(cast(dialog), cast(page))
        pageTitles.append(string(adw_preferences_page_get_title(cast(page))) ?? "")
    }

    /// Shows a short message at the bottom of the dialog, which covers the window's own.
    func toast(_ text: String) {
        adw_preferences_dialog_add_toast(cast(dialog), adw_toast_new(text))
    }
}
