import CGtk
import CoreInterface
import GtkBinding
import Presentation
import ReqlyModel

/// What the Raw page shows: the request and the response as text, with or without their secrets,
/// and what it says around them.
struct RawContent: Hashable {
    var request: RawText
    var response: RawText?
    var hasSecrets: Bool
    var showsSecrets: Bool
    var noResponse: String
    var note: String?
}

extension DetailsPane {
    /// The request and the response as the core writes them, the way HTTP/1.1 does, their bodies
    /// cut at 256 KB.
    func rawContent(_ details: ExchangeDetails) -> RawContent {
        let exchange = details.exchange
        let hides = !rawShowsSecrets
        let request = RawMessage(request: exchange.request, body: exchange.requestBody, hidingSecrets: hides)
        let response = exchange.response.map {
            RawMessage(
                response: $0, body: exchange.responseBody, trailers: exchange.responseTrailers, hidingSecrets: hides)
        }
        return RawContent(
            request: RawText(request), response: response.map(RawText.init), hasSecrets: RawWords.hasSecrets(exchange),
            showsSecrets: rawShowsSecrets, noResponse: RawWords.noResponse(exchange), note: RawWords.note(exchange))
    }

    /// The Raw page, as the Mac's: Show Them or Hide Them for the secrets, then the request and
    /// the response, each with its copy button, its header names in bold, its text wrapping, and
    /// the note for HTTP/2.
    func buildRaw(_ raw: RawContent, in box: Widget) {
        if raw.hasSecrets {
            let words = RawWords.secrets(showing: raw.showsSecrets)
            let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
            let text = DetailsBlocks.note(words.text)
            gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
            let toggle = DetailsBlocks.textButton(words.button)
            gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
            setAccessibleDescription(toggle, words.text)
            connect(toggle, "clicked") { [weak self] in
                guard let self else { return }
                rawShowsSecrets.toggle()
                refresh(.raw)
            }
            gtk_box_append(cast(line), text)
            gtk_box_append(cast(line), toggle)
            gtk_box_append(cast(box), line)
        }
        gtk_box_append(cast(box), section("Request", raw.request))
        if let response = raw.response {
            gtk_box_append(cast(box), section("Response", response))
        } else {
            gtk_box_append(cast(box), DetailsBlocks.section("Response", content: [DetailsBlocks.note(raw.noResponse)]))
        }
        if let note = raw.note {
            gtk_box_append(cast(box), DetailsBlocks.note(note))
        }
    }

    /// The request's or the response's text, with Copy Raw Request or Copy Raw Response, which
    /// copies it as it shows, dots and all.
    private func section(_ title: String, _ text: RawText) -> Widget {
        let words = text.text
        let copy = DetailsBlocks.copyButton("Copy Raw \(title)") { words }
        return DetailsBlocks.section(
            title, end: [copy], content: [Self.textView(text, named: "Raw \(title.lowercased())")])
    }

    /// A text view of `text`, which you can read with the caret and select, but not change.
    static func textView(_ text: RawText, named name: String) -> Widget {
        let view = gtk_text_view_new()!
        gtk_text_view_set_editable(cast(view), 0)
        gtk_text_view_set_cursor_visible(cast(view), 1)
        gtk_text_view_set_accepts_tab(cast(view), 0)
        gtk_text_view_set_monospace(cast(view), 1)
        gtk_text_view_set_wrap_mode(cast(view), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_top_margin(cast(view), 10)
        gtk_text_view_set_bottom_margin(cast(view), 10)
        gtk_text_view_set_left_margin(cast(view), 12)
        gtk_text_view_set_right_margin(cast(view), 12)
        gtk_widget_add_css_class(view, "details-raw")
        setAccessibleLabel(view, name)
        let buffer = gtk_text_view_get_buffer(cast(view))
        // Without the line the last one ends with, which would show as an empty one.
        let shown = text.text.hasSuffix("\n") ? String(text.text.dropLast()) : text.text
        gtk_text_buffer_set_text(buffer, shown, -1)
        let table = gtk_text_buffer_get_tag_table(buffer)
        // Header names stand out in the text's own color, which is the Mac's color for them;
        // the notes about bodies are dim, as the Mac's comments are, in light and dark alike.
        let names = gtk_text_tag_new("name")!
        set(raw(names), "weight", .int(600))
        let notes = gtk_text_tag_new("note")!
        set(raw(notes), "foreground", .string("#8E8E93"))
        for tag in [names, notes] {
            gtk_text_tag_table_add(table, tag)
            g_object_unref(raw(tag))
        }
        for (tag, ranges) in [("name", text.names), ("note", text.notes)] {
            for range in ranges {
                var start = GtkTextIter()
                var end = GtkTextIter()
                gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(range.lowerBound))
                gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(range.upperBound))
                gtk_text_buffer_apply_tag_by_name(buffer, tag, &start, &end)
            }
        }
        return view
    }
}
