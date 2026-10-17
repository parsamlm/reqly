# Assembles BoringSSL's x86-64 assembly for Windows (windows/third-party/boringssl-asm) into a static
# library, CNIOBoringSSLAsm.lib, which NIOSSL links on Windows. BoringSSL writes it for NASM, which
# SwiftPM can't run, so it's built before the Swift build, as SQLite is.
#   windows\scripts\build-boringssl-asm.ps1 -PackagePath <core or ReqlyCore> [-Arch x64|arm64] [-Nasm <nasm.exe>]
# NASM is the one given, or $env:NASM, nasm on the PATH, or windows\.build\nasm\nasm.exe. The library
# goes in windows\.build\boringssl-asm\<arch>, and is built again only when its sources change.
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [string]$Nasm = ''
)
$ErrorActionPreference = 'Stop'

# ARM64's assembly comes in the package itself, for clang; NIOSSL leaves it off on Windows.
if ($Arch -ne 'x64') { return }
$root = Resolve-Path "$PSScriptRoot\..\.."
$source = Join-Path $root 'windows\third-party\boringssl-asm'
$out = Join-Path $root "windows\.build\boringssl-asm\$Arch"
$lib = Join-Path $out 'CNIOBoringSSLAsm.lib'

# The NIOSSL the package builds with, edited or checked out: its BoringSSL has to be the one these
# files come from, and its include folder has the symbol prefixes.
$state = Join-Path $PackagePath '.build\workspace-state.json'
if (-not (Test-Path $state)) {
    $ErrorActionPreference = 'Continue'
    swift package resolve --package-path $PackagePath | Out-Host
    $ErrorActionPreference = 'Stop'
}
$niossl = Join-Path $PackagePath '.build\checkouts\swift-nio-ssl'
$edit = (Get-Content $state -Raw | ConvertFrom-Json).object.dependencies |
    Where-Object { $_.packageRef.identity -eq 'swift-nio-ssl' -and $_.state.name -eq 'edited' } | Select-Object -First 1
if ($edit) { $niossl = $edit.state.path }
$boringssl = Join-Path $niossl 'Sources\CNIOBoringSSL'
$revision = (Get-Content (Join-Path $source 'REVISION')).Trim()
if ((Get-Content (Join-Path $boringssl 'hash.txt') -Raw) -notmatch $revision) {
    throw "NIOSSL's BoringSSL isn't $revision, the revision of windows\third-party\boringssl-asm. Download its assembly at NIOSSL's revision; the README says how."
}

$sources = @(Get-ChildItem $source -Recurse -Filter '*.asm')
$newest = ($sources + @(Get-Item (Join-Path $boringssl 'include\boringssl_prefix_symbols_nasm.inc')) | Measure-Object -Property LastWriteTime -Maximum).Maximum
if ((Test-Path $lib) -and (Get-Item $lib).LastWriteTime -gt $newest) { return }

if (-not $Nasm) { $Nasm = $env:NASM }
if (-not $Nasm) { $Nasm = (Get-Command nasm -ErrorAction SilentlyContinue).Source }
if (-not $Nasm) { $Nasm = Join-Path $root 'windows\.build\nasm\nasm.exe' }
if (-not (Test-Path $Nasm)) {
    throw 'NASM is needed for BoringSSL''s assembly: put nasm.exe on the PATH, set NASM to it, or copy it to windows\.build\nasm.'
}
New-Item -ItemType Directory -Force $out | Out-Null

# As BoringSSL's own build assembles them, with NIOSSL's prefix. From here on, the tools' exit codes count.
$ErrorActionPreference = 'Continue'
$objects = foreach ($file in $sources) {
    $object = Join-Path $out ($file.BaseName + '.obj')
    & $Nasm -f win64 -DBORINGSSL_PREFIX=CNIOBoringSSL "-I$boringssl\include\" -o $object $file.FullName
    if ($LASTEXITCODE) { throw "NASM couldn't assemble $($file.Name)." }
    $object
}
llvm-lib "/OUT:$lib" @objects
if ($LASTEXITCODE) { throw 'Making CNIOBoringSSLAsm.lib failed.' }
