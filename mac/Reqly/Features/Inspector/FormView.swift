import BodyKit
import SwiftUI

/// A form's fields, for a body sent as `application/x-www-form-urlencoded` or as
/// `multipart/form-data`. Uploaded files show their name, type and size.
struct FormView: View {
    let fields: [FormField]?
    let parts: [MultipartPart]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let fields {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    DetailRow(field.name, field.value, monospaced: true)
                }
            }
            if let parts {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    DetailRow(part.name ?? "Unnamed part", Self.describe(part), monospaced: part.filename == nil)
                }
            }
            if (fields ?? []).isEmpty, (parts ?? []).isEmpty {
                Text("This form has no fields.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A text field's value, or what a file is.
    private static func describe(_ part: MultipartPart) -> String {
        let size = Format.size(Int64(part.body.count))
        if let filename = part.filename {
            return [filename, part.contentType, size].compactMap { $0 }.joined(separator: " · ")
        }
        guard let text = BodyText.decode(part.body, contentType: part.contentType) else {
            return [part.contentType ?? "Binary data", size].joined(separator: " · ")
        }
        return text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
    }
}
