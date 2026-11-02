import AppSetup
import CGtk
import GtkBinding

extension SettingsDialog {
    /// The ports Reqly can listen on, as on the Mac and Windows: the ones above the well-known
    /// ports.
    static let ports = 1024...65535

    /// Settings › General: the port Reqly captures on, whether capturing starts when Reqly opens,
    /// and which of your desktop's proxy settings it changes. Each change is saved at once.
    func generalPage() -> Widget {
        let page = adw_preferences_page_new()!
        adw_preferences_page_set_title(cast(page), "General")
        adw_preferences_page_set_icon_name(cast(page), "preferences-system-symbolic")
        let capture = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(capture), "Capture")
        adw_preferences_group_set_description(cast(capture), proxyDescription())

        let port = adw_spin_row_new_with_range(Double(Self.ports.lowerBound), Double(Self.ports.upperBound), 1)!
        adw_preferences_row_set_title(cast(port), "Port")
        adw_spin_row_set_numeric(cast(port), 1)
        // A number out of range goes back to the port before, rather than to the nearest one.
        adw_spin_row_set_update_policy(cast(port), GTK_UPDATE_IF_VALID)
        adw_spin_row_set_value(cast(port), Double(model.settings.proxyPort))
        showPort(port, problem: nil)
        connect(port, "changed") { [weak self] in
            let isPort = Int(string(gtk_editable_get_text(cast(port))) ?? "").map(Self.ports.contains) ?? false
            let problem = "Enter a port from \(Self.ports.lowerBound) to \(Self.ports.upperBound)."
            self?.showPort(port, problem: isPort ? nil : problem)
        }
        connect(port, "notify::value") { [weak self] in
            let value = Int(adw_spin_row_get_value(cast(port)))
            self?.save { $0.proxyPort = value }
            self?.showPort(port, problem: nil)
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
        // Each time Settings opens: capturing may have started on another port since.
        whenPresented { [weak self] in
            guard let self else { return }
            adw_preferences_group_set_description(cast(capture), proxyDescription())
            adw_spin_row_set_value(cast(port), Double(model.settings.proxyPort))
            showPort(port, problem: nil)
        }
        return page
    }

    /// Which of your desktop's proxy settings capturing changes, as Windows' "Your network
    /// settings" says it.
    func proxyDescription() -> String {
        guard let settings = model.desktopProxy.partsToChange.settings else {
            return "This copy of Reqly doesn't change your proxy settings, so it captures only the apps you point at "
                + "127.0.0.1, port \(model.port)."
        }
        return "While capturing, Reqly points \(settings) at itself, and puts yours back when you stop, even if it "
            + "quits unexpectedly."
    }

    /// The port row's subtitle: what the port is for, why what you typed isn't one, or when a new
    /// port takes over from the one Reqly captures on.
    private func showPort(_ row: Widget, problem: String?) {
        let subtitle: String
        if let problem {
            subtitle = problem
            gtk_widget_add_css_class(row, "error")
        } else {
            gtk_widget_remove_css_class(row, "error")
            // Capturing keeps the port it started on until it starts again.
            let next = model.options.port ?? model.settings.proxyPort
            if let listening = model.listeningPort, listening != next {
                subtitle = "Reqly uses port \(next) the next time you start capturing."
            } else {
                subtitle = "Reqly listens on this port on your computer. Change it if another app already uses it."
            }
        }
        adw_action_row_set_subtitle(cast(row), subtitle)
    }

    private func save(_ change: (inout AppSettings) -> Void) {
        do {
            try model.changeSettings(change)
        } catch {
            toast("Reqly couldn't save its settings. \(error.localizedDescription)")
        }
    }
}
