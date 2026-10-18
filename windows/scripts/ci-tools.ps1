# Installs what Reqly for Windows builds with that GitHub's Windows machines don't have: Swift 6.4.0,
# the version whose runtime the licenses list has, and NASM, for BoringSSL's assembly. Each comes
# from its own site and is checked against the hash it should have. The steps after this one get
# Swift on their PATH, with SDKROOT, and NASM in NASM. For CI only: on a PC of your own, install
# Swift from swift.org or winget, and NASM as build-boringssl-asm.ps1 says.
#   windows\scripts\ci-tools.ps1
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest is many times slower with its progress bar.
$ProgressPreference = 'SilentlyContinue'
if (-not $env:GITHUB_ENV -or -not $env:GITHUB_PATH) { throw 'This is for GitHub Actions, which sets GITHUB_ENV and GITHUB_PATH.' }
$temp = Join-Path $env:RUNNER_TEMP 'reqly-tools'
New-Item -ItemType Directory -Force $temp | Out-Null

function Download([string]$url, [string]$file) {
    "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
}

function Check([string]$file, [string]$sha256, [string]$what) {
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($hash -ne $sha256) { throw "$what isn't the one it should be: its SHA-256 is $hash, not $sha256." }
}

# Swift, as swift.org's installer puts it, the same installer and hash as winget's manifest for 6.4.0.
$installer = Join-Path $temp 'swift-6.4.0-RELEASE-windows10.exe'
Download 'https://download.swift.org/swift-6.4.0-release/windows10/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE-windows10.exe' $installer
Check $installer '76169A85BCBA82854A0CD8F9655FFB74B3758D60C35A245457510095F2823C03' "Swift's installer"
$install = Start-Process -FilePath $installer -ArgumentList '/quiet', '/norestart' -Wait -PassThru
if ($install.ExitCode -ne 0) { throw "Swift's installer failed, with exit code $($install.ExitCode)." }
# The installer sets PATH and SDKROOT for the user, or for every user, where only new processes see them.
$folders = foreach ($scope in 'User', 'Machine') {
    ([Environment]::GetEnvironmentVariable('Path', $scope) -split ';') | Where-Object { $_ -match '\\Swift\\' }
}
if (-not $folders) { throw "Swift's installer didn't put Swift on the PATH." }
foreach ($folder in $folders) { Add-Content -Path $env:GITHUB_PATH -Value $folder }
$sdkroot = @('User', 'Machine' | ForEach-Object { [Environment]::GetEnvironmentVariable('SDKROOT', $_) } | Where-Object { $_ })[0]
if (-not $sdkroot) { throw "Swift's installer didn't set SDKROOT." }
Add-Content -Path $env:GITHUB_ENV -Value "SDKROOT=$sdkroot"
$swift = $folders | ForEach-Object { Join-Path $_ 'swift.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $swift) { throw "Swift's installer put no swift.exe on the PATH." }
"Swift: $swift"

# NASM, from its own site, the same nasm.exe as the one Reqly is built with on a PC.
$zip = Join-Path $temp 'nasm-2.16.03-win64.zip'
Download 'https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/win64/nasm-2.16.03-win64.zip' $zip
Expand-Archive -Path $zip -DestinationPath $temp -Force
$nasm = Join-Path $temp 'nasm-2.16.03\nasm.exe'
Check $nasm 'A93276636266516421CC9B422F47476C21F7A2949F1AE251556B2F1D33A3BE04' 'nasm.exe'
Add-Content -Path $env:GITHUB_ENV -Value "NASM=$nasm"
"NASM: $nasm"

# What each says it is. Windows PowerShell takes a native program's stderr for errors, so only exit codes count.
$ErrorActionPreference = 'Continue'
& $swift --version 2>&1 | Out-Host
if ($LASTEXITCODE) { throw "Swift doesn't run: exit code $LASTEXITCODE." }
& $nasm -v 2>&1 | Out-Host
if ($LASTEXITCODE) { throw "NASM doesn't run: exit code $LASTEXITCODE." }
