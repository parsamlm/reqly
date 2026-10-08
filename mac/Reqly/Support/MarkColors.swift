import AppKit
import ReqlyModel
import SwiftUI

extension MarkColor {
    var title: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    /// System colors, so marks adapt to dark mode and Increase Contrast, as Finder's tags do.
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A dot in the color, for menus. It isn't a template, so menus keep its color.
    var menuImage: NSImage? {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [nsColor]))
        image?.isTemplate = false
        return image
    }
}
