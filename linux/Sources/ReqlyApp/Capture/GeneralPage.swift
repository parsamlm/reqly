import AppSetup
import CGtk
import GtkBinding

extension SettingsDialog {
    /// Settings › General: the port Reqly captures on, and whether capturing starts when Reqly
    /// opens. Each change is saved at once.
    func generalPage() -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(cast(page), "General")
        adw_preferences_page_set_icon_name(cast(page), "preferences-system-symbolic")
        let capture = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(capture), "Capture")

        let port = adw_spin_row_new_with_range(1024, 65535, 1)!
        adw_preferences_row_set_title(cast(port), "Port")
        adw_spin_row_set_value(cast(port), Double(model.settings.proxyPort))
        connect(port, "notify::value") { [weak self] in
            let value = Int(adw_spin_row_get_value(cast(port)))
            self?.save { $0.proxyPort = value }
        }
        adw_preferences_group_add(cast(capture), port)

        let starts = adw_switch_row_new()!
        adw_preferences_row_set_title(cast(starts), "Start Capturing When Reqly Opens")
        adw_switch_row_set_active(cast(starts), cBool(model.settings.startsCapturingOnLaunch))
        connect(starts, "notify::active") { [weak self] in
            let isOn = adw_switch_row_get_active(cast(starts)) != 0
            self?.save { $0.startsCapturingOnLaunch = isOn }
        }
        adw_preferences_group_add(cast(capture), starts)

        adw_preferences_page_add(cast(page), cast(capture))
        return page
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do {
            try model.changeSettings(change)
        } catch {
            toast("Reqly couldn't save its settings. \(error.localizedDescription)")
        }
    }
}
