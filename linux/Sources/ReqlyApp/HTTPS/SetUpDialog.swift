import CGtk
import Foundation
import GtkBinding
import LinuxTrust

/// Set Up HTTPS…: says what Reqly will do, and lists each place it found, with a switch each, and
/// where the key will go, then makes the certificate, adds it to the places switched on, and
/// shows how each went. The computer's list is switched on too: Linux asks for an administrator's
/// password before it changes, which is the confirmation. A test run shows its stand-in
/// certificate instead, and changes nothing on the computer.
@MainActor
final class SetUpDialog {
    /// The one that's open, kept until it closes, so there's only one, and the self-check finds it.
    private(set) static var showing: SetUpDialog?

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

    private let https: HTTPSModel
    private let stack: Widget
    private let toasts: Widget
    private let placesGroup: Widget
    private let results: Widget
    private let progress: (box: Widget, label: Widget)
    private let failure: Widget
    /// The kind of each switch row, in order.
    private var switches: [(kind: TrustPlace.Kind, row: Widget)] = []
    private var cancellation: Cancellation?

    init(https: HTTPSModel) {
        self.https = https
        dialog = cast(adw_dialog_new())
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
        gtk_widget_set_sensitive(continueButton, 0)
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
        keyRow = HTTPSWidgets.row("Reqly's Key", "Looking for your keyring…")
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
        Task { [weak self] in await self?.load() }
    }

    /// Shows the dialog over `window`.
    func present(over window: Widget) {
        Self.showing = self
        adw_dialog_present(cast(dialog), window)
    }

    /// Reads each place, and what keeping the key involves, then lets Continue start.
    private func load() async {
        await https.readPlaces()
        let keyring = await https.keyringState()
        showPlaces()
        adw_action_row_set_subtitle(cast(keyRow), keyText(keyring))
        isReady = true
        gtk_widget_set_sensitive(continueButton, 1)
    }

    private func showPlaces() {
        for row in placeRows {
            adw_preferences_group_remove(cast(placesGroup), row)
        }
        switches = []
        if https.isStandIn {
            placeRows = [
                HTTPSWidgets.row(
                    "Test Run's Certificate",
                    "It counts as trusted, so Reqly decrypts with it while nothing on this computer trusts it: not "
                        + "your browsers, Firefox or the computer's list.")
            ]
        } else {
            placeRows = https.places.map { place in
                let row = adw_switch_row_new()!
                adw_preferences_row_set_use_markup(cast(row), 0)
                adw_preferences_row_set_title(cast(row), place.name)
                adw_action_row_set_subtitle(
                    cast(row),
                    place.status == .trusted ? "It trusts the certificate already." : HTTPSWidgets.detail(of: place))
                // Unavailable places, and places with nothing to add it to, show why, switched off.
                adw_switch_row_set_active(cast(row), cBool(place.canTrust || place.status == .trusted))
                gtk_widget_set_sensitive(row, cBool(place.canTrust))
                switches.append((place.kind, row))
                return row
            }
        }
        for row in placeRows {
            adw_preferences_group_add(cast(placesGroup), row)
        }
    }

    /// Where the key goes, and what Linux will ask before it's kept, so its question comes as no
    /// surprise.
    private func keyText(_ keyring: KeyringState?) -> String {
        if https.isStandIn {
            return "In the test run's stand-in file, with the certificate"
        }
        if let kept = https.keyDescription {
            return kept
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
        gtk_widget_set_sensitive(continueButton, 0)
        for (_, row) in switches {
            gtk_widget_set_sensitive(row, 0)
        }
        HTTPSWidgets.say(failure, nil)
        HTTPSWidgets.show(
            progress,
            kinds.contains(.computer)
                ? "Setting up HTTPS. Linux asks for an administrator's password…" : "Setting up HTTPS…")
        let https = https
        Task { [weak self] in
            let result = await https.setUp(trusting: kinds, cancellation: cancellation)
            self?.finish(result)
        }
    }

    private func finish(_ result: HTTPSModel.SetupResult) {
        cancellation = nil
        HTTPSWidgets.show(progress, nil)
        if let failure = result.failure {
            HTTPSWidgets.say(self.failure, failure)
            showPlaces()
            gtk_widget_set_sensitive(continueButton, 1)
            return
        }
        showResults(result)
        isDone = true
        gtk_button_set_label(cast(continueButton), "Done")
        gtk_widget_set_sensitive(continueButton, 1)
        gtk_widget_set_visible(cancelButton, 0)
        gtk_stack_set_visible_child_name(cast(stack), "results")
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
        adw_preferences_page_add(cast(results), cast(status))

        if !https.isStandIn {
            let places = adw_preferences_group_new()!
            adw_preferences_group_set_title(cast(places), "Places")
            resultRows = https.places.map { place in
                let problem = result.problems[place.kind]
                let row = HTTPSWidgets.row(place.name, outcome(of: place, problem))
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
            adw_preferences_page_add(cast(results), cast(places))
        }

        let key = adw_preferences_group_new()!
        adw_preferences_group_add(cast(key), HTTPSWidgets.row("Reqly's Key", https.keyDescription ?? "Not kept yet"))
        adw_preferences_page_add(cast(results), cast(key))
    }

    /// What a place's row says once Reqly has tried it.
    private func outcome(of place: TrustPlace, _ problem: TrustProblem?) -> String {
        switch problem {
        case .cancelled?: "You closed the password dialog. You can trust it later in Settings, under HTTPS."
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
        if Self.showing === self {
            Self.showing = nil
        }
    }
}
