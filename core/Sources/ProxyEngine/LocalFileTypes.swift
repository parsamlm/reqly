import Foundation

/// The types of the files Map Local answers with, by their extensions, and the other way round,
/// for a response saved as a file to answer with.
public enum LocalFileTypes {
    /// Each extension and the type a file with it is sent as. A type's usual extension comes first.
    static let types: [(fileExtension: String, type: String)] = [
        ("json", "application/json"), ("html", "text/html; charset=utf-8"), ("htm", "text/html; charset=utf-8"),
        ("css", "text/css"), ("js", "text/javascript"), ("mjs", "text/javascript"),
        ("txt", "text/plain; charset=utf-8"), ("xml", "application/xml"), ("png", "image/png"),
        ("jpg", "image/jpeg"), ("jpeg", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp"),
        ("svg", "image/svg+xml"), ("ico", "image/x-icon"), ("pdf", "application/pdf"), ("mp4", "video/mp4"),
        ("mp3", "audio/mpeg"), ("wasm", "application/wasm"), ("woff", "font/woff"), ("woff2", "font/woff2"),
    ]

    /// The type of a file Map Local answers with, from its extension.
    public static func contentType(forFile path: String) -> String {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return types.first { $0.fileExtension == fileExtension }?.type ?? "application/octet-stream"
    }

    /// The extension a file of a type usually has, such as `json` for
    /// `application/json; charset=utf-8`, or `nil` for a type Map Local doesn't know.
    public static func fileExtension(forType contentType: String) -> String? {
        let type = mediaType(contentType)
        return types.first { mediaType($0.type) == type }?.fileExtension
    }

    /// The type without its parameters, such as `text/html` for `text/html; charset=utf-8`.
    private static func mediaType(_ contentType: String) -> String {
        (contentType.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }
}
