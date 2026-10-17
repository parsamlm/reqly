# Microsoft's terms

Reqly for Windows comes with software from Microsoft that Microsoft licenses under its own terms,
which ask that people who get Reqly agree to them. Reqly asks once, the first time it opens, and
again whenever these texts change: `Help/Terms.cs` lists them.

- `WindowsAppSDK.txt` is `license.txt` from the Windows App SDK's NuGet packages, as Reqly.csproj
  pins them (Microsoft.WindowsAppSDK.WinUI 2.3.9 and the others, which carry the same text).
- `WindowsSDK.txt` is `sdk_license.txt` from Microsoft.Windows.SDK.BuildTools.MSIX 1.7.251221100,
  the Windows SDK's terms, which cover its interface for .NET (Microsoft.Windows.SDK.NET.dll and
  WinRT.Runtime.dll). The package's copy is Markdown; this one has its words without the marks.

The Visual C++ runtime, which comes with Swift's runtime, is under Microsoft's terms at
https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/, which Reqly links to.

When a package's version changes, copy its text again.
