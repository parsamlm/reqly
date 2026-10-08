import ReqlyModel
import SwiftUI

/// The cookies a request sent, or the ones a response set. Like the cookie headers, their values
/// stay hidden until you choose to show them.
struct CookiesSection: View {
    var sent: [RequestCookie] = []
    var set: [ResponseCookie] = []
    @State private var isRevealed = false

    var body: some View {
        let count = sent.count + set.count
        if count > 0 {
            DetailSection("Cookies", count: count) {
                ForEach(Array(sent.enumerated()), id: \.offset) { _, cookie in
                    CookieRow(name: cookie.name, value: cookie.value, attributes: [], isRevealed: isRevealed)
                }
                ForEach(Array(set.enumerated()), id: \.offset) { _, cookie in
                    CookieRow(
                        name: cookie.name, value: cookie.value, attributes: Self.attributes(of: cookie),
                        isRevealed: isRevealed)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(isRevealed ? "Hide Values" : "Show Values") { isRevealed.toggle() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }

    /// When a cookie expires, then the rest of its attributes.
    private static func attributes(of cookie: ResponseCookie) -> [String] {
        var words: [String] = []
        if let date = cookie.expiryDate {
            words.append("Expires \(date.formatted(date: .abbreviated, time: .shortened))")
        } else if let expires = cookie.expires {
            words.append("Expires \(expires)")
        }
        return words + cookie.attributes
    }
}

private struct CookieRow: View {
    let name: String
    let value: String
    let attributes: [String]
    let isRevealed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name.isEmpty ? "No name" : name)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(isRevealed ? value : String(repeating: "•", count: min(max(value.count, 8), 16)))
                    .textSelection(.enabled)
                    .accessibilityLabel(isRevealed ? value : "Hidden")
                if !attributes.isEmpty {
                    Text(attributes.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout.monospaced())
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider() }
    }
}
