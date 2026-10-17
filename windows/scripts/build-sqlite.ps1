# Builds the bundled SQLite (windows/third-party/sqlite) into a static library, sqlite3.lib, for
# GRDB to link. GRDB looks for a SQLite the system provides, and Windows has none to build against.
#   windows\scripts\build-sqlite.ps1 [-Arch x64|arm64]
# The library goes in windows\.build\sqlite\<arch>. It's built again only when the source changes.
param([ValidateSet('x64', 'arm64')][string]$Arch = 'x64')
$ErrorActionPreference = 'Stop'

$root = Resolve-Path "$PSScriptRoot\..\.."
$source = Join-Path $root 'windows\third-party\sqlite'
$out = Join-Path $root "windows\.build\sqlite\$Arch"
$lib = Join-Path $out 'sqlite3.lib'
if ((Test-Path $lib) -and (Get-Item $lib).LastWriteTime -gt (Get-Item "$source\sqlite3.c").LastWriteTime) { return }
New-Item -ItemType Directory -Force $out | Out-Null

# Visual Studio's C++ compiler and librarian, for this architecture.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Import-Module (Join-Path $vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments "-arch=$Arch -host_arch=$hostArch" | Out-Null

# What GRDB and Reqly's search use: full-text search and WAL snapshots. Like the Mac's SQLite, a
# commit in WAL mode doesn't wait for the disk, only checkpoints do, and the API checks its
# arguments. /MD matches the C runtime Swift links on Windows. From here on, only the tools' exit
# codes count.
$ErrorActionPreference = 'Continue'
$defines = '/DSQLITE_ENABLE_FTS5', '/DSQLITE_ENABLE_SNAPSHOT', '/DSQLITE_THREADSAFE=1', '/DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1',
    '/DSQLITE_ENABLE_API_ARMOR'
cl.exe /nologo /c /O2 /MD /W0 @defines "/Fo$out\sqlite3.obj" "$source\sqlite3.c"
if ($LASTEXITCODE) { throw 'Compiling SQLite failed.' }
lib.exe /nologo "/OUT:$lib" "$out\sqlite3.obj"
if ($LASTEXITCODE) { throw 'Making sqlite3.lib failed.' }
