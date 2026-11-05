import BodyKit
import CGtk
import CoreInterface
import Foundation
import GtkBinding
import Presentation
import ReqlyModel

/// One body of one request, as the Request and Response pages show it: a line saying what it is,
/// such as "JSON · 1.2 KB", with the switch between its modes and Copy Body; the body in the mode
/// chosen, as code, a tree, a form, a picture or hex; and footnotes when it was unpacked or cut
/// short. A page makes one for each body it shows, puts ``widget`` in its box, and hands it the
/// body as the session presents it, again as it grows.
///
/// The mode you choose stays for the next body of the same part, a request's or a response's,
/// that has it, as on the Mac. Code past ``CodeText/lineLimit`` lines or ``CodeText/byteLimit``
/// bytes shows its start, with Show Whole Body, which opens all of it in a view of its own. Each
/// mode's view is made the first time it shows, and kept until the body changes.
@MainActor
final class BodyView {
    let id: ExchangeID
    let part: MessagePart
    /// The line, then the body, one under the other.
    let widget: Widget
    /// The switch between the body's modes, one button for each, one always on; or a label, when
    /// there's only one mode.
    let modeSwitch: Widget
    /// The body, as the session last presented it.
    private(set) var body: PresentedBody?
    /// The mode it shows the body in.
    private(set) var mode: BodyMode?
    /// Runs when you choose another mode, so the page can choose it for the next body like this
    /// one.
    var onMode: ((BodyMode) -> Void)?

    /// What the line says the body is, such as "JSON · 1.2 KB".
    let summary: Widget
    let copyButton: Widget
    /// Why the body shows as it does, such as JSON that isn't valid, over it.
    let note: Widget
    /// The modes' views, one showing.
    let stack: Widget
    /// "Showing the first 5,000 lines of 41,233." and Show Whole Body, under code that's cut.
    let startLine: Widget
    let showWhole: Widget
    /// The footnotes, under the body.
    let footnotes: Widget
    /// The views made so far for the body, by mode: a CodeHolder, TreeView, FormView, PreviewView
    /// or HexView.
    private(set) var views: [BodyMode: AnyObject] = [:]
    /// The whole body's view, while it's open.
    private(set) var whole: WholeBody?
    /// The body as it has grown since you opened the whole of it, which shows once you close that.
    private(set) var waiting: PresentedBody?
    /// Whether Show Whole Body has the keyboard's focus again once the grown body's code is laid
    /// out, as it had before the whole body opened.
    private var focusesShowWhole = false

    /// The mode last chosen for each part's bodies, for the next body that has it.
    static var chosen: [MessagePart: BodyMode] = [:]

    private let model: AppModel
    private let noteLabel: Widget
    private let startLabel: Widget
    /// The mode switch's buttons, by mode.
    private var buttons: [BodyMode: Widget] = [:]
    /// Whether the switch is being set to the mode shown, rather than by you.
    private var isShowingMode = false
    /// Counts the bodies shown, so work for one that's gone is dropped.
    private var shown = 0

    init(model: AppModel, id: ExchangeID, part: MessagePart) {
        self.model = model
        self.id = id
        self.part = part
        BodyStyles.install()
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
        g_object_ref_sink(raw(widget))
        gtk_widget_add_css_class(widget, "body-view")

        summary = gtk_label_new(nil)
        gtk_label_set_xalign(cast(summary), 0)
        gtk_label_set_ellipsize(cast(summary), PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(summary, 1)
        gtk_widget_add_css_class(summary, "dim-label")
        modeSwitch = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_add_css_class(modeSwitch, "linked")
        gtk_widget_set_valign(modeSwitch, GTK_ALIGN_CENTER)
        copyButton = gtk_button_new_from_icon_name("edit-copy-symbolic")
        gtk_widget_add_css_class(copyButton, "flat")
        gtk_widget_set_valign(copyButton, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(copyButton, "Copy Body")
        setAccessibleLabel(copyButton, "Copy Body")
        let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        gtk_widget_add_css_class(line, "body-line")
        for child in [summary, modeSwitch, copyButton] {
            gtk_box_append(cast(line), child)
        }

        noteLabel = gtk_label_new(nil)
        note = Self.noteLine(noteLabel, icon: "dialog-information-symbolic")
        stack = gtk_stack_new()
        gtk_stack_set_vhomogeneous(cast(stack), 0)
        gtk_stack_set_hhomogeneous(cast(stack), 0)
        startLabel = gtk_label_new(nil)
        showWhole = gtk_button_new_with_label("Show Whole Body")
        startLine = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)
        gtk_label_set_xalign(cast(startLabel), 0)
        gtk_label_set_wrap(cast(startLabel), 1)
        gtk_widget_set_hexpand(startLabel, 1)
        gtk_widget_add_css_class(startLabel, "dim-label")
        gtk_widget_set_valign(showWhole, GTK_ALIGN_CENTER)
        gtk_box_append(cast(startLine), startLabel)
        gtk_box_append(cast(startLine), showWhole)
        gtk_widget_set_visible(startLine, 0)
        footnotes = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)

        for child in [line, note, stack, startLine, footnotes] {
            gtk_box_append(cast(widget), child)
        }
        connect(copyButton, "clicked") { [weak self] in self?.copyBody() }
        connect(showWhole, "clicked") { [weak self] in self?.showWholeBody() }
    }

    isolated deinit {
        whole?.close()
        g_object_unref(raw(widget))
    }

    /// A note with its icon, which screen readers skip, as the label says it all.
    private static func noteLine(_ label: Widget, icon: String) -> Widget {
        let line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
        let image = gtk_image_new_from_icon_name(icon)!
        gtk_widget_set_valign(image, GTK_ALIGN_START)
        setAccessibleHidden(image, true)
        gtk_label_set_xalign(cast(label), 0)
        gtk_label_set_wrap(cast(label), 1)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(cast(line), image)
        gtk_box_append(cast(line), label)
        gtk_widget_add_css_class(line, "dim-label")
        gtk_widget_set_visible(line, 0)
        return line
    }

    // MARK: - Showing

    /// Shows `body`, in the mode last chosen for bodies of its part while it has that mode, in the
    /// mode it showed in while it has that, and in its first mode otherwise. The same body again,
    /// as it was, changes nothing; one that has grown while you read the whole of it waits until
    /// you close that.
    func show(_ body: PresentedBody) {
        if let old = self.body, Self.isSame(old.body, body.body) {
            self.body = body
            return
        }
        guard whole == nil else {
            waiting = body
            return
        }
        waiting = nil
        self.body = body
        shown += 1
        clearViews()
        let presented = body.body
        let isEmpty = presented.wireSize == 0
        gtk_label_set_text(cast(summary), isEmpty ? BodyWords.empty(part) : BodyWords.summary(presented))
        gtk_widget_set_visible(copyButton, cBool(!isEmpty))
        gtk_label_set_text(cast(noteLabel), presented.note ?? "")
        gtk_widget_set_visible(note, cBool(presented.note != nil && !isEmpty))
        while let child = gtk_widget_get_first_child(footnotes) {
            gtk_box_remove(cast(footnotes), child)
        }
        for footnote in isEmpty ? [] : BodyWords.footnotes(presented) {
            let label = gtk_label_new(footnote)!
            gtk_label_set_xalign(cast(label), 0)
            gtk_label_set_wrap(cast(label), 1)
            gtk_widget_add_css_class(label, "dim-label")
            gtk_widget_add_css_class(label, "caption")
            gtk_box_append(cast(footnotes), label)
        }
        makeSwitch(isEmpty ? [] : presented.modes, in: presented)
        guard !isEmpty else {
            mode = nil
            gtk_widget_set_visible(stack, 0)
            return
        }
        gtk_widget_set_visible(stack, 1)
        let modes = presented.modes
        let next =
            Self.chosen[part].flatMap { modes.contains($0) ? $0 : nil }
            ?? mode.flatMap { modes.contains($0) ? $0 : nil } ?? modes.first ?? .hex
        show(mode: next)
    }

    /// Shows the body in `mode`, when it has it.
    func show(mode: BodyMode) {
        guard let presented = body?.body, presented.modes.contains(mode) else { return }
        self.mode = mode
        // The others in its group go off as it goes on.
        isShowingMode = true
        buttons[mode].map { gtk_toggle_button_set_active(cast($0), 1) }
        isShowingMode = false
        let view = views[mode] ?? makeView(mode, of: presented)
        views[mode] = view
        gtk_stack_set_visible_child_name(cast(stack), Self.name(mode))
        showStart()
    }

    /// Whether two presentations of a body show the same: the same bytes' worth, read the same.
    private static func isSame(_ one: BodyPresentation, _ other: BodyPresentation) -> Bool {
        one.wireSize == other.wireSize && one.content.count == other.content.count && one.modes == other.modes
            && one.protobufType == other.protobufType && one.note == other.note
    }

    private static func name(_ mode: BodyMode) -> String { "\(mode)" }

    /// The buttons for `modes`, or a label for one.
    private func makeSwitch(_ modes: [BodyMode], in presented: BodyPresentation) {
        while let child = gtk_widget_get_first_child(modeSwitch) {
            gtk_box_remove(cast(modeSwitch), child)
        }
        buttons = [:]
        guard modes.count > 1 else {
            if let only = modes.first {
                let label = gtk_label_new(BodyWords.title(of: only, in: presented))!
                gtk_widget_add_css_class(label, "dim-label")
                gtk_box_append(cast(modeSwitch), label)
            }
            return
        }
        var first: Widget?
        for mode in modes {
            let button = gtk_toggle_button_new_with_label(BodyWords.title(of: mode, in: presented))!
            if let first {
                gtk_toggle_button_set_group(cast(button), cast(first))
            } else {
                first = button
            }
            connect(button, "toggled") { [weak self] in
                guard let self, !isShowingMode, gtk_toggle_button_get_active(cast(button)) != 0 else { return }
                Self.chosen[part] = mode
                show(mode: mode)
                onMode?(mode)
            }
            gtk_box_append(cast(modeSwitch), button)
            buttons[mode] = button
        }
    }

    /// Drops the views made for the body before.
    private func clearViews() {
        while let child = gtk_widget_get_first_child(stack) {
            gtk_stack_remove(cast(stack), child)
        }
        views = [:]
        gtk_widget_set_visible(startLine, 0)
    }

    /// The view for `mode`, in the stack. Code is laid out away from the window first, so its view
    /// comes a moment later.
    private func makeView(_ mode: BodyMode, of presented: BodyPresentation) -> AnyObject {
        let made: AnyObject
        let child: Widget
        switch mode {
        case .formatted, .raw:
            let holder = CodeHolder()
            made = holder
            child = holder.widget
            if let code = mode == .formatted ? presented.formatted ?? presented.raw : presented.raw {
                let shown = shown
                Task { [weak self, weak holder] in
                    let text = await Task.detached(priority: .userInitiated) { CodeText(code) }.value
                    guard let self, let holder, self.shown == shown else { return }
                    holder.show(CodeView(text))
                    if self.mode == mode {
                        showStart()
                    }
                }
            }
        case .tree:
            let tree = TreeView(presented.tree ?? JSONTree(.null, rootLabel: "")) { [weak self] node in
                guard let self, let session = model.session else { return nil }
                return try? await session.bodyNode(id, part: part == .request ? .request : .response, node: node)
            }
            tree.onCopy = { [weak self] _ in self?.say("Copied") }
            made = tree
            child = tree.widget
        case .form:
            let form = FormView(fields: presented.fields, parts: presented.parts)
            made = form
            child = form.widget
        case .preview:
            let format: ImageFormat
            if case .image(let found) = presented.kind {
                format = found
            } else {
                format = .png
            }
            let preview = PreviewView(presented.content, format: format) { [weak self] in
                guard let self, let session = model.session else { return nil }
                return await session.rows([id]).first?.url
            }
            preview.onSay = { [weak self] words in self?.say(words) }
            made = preview
            child = preview.widget
        case .hex:
            // The session unpacks a body only for one that came packed; otherwise its bytes are the
            // same either way, and reading them as they came is quicker.
            let unpacked = presented.unpackedFrom != nil
            let hex = HexView(size: presented.content.count) { [weak self] offset, limit in
                guard let self, let session = model.session else { return nil }
                return await session.body(
                    id, part: part == .request ? .request : .response, offset: offset, limit: limit, unpacked: unpacked)
            }
            hex.onCopy = { [weak self] _ in self?.say("Copied") }
            made = hex
            child = hex.widget
        }
        gtk_stack_add_named(cast(stack), child, Self.name(mode))
        return made
    }

    /// The code view that shows now, once it's laid out.
    var codeView: CodeView? {
        mode.flatMap { views[$0] as? CodeHolder }?.code
    }

    /// Shows how much of the code shows, and Show Whole Body, when it's cut.
    private func showStart() {
        guard let text = codeView?.text, text.isCut else {
            gtk_widget_set_visible(startLine, 0)
            return
        }
        gtk_label_set_text(cast(startLabel), BodyWords.start(of: text))
        gtk_widget_set_visible(startLine, 1)
        if focusesShowWhole {
            focusesShowWhole = false
            let focus = gtk_widget_get_root(widget).flatMap { gtk_root_get_focus($0) }
            if focus == copyButton {
                gtk_widget_grab_focus(showWhole)
            }
        }
    }

    // MARK: - Show Whole Body

    /// Opens the whole of the code that shows in a view of its own.
    func showWholeBody() {
        guard let presented = body?.body, let mode, whole == nil,
            let code = mode == .formatted ? presented.formatted ?? presented.raw : presented.raw
        else { return }
        let title = part == .request ? "Request Body" : "Response Body"
        let summary = BodyWords.summary(presented)
        let shown = shown
        Task { [weak self] in
            let text = await Task.detached(priority: .userInitiated) {
                CodeText(code, lineLimit: .max, byteLimit: .max, pieces: CodeText.longestLine)
            }.value
            guard let self, self.shown == shown, whole == nil else { return }
            let whole = WholeBody(text, title: title, summary: summary) { [weak self] in self?.copyBody() }
            whole.onClosed = { [weak self] in
                guard let self else { return }
                self.whole = nil
                if let waiting {
                    // The body that grew meanwhile shows now. Show Whole Body goes until its code
                    // is laid out, and Copy Body has the focus till then.
                    show(waiting)
                    if gtk_widget_get_visible(copyButton) != 0 {
                        gtk_widget_grab_focus(copyButton)
                        focusesShowWhole = true
                    }
                } else if gtk_widget_get_mapped(showWhole) != 0 {
                    gtk_widget_grab_focus(showWhole)
                }
            }
            self.whole = whole
            whole.present(over: widget)
        }
    }

    // MARK: - Copying

    /// Copies the body as the Mac's Copy Body does, by its mode: its text, or the image, or else
    /// the hex of the lines chosen, or of its first megabyte.
    func copyBody() {
        guard let presented = body?.body, let mode else { return }
        let clipboard = gtk_widget_get_clipboard(widget)
        if let text = presented.copyableText(in: mode) {
            gdk_clipboard_set_text(clipboard, text)
            say("Copied")
            return
        }
        if case .image = presented.kind, let texture = picture(of: presented) {
            gdk_clipboard_set_texture(clipboard, cast(texture))
            g_object_unref(raw(texture))
            say("Copied")
            return
        }
        if let hex = views[.hex] as? HexView {
            Task { [weak self] in
                guard let text = await hex.hexToCopy(), let self else { return }
                gdk_clipboard_set_text(gtk_widget_get_clipboard(widget), text)
                say("Copied")
            }
            return
        }
        gdk_clipboard_set_text(clipboard, HexLines.hex(presented.content.prefix(1 << 20)))
        say("Copied")
    }

    /// The image, as the preview read it, or read now: a reference to release.
    private func picture(of presented: BodyPresentation) -> OpaquePointer? {
        if let texture = (views[.preview] as? PreviewView)?.texture {
            g_object_ref(raw(texture))
            return texture
        }
        let bytes = presented.content.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        return gdk_texture_new_from_bytes(bytes, nil).map { cast($0) }
    }

    /// Says `words` at the bottom of the window, as a toast, such as "Copied".
    private func say(_ words: String) {
        DetailsBlocks.toast(words, from: widget)
    }
}

/// Where a mode's code view goes, once its text is laid out.
@MainActor
final class CodeHolder {
    let widget: Widget
    private(set) var code: CodeView?

    init() {
        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        g_object_ref_sink(raw(widget))
    }

    isolated deinit {
        g_object_unref(raw(widget))
    }

    func show(_ code: CodeView) {
        self.code = code
        gtk_box_append(cast(widget), code.widget)
    }
}
