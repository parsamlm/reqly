import SwiftUI

extension View {
    /// Colors text on a button filled with the accent color, such as Start Capturing. It picks
    /// black or white, whichever contrasts more with the accent color, so the text stays readable
    /// with any accent the user chooses. On Reqly teal that's black, in light and dark mode.
    func readableOnAccent() -> some View {
        modifier(ReadableOnAccent())
    }
}

private struct ReadableOnAccent: ViewModifier {
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        let accent = Color.accentColor.resolve(in: environment)
        // Relative luminance, as WCAG defines it. Above 0.179, black contrasts more than white.
        let luminance = 0.2126 * accent.linearRed + 0.7152 * accent.linearGreen + 0.0722 * accent.linearBlue
        content.foregroundStyle(luminance > 0.179 ? Color.black : Color.white)
    }
}
