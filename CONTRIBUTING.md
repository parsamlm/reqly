# Contributing to Reqly

Thank you for helping. Reports, ideas and changes are all welcome.

## Reporting a problem

[Open an issue](https://github.com/parsamlm/reqly/issues/new/choose) that says what you did, what you expected, and what happened instead, with the versions of Reqly and of macOS or Windows. After a crash, Reqly offers to open an issue for you with the crash report filled in, which you can read and edit first.

Report security problems privately instead, as [SECURITY.md](SECURITY.md) says.

## Suggesting a feature

Open an issue that says what you're trying to do, and where Reqly gets in the way. The [roadmap](ROADMAP.md) says what's planned, phase by phase.

## Changing the code

For anything bigger than a fix, open an issue first to talk about the approach, before you spend time on it.

1. Fork the repository, and make a branch from `main`.
2. Build Reqly as the [README](README.md#building) says for the Mac, or [windows/README.md](windows/README.md#building) for Windows. [ARCHITECTURE.md](ARCHITECTURE.md) explains how the parts fit together.
3. Run the tests for what you changed. The core's run on macOS and Linux:

   ```bash
   swift test --package-path core
   ```

   The Mac's own modules have theirs in `mac/ReqlyMacKit`, and the Windows app's core interface in `windows/ReqlyCore`. On Windows, `windows\scripts\core.ps1 test` runs the core's tests with the patches Windows needs. CI runs them on macOS, Linux and Windows, and every test has to pass on each.
4. Format Swift code with `swift format`, as CI checks it:

   ```bash
   xcrun swift-format lint --strict --recursive --configuration .swift-format mac/Reqly mac/ReqlyHelper mac/ReqlyMacKit/Sources mac/ReqlyMacKit/Tests mac/ReqlyMacKit/Package.swift core/Sources core/Tests core/Package.swift windows/ReqlyCore/Sources windows/ReqlyCore/Tests windows/ReqlyCore/Package.swift
   ```

5. Open a pull request that says what changed and why, and how you checked it.

Keep each pull request to one change, and write it the way the code around it is written. The words the app shows are plain: short sentences, everyday words. The [design guidelines](design/GUIDELINES.md) cover the logo, color, type and icons.

## License

Reqly is released under the [MIT License](LICENSE). When you send a pull request, you agree that your change is released under it too. The Reqly name and logo aren't covered by it; see [TRADEMARKS.md](TRADEMARKS.md).

## Code of conduct

Everyone who takes part follows the [code of conduct](CODE_OF_CONDUCT.md).
