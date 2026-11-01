import CGtk
import Foundation
import GtkBinding
import LinuxTrust

/// Set Up HTTPS…: says what Reqly will do, and lists each place it found, with a switch each, and
/// where the key will go, then makes the certificate, adds it to the places switched on, and
/// shows how each went. The computer's list is switched on too: Linux asks for an administrator's
/// password before it changes, which is the confirmation. A test run shows its stand-in
/// certificate instead, and changes nothing on the computer.
///
/// The window makes it once and presents it again each time, from the start, as Settings is:
/// libadwaita never frees the pages of a dialog. What an opening started that's still going when
/// it closes, such as reading the places, shows nothing once it's opened again.
@MainActor
final class SetUpDialog {
    let dialog: Widget
    let cancelButton: Widget
    /// Continue, and Done once Reqly has set up HTTPS.
    let continueButton: Widget
    /// Where the key will go, or is.
    let keyRow: Widget
    /// Each place's row, with its switch, or the test run's stand-in's.
    private(set) var placeRows: [Widget] = []
    /// What the results say, once they show: the status, then each place's outcome.
    private(set) var statusRow: Widget?
    private(set) var resultRows: [Widget] = []
    /// Whether the places have been read, so Continue can start.
    private(set) var isReady = false
    /// Whether Reqly has set up HTTPS, and the results show.
    private(set) var isDone = false
    /// Whether it's open, over the window.
    private(set) var isShowing = false

    private let https: HTTPSModel
    private let stack: Widget
    private let toasts: Widget
    private let placesGroup: Widget
    private let results: Widget
    private var resultGroups: [Widget] = []
    private let progress: (box: Widget, label: Widget)
    private let failure: Widget
    /// The kind of each switch row, in order.
    private var switches: [(kind: TrustPlace.Kind, row: Widget)] = []
    /// What keeping the key in your keyring involves, as last read, for the progress line.
    private var keyring: KeyringState?
    /// The setup this opening started, while it's under way.
    private var cancellation: Cancellation?
    /// Counts the openings, so what an earlier one started shows nothing in a later one.
    private var opening = 0

    init(https: HTTPSModel) {
        self.https = https
        dialog = cast(adw_dialog_new())
        // Kept for as long as the window is, rather than freed as it closes.
        g_object_ref_sink(raw(dialog))
        adw_dialog_set_title(cast(dialog), "Set Up HTTPS")
        adw_dialog_set_content_width(cast(dialog), 520)
        // Tall enough for the three places and the key without scrolling, when the window has room.
        adw_dialog_set_content_height(cast(dialog), 640)

        let header = adw_header_bar_new()!
        adw_header_bar_set_show_start_title_buttons(cast(header), 0)
        adw_header_bar_set_show_end_title_buttons(cast(header), 0)
        cancelButton = gtk_button_new_with_label("Cancel")
        continueButton = gtk_button_new_with_label("Continue")
        gtk_widget_add_css_class(continueButton, "suggested-action")
        adw_header_bar_pack_start(cast(header), cancelButton)
        adw_header_bar_pack_end(cast(header), continueButton)

        // What Reqly will do, each place, and the key.
        let choices = adw_preferences_page_new()!
        let about = adw_preferences_group_new()!
        adw_preferences_group_set_description(
            cast(about),
            https.isStandIn
                ? "This is a test run, so Reqly makes a certificate in a stand-in file of its own, which counts as "
                    + "trusted. Nothing on this computer changes. Reqly decrypts only the hosts you choose."
                : "To show what's inside HTTPS requests, Reqly makes its own certificate on this computer, and adds "
                    + "it to the places below, so apps trust it. Reqly decrypts only the hosts you choose. Everything "
                    + "else passes through untouched.")
        placesGroup = adw_preferences_group_new()
        adw_preferences_group_set_title(cast(placesGroup), "Add It To")
        adw_preferences_group_set_description(
            cast(placesGroup), "You can remove it from every place at any time, in Settings, under HTTPS.")
        keyRow = HTTPSWidgets.row("Reqly's Key")
        let key = adw_preferences_group_new()!
        adw_preferences_group_add(cast(key), keyRow)
        progress = HTTPSWidgets.progress()
        failure = HTTPSWidgets.message("error")
        let below = adw_preferences_group_new()!
        adw_preferences_group_add(cast(below), progress.box)
        adw_preferences_group_add(cast(below), failure)
        for group in [about, placesGroup, key, below] {
            adw_preferences_page_add(cast(choices), cast(group))
        }
        results = adw_preferences_page_new()

        stack = gtk_stack_new()
        gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_stack_add_named(cast(stack), choices, "choices")
        gtk_stack_add_named(cast(stack), results, "results")
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(cast(toolbar), header)
        adw_toolbar_view_set_content(cast(toolbar), stack)
        toasts = adw_toast_overlay_new()
        adw_toast_overlay_set_child(cast(toasts), toolbar)
        adw_dialog_set_child(cast(dialog), toasts)

        connect(cancelButton, "clicked") { [weak self] in self?.cancel() }
        connect(continueButton, "clicked") { [weak self] in self?.continueOrClose() }
        connect(dialog, "closed") { [weak self] in self?.closed() }
        https.observe { [weak self] in self?.showWhetherItCanStart() }
    }

    /// Shows the dialog over `window`, from the start: the places as they are now.
    func present(over window: Widget) {
        opening += 1
        isShowing = true
        isReady = false
        isDone = false
        cancellation = nil
        gtk_stack_set_visible_child_name(cast(stack), "choices")
        gtk_button_set_label(cast(continueButton), "Continue")
        gtk_widget_set_visible(cancelButton, 1)
        HTTPSWidgets.say(failure, nil)
        adw_action_row_set_subtitle(cast(keyRow), "Looking for your keyring…")
        for group in resultGroups {
            adw_preferences_page_remove(cast(results), cast(group))
        }
        resultGroups = []
        statusRow = nil
        resultRows = []
        showWhetherItCanStart()
        presentKept(dialog, over: window)
        let opening = opening
        Task { [weak self] in await self?.load(opening) }
    }

    /// Reads each place, and what keeping the key involves, then lets Continue start, unless
    /// the dialog has closed or opened again meanwhile.
    private func load(_ opening: Int) async {
        await https.readPlaces()
        let keyring = await https.keyringState()
        guard opening == self.opening, isShowing else { return }
        self.keyring = keyring
        showPlaces()
        adw_action_row_set_subtitle(cast(keyRow), keyText(keyring))
        isReady = true
        showWhetherItCanStart()
    }

    /// Continue starts once the places are read, and not while Reqly is busy with its certificate,
    /// as when a setup you closed this dialog on still waits for the keyring, which then shows.
    private func showWhetherItCanStart() {
        guard isShowing, !isDone, cancellation == nil else { return }
        gtk_widget_set_sensitive(continueButton, cBool(isReady && !https.isWorking))
        HTTPSWidgets.show(progress, https.isWorking ? "Reqly is still busy with its certificate…" : nil)
    }

    /// Shows each place in its row. A place keeps its row from one opening to the next, changed
    /// in place, so a row that has the keyboard's focus as the places are read again keeps it.
    private func showPlaces() {
        var rows: [Widget] = []
        if https.isStandIn {
            rows =
                placeRows.isEmpty
                ? [
                    HTTPSWidgets.row(
                        "Test Run's Certificate",
                        "It counts as trusted, so Reqly decrypts with it while nothing on this computer trusts it: "
                            + "not your browsers, Firefox or the computer's list.")
                ] : placeRows
        } else {
            let before = switches
            switches = https.places.map { place in
                let row = before.first { $0.kind == place.kind }?.row ?? Self.switchRow()
                adw_preferences_row_set_title(cast(row), place.title)
                adw_action_row_set_subtitle(
                    cast(row),
                    place.status == .trusted ? "It trusts the certificate already." : HTTPSWidgets.detail(of: place))
                // Unavailable places, and places with nothing to add it to, show why, switched off.
                adw_switch_row_set_active(cast(row), cBool(place.canTrust || place.status == .trusted))
                gtk_widget_set_sensitive(row, cBool(place.canTrust))
                return (place.kind, row)
            }
            rows = switches.map(\.row)
        }
        for row in placeRows where !rows.contains(row) {
            adw_preferences_group_remove(cast(placesGroup), row)
        }
        for row in rows where !placeRows.contains(row) {
            adw_preferences_group_add(cast(placesGroup), row)
        }
        placeRows = rows
    }

    private static func switchRow() -> Widget {
        let row = adw_switch_row_new()!
        adw_preferences_row_set_use_markup(cast(row), 0)
        return row
    }

    /// Where the key goes, and what Linux will ask before it's kept, so its question comes as no
    /// surprise.
    private func keyText(_ keyring: KeyringState?) -> String {
        if https.isStandIn {
            return "In the test run's stand-in file, with the certificate"
        }
        return Self.keyText(key: https.keyStatus, kept: https.keyDescription, keyring: keyring)
    }

    /// Where the key goes, as `key` says: where it's `kept` already, which asks nothing, unless
    /// your keyring has it locked, which asks to unlock it as setting up reads it, as `keyring`
    /// says. A key that has gone from your keyring or its file is kept again, which the keyring
    /// asks about as it does at the first setup.
    nonisolated static func keyText(key: HTTPSModel.KeyStatus, kept: String?, keyring: KeyringState?) -> String {
        switch (key, keyring) {
        case (.unread, .locked?), (.unread, .needsNewKeyring?):
            return "\(kept ?? "In your keyring"). Linux will ask for your keyring's password, to read Reqly's key."
        case (.unread, _), (.kept, _):
            return kept ?? "In your keyring"
        case (.new, _):
            break
        }
        let orFile = " If you close it, Reqly keeps the key in a file only you can read."
        switch keyring {
        case .ready?:
            return "In your keyring"
        case .locked?:
            return "Linux will ask for your keyring's password, to keep Reqly's key in it." + orFile
        case .needsNewKeyring?:
            return "Linux will ask you to choose a password for a new keyring, which keeps Reqly's key." + orFile
        case .unavailable?, nil:
            return "There's no keyring, so Reqly keeps its key in a file only you can read."
        }
    }

    private func continueOrClose() {
        guard !isDone else {
            adw_dialog_close(cast(dialog))
            return
        }
        let kinds = Set(
            switches.filter { adw_switch_row_get_active(cast($0.row)) != 0 && gtk_widget_get_sensitive($0.row) != 0 }
                .map(\.kind))
        let cancellation = Cancellation()
        self.cancellation = cancellation
        // Cancel, which stops the wait, takes the focus from Continue and the places, which GTK
        // would give to nothing as they turn insensitive.
        refocus(cancelButton, in: dialog)
        gtk_widget_set_sensitive(continueButton, 0)
        for (_, row) in switches {
            gtk_widget_set_sensitive(row, 0)
        }
        HTTPSWidgets.say(failure, nil)
        HTTPSWidgets.show(
            progress,
            Self.startText(keyring: keyring, key: https.keyStatus, trustsComputer: kinds.contains(.computer)))
        let https = https
        let opening = opening
        Task { [weak self] in
            let result = await https.setUp(trusting: kinds, cancellation: cancellation) { [weak self] in
                // The key is kept: the administrator's password comes next.
                guard let self, opening == self.opening, self.cancellation === cancellation else { return }
                HTTPSWidgets.show(
                    self.progress,
                    Self.progressText(keyring: nil, keyKept: true, trustsComputer: kinds.contains(.computer)))
            }
            guard let self, opening == self.opening else { return }
            finish(result)
        }
    }

    /// What the progress line says as Continue starts: the question Linux asks first, which is the
    /// keyring's, as `keyring` says, unless `key` is kept and read already. A key that has gone
    /// from your keyring or its file isn't, so a new one is kept as at the first setup; and one
    /// your keyring has, locked, is read, which asks for your keyring's password.
    nonisolated static func startText(keyring: KeyringState?, key: HTTPSModel.KeyStatus, trustsComputer: Bool)
        -> String
    {
        let asks: KeyringState? =
            switch (key, keyring) {
            case (.kept, _): nil
            case (.unread, .locked?), (.unread, .needsNewKeyring?): .locked
            case (.unread, _): nil
            case (.new, _): keyring
            }
        return progressText(keyring: asks, keyKept: false, trustsComputer: trustsComputer)
    }

    /// What the progress line says while Reqly sets up HTTPS, naming the question Linux asks at
    /// each step: the keyring's, while the key is kept, as `keyring` says it will ask, then an
    /// administrator's password, for the computer's list.
    nonisolated static func progressText(keyring: KeyringState?, keyKept: Bool, trustsComputer: Bool) -> String {
        switch keyring {
        case .locked? where !keyKept:
            return "Setting up HTTPS. Linux asks for your keyring's password…"
        case .needsNewKeyring? where !keyKept:
            return "Setting up HTTPS. Linux asks you to choose a password for a new keyring…"
        default:
            return trustsComputer
                ? "Setting up HTTPS. Linux asks for an administrator's password…" : "Setting up HTTPS…"
        }
    }

    private func finish(_ result: HTTPSModel.SetupResult) {
        cancellation = nil
        HTTPSWidgets.show(progress, nil)
        if let failure = result.failure {
            HTTPSWidgets.say(self.failure, failure)
            showPlaces()
            showWhetherItCanStart()
            // Continue again, to try again.
            if gtk_widget_get_sensitive(continueButton) != 0 {
                refocus(continueButton, in: dialog)
            }
            return
        }
        showResults(result)
        isDone = true
        gtk_button_set_label(cast(continueButton), "Done")
        gtk_widget_set_sensitive(continueButton, 1)
        gtk_widget_set_visible(cancelButton, 0)
        gtk_stack_set_visible_child_name(cast(stack), "results")
        refocus(continueButton, in: dialog)
    }

    /// How it went: whether Reqly decrypts now, each place, and where the key is.
    private func showResults(_ result: HTTPSModel.SetupResult) {
        let status = adw_preferences_group_new()!
        let advice =
            switch https.state?.status {
            case .trusted where https.isStandIn:
                "This test run decrypts with its own certificate. Choose the hosts to decrypt in Settings, under HTTPS."
            case .trusted:
                "Restart your browsers and the other apps that are open, so they read the certificate. Choose the "
                    + "hosts to decrypt in Settings, under HTTPS."
            default:
                "No place trusts Reqly's certificate yet, so Reqly decrypts nothing. You can trust it in Settings, "
                    + "under HTTPS."
            }
        let statusRow = HTTPSWidgets.row(https.statusName, advice)
        self.statusRow = statusRow
        adw_preferences_group_add(cast(status), statusRow)
        resultGroups = [status]

        if !https.isStandIn {
            let places = adw_preferences_group_new()!
            adw_preferences_group_set_title(cast(places), "Places")
            resultRows = https.places.map { place in
                let problem = result.problems[place.kind]
                let row = HTTPSWidgets.row(place.title, outcome(of: place, problem))
                let status = HTTPSWidgets.suffixLabel()
                gtk_label_set_text(cast(status), place.statusName)
                adw_action_row_add_suffix(cast(row), status)
                let byHand: String? =
                    if case .noPasswordDialog(let commands)? = problem {
                        commands
                    } else {
                        place.kind == .computer ? https.commandsToTrustByHand : nil
                    }
                if let byHand {
                    adw_action_row_add_suffix(
                        cast(row),
                        HTTPSWidgets.copyButton(byHand, label: "Copy the commands") { [weak self] in
                            self?.toast("Copied")
                        })
                }
                adw_preferences_group_add(cast(places), row)
                return row
            }
            resultGroups.append(places)
        }

        let key = adw_preferences_group_new()!
        adw_preferences_group_add(cast(key), HTTPSWidgets.row("Reqly's Key", https.keyDescription ?? "Not kept yet"))
        resultGroups.append(key)
        // The old certificate, whose key had gone, which Chromium's own list still trusts.
        if let left = result.leftInChromium {
            let old = adw_preferences_group_new()!
            adw_preferences_group_add(cast(old), HTTPSWidgets.row("Reqly's Old Certificate", left))
            resultGroups.append(old)
        }
        for group in resultGroups {
            adw_preferences_page_add(cast(results), cast(group))
        }
    }

    /// What a place's row says once Reqly has tried it.
    private func outcome(of place: TrustPlace, _ problem: TrustProblem?) -> String {
        switch problem {
        case .cancelled?: "You closed the password dialog. You can trust it later in Settings, under HTTPS."
        case .refused?:
            "The password dialog was closed, or the password wasn't accepted. You can trust it later in Settings, "
                + "under HTTPS."
        case let problem?: problem.errorDescription ?? place.detail
        case nil where place.kind == .computer: HTTPSWidgets.detail(of: place, byHand: https.commandsToTrustByHand)
        case nil: HTTPSWidgets.detail(of: place)
        }
    }

    private func toast(_ text: String) {
        adw_toast_overlay_add_toast(cast(toasts), adw_toast_new(text))
    }

    /// Cancel stops waiting for the password dialog, which closes with it, and closes setup. What
    /// Reqly did by then stays: the certificate, and the places it added it to.
    private func cancel() {
        cancellation?.cancel()
        adw_dialog_close(cast(dialog))
    }

    private func closed() {
        cancellation?.cancel()
        isShowing = false
    }
}
