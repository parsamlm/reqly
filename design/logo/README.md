# Reqly logo

The app icon is a glass disc sitting on a line of traffic. Seen through the glass, the line shifts: Reqly lets you see into your traffic. It contains no text.

For how to use the logo, colors, type and voice, see the [design guidelines](../GUIDELINES.md).

The files in this folder are not covered by the MIT License. The Reqly name and logo are reserved; see [TRADEMARKS.md](../../TRADEMARKS.md).

## Files

| Path | What it is |
|---|---|
| `Reqly.icon/` | Icon Composer document, the source of the macOS and iOS app icon. It covers the default, dark, tinted and clear appearances. Add it to the app target in Xcode. |
| `Reqly.icon/Assets/` | The three vector layers on a 1024 × 1024 canvas: `line.svg` (the traffic), `inner-line.svg` (the line seen through the glass) and `disc.svg` (the glass). |
| `exports/reqly-icon-default.png`, `exports/reqly-icon-dark.png` | 1024 px renders for the README, website and App Store. |
| `exports/reqly-icon.svg` | A flat vector version of the icon for the web. |
| `wordmark/reqly-wordmark-on-light.svg`, `wordmark/reqly-wordmark-on-dark.svg` | The "Reqly" wordmark, for light and dark backgrounds. |
| `lockup/reqly-lockup-on-light.svg`, `lockup/reqly-lockup-on-dark.svg` | The icon and wordmark together, for light and dark backgrounds. |
| `menubar/MenuBarIcon.imageset/` | Menu-bar template image (18 pt). Drop it into `Assets.xcassets`. |

## Wordmark

"Reqly" is drawn letter by letter rather than typeset, so it needs no font and has no font license. Every letter is a single line with round ends, like the lines in the icon. The rounded "y" and the small foot on the "l" give it a friendly feel.

| Measure | Value (font units) |
|---|---|
| Cap height (R) | 700 |
| x-height | 520 |
| Ascender (l) / descender (q, y) | 740 / −210 |
| Line weight | 84 |

Ink colors: `#131816` on light backgrounds, `#F2F5F4` on dark backgrounds.

## Using the logo in a README

This header switches between the light and dark versions with GitHub's theme:

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/logo/lockup/reqly-lockup-on-dark.svg">
    <img alt="Reqly" src="design/logo/lockup/reqly-lockup-on-light.svg" width="320">
  </picture>
</p>
```

## Colors

| Part | Default (light) | Dark |
|---|---|---|
| Background | `#30D3B5` → `#0A9882` (top to bottom) | `#323837` → `#0E1211` |
| Disc (glass) | `#FFFFFF` | `#3FDDC0` |
| Line seen through the disc | `#0E9F88` | `#0B2F29` |
| Traffic line | `#FFFFFF` at 62% | `#E6EEEC` |

The tinted and clear appearances are derived by the system from these layers.
