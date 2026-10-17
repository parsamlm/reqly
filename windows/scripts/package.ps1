# Makes Reqly for Windows' installer and its updates, with Velopack:
#   windows\scripts\package.ps1 [-Replace]
# It builds ReqlyCore.dll and the app for release, publishes the app with .NET inside it, adds
# the Swift runtime's DLLs that ReqlyCore.dll needs, and has vpk make, in windows\.build\releases:
# Reqly.App-win-Setup.exe, the full package and a delta from the release before (if it's there),
# releases.win.json, which copies of Reqly read to find updates, and Reqly.App-win-Portable.zip.
# It also writes winget's manifests for this version there. The version is Reqly.csproj's.
# ReqlyCore.dll goes without its debug information; the whole one stays in
# windows\.build\symbols\<version>, with Reqly.pdb, for reading crash reports from that version.
# Signing comes later, from CI, with SignPath; until then everything is unsigned.
# vpk makes each version once. To package a version again before it's out, -Replace empties
# windows\.build\releases first.
param([ValidateSet('x64')][string]$Arch = 'x64', [switch]$Replace)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path "$PSScriptRoot\..\.."
$windows = Join-Path $root 'windows'
$app = Join-Path $windows 'Reqly'
$publish = Join-Path $windows ".build\publish\$Arch"
$releases = Join-Path $windows ".build\releases"
# Velopack installs Reqly under %LOCALAPPDATA%\<this id>, apart from Reqly's own files in
# %LOCALAPPDATA%\Reqly, since uninstalling removes the whole folder.
$packId = 'Reqly.App'

[xml]$project = Get-Content (Join-Path $app 'Reqly.csproj')
$version = @($project.Project.PropertyGroup | ForEach-Object { $_.Version } | Where-Object { $_ })[0]
if (-not $version) { throw 'Reqly.csproj has no <Version>.' }
"Reqly $version"
if (Test-Path (Join-Path $releases "$packId-$version-full.nupkg")) {
    if (-not $Replace) {
        throw "windows\.build\releases already has Reqly $version. To package it again, run with -Replace, which empties that folder."
    }
    Remove-Item $releases -Recurse -Force
}

# ReqlyCore.dll, optimized.
& "$PSScriptRoot\core.ps1" build -Package ReqlyCore --configuration release --product ReqlyCore
if ($LASTEXITCODE) { exit $LASTEXITCODE }

# Windows PowerShell takes a native program's warnings on stderr for errors, so only exit codes
# count from here on.
$ErrorActionPreference = 'Continue'
$bin = swift build --package-path "$windows\ReqlyCore" --triple x86_64-unknown-windows-msvc `
    --configuration release --show-bin-path 2>$null | Select-Object -Last 1
# Nothing is sent automatically: .NET's build tools don't report back either.
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
# Self-contained, so .NET comes with Reqly, as the Windows App SDK does.
dotnet publish "$app\Reqly.csproj" -c Release -r "win-$Arch" --self-contained -p:ReqlyCoreDir="$bin" -o $publish -nologo
if ($LASTEXITCODE) { exit $LASTEXITCODE }

# The Swift runtime's DLLs that ReqlyCore.dll needs, and the ones those need, found by following
# their imports. They come from the Swift runtime installed with the toolchain, which carries the
# Visual C++ runtime beside them, as Swift's own runtime installer does.
$runtime = Split-Path (Get-Command swiftCore.dll -ErrorAction Stop).Source
$objdump = Join-Path (Split-Path (Get-Command swift.exe -ErrorAction Stop).Source) 'llvm-objdump.exe'
$waiting = [System.Collections.Generic.Queue[string]]::new()
$waiting.Enqueue((Join-Path $publish 'ReqlyCore.dll'))
$seen = @{}
$copied = @()
while ($waiting.Count -gt 0) {
    $file = $waiting.Dequeue()
    $imports = & $objdump --private-headers $file 2>$null | Select-String 'DLL Name: (.+)$' | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    foreach ($name in $imports) {
        if ($seen.ContainsKey($name.ToLowerInvariant())) { continue }
        $seen[$name.ToLowerInvariant()] = $true
        $source = Join-Path $runtime $name
        if (-not (Test-Path $source)) { continue }
        $target = Join-Path $publish $name
        if (-not (Test-Path $target)) {
            Copy-Item $source $target
            $copied += $name
        }
        $waiting.Enqueue($source)
    }
}
"Swift runtime: $($copied.Count) DLLs from $runtime"
if ($copied -notcontains 'swiftCore.dll') { throw "ReqlyCore.dll doesn't import swiftCore.dll from $runtime." }
# The ones whose licenses Reqly's list has, as tools/acknowledgements.py writes it: Swift's, with
# ICU in _FoundationICU.dll and libxml2 in FoundationXML.dll, and the Visual C++ runtime, under
# Microsoft's terms, which Reqly asks you to agree to. Another may carry code under a license of
# its own, as FoundationNetworking.dll carries curl.
$licensed = 'BlocksRuntime.dll', 'dispatch.dll', 'Foundation.dll', 'FoundationEssentials.dll',
    'FoundationInternationalization.dll', 'FoundationXML.dll', '_FoundationICU.dll', 'swiftCore.dll',
    'swiftCRT.dll', 'swiftDispatch.dll', 'swiftObservation.dll', 'swiftSynchronization.dll', 'swiftWinSDK.dll',
    'swift_Concurrency.dll', 'swift_RegexParser.dll', 'swift_StringProcessing.dll',
    'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
$unlisted = @($copied | Where-Object { $licensed -notcontains $_ })
if ($unlisted) {
    throw "ReqlyCore.dll now needs $($unlisted -join ', ') from Swift's runtime. Check what each carries, and its license; add that to tools/acknowledgements.py if it needs to be, then the DLL to `$licensed here."
}

# Not Swift's backtracer, swift-backtrace.exe: started by a Windows app, which has no console,
# it gets a console window of its own, which flashes up as Reqly crashes, and writes there instead
# of to the crash log. Windows' report of the crash says where it happened instead.

# The runtimes are the versions whose licenses Reqly's list has.
$listed = @{}
(Get-Content (Join-Path $app 'Assets\Acknowledgements.json') -Raw -Encoding UTF8 | ConvertFrom-Json).packages |
    ForEach-Object { $listed[$_.name] = $_.version }
# The Swift runtime's folder is ...\Runtimes\<version>\usr\bin.
$carried = @{
    'Swift' = Split-Path (Split-Path (Split-Path $runtime -Parent) -Parent) -Leaf
    '.NET'  = ((Get-Content (Join-Path $publish 'Reqly.runtimeconfig.json') -Raw | ConvertFrom-Json).runtimeOptions.includedFrameworks |
        Where-Object { $_.name -eq 'Microsoft.NETCore.App' }).version
}
foreach ($name in $carried.Keys) {
    if ($listed[$name] -ne $carried[$name]) {
        throw "Reqly carries $name $($carried[$name]), but its licenses list has $name $($listed[$name]). Update RUNTIMES in tools/acknowledgements.py, and the texts it asks for."
    }
}
"Runtimes: Swift $($carried['Swift']), .NET $($carried['.NET']), as the licenses list has them"

# The Visual C++ runtime isn't part of Windows, so whatever needs one of its DLLs finds it here.
$beside = @{}
Get-ChildItem $publish -File | ForEach-Object { $beside[$_.Name.ToLowerInvariant()] = $true }
foreach ($file in Get-ChildItem $publish -File | Where-Object { $_.Extension -in '.dll', '.exe' }) {
    $needs = & $objdump --private-headers $file.FullName 2>$null | Select-String 'DLL Name: (.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() }
    foreach ($name in $needs) {
        if ($name -match '^(vcruntime|msvcp|concrt|vccorlib|vcomp|msvcr|mfc|ucrtbased)' -and -not $beside.ContainsKey($name.ToLowerInvariant())) {
            throw "$($file.Name) needs $name, which isn't beside Reqly, and not every PC has it."
        }
    }
}

# ReqlyCore.dll without its debug information, which is most of its size.
$symbols = Join-Path $windows ".build\symbols\$version"
if (Test-Path $symbols) { Remove-Item $symbols -Recurse -Force }
New-Item -ItemType Directory -Force -Path $symbols | Out-Null
Copy-Item (Join-Path $publish 'ReqlyCore.dll') $symbols
if (Test-Path (Join-Path $publish 'Reqly.pdb')) { Copy-Item (Join-Path $publish 'Reqly.pdb') $symbols }
$before = (Get-Item (Join-Path $publish 'ReqlyCore.dll')).Length
& (Join-Path (Split-Path $objdump) 'llvm-strip.exe') --strip-debug (Join-Path $publish 'ReqlyCore.dll')
if ($LASTEXITCODE) { exit $LASTEXITCODE }
"ReqlyCore.dll: {0:N1} MB, {1:N1} MB with its debug information, which is in $symbols" -f ((Get-Item (Join-Path $publish 'ReqlyCore.dll')).Length / 1MB), ($before / 1MB)

# The installer, the packages and the feed. vpk is the local tool windows\.config pins.
Push-Location $windows
try {
    dotnet tool restore | Out-Null
    dotnet tool run vpk -- pack --packId $packId --packVersion $version --runtime "win-$Arch" --packDir $publish --mainExe Reqly.exe `
        --packTitle Reqly --packAuthors 'The Reqly Authors' --icon "$app\Assets\Reqly.ico" `
        --splashImage "$app\Assets\Reqly.png" --shortcuts StartMenuRoot --outputDir $releases
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
}

# winget's manifests for this version, from the templates beside the Homebrew cask's.
$setup = Join-Path $releases "$packId-win-Setup.exe"
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash
$manifests = Join-Path $releases "winget\$version"
New-Item -ItemType Directory -Force -Path $manifests | Out-Null
foreach ($template in Get-ChildItem (Join-Path $windows 'distribution\winget') -Filter '*.yaml') {
    $text = (Get-Content $template.FullName -Raw) -replace '\{version\}', $version -replace '\{sha256\}', $hash
    # UTF-8 without the byte-order mark Windows PowerShell adds.
    [System.IO.File]::WriteAllText((Join-Path $manifests $template.Name), $text, [System.Text.UTF8Encoding]::new($false))
}

"=== $releases"
Get-ChildItem $releases -File | ForEach-Object { "{0,-44} {1,10:N0} KB" -f $_.Name, ($_.Length / 1KB) }
"app folder: $([math]::Round(((Get-ChildItem $publish -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)) MB in $((Get-ChildItem $publish -Recurse -File).Count) files"
"Setup SHA-256: $hash"
