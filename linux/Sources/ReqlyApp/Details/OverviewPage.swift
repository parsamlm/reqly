import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

/// What Overview shows, under its comment: the decryption note, with whether Reqly is busy with
/// its certificate, which turns the note's button off, then the URL, the failure and the sections.
struct OverviewContent: Hashable {
    var note: DecryptionNote?
    var isWorking: Bool
    var words: OverviewWords
}

extension DetailsPane {
    /// Overview for `details`, with the decryption note as the hosts to decrypt are now.
    func overviewContent(_ details: ExchangeDetails) -> OverviewContent {
        let host = details.exchange.request.host
        let note = DecryptionNote(
            details.decryption, host: host, isDecrypting: model.https.decrypts(host),
            device: details.exchange.device?.name)
        return OverviewContent(note: note, isWorking: model.https.isWorking, words: OverviewWords(details))
    }

    /// Overview, as the Mac's: the decryption note; the URL, in a box; the failure, in red; the
    /// rules and what scripts printed; then the request's rows, and the response's and the
    /// connection's.
    func buildOverview(_ overview: OverviewContent, in box: Widget) {
        let words = overview.words
        if let note = overview.note {
            gtk_box_append(cast(box), decryptionNote(note, isWorking: overview.isWorking))
        }
        if let url = words.url {
            let text = DetailsBlocks.label(url)
            gtk_label_set_wrap_mode(cast(text), PANGO_WRAP_CHAR)
            gtk_label_set_selectable(cast(text), 1)
            gtk_widget_add_css_class(text, "details-url")
            setAccessibleDescription(text, "URL")
            let card = DetailsBlocks.card([text])
            gtk_box_append(cast(box), DetailsBlocks.section("URL", content: [card]))
        }
        if let failure = words.failure {
            gtk_box_append(cast(box), Self.failure(failure))
        }
        if let rules = words.rules {
            gtk_box_append(
                cast(box),
                DetailsBlocks.section(rules.title, count: rules.count, content: [DetailsBlocks.card(rules.rows)]))
        }
        if !words.scripts.isEmpty {
            let rows = words.scripts.map { script in
                let lines = DetailsBlocks.label(script.value)
                gtk_label_set_selectable(cast(lines), 1)
                gtk_widget_add_css_class(lines, "monospace")
                let name = DetailsBlocks.label(script.name)
                gtk_widget_add_css_class(name, "dim-label")
                let output = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
                gtk_widget_add_css_class(output, "details-row")
                gtk_box_append(cast(output), name)
                gtk_box_append(cast(output), lines)
                setAccessibleRelation(lines, GTK_ACCESSIBLE_RELATION_LABELLED_BY, [name])
                return output
            }
            gtk_box_append(cast(box), DetailsBlocks.section("Script output", content: [DetailsBlocks.card(rows)]))
        }
        for section in words.sections {
            let content = section.rows.isEmpty ? section.note.map(DetailsBlocks.note) : DetailsBlocks.card(section.rows)
            gtk_box_append(cast(box), DetailsBlocks.section(section.title, content: content.map { [$0] } ?? []))
        }
    }

    /// A failure's words, in red, beside a warning.
    static func failure(_ text: String) -> Widget {
        let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        let icon = DetailsBlocks.icon(Icons.warning)
        gtk_widget_add_css_class(icon, "error")
        let words = DetailsBlocks.label(text)
        gtk_label_set_selectable(cast(words), 1)
        gtk_widget_add_css_class(words, "error")
        gtk_widget_set_hexpand(words, 1)
        gtk_box_append(cast(line), icon)
        gtk_box_append(cast(line), words)
        return line
    }

    /// The decryption note: a lock, or an open lock, or a warning, beside what it says, over its
    /// button, which decrypts the host or stops.
    private func decryptionNote(_ note: DecryptionNote, isWorking: Bool) -> Widget {
        let card = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10)!
        gtk_widget_add_css_class(card, "card")
        gtk_widget_add_css_class(card, "details-note")
        let name =
            switch note.look {
            case .locked: Icons.lock
            case .unlocked: Icons.openLock
            case .warning: Icons.warning
            }
        let icon = DetailsBlocks.icon(name)
        if note.look == .warning {
            gtk_widget_add_css_class(icon, "warning")
        }
        let side = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        gtk_widget_set_hexpand(side, 1)
        let text = DetailsBlocks.label(note.text)
        gtk_box_append(cast(side), text)
        if let action = note.action, let title = note.actionTitle {
            let button = gtk_button_new_with_label(title)!
            gtk_widget_set_halign(button, GTK_ALIGN_START)
            if note.isSuggested {
                gtk_widget_add_css_class(button, "suggested-action")
            }
            gtk_widget_set_sensitive(button, cBool(!isWorking))
            // Said with the note, as its description.
            setAccessibleDescription(button, note.text)
            let host = note.host
            connect(button, "clicked") { [weak self] in self?.decrypt(action == .decrypt, host) }
            gtk_box_append(cast(side), button)
        }
        gtk_box_append(cast(card), icon)
        gtk_box_append(cast(card), side)
        return card
    }
}
