import Foundation
import ReqlyModel
import Testing

@testable import ReqlyApp

/// Colors that show something on their own stand out from what's behind them: text at 4.5:1,
/// and a part of the window, such as a mark's stripe, at 3:1, in light, dark and high contrast.
@Suite struct ContrastTests {
    /// A mark's stripe, on its row's tint over the list's background, libadwaita's view color.
    @MainActor @Test func showsEveryMarksStripeAtThreeToOne() {
        let styles = [
            ("light", ListStyles.light, "#ffffff"), ("dark", ListStyles.dark, "#1e1e1e"),
            ("light, high contrast", ListStyles.lightContrast, "#ffffff"),
            ("dark, high contrast", ListStyles.darkContrast, "#1e1e1e"),
        ]
        for (style, palette, list) in styles {
            for color in MarkColor.allCases {
                let row = Self.over(Self.rgb(palette.marks[color]!), alpha: palette.tint, Self.rgb(list))
                let contrast = Self.contrast(Self.rgb(palette.stripe(color)), row)
                #expect(contrast >= 3, "\(style): \(color)'s stripe is \(contrast):1")
            }
        }
    }

    /// The Raw page's notes about bodies, on its background, as code's comments are.
    @MainActor @Test func showsTheRawPagesNotesAtFourAndAHalfToOne() {
        let styles = [
            (BodyStyles.Look(isDark: false, isHighContrast: false), "#F6F7F7"),
            (BodyStyles.Look(isDark: true, isHighContrast: false), "#242528"),
            (BodyStyles.Look(isDark: false, isHighContrast: true), "#FFFFFF"),
            (BodyStyles.Look(isDark: true, isHighContrast: true), "#161618"),
        ]
        for (look, background) in styles {
            let back = Self.rgb(background)
            let contrast = Self.contrast(Self.color(BodyStyles.css(.comment, look), over: back), back)
            #expect(contrast >= 4.5, "\(look): the notes are \(contrast):1")
        }
    }

    typealias RGB = (Double, Double, Double)

    /// `#rrggbb` as red, green and blue from 0 to 1.
    static func rgb(_ hex: String) -> RGB {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return (Double(value >> 16 & 255) / 255, Double(value >> 8 & 255) / 255, Double(value & 255) / 255)
    }

    /// A CSS color, `#rrggbb` or `rgba(r,g,b,a)`, as it shows over `background`.
    static func color(_ css: String, over background: RGB) -> RGB {
        guard css.hasPrefix("rgba(") else { return rgb(css) }
        let parts = css.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0) }
        return over((parts[0] / 255, parts[1] / 255, parts[2] / 255), alpha: parts[3], background)
    }

    static func over(_ color: RGB, alpha: Double, _ background: RGB) -> RGB {
        (
            color.0 * alpha + background.0 * (1 - alpha), color.1 * alpha + background.1 * (1 - alpha),
            color.2 * alpha + background.2 * (1 - alpha)
        )
    }

    /// The contrast of two colors, as WCAG works it out.
    static func contrast(_ one: RGB, _ other: RGB) -> Double {
        func luminance(_ color: RGB) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
        }
        let (light, dark) = (max(luminance(one), luminance(other)), min(luminance(one), luminance(other)))
        return ((light + 0.05) / (dark + 0.05) * 100).rounded() / 100
    }
}
