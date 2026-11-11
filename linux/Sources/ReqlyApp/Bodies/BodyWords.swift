import BodyKit
import Foundation
import Presentation
import ReqlyModel

/// What a body's view says, as the Mac's body section says it: the line over the body, the
/// modes' titles, the notes under it, and what its form, picture and hex views say. None of it
/// needs a window.
enum BodyWords {
    /// What the line over the body says it is, such as "JSON · 1.2 KB", or
    /// "gRPC · 3 messages · 1.2 KB".
    static func summary(_ body: BodyPresentation, locale: Locale = .current) -> String {
        var pieces = [body.kind.name]
        if let count = body.messageCount {
            pieces.append(count == 1 ? "1 message" : "\(count.formatted(.number.locale(locale))) messages")
        }
        pieces.append(ByteCount.text(Int64(body.wireSize)))
        return pieces.joined(separator: " · ")
    }

    /// A mode's title on its button. Raw is "Text" for plain text, which isn't code, though a
    /// form's stays Raw.
    static func title(of mode: BodyMode, in body: BodyPresentation) -> String {
        switch mode {
        case .formatted: "Formatted"
        case .tree: "Tree"
        case .raw: body.raw?.isCode == false && body.kind != .form ? "Text" : "Raw"
        case .preview: "Preview"
        case .form: "Form"
        case .hex: "Hex"
        }
    }

    /// What shows for a body with nothing in it.
    static func empty(_ part: MessagePart) -> String {
        part == .request ? "This request has no body." : "This response has no body."
    }

    /// The notes under the body: a gRPC response's status, more about its stream, what the body
    /// was unpacked from, and where its text stops.
    static func footnotes(_ body: BodyPresentation) -> [String] {
        var notes: [String] = []
        if let status = body.grpcStatus {
            notes.append("gRPC status: \(status.code) \(status.name)\(status.message.map { ". \($0)" } ?? "")")
        }
        notes += body.details
        if let encoding = body.unpackedFrom {
            notes.append(
                "Unpacked from \(encoding): \(ByteCount.text(Int64(body.wireSize))) became "
                    + "\(ByteCount.text(Int64(body.content.count))).")
        }
        if body.isTruncated {
            notes.append(
                "Showing the first \(ByteCount.text(Int64(BodyPresentation.displayLimit))) of "
                    + "\(ByteCount.text(Int64(body.content.count))).")
        }
        return notes
    }

    /// What the page says when it shows only the start of a long body: how many of its lines, or
    /// of its bytes, when its first lines are long.
    static func start(of text: CodeText, locale: Locale = .current) -> String {
        if text.shownLines < text.lines {
            let shown = text.shownLines.formatted(.number.locale(locale))
            return "Showing the first \(shown) lines of \(text.lines.formatted(.number.locale(locale)))."
        }
        return "Showing the first \(ByteCount.text(Int64(text.shownBytes))) of \(ByteCount.text(Int64(text.bytes)))."
    }

    // MARK: - Forms

    /// What a form shows when it has nothing in it.
    static let noFields = "This form has no fields."

    /// A multipart form's part: its value, when it's text, or what it holds, such as
    /// "map.png · image/png · 92 B" for a file.
    static func describe(_ part: MultipartPart) -> String {
        let size = ByteCount.text(Int64(part.body.count))
        if let filename = part.filename {
            return [filename, part.contentType, size].compactMap { $0 }.joined(separator: " · ")
        }
        guard let text = BodyText.decode(part.body, contentType: part.contentType) else {
            return [part.contentType ?? "Binary data", size].joined(separator: " · ")
        }
        return text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
    }

    /// A part's name, or what to call one that has none.
    static func name(of part: MultipartPart) -> String {
        part.name ?? "Unnamed part"
    }

    // MARK: - Pictures

    /// The picture's format, such as "PNG, with transparency".
    static func format(_ format: ImageFormat, hasAlpha: Bool) -> String {
        hasAlpha ? "\(format.rawValue), with transparency" : format.rawValue
    }

    /// Its size in pixels, such as "32 × 24 pixels", with its size in points for a picture
    /// whose file's name says it's drawn at 2x or 3x, as `icon@2x.png` does.
    static func dimensions(width: Int, height: Int, fileName: String = "", locale: Locale = .current) -> String {
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        let pixels = "\(width.formatted(number)) × \(height.formatted(number)) pixels"
        for scale in [2, 3] where fileName.contains("@\(scale)x") {
            return "\(pixels) (\(width / scale) × \(height / scale) points at \(scale)x)"
        }
        return pixels
    }

    /// The name to save or open a picture as: its URL's last part, when it has the picture's
    /// format's extension, or with that in place of another; or else "image" and its format's.
    /// The server names it, so it can't lead out of its folder, hide as a dot file, or open as
    /// anything but a picture. A long name is cut short, keeping its extension, to fit
    /// ``longestFileName``.
    static func fileName(for format: ImageFormat, url: URL?) -> String {
        let extensions = fileExtensions(of: format)
        // The last part is decoded, so a %2F in it is a slash.
        let last = url?.lastPathComponent.split(separator: "/").last ?? ""
        let name = last.drop { $0 == "." }
        guard let dot = name.lastIndex(of: ".") else { return "image." + extensions[0] }
        let found = String(name[name.index(after: dot)...])
        return cut(name[..<dot], keeping: extensions.contains(found.lowercased()) ? found : extensions[0])
    }

    /// The longest name a picture's file gets, in bytes: well under the 255 file systems take.
    static let longestFileName = 200

    /// `stem` with the extension `kept`, the stem cut short at a character's end so the name fits
    /// ``longestFileName``.
    private static func cut(_ stem: Substring, keeping kept: String) -> String {
        let room = longestFileName - kept.utf8.count - 1
        var end = stem.startIndex
        var bytes = 0
        for index in stem.indices {
            bytes += stem[index].utf8.count
            guard bytes <= room else { break }
            end = stem.index(after: index)
        }
        return String(stem[..<end]) + "." + kept
    }

    /// A format's file extensions, the one a picture is named with first.
    private static func fileExtensions(of format: ImageFormat) -> [String] {
        switch format {
        case .jpeg: ["jpeg", "jpg", "jpe"]
        case .tiff: ["tiff", "tif"]
        case .heic: ["heic", "heif"]
        default: [format.rawValue.lowercased()]
        }
    }

    /// What shows in place of a picture GTK can't read.
    static let unreadablePicture = "Reqly can't show this image."

    // MARK: - Hex

    /// An exact count, such as "12,871 bytes", for where every byte matters.
    static func bytes(_ count: Int, locale: Locale = .current) -> String {
        count == 1 ? "1 byte" : "\(count.formatted(.number.locale(locale))) bytes"
    }

    /// The lines chosen in the hex view, such as "32 bytes selected at offset 16".
    static func selected(_ bytes: Range<Int>, locale: Locale = .current) -> String {
        "\(Self.bytes(bytes.count, locale: locale)) selected at offset \(bytes.lowerBound.formatted(.number.locale(locale)))"
    }
}
