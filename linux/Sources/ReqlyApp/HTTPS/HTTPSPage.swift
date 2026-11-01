import CGtk
import CoreInterface
import Foundation
import GtkBinding
import LinuxDesktop
import LinuxTrust
import ReqlyModel

/// Settings › HTTPS: whether Reqly decrypts, each place that trusts its certificate, what no place
/// reaches, where the key is, the hosts to decrypt, and removing the certificate. Settings keeps
/// it, and it follows the HTTPS model. It reads each place again each time Settings opens, since
/// Chrome may have made its database since, and the certificate too when the session couldn't
/// read it, as when your keyring stayed locked.
@MainActor
final class HTTPSPage {
    let page: Widget
    /// The certificate's status, with Set Up HTTPS… until a place trusts it.
    let statusRow: Widget
    let keyRow: Widget
    /// Each place's row, with its status, its Trust… button, and for the computer's list a button
    /// that copies the commands that do it by hand; or the test run's stand-in's row.
    private(set) var placeRows: [(kind: TrustPlace.Kind?, row: Widget, status: Widget, buttons: [Widget])] = []
    /// The fix for each app no place reaches, with its copy button.
    private(set) var uncovered: [(app: UncoveredApp, copy: Widget)] = []
    let everyHostRow: Widget
    let newHostRow: Widget
    /// Why the host typed can't join the list, in the session's words.
    let addProblem: Widget
    let removeButton: Widget
    /// Copies the commands that take the certificate out of the computer's list by hand, beside
    /// what a removal left, when Reqly can't ask for the password.
    let removeCommandsButton: Widget
    /// Remove Certificate…'s question, while it shows.
    private(set) var removeConfirmation: Widget?
    /// Whether the places have been read since the page opened.
    private(set) var isReady = false

    private weak var settings: SettingsDialog?
    private let https: HTTPSModel
    private let setUpButton: Widget
    /// What's left after a removal that didn't finish, and why, with the copy button.
    private let removeNote: Widget
    private let removeLeft: Widget
    private let placesGroup: Widget
    private let hostsGroup: Widget
    private let hostList: Widget
    private let noHosts: Widget
    private var hostRows: [HostPattern: Widget] = [:]
    private let progress: (box: Widget, label: Widget)
    /// Copies the lines that set up your shell for Reqly, as Copy Terminal Setup does.
    private let terminalSetupButton: Widget
    /// What the page itself waits for, such as a removal.
    private var waitingFor: String?
    /// Whether the switches are being set to the model's state, rather than by you.
    private var isShowing = false

    init(settings: SettingsDialog, https: HTTPSModel) {
        self.settings = settings
        self.https = https
        page = adw_preferences_page_new()
        adw_preferences_page_set_title(cast(page), "HTTPS")
        adw_preferences_page_set_name(cast(page), "https")
        adw_preferences_page_set_icon_name(cast(page), "channel-secure-symbolic")

        // The certificate: its status, and where its key is.
        let certificate = adw_preferences_group_new()!
        statusRow = HTTPSWidgets.row("Reqly's Certificate")
        setUpButton = HTTPSWidgets.suffixButton("Set Up HTTPS…")
        gtk_actionable_set_action_name(cast(setUpButton), "app.set-up-https")
        adw_action_row_add_suffix(cast(statusRow), setUpButton)
        keyRow = HTTPSWidgets.row("Reqly's Key")
        progress = HTTPSWidgets.progress()
        adw_preferences_group_add(cast(certificate), statusRow)
        adw_preferences_group_add(cast(certificate), keyRow)
        adw_preferences_group_add(cast(certificate), progress.box)

        placesGroup = adw_preferences_group_new()
        adw_preferences_group_set_title(cast(placesGroup), "Where It's Trusted")
        if !https.isStandIn {
            adw_preferences_group_set_description(
                cast(placesGroup),
                "Apps that are open keep the list they read when they started, so restart them after a change.")
        }

        // What no place reaches: a terminal set up for Reqly, then each kind of app's own fix.
        let notCovered = adw_preferences_group_new()!
        adw_preferences_group_set_title(cast(notCovered), "Not Covered")
        adw_preferences_group_set_description(
            cast(notCovered),
            "These keep a list of certificates of their own, so the places above don't reach them. A terminal set "
                + "up for Reqly covers most command-line tools, and each app below has its fix.")
        let terminal = HTTPSWidgets.row(
            "A Terminal Set Up for Reqly",
            "Sets the variables most command-line tools read, Node's and Python's included, for what you start "
                + "from it.")
        let openTerminal = HTTPSWidgets.suffixButton("Open Terminal")
        gtk_actionable_set_action_name(cast(openTerminal), "app.open-terminal")
        adw_action_row_add_suffix(cast(terminal), openTerminal)
        let model = settings.model
        let shell = TerminalSetup.Shell(shell: ProcessInfo.processInfo.environment["SHELL"])
        terminalSetupButton = HTTPSWidgets.copyButton(
            TerminalSetup(port: model.port, certificates: https.terminalCertificates).text(for: shell),
            label: "Copy Terminal Setup"
        ) { [weak settings] in settings?.toast(TerminalWords.copied(for: shell)) }
        adw_action_row_add_suffix(cast(terminal), terminalSetupButton)
        adw_preferences_group_add(cast(notCovered), terminal)

        // The hosts: a list with the new host's row last, so a host joins above it.
        hostsGroup = adw_preferences_group_new()
        adw_preferences_group_set_title(cast(hostsGroup), "Decrypt HTTPS for These Hosts")
        hostList = gtk_list_box_new()
        gtk_list_box_set_selection_mode(cast(hostList), GTK_SELECTION_NONE)
        gtk_widget_add_css_class(hostList, "boxed-list")
        noHosts = HTTPSWidgets.row("No hosts yet. Add one below.")
        gtk_widget_add_css_class(noHosts, "dim-label")
        newHostRow = adw_entry_row_new()
        adw_preferences_row_set_title(cast(newHostRow), "Add Host")
        adw_entry_row_set_show_apply_button(cast(newHostRow), 1)
        gtk_list_box_append(cast(hostList), noHosts)
        gtk_list_box_append(cast(hostList), newHostRow)
        addProblem = HTTPSWidgets.message("error")
        gtk_widget_set_margin_top(addProblem, 6)
        adw_preferences_group_add(cast(hostsGroup), hostList)
        adw_preferences_group_add(cast(hostsGroup), addProblem)

        let everyHost = adw_preferences_group_new()!
        everyHostRow = adw_switch_row_new()
        adw_preferences_row_set_title(cast(everyHostRow), "Decrypt All Hosts")
        adw_action_row_set_subtitle(
            cast(everyHostRow), "Not recommended. Some apps stop working when their traffic is decrypted.")
        adw_preferences_group_add(cast(everyHost), everyHostRow)

        let removal = adw_preferences_group_new()!
        removeButton = gtk_button_new_with_label("Remove Certificate…")
        gtk_widget_add_css_class(removeButton, "destructive-action")
        gtk_widget_set_halign(removeButton, GTK_ALIGN_START)
        removeNote = HTTPSWidgets.message("dim-label")
        gtk_widget_set_hexpand(removeNote, 1)
        removeCommandsButton = HTTPSWidgets.copyButton(
            https.commandsToRemoveByHand ?? "", label: "Copy the commands"
        ) { [weak settings] in settings?.toast("Copied") }
        gtk_widget_set_valign(removeCommandsButton, GTK_ALIGN_START)
        removeLeft = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)
        gtk_widget_set_margin_top(removeLeft, 6)
        gtk_box_append(cast(removeLeft), removeNote)
        gtk_box_append(cast(removeLeft), removeCommandsButton)
        gtk_widget_set_visible(removeLeft, 0)
        adw_preferences_group_add(cast(removal), removeButton)
        adw_preferences_group_add(cast(removal), removeLeft)

        for group in [certificate, placesGroup, notCovered, hostsGroup, everyHost, removal] {
            adw_preferences_page_add(cast(page), cast(group))
        }
        // A test run without a stand-in has no certificate, and no places or hosts.
        for group in [placesGroup, hostsGroup, everyHost] {
            gtk_widget_set_visible(group, cBool(https.isAvailable))
        }

        let apps = UncoveredApp.all(
            pemFile: https.pemFile, bundleFile: https.bundleFile, chromiumSnap: https.isChromiumSnapOutOfReach)
        for app in apps {
            let row = HTTPSWidgets.row(app.name, app.detail + "\n" + app.fix)
            adw_action_row_set_subtitle_selectable(cast(row), 1)
            let copy = HTTPSWidgets.copyButton(app.fix, label: "Copy the fix for \(app.name)") { [weak self] in
                self?.settings?.toast("Copied")
            }
            adw_action_row_add_suffix(cast(row), copy)
            adw_preferences_group_add(cast(notCovered), row)
            uncovered.append((app, copy))
        }

        connect(newHostRow, "apply") { [weak self] in self?.addHost() }
        connect(newHostRow, "entry-activated") { [weak self] in self?.addHost() }
        connect(newHostRow, "changed") { [weak self] in
            guard let self else { return }
            HTTPSWidgets.say(addProblem, nil)
        }
        connect(everyHostRow, "notify::active") { [weak self] in
            guard let self, !isShowing else { return }
            let isOn = adw_switch_row_get_active(cast(everyHostRow)) != 0
            Task { await self.https.setDecryptsEveryHost(isOn) }
        }
        connect(removeButton, "clicked") { [weak self] in self?.confirmRemoval() }
        https.observe { [weak self] in self?.show() }
        show()
        settings.whenPresented { [weak self] in self?.readAgain() }
    }

    /// Reads each place again, and the certificate when the session couldn't, as Settings opens.
    /// What an earlier removal left is said again only if it's still so.
    private func readAgain() {
        isReady = false
        HTTPSWidgets.say(removeNote, nil)
        gtk_widget_set_visible(removeLeft, 0)
        Task { [weak self] in
            guard let https = self?.https else { return }
            await https.readAgain()
            self?.isReady = true
            self?.show()
        }
    }

    // MARK: - Showing

    private func show() {
        isShowing = true
        defer { isShowing = false }
        showCertificate()
        if isReady {
            showPlaces()
        }
        showHosts()
        let isWorking = https.isWorking
        gtk_widget_set_visible(removeButton, cBool(https.hasCertificate))
        gtk_widget_set_sensitive(removeButton, cBool(!isWorking))
        gtk_widget_set_sensitive(setUpButton, cBool(!isWorking))
        HTTPSWidgets.show(progress, isWorking ? waitingFor ?? "Setting up HTTPS…" : nil)
    }

    private func showCertificate() {
        let status: String
        switch https.state?.status {
        case .trusted where https.isStandIn:
            status = "Decrypting. A test run's certificate, which counts as trusted. Nothing on this computer changed."
        case .trusted:
            let made = https.state?.created.map { "Made on \($0.formatted(date: .abbreviated, time: .omitted)). " }
            status = "Decrypting. \(made ?? "")It never leaves this computer."
        case .notTrusted:
            status = "Not trusted. Reqly decrypts nothing until a place below trusts its certificate."
        case .notSetUp:
            if let unread = https.readProblem {
                status = "Reqly couldn't read its certificate. \(unread) It tries again each time you open Settings."
            } else {
                status =
                    "Not set up. To read HTTPS traffic, apps on this computer need to trust a certificate that Reqly "
                    + "makes just for you. It never leaves this computer."
            }
        case nil:
            status = https.problem ?? "Checking Reqly's certificate…"
        }
        adw_action_row_set_subtitle(cast(statusRow), status)
        // Setting up while the certificate can't be read would only fail the same way.
        let canSetUp = https.state.map { $0.status != .trusted && $0.readProblem == nil } ?? false
        gtk_widget_set_visible(setUpButton, cBool(canSetUp))
        let key = https.keyDescription
        adw_action_row_set_subtitle(cast(keyRow), key ?? "")
        gtk_widget_set_visible(keyRow, cBool(key != nil))
    }

    /// Each place as it is now. The rows are made the first time, and changed after, so a
    /// Trust… button keeps its focus.
    private func showPlaces() {
        if placeRows.isEmpty {
            if https.isStandIn {
                let row = HTTPSWidgets.row(
                    "Test Run's Certificate",
                    "It counts as trusted. Reqly changes nothing on this computer: not your browsers, Firefox or "
                        + "the computer's list.")
                placeRows = [(nil, row, HTTPSWidgets.suffixLabel(), [])]
            } else {
                let https = https
                placeRows = https.places.map { place in
                    let row = HTTPSWidgets.row(place.title)
                    let trust = HTTPSWidgets.suffixButton("Trust…")
                    setAccessibleLabel(trust, "Trust in \(place.title)")
                    let kind = place.kind
                    connect(trust, "clicked") { [weak self] in self?.trust(kind) }
                    guard kind == .computer else { return (kind, row, HTTPSWidgets.suffixLabel(), [trust]) }
                    let copy = HTTPSWidgets.copyButton(
                        https.commandsToTrustByHand ?? "", label: "Copy the commands"
                    ) { [weak self] in self?.settings?.toast("Copied") }
                    return (kind, row, HTTPSWidgets.suffixLabel(), [trust, copy])
                }
            }
            for (_, row, status, buttons) in placeRows {
                adw_action_row_add_suffix(cast(row), status)
                for button in buttons {
                    adw_action_row_add_suffix(cast(row), button)
                }
                adw_preferences_group_add(cast(placesGroup), row)
            }
        }
        let byHand = https.commandsToTrustByHand
        for (kind, row, status, buttons) in placeRows {
            guard let place = https.places.first(where: { $0.kind == kind }) else {
                gtk_label_set_text(cast(status), https.hasCertificate ? "Trusted" : "")
                continue
            }
            adw_action_row_set_subtitle(
                cast(row), HTTPSWidgets.detail(of: place, byHand: kind == .computer ? byHand : nil))
            gtk_label_set_text(cast(status), place.statusName)
            if let trust = buttons.first {
                // Before there's a certificate, Set Up HTTPS… makes it and trusts it.
                gtk_widget_set_visible(trust, cBool(place.canTrust && https.hasCertificate))
                gtk_widget_set_sensitive(trust, cBool(!https.isWorking))
            }
            if let copy = buttons.dropFirst().first {
                gtk_widget_set_visible(copy, cBool(byHand != nil))
            }
        }
    }

    private func showHosts() {
        let hosts = https.state?.hosts ?? DecryptedHosts()
        adw_preferences_group_set_description(
            cast(hostsGroup),
            hosts.includesEveryHost
                ? "Reqly decrypts every host except the ones switched off here. Use * to include subdomains, like "
                    + "*.weatherly.dev."
                : "Traffic to other hosts passes through Reqly still encrypted. Use * to include subdomains, like "
                    + "*.weatherly.dev.")
        adw_switch_row_set_active(cast(everyHostRow), cBool(hosts.includesEveryHost))
        let patterns = Set(hosts.entries.map(\.pattern))
        for (pattern, row) in hostRows where !patterns.contains(pattern) {
            gtk_list_box_remove(cast(hostList), row)
            hostRows[pattern] = nil
        }
        for (index, entry) in hosts.entries.enumerated() {
            let row = hostRows[entry.pattern] ?? hostRow(entry.pattern)
            if gtk_widget_get_parent(row) == nil || gtk_list_box_row_get_index(cast(row)) != Int32(index) {
                if gtk_widget_get_parent(row) != nil {
                    g_object_ref(raw(row))
                    gtk_list_box_remove(cast(hostList), row)
                    gtk_list_box_insert(cast(hostList), row, Int32(index))
                    g_object_unref(raw(row))
                } else {
                    gtk_list_box_insert(cast(hostList), row, Int32(index))
                }
            }
            adw_switch_row_set_active(cast(row), cBool(entry.isOn))
        }
        gtk_widget_set_visible(noHosts, cBool(hosts.entries.isEmpty))
    }

    /// A host on the list, with its switch and a button that removes it.
    private func hostRow(_ pattern: HostPattern) -> Widget {
        let row = adw_switch_row_new()!
        adw_preferences_row_set_use_markup(cast(row), 0)
        adw_preferences_row_set_title(cast(row), pattern.rawValue)
        gtk_widget_add_css_class(row, "monospace")
        let remove = gtk_button_new_from_icon_name("user-trash-symbolic")!
        gtk_widget_add_css_class(remove, "flat")
        gtk_widget_set_valign(remove, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(remove, "Remove")
        setAccessibleLabel(remove, "Remove \(pattern.rawValue)")
        adw_action_row_add_suffix(cast(row), remove)
        connect(row, "notify::active") { [weak self] in
            guard let self, !isShowing else { return }
            let isOn = adw_switch_row_get_active(cast(row)) != 0
            Task { await self.https.setDecrypts(isOn, pattern) }
        }
        connect(remove, "clicked") { [weak self] in
            guard let self else { return }
            Task { await self.https.removeHost(pattern) }
        }
        hostRows[pattern] = row
        return row
    }

    // MARK: - Changes

    private func addHost() {
        let text = string(gtk_editable_get_text(cast(newHostRow))) ?? ""
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if let problem = await https.addHost(text) {
                HTTPSWidgets.say(addProblem, problem)
            } else {
                gtk_editable_set_text(cast(newHostRow), "")
            }
        }
    }

    private func trust(_ kind: TrustPlace.Kind) {
        waitingFor = kind == .computer ? "Waiting for an administrator's password…" : "Adding Reqly's certificate…"
        Task { [weak self] in
            guard let https = self?.https else { return }
            let problem = await https.trust(kind)
            self?.waitingFor = nil
            self?.say(problem)
        }
    }

    /// Says what went wrong with Trust…. Closing the password dialog isn't a failure: the place
    /// stays Not trusted, with its Trust… button.
    private func say(_ problem: TrustProblem?) {
        switch problem {
        case nil, .cancelled?, .refused?:
            break
        case .noPasswordDialog(let commands)?:
            showCommands(commands)
        case let problem?:
            settings?.toast(problem.errorDescription ?? "Reqly couldn't trust its certificate there.")
        }
    }

    /// With no password dialog, the commands that add the certificate by hand, to copy.
    private func showCommands(_ commands: String) {
        let alert: Widget = cast(
            adw_alert_dialog_new(
                "Run These in a Terminal",
                "No password dialog is available, so Reqly can't ask for an administrator's password. These add "
                    + "Reqly's certificate to this computer's list."))
        let label = gtk_label_new(commands)!
        gtk_label_set_selectable(cast(label), 1)
        gtk_label_set_wrap(cast(label), 1)
        gtk_label_set_xalign(cast(label), 0)
        gtk_widget_add_css_class(label, "monospace")
        adw_alert_dialog_set_extra_child(cast(alert), label)
        adw_alert_dialog_add_response(cast(alert), "close", "Close")
        adw_alert_dialog_add_response(cast(alert), "copy", "Copy Commands")
        adw_alert_dialog_set_response_appearance(cast(alert), "copy", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_default_response(cast(alert), "copy")
        adw_alert_dialog_set_close_response(cast(alert), "close")
        connect(alert, "response") { [weak self] (arguments: Arguments) in
            guard arguments.string(1) == "copy", let self else { return }
            gdk_clipboard_set_text(gtk_widget_get_clipboard(page), commands)
            settings?.toast("Copied")
        }
        adw_dialog_present(cast(alert), page)
    }

    private func confirmRemoval() {
        let alert: Widget = cast(
            adw_alert_dialog_new(
                "Remove Reqly's Certificate?",
                https.isStandIn
                    ? "Reqly stops decrypting HTTPS, and removes this test run's certificate. Nothing on this "
                        + "computer changes. You can set up HTTPS again at any time."
                    : "Reqly stops decrypting HTTPS, and removes its certificate from your browsers, this computer's "
                        + "list and its key. Removing it from the computer's list asks for an administrator's "
                        + "password. You can set up HTTPS again at any time."))
        adw_alert_dialog_add_response(cast(alert), "cancel", "Cancel")
        adw_alert_dialog_add_response(cast(alert), "remove", "Remove Certificate")
        adw_alert_dialog_set_response_appearance(cast(alert), "remove", ADW_RESPONSE_DESTRUCTIVE)
        adw_alert_dialog_set_default_response(cast(alert), "cancel")
        adw_alert_dialog_set_close_response(cast(alert), "cancel")
        connect(alert, "response") { [weak self] (arguments: Arguments) in
            if arguments.string(1) == "remove" {
                self?.remove()
            }
        }
        connect(alert, "closed") { [weak self] in self?.removeConfirmation = nil }
        removeConfirmation = alert
        adw_dialog_present(cast(alert), page)
    }

    /// Removes the certificate. If you close the password dialog, the places that still trust it
    /// stay, with the key, and Remove Certificate… with them.
    private func remove() {
        waitingFor = "Removing Reqly's certificate…"
        HTTPSWidgets.say(removeNote, nil)
        Task { [weak self] in
            guard let https = self?.https else { return }
            let left = await https.remove()
            guard let self else { return }
            waitingFor = nil
            HTTPSWidgets.say(removeNote, left)
            gtk_widget_set_visible(removeLeft, cBool(left != nil))
            gtk_widget_set_visible(removeCommandsButton, cBool(left != nil && https.commandsToRemoveByHand != nil))
            show()
            if left != nil {
                showWhatsLeft()
            }
        }
    }

    /// Scrolls the page to what's left after a removal, below the button, at the page's end, and
    /// gives the copy button the focus when it shows. It waits for the page to lay it out first.
    private func showWhatsLeft() {
        idle { [weak self] in
            guard let self else { return false }
            if let viewport = gtk_widget_get_ancestor(removeLeft, gtk_viewport_get_type()) {
                gtk_viewport_scroll_to(cast(viewport), removeLeft, nil)
            }
            if gtk_widget_get_visible(removeCommandsButton) != 0 {
                gtk_widget_grab_focus(removeCommandsButton)
            }
            return false
        }
    }
}
