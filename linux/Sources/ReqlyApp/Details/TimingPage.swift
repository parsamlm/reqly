import CGtk
import CoreInterface
import GtkBinding
import ReqlyModel

/// What the Timing page shows: the failure, if any, and the waterfall.
struct TimingContent: Hashable {
    var failure: String?
    var waterfall: Waterfall
}

extension DetailsPane {
    func timingContent(_ details: ExchangeDetails) -> TimingContent {
        TimingContent(failure: details.failure, waterfall: Waterfall(details))
    }

    /// The Timing page, as the Mac's: the failure, in red; the waterfall, a row for each step with
    /// its bar and its duration, and the total; then the connection's rows.
    func buildTiming(_ timing: TimingContent, in box: Widget) {
        let waterfall = timing.waterfall
        if let failure = timing.failure {
            gtk_box_append(cast(box), Self.failure(failure))
        }
        if waterfall.isShown {
            let rows =
                waterfall.steps.map { step(title: $0.title, value: $0.value, bar: Self.bar($0)) }
                + [step(title: "Total", value: waterfall.total, bar: nil)]
            gtk_box_append(cast(box), DetailsBlocks.card(rows))
        }
        if !waterfall.connection.isEmpty {
            gtk_box_append(
                cast(box), DetailsBlocks.section("Connection", content: [DetailsBlocks.card(waterfall.connection)]))
        }
    }

    /// A step's row: its title, its bar, which screen readers skip, and its duration, which they
    /// read with the title, as one.
    private func step(title: String, value: String, bar: Widget?) -> Widget {
        let name = DetailsBlocks.label(title)
        gtk_label_set_width_chars(cast(name), 16)
        gtk_label_set_max_width_chars(cast(name), 16)
        let duration = gtk_label_new(value)!
        gtk_label_set_xalign(cast(duration), 1)
        gtk_label_set_width_chars(cast(duration), 8)
        gtk_label_set_selectable(cast(duration), 1)
        gtk_widget_add_css_class(duration, "numeric")
        setAccessibleRelation(duration, GTK_ACCESSIBLE_RELATION_LABELLED_BY, [name])
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)!
        gtk_widget_add_css_class(row, "details-step")
        let space = bar ?? gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_set_hexpand(space, 1)
        if bar == nil {
            for label in [name, duration] {
                gtk_widget_add_css_class(label, "details-total")
            }
        } else {
            gtk_widget_add_css_class(name, "dim-label")
        }
        for widget in [name, space, duration] {
            gtk_box_append(cast(row), widget)
        }
        return row
    }

    /// A step's bar, placed on the timeline by when it started and how long it took, at least a
    /// few pixels long, in its look's color: the accent for the server's time, half of it for the
    /// transfer, dim for the rest, and red for the step a failed exchange stopped in.
    static func bar(_ step: Waterfall.Step) -> Widget {
        let area = gtk_drawing_area_new()!
        gtk_drawing_area_set_content_height(cast(area), 8)
        gtk_widget_set_valign(area, GTK_ALIGN_CENTER)
        gtk_widget_add_css_class(area, "details-bar")
        switch step.look {
        case .accent: gtk_widget_add_css_class(area, "accent")
        case .halfAccent: gtk_widget_add_css_class(area, "half-accent")
        case .failed: gtk_widget_add_css_class(area, "failed")
        case .dim: break
        }
        setAccessibleHidden(area, true)
        let offset = step.offset
        let length = step.length
        setDraw(area) { cairo, width, height in
            let whole = Double(width)
            let long = max(3, whole * length)
            let x = max(0, min(whole * offset, whole - long))
            let tall = min(8, Double(height))
            let y = (Double(height) - tall) / 2
            var color = GdkRGBA()
            gtk_widget_get_color(area, &color)
            gdk_cairo_set_source_rgba(cairo, &color)
            // A capsule, its ends as round as its height lets them be, or its length.
            let radius = min(tall, long) / 2
            let quarter = Double.pi / 2
            cairo_new_path(cairo)
            cairo_arc(cairo, x + long - radius, y + radius, radius, -quarter, 0)
            cairo_arc(cairo, x + long - radius, y + tall - radius, radius, 0, quarter)
            cairo_arc(cairo, x + radius, y + tall - radius, radius, quarter, 2 * quarter)
            cairo_arc(cairo, x + radius, y + radius, radius, 2 * quarter, 3 * quarter)
            cairo_close_path(cairo)
            cairo_fill(cairo)
        }
        return area
    }
}
