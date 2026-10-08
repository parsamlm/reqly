import AppKit
import BodyKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An image body, on a checkerboard so transparency shows, with its format and size.
struct ImagePreview: View {
    let data: Data
    let format: ImageFormat
    /// Where the image came from. It names saved files, and `@2x` in it gives the point size.
    let url: URL?

    var body: some View {
        let info = ImageInfo(data: data)
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Checkerboard()
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(
                            maxWidth: info.pixelWidth.map(CGFloat.init), maxHeight: info.pixelHeight.map(CGFloat.init)
                        )
                        .padding(16)
                        .accessibilityLabel("The image")
                } else {
                    Text("Reqly can't show this image.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 300)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))

            VStack(spacing: 0) {
                DetailRow("Format", info.hasAlpha ? "\(format.rawValue), with transparency" : format.rawValue)
                if let dimensions = dimensions(info) {
                    DetailRow("Dimensions", dimensions)
                }
                DetailRow("Size", Format.size(Int64(data.count)))
            }

            HStack(spacing: 8) {
                Button("Open in Preview") { openInPreview() }
                Button("Save Image…") { save() }
            }
            .controlSize(.small)
        }
    }

    private func dimensions(_ info: ImageInfo) -> String? {
        guard let width = info.pixelWidth, let height = info.pixelHeight else { return nil }
        let pixels = "\(width.formatted()) × \(height.formatted()) pixels"
        let name = url?.lastPathComponent ?? ""
        for scale in [2, 3] where name.contains("@\(scale)x") {
            return "\(pixels) (\(width / scale) × \(height / scale) points at \(scale)x)"
        }
        return pixels
    }

    /// A name for the image's file, from its URL or its format.
    private var fileName: String {
        let name = url?.lastPathComponent ?? ""
        if !name.isEmpty, name.contains(".") {
            return name
        }
        return "image." + format.rawValue.lowercased()
    }

    private func openInPreview() {
        let folder = URL.temporaryDirectory.appending(path: "Reqly Images", directoryHint: .isDirectory)
        let file = folder.appending(path: fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
        } catch {
            return
        }
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? data.write(to: destination)
    }
}

/// What ImageIO reads from an image's header.
private struct ImageInfo {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var hasAlpha = false

    init(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            // ImageIO doesn't read SVG; AppKit gives its size in points.
            if let image = NSImage(data: data) {
                pixelWidth = Int(image.size.width)
                pixelHeight = Int(image.size.height)
            }
            return
        }
        pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
        pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
        hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }
}

/// The pattern that shows where an image is transparent.
private struct Checkerboard: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let light = colorScheme == .dark ? Color(white: 0.17) : .white
        let dark = colorScheme == .dark ? Color(white: 0.21) : Color(red: 0.93, green: 0.94, blue: 0.94)
        Canvas { context, size in
            let square: CGFloat = 10
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var squares = Path()
            for row in 0...Int(size.height / square) {
                for column in 0...Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    squares.addRect(
                        CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(squares, with: .color(dark))
        }
        .accessibilityHidden(true)
    }
}
