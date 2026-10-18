# Accessibility

Reqly is for everyone who builds or tests software, however they use their computer.

## Where it runs

- **Reqly for Mac,** on macOS 26 or later. It's built from macOS's own controls, so it works with VoiceOver and the keyboard, and Reqly's own views carry labels for VoiceOver. In the request list, VoiceOver reads each request's status, and whether it's pinned, marked with a color, or has a comment. Text and backgrounds use macOS's own colors, which follow light and dark mode and Increase Contrast, and the [design guidelines](design/GUIDELINES.md) ask that every screen be checked in light and dark mode and with Increase Contrast on.
- **Reqly for Windows,** on Windows 11, in beta. It's built from WinUI's controls, which work with Narrator and the keyboard, and it follows Windows' light and dark mode. Its buttons that show only an icon have names for screen readers.

## Known limitations

- Reqly for Windows hasn't yet been checked with Narrator and with Windows' contrast themes as thoroughly as Reqly for Mac has with VoiceOver.

## Reporting a barrier

If something in Reqly is hard or impossible to use the way you work, [report it](https://github.com/parsamlm/reqly/issues/new?template=accessibility.yml): say what you were trying to do, how you use your computer, and what got in the way. Barriers are treated as bugs.
