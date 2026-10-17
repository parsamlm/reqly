# Builds or tests the core (ReqlyKit), or ReqlyCore.dll, on Windows, with the bundled SQLite that
# GRDB links, and SwiftNIO and swift-nio-ssl with Reqly's patches for Windows (windows/patches).
#   windows\scripts\core.ps1 build|test [-Package core|ReqlyCore] [-Arch x64|arm64] [more swift options]
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('build', 'test')][string]$Command,
    [ValidateSet('core', 'ReqlyCore')][string]$Package = 'core',
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [Parameter(ValueFromRemainingArguments)][string[]]$Rest = @()
)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path "$PSScriptRoot\..\.."
$packagePath = if ($Package -eq 'core') { "$root\core" } else { "$root\windows\ReqlyCore" }
# On Windows, SwiftPM leaves the packages it builds edited copies of, the patched ones, out of
# Package.resolved, which belongs to the repository, so the file goes back as it was afterwards.
$resolved = Join-Path $packagePath 'Package.resolved'
$pinned = [System.IO.File]::ReadAllBytes($resolved)
$code = 1
try {
    & "$PSScriptRoot\build-sqlite.ps1" -Arch $Arch | Out-Host
    $sqlite = Join-Path $root "windows\.build\sqlite\$Arch"
    # SwiftNIO and swift-nio-ssl with the fixes for Windows their releases don't have yet. NIOSSL's
    # copy also tells the next step which BoringSSL it has.
    & "$PSScriptRoot\patch-packages.ps1" -PackagePath $packagePath | Out-Host
    # BoringSSL's assembly, which NIOSSL links on x86-64: TLS is many times slower without it.
    & "$PSScriptRoot\build-boringssl-asm.ps1" -PackagePath $packagePath -Arch $Arch | Out-Host
    $boringssl = Join-Path $root "windows\.build\boringssl-asm\$Arch"
    $triple = if ($Arch -eq 'arm64') { 'aarch64-unknown-windows-msvc' } else { 'x86_64-unknown-windows-msvc' }

    # GRDB finds sqlite3.h in the bundled source and sqlite3.lib in the build folder, and NIOSSL
    # finds CNIOBoringSSLAsm.lib in its own. Windows PowerShell takes a native program's warnings on
    # stderr for errors, so only its exit code counts.
    $ErrorActionPreference = 'Continue'
    swift $Command --package-path $packagePath --triple $triple `
        -Xcc "-I$root\windows\third-party\sqlite" -Xswiftc "-L$sqlite" -Xswiftc "-L$boringssl" @Rest
    $code = $LASTEXITCODE
}
finally {
    [System.IO.File]::WriteAllBytes($resolved, $pinned)
}
exit $code
