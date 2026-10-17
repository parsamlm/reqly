# Builds Reqly for Windows: ReqlyCore.dll from the Swift core, then the WinUI app around it.
#   windows\scripts\app.ps1 [-Configuration Debug|Release]
param([ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug')
$ErrorActionPreference = 'Stop'

$root = Resolve-Path "$PSScriptRoot\..\.."
$swift = $Configuration.ToLowerInvariant()
& "$PSScriptRoot\core.ps1" build -Package ReqlyCore --configuration $swift --product ReqlyCore
if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Windows PowerShell takes a native program's warnings on stderr for errors, so only exit codes
# count from here on.
$ErrorActionPreference = 'Continue'
$bin = swift build --package-path "$root\windows\ReqlyCore" --triple x86_64-unknown-windows-msvc `
    --configuration $swift --show-bin-path 2>$null | Select-Object -Last 1
# Nothing is sent automatically: .NET's build tools don't report back either.
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
dotnet build "$root\windows\Reqly\Reqly.csproj" -c $Configuration -p:ReqlyCoreDir="$bin" -nologo
exit $LASTEXITCODE
