import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

/// What the Request or Response page shows: the message's words, and which of its secrets you
/// chose to show.
struct MessageContent: Hashable {
    var part: MessagePart
    var words: MessageWords
    /// The places of the secret headers you showed.
    var shownHeaders: Set<Int>
    var showsCookieValues: Bool
}

extension DetailsPane {
    func messageContent(_ details: ExchangeDetails, _ part: MessagePart) -> MessageContent {
        let prefix = "\(part.rawValue):"
        let shown = Set(shownHeaders.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil })
        return MessageContent(
            part: part, words: MessageWords(details, part: part), shownHeaders: shown,
            showsCookieValues: showsCookieValues.contains(part))
    }

    /// The Request or Response page, as the Mac's: the query's parameters; the headers, with
    /// Copy Headers, each secret as dots with Show; the cookies, with Show Values; the body, in its
    /// view; and the response's trailers.
    func buildMessage(_ message: MessageContent, in box: Widget) {
        let words = message.words
        let part = message.part
        if words.isWholePage {
            gtk_box_append(cast(box), DetailsBlocks.note(words.note ?? ""))
            return
        }
        if !words.query.isEmpty {
            let card = DetailsBlocks.card(words.query)
            gtk_box_append(
                cast(box), DetailsBlocks.section("Query parameters", count: words.query.count, content: [card]))
        }
        let headers = headerRows(words.headers, part: part, shown: message.shownHeaders)
        let copy = headers.isEmpty ? [] : [DetailsBlocks.copyButton("Copy Headers") { words.headersText }]
        gtk_box_append(
            cast(box),
            DetailsBlocks.section(
                "Headers", count: words.headers.count, end: copy,
                content: headers.isEmpty ? [] : [DetailsBlocks.card(headers)]))
        if !words.cookies.isEmpty {
            gtk_box_append(cast(box), cookies(words.cookies, part: part, showsValues: message.showsCookieValues))
        }
        if words.hasBody, let view = bodyView(part, size: words.bodySize) {
            gtk_box_append(cast(box), DetailsBlocks.section("Body", content: [view.widget]))
        } else if let note = words.note {
            gtk_box_append(cast(box), DetailsBlocks.section("Body", content: [DetailsBlocks.note(note)]))
        }
        if !words.trailers.isEmpty {
            let trailers = headerRows(
                words.trailers, part: part, shown: message.shownHeaders, offset: words.headers.count)
            gtk_box_append(
                cast(box),
                DetailsBlocks.section(
                    "Trailers", count: words.trailers.count, content: [DetailsBlocks.card(trailers)]))
        }
    }

    /// A row for each header. A secret shows as dots, which screen readers call hidden, with Show,
    /// until you show it, and stays shown while the request shows. `offset` places trailers after
    /// the headers.
    private func headerRows(
        _ headers: [MessageWords.Header], part: MessagePart, shown: Set<Int>, offset: Int = 0
    ) -> [Widget] {
        headers.enumerated().map { index, header in
            let place = offset + index
            guard header.isSecret, !shown.contains(place) else {
                return DetailsBlocks.row(header.name, value: header.value, isCode: true, isHeader: true)
            }
            let dots = DetailsBlocks.label(MessageWords.mask(header.value))
            gtk_widget_add_css_class(dots, "monospace")
            setAccessibleLabel(dots, "Hidden")
            let show = DetailsBlocks.textButton("Show")
            connect(show, "clicked") { [weak self] in
                self?.shownHeaders.insert("\(part.rawValue):\(place)")
                self?.refresh(part == .request ? .request : .response)
            }
            let row = DetailsBlocks.row(header.name, isHeader: true, value: [dots, show], labelling: nil)
            // "Show Authorization": GTK names a button by its own label, so by that and the header's.
            if let words = gtk_button_get_child(cast(show)), let name = gtk_widget_get_first_child(row) {
                setAccessibleRelation(show, GTK_ACCESSIBLE_RELATION_LABELLED_BY, [words, name])
            }
            return row
        }
    }

    /// The cookies a request sent, or the ones a response set, with when each expires and its
    /// attributes, their values hidden until Show Values.
    private func cookies(_ cookies: [MessageWords.Cookie], part: MessagePart, showsValues: Bool) -> Widget {
        let rows = cookies.map { cookie in
            let value = DetailsBlocks.label(showsValues ? cookie.value : MessageWords.mask(cookie.value))
            gtk_widget_add_css_class(value, "monospace")
            if showsValues {
                gtk_label_set_selectable(cast(value), 1)
            } else {
                setAccessibleLabel(value, "Hidden")
            }
            var widgets = [value]
            if let attributes = cookie.attributes {
                let line = DetailsBlocks.label(attributes)
                gtk_widget_add_css_class(line, "caption")
                gtk_widget_add_css_class(line, "dim-label")
                widgets.append(line)
            }
            let column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
            for widget in widgets {
                gtk_box_append(cast(column), widget)
            }
            if let line = widgets.dropFirst().first {
                setAccessibleRelation(value, GTK_ACCESSIBLE_RELATION_DESCRIBED_BY, [line])
            }
            let row = DetailsBlocks.row(
                MessageWords.name(of: cookie), isHeader: true, value: [column], labelling: showsValues ? value : nil)
            gtk_widget_add_css_class(row, "details-cookie")
            return row
        }
        let toggle = DetailsBlocks.textButton(showsValues ? "Hide Values" : "Show Values")
        gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
        connect(toggle, "clicked") { [weak self] in
            guard let self else { return }
            if showsValues {
                showsCookieValues.remove(part)
            } else {
                showsCookieValues.insert(part)
            }
            refresh(part == .request ? .request : .response)
        }
        return DetailsBlocks.section(
            "Cookies", count: cookies.count, end: [toggle], content: [DetailsBlocks.card(rows)])
    }
}
