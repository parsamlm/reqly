import BodyKit
import CGtk
import Foundation
import GtkBinding
import Presentation

/// An image body, as the Mac's preview shows it: the picture on a checkerboard, so its
/// transparency shows, in the style's own two shades; its format, its size in pixels and its size
/// in bytes; and Open With…, which asks which app to open it in, and Save Image…. GTK reads the
/// picture away from the window.
@MainActor
final class PreviewView {
    let widget: Widget
    let picture: Widget
    /// The rows under it: Format, Dimensions and Size, as they say.
    private(set) var facts: [(name: String, value: String)] = []
    /// The picture GTK read, or `nil` until it has, or when it can't.
    private(set) var texture: OpaquePointer?
    /// Whether GTK has tried to read it, and what went wrong if it couldn't.
    private(set) var isRead = false
    /// Runs once the picture's read, or GTK gave up.
    var onRead: (() -> Void)?
    /// Runs with what to say after saving or opening, such as why it didn't work.
    var onSay: ((String) -> Void)?

    private let data: Data
    private let format: ImageFormat
    private let url: @MainActor () async -> URL?
    private let board: Widget
    /// Where the facts' card goes, as the details' rows: each name beside its value, which you can
    /// select.
    private let factsBox: Widget
    private let cannotShow: Widget

    /// Shows `data`, a picture in `format`; `url` gives where it came from, which names its file.
    init(_ data: Data, format: ImageFormat, url: @escaping @MainActor () async -> URL?) {
        self.data = data
        self.format = format
        self.url = url
        BodyStyles.install()
        board = gtk_drawing_area_new()
        gtk_widget_set_hexpand(board, 1)
        picture = gtk_picture_new()
        gtk_picture_set_content_fit(cast(picture), GTK_CONTENT_FIT_SCALE_DOWN)
        gtk_picture_set_can_shrink(cast(picture), 1)
        gtk_widget_set_margin_top(picture, 16)
        gtk_widget_set_margin_bottom(picture, 16)
        gtk_widget_set_margin_start(picture, 16)
        gtk_widget_set_margin_end(picture, 16)
        setAccessibleLabel(picture, "The image")
        cannotShow = gtk_label_new(BodyWords.unreadablePicture)
        gtk_widget_add_css_class(cannotShow, "dim-label")
        gtk_widget_set_visible(cannotShow, 0)
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(cast(overlay), board)
        gtk_overlay_add_overlay(cast(overlay), picture)
        gtk_overlay_add_overlay(cast(overlay), cannotShow)
        gtk_widget_set_size_request(overlay, -1, 300)
        gtk_widget_add_css_class(overlay, "card")
        gtk_widget_set_overflow(overlay, GTK_OVERFLOW_HIDDEN)

        factsBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        let open = gtk_button_new_with_label("Open With…")!
        let save = gtk_button_new_with_label("Save Image…")!
        let buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
        gtk_box_append(cast(buttons), open)
        gtk_box_append(cast(buttons), save)

        widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)
        g_object_ref_sink(raw(widget))
        for child in [overlay, factsBox, buttons] {
            gtk_box_append(cast(widget), child)
        }

        setDraw(board) { cairo, width, height in
            let shades = BodyStyles.checkerboard(.now)
            cairo_set_source_rgb(cairo, shades.light, shades.light, shades.light)
            cairo_paint(cairo)
            cairo_set_source_rgb(cairo, shades.dark.0, shades.dark.1, shades.dark.2)
            let square = 10
            for row in 0...Int(height) / square {
                for column in 0...Int(width) / square where (row + column).isMultiple(of: 2) {
                    cairo_rectangle(
                        cairo, Double(column * square), Double(row * square), Double(square), Double(square))
                }
            }
            cairo_fill(cairo)
        }
        let manager = adw_style_manager_get_default()
        let board = board
        connect(raw(manager), "notify::dark", whileAlive: raw(board)) { gtk_widget_queue_draw(board) }
        connect(open, "clicked") { [weak self] in self?.openWith() }
        connect(save, "clicked") { [weak self] in self?.saveImage() }
        showFacts(width: nil, height: nil, hasAlpha: false)
        readPicture()
    }

    isolated deinit {
        g_object_unref(raw(widget))
        if let texture {
            g_object_unref(raw(texture))
        }
    }

    // MARK: - The picture

    /// Reads the picture away from the window, as a big one takes a moment.
    private func readPicture() {
        let data = data
        Task { [weak self, url] in
            let read = await Task.detached(priority: .userInitiated) { () -> Unchecked<OpaquePointer?> in
                let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
                defer { g_bytes_unref(bytes) }
                var error: UnsafeMutablePointer<GError>?
                let texture = gdk_texture_new_from_bytes(bytes, &error)
                if texture == nil {
                    _ = message(error)
                }
                return Unchecked(texture.map { cast($0) })
            }.value
            let name = await url()?.lastPathComponent ?? ""
            guard let self else {
                read.value.map { g_object_unref(raw($0)) }
                return
            }
            shownName = name
            show(read.value)
        }
    }

    private func show(_ texture: OpaquePointer?) {
        self.texture = texture
        isRead = true
        if let texture {
            gtk_picture_set_paintable(cast(picture), cast(texture))
            let width = Int(gdk_texture_get_width(cast(texture)))
            let height = Int(gdk_texture_get_height(cast(texture)))
            showFacts(width: width, height: height, hasAlpha: Self.hasAlpha(gdk_texture_get_format(cast(texture))))
        } else {
            gtk_widget_set_visible(picture, 0)
            gtk_widget_set_visible(cannotShow, 1)
        }
        onRead?()
    }

    /// Format, Dimensions and Size, as the Mac's rows say them, each value one you can select.
    private func showFacts(width: Int?, height: Int?, hasAlpha: Bool) {
        DetailsBlocks.empty(factsBox)
        facts = [("Format", BodyWords.format(format, hasAlpha: hasAlpha))]
        if let width, let height {
            facts.append(("Dimensions", BodyWords.dimensions(width: width, height: height, fileName: shownName)))
        }
        facts.append(("Size", ByteCount.text(Int64(data.count))))
        gtk_box_append(cast(factsBox), DetailsBlocks.card(facts.map { DetailsBlocks.row($0.name, value: $0.value) }))
    }

    /// The file's name, once the URL's known, for its 2x or 3x.
    private var shownName = ""

    /// Whether a texture's memory format keeps an alpha channel, as an image with transparency
    /// has.
    static func hasAlpha(_ format: GdkMemoryFormat) -> Bool {
        let opaque: [GdkMemoryFormat] = [
            GDK_MEMORY_R8G8B8, GDK_MEMORY_B8G8R8, GDK_MEMORY_R16G16B16, GDK_MEMORY_R16G16B16_FLOAT,
            GDK_MEMORY_R32G32B32_FLOAT, GDK_MEMORY_G8, GDK_MEMORY_G16, GDK_MEMORY_B8G8R8X8, GDK_MEMORY_X8R8G8B8,
            GDK_MEMORY_R8G8B8X8, GDK_MEMORY_X8B8G8R8,
        ]
        return !opaque.contains(format)
    }

    // MARK: - Opening and saving

    /// The picture as a file to open, named as its URL names it, in ``openingFolder(environment:)``,
    /// written away from the window as ``write(_:named:in:)`` says.
    func fileToOpen() async throws -> URL {
        guard let folder = Self.openingFolder() else { throw CocoaError(.fileNoSuchFile) }
        let name = BodyWords.fileName(for: format, url: await url())
        let data = data
        return try await Task.detached(priority: .userInitiated) { try Self.write(data, named: name, in: folder) }
            .value
    }

    /// Writes `data` as `name` in a folder of its own in `folder`, named for its bytes, and gives
    /// the file: a picture opened again has the same file, rather than one more copy each time, and
    /// another picture never writes over one a viewer may still show.
    nonisolated static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        let files = FileManager.default
        let own = folder.appending(path: folderName(for: data), directoryHint: .isDirectory)
        for made in [folder, own] {
            try files.createDirectory(
                at: made, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let file = own.appending(path: name)
        // Written once: the folder's name says what's in it.
        var status = stat()
        if stat(file.path, &status) != 0 || Int(status.st_size) != data.count {
            try data.write(to: file, options: .atomic)
        }
        return file
    }

    /// A folder's name for a picture's bytes: their FNV-1a hash and their count.
    nonisolated static func folderName(for data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(hash, radix: 16) + "-" + String(data.count)
    }

    /// Takes away the pictures written for you to open in an earlier run, as Reqly starts, so they
    /// don't pile up in `XDG_RUNTIME_DIR`, which is kept in memory, or in your cache folder.
    static func clearOpened() {
        guard let folder = openingFolder() else { return }
        Task.detached(priority: .utility) { removeAll(in: folder) }
    }

    /// Takes away everything in `folder`, but not the folder.
    nonisolated static func removeAll(in folder: URL) {
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? files.removeItem(at: folder.appending(path: name))
        }
    }

    /// The folder the pictures you open are written to: Reqly's in `XDG_RUNTIME_DIR`, which only
    /// you can open, as its icons' is, or in your cache folder. Never one in the temporary folder
    /// others share, which another account could make first, with links in it.
    static func openingFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let runtime = environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
            return URL(filePath: runtime, directoryHint: .isDirectory)
                .appending(path: "net.reqly.Reqly/images", directoryHint: .isDirectory)
        }
        let cache =
            environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? environment["HOME"].map { $0 + "/.cache" }
        return cache.map { URL(filePath: $0, directoryHint: .isDirectory).appending(path: "reqly/images") }
    }

    /// Opens the picture in an app you choose, through GTK's file launcher, which asks.
    private func openWith() {
        Task { [weak self] in
            guard let self else { return }
            let file: URL
            do {
                file = try await fileToOpen()
            } catch {
                onSay?("Reqly couldn't write the image to open it.")
                return
            }
            let opened = g_file_new_for_path(file.path)
            let launcher = gtk_file_launcher_new(opened)!
            g_object_unref(raw(opened))
            gtk_file_launcher_set_always_ask(launcher, 1)
            let (callback, context) = whenReady { [weak self] source, result in
                var error: UnsafeMutablePointer<GError>?
                if gtk_file_launcher_launch_finish(cast(source), result, &error) == 0, let error {
                    // Closing the list of apps isn't a problem.
                    let isDismissed =
                        error.pointee.domain == gtk_dialog_error_quark()
                        && error.pointee.code == Int32(GTK_DIALOG_ERROR_DISMISSED.rawValue)
                    let problem = message(error)
                    if !isDismissed {
                        self?.onSay?("Reqly couldn't open the image: \(problem)")
                    }
                }
                g_object_unref(raw(source))
            }
            gtk_file_launcher_launch(launcher, cast(gtk_widget_get_root(widget)), nil, callback, context)
        }
    }

    /// Asks where to save the picture, then saves it there.
    private func saveImage() {
        Task { [weak self] in
            guard let self, let window = gtk_widget_get_root(widget).map({ cast($0) as Widget }) else { return }
            let name = BodyWords.fileName(for: format, url: await url())
            guard let file = await FileDialogs.save(title: "Save Image", over: window, name: name) else { return }
            save(to: file)
        }
    }

    /// Writes the picture to `file`, as Save Image… does once you've chosen where.
    func save(to file: URL) {
        do {
            try data.write(to: file)
        } catch {
            onSay?("Reqly couldn't save the image to \(file.path).")
        }
    }
}
