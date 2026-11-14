import CGtk
import Foundation
import GtkBinding

/// The self-check's pictures of the window, as PNG files: a widget's own, drawn with the window's
/// renderer at the screen's scale, which misses popovers and menus; and the X screen's, from
/// ImageMagick's import, menus and all. Parts keep them in ``SelfCheck/picture(_:)``'s folder.
@MainActor
enum Pictures {
    /// A picture's size in pixels.
    struct Size: Equatable, CustomStringConvertible {
        var width: Int
        var height: Int
        var description: String { "\(width) × \(height)" }
    }

    /// Draws `widget`, such as the window or one of its pages, as it shows now, into a PNG at
    /// `file`, with as many pixels as the screen gives it: twice its size at a scale of 2. Gives
    /// the picture's size.
    static func own(_ widget: Widget, to file: URL) throws -> Size {
        let width = gtk_widget_get_width(widget)
        let height = gtk_widget_get_height(widget)
        guard width > 0, height > 0, let native = gtk_widget_get_native(widget),
            let renderer = gtk_native_get_renderer(native)
        else { throw SelfCheck.Failure("\(typeName(raw(widget))) doesn't show, so there's nothing to draw") }
        // The surface's own scale, which can be a fraction, such as 1.25.
        let scale = gtk_native_get_surface(native).map { gdk_surface_get_scale($0) } ?? 1
        let paintable = gtk_widget_paintable_new(widget)!
        defer { g_object_unref(raw(paintable)) }
        let snapshot = gtk_snapshot_new()!
        gtk_snapshot_scale(snapshot, Float(scale), Float(scale))
        gdk_paintable_snapshot(cast(paintable), cast(snapshot), Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else {
            throw SelfCheck.Failure("\(typeName(raw(widget))) drew nothing")
        }
        defer { gsk_render_node_unref(node) }
        let pixels = Size(
            width: Int((Double(width) * scale).rounded()), height: Int((Double(height) * scale).rounded()))
        var viewport = graphene_rect_t()
        graphene_rect_init(&viewport, 0, 0, Float(pixels.width), Float(pixels.height))
        guard let texture = gsk_renderer_render_texture(renderer, node, &viewport) else {
            throw SelfCheck.Failure("the renderer drew nothing for \(typeName(raw(widget)))")
        }
        defer { g_object_unref(raw(texture)) }
        guard gdk_texture_save_to_png(texture, file.path) != 0 else {
            throw SelfCheck.Failure("couldn't save \(file.path)")
        }
        return Size(width: Int(gdk_texture_get_width(texture)), height: Int(gdk_texture_get_height(texture)))
    }

    /// The whole X screen, as ImageMagick's import takes it, into a PNG at `file`. Gives the
    /// picture's size.
    static func screen(to file: URL) async throws -> Size {
        guard let display = ProcessInfo.processInfo.environment["DISPLAY"] else {
            throw SelfCheck.Failure("there's no X screen to take a picture of")
        }
        let ended = try await Program.run(["import", "-display", display, "-window", "root", file.path], seconds: 20)
        if let problem = ended.problem {
            throw SelfCheck.Failure("import didn't take the picture: \(problem)")
        }
        return try size(of: file)
    }

    /// A PNG's size, from its header.
    static func size(of file: URL) throws -> Size {
        let bytes = [UInt8](try Data(contentsOf: file).prefix(24))
        // The signature, then the header chunk: its length, "IHDR", and the width and height.
        guard bytes.count == 24, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            bytes[12..<16] == [0x49, 0x48, 0x44, 0x52]
        else { throw SelfCheck.Failure("\(file.lastPathComponent) isn't a PNG") }
        func number(at offset: Int) -> Int {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        return Size(width: number(at: 16), height: number(at: 20))
    }
}

extension SelfCheck {
    /// ``Pictures/own(_:to:)``, tried again over the next frames while `widget` draws nothing, as
    /// it can for a moment after the style changes, until GTK has laid it out again.
    func ownPicture(_ widget: Widget, to file: URL) async throws -> Pictures.Size {
        for _ in 0..<10 {
            if let size = try? Pictures.own(widget, to: file) {
                return size
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try Pictures.own(widget, to: file)
    }

    /// Where a part keeps a picture: `$REQLY_PICTURES`, when it names a folder, as app.sh's
    /// `--pictures` has it, or else the scratch folder, which goes. `name` is the file's, such as
    /// `window-dark.png`.
    func picture(_ name: String) throws -> URL {
        let folder =
            ProcessInfo.processInfo.environment["REQLY_PICTURES"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? scratch.appending(path: "Pictures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }
}
