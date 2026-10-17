# Says where in Reqly's code each frame of a crash report's crashed thread was: the function and
# the line, from that version's debug information, which package.ps1 keeps in
# windows\.build\symbols\<version>. A released Reqly's ReqlyCore.dll goes without it, so its
# report gives offsets, such as "1  ReqlyCore.dll  +0x4084". A build of your own keeps it, and
# its report names the frames already, when llvm-symbolizer is on the PC.
#   windows\scripts\symbolicate.ps1 <report> [-Symbols <folder, or ReqlyCore.dll>]
# The report is the issue's text, saved to a file, or the crashed run's own file, Crash-<time>.txt
# in %LOCALAPPDATA%\Reqly\Crashes, which also has each module's time stamp to check the symbols by.
# It needs Swift's toolchain: its llvm-symbolizer and swift-demangle.
param([Parameter(Mandatory)][string]$Report, [string]$Symbols = '')
$ErrorActionPreference = 'Stop'

$text = Get-Content $Report -Encoding UTF8
$version = $null
foreach ($line in $text) {
    if ($line -match '^(?:- )?Reqly (\S+)\s*$') { $version = $Matches[1]; break }
}
if (-not $Symbols) {
    if (-not $version) { throw "The report doesn't say which version of Reqly crashed; pass -Symbols." }
    $Symbols = Join-Path $PSScriptRoot "..\.build\symbols\$version"
}
$dll = if (Test-Path $Symbols -PathType Container) { Join-Path $Symbols 'ReqlyCore.dll' } else { $Symbols }
if (-not (Test-Path $dll)) { throw "There's no $dll. package.ps1 keeps each version's debug information there." }
$symbolizer = (Get-Command llvm-symbolizer.exe -ErrorAction Stop).Source
$demangler = Join-Path (Split-Path $symbolizer) 'swift-demangle.exe'

# The frames: as the crashed run wrote them, with the modules' places and time stamps, or as the
# issue gives them, by their offsets. Each frame after the first is where a call returns to. .NET's
# own frames, which .NET named itself, stay as they are.
$images = @{}
foreach ($line in $text) {
    if ($line -match '^0x([0-9a-fA-F]+)\S*?0x[0-9a-fA-F]+\s+([0-9a-fA-F]{8})\s+(\S+)\s') {
        $images[$Matches[3]] = @{ Start = [Convert]::ToUInt64($Matches[1], 16); Stamp = $Matches[2] }
    }
}
$frames = @()
foreach ($line in $text) {
    $trimmed = $line -replace '^\s*\|\s?', ''
    if ($trimmed -match '^(\d+)\s+(\[ra\]\s+)?0x([0-9a-fA-F]+)\s+<unknown> in (\S+)$' -and $images.ContainsKey($Matches[4])) {
        $offset = [uint64]([Convert]::ToUInt64($Matches[3], 16) - $images[$Matches[4]].Start)
        $frames += [pscustomobject]@{ Number = [int]$Matches[1]; Module = $Matches[4]; Offset = $offset; Line = $null }
    } elseif ($trimmed -match '^(\d+)\s+(\S+)\s+\+0x([0-9a-fA-F]+)$') {
        $frames += [pscustomobject]@{ Number = [int]$Matches[1]; Module = $Matches[2]; Offset = [Convert]::ToUInt64($Matches[3], 16); Line = $null }
    } elseif ($trimmed -match '^(\d+)(?:[-\u2013]\d+)?\s+\S') {
        $frames += [pscustomobject]@{ Number = [int]$Matches[1]; Module = $null; Offset = $null; Line = $trimmed.Trim() }
    } elseif ($trimmed -match '^\s+at \S') {
        # .NET's own frames, which .NET named as Reqly crashed.
        $frames += [pscustomobject]@{ Number = -1; Module = $null; Offset = $null; Line = $trimmed.TrimEnd() }
    }
}
if (-not $frames) { throw "The report has no frames of a crashed thread." }

# The debug information must be the build's that crashed, when the report says which that was.
if ($images.ContainsKey('ReqlyCore.dll')) {
    $file = [IO.File]::OpenRead((Resolve-Path $dll))
    try {
        $reader = New-Object IO.BinaryReader($file)
        $file.Position = 0x3C
        $file.Position = $reader.ReadInt32() + 8
        $stamp = '{0:x8}' -f $reader.ReadUInt32()
    } finally { $file.Dispose() }
    if ($stamp -ne $images['ReqlyCore.dll'].Stamp.ToLowerInvariant()) {
        Write-Warning "$dll is the build stamped $stamp, but the report's is $($images['ReqlyCore.dll'].Stamp): the lines would be another build's."
    }
}

$core = @($frames | Where-Object { $_.Module -eq 'ReqlyCore.dll' })
$found = @{}
$short = @{}
if ($core) {
    # A return address is just past its call, which can be the next line's.
    $addresses = $core | ForEach-Object { '0x{0:x}' -f [uint64]$(if ($_.Number -gt 0) { $_.Offset - [uint64]1 } else { $_.Offset }) }
    $answers = $addresses | & $symbolizer "--obj=$dll" --relative-address --inlines --output-style=JSON
    $names = @()
    foreach ($answer in $answers) {
        $parsed = $answer | ConvertFrom-Json
        $found[[uint64][Convert]::ToUInt64(($parsed.Address -replace '^0x', ''), 16)] = @($parsed.Symbol | Where-Object { $_.FileName -and $_.Line })
        $names += @($parsed.Symbol | ForEach-Object { $_.FunctionName } | Where-Object { $_ -like '$s*' })
    }
    # Swift's names, made short, as Swift's backtracer makes them.
    $names = @($names | Select-Object -Unique)
    if ($names -and (Test-Path $demangler)) {
        $demangled = @($names | & $demangler --simplified --compact)
        for ($i = 0; $i -lt $names.Count -and $i -lt $demangled.Count; $i++) { $short[$names[$i]] = $demangled[$i] }
    }
}

foreach ($frame in $frames) {
    if ($frame.Line) { $frame.Line; continue }
    $at = [uint64]$(if ($frame.Number -gt 0) { $frame.Offset - [uint64]1 } else { $frame.Offset })
    $entries = @(if ($frame.Module -eq 'ReqlyCore.dll' -and $found.ContainsKey($at)) { $found[$at] })
    if (-not $entries) { '{0}  {1}  +0x{2:x}' -f $frame.Number, $frame.Module, $frame.Offset; continue }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $symbol = $entries[$i]
        $function = [string]$symbol.FunctionName
        $name = if ($function -and $short.ContainsKey($function)) { $short[$function] } elseif ($function -like '$s*') { '' } else { $function }
        $inlined = if ($i -lt $entries.Count - 1) { '[inlined] ' } else { '' }
        $place = '{0}:{1}' -f (Split-Path $symbol.FileName -Leaf), $symbol.Line
        '{0}  {1}  {2}{3}' -f $frame.Number, $frame.Module, $inlined, $(if ($name) { "$name at $place" } else { "at $place" })
    }
}
