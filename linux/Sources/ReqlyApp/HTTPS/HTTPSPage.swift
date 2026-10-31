import CGtk
import GtkBinding

extension SettingsDialog {
    /// Settings › HTTPS: Reqly's certificate, and whether it's trusted.
    func httpsPage() -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(cast(page), "HTTPS")
        adw_preferences_page_set_icon_name(cast(page), "channel-secure-symbolic")
        let certificate = adw_preferences_group_new()!
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(cast(row), "Reqly's Certificate")
        let status =
            switch model.https.state?.status {
            case .trusted: "Trusted"
            case .notTrusted: "Not trusted"
            case .notSetUp: "Not set up"
            case nil: model.https.problem ?? "Not known yet"
            }
        adw_action_row_set_subtitle(cast(row), status)
        adw_preferences_group_add(cast(certificate), row)
        adw_preferences_page_add(cast(page), cast(certificate))
        return page
    }
}
