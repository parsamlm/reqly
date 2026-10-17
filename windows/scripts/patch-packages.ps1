# Has a package build on Windows with SwiftNIO and swift-nio-ssl as Reqly patches them, until their
# releases have the same fixes:
#   windows\scripts\patch-packages.ps1 -PackagePath <core or windows\ReqlyCore>
# For each folder in windows\patches, named after a package, it makes a copy of the version its
# VERSION file names, which must be the one Package.resolved pins, from the package's own
# repository, applies the folder's patches in order, and has the package build with that copy,
# which SwiftPM calls editing it. The copies, in windows\.build\patched, are made again only when
# the version or the patches change. core.ps1 runs it before every build, so nothing else needs to.
param([Parameter(Mandatory)][string]$PackagePath)
$ErrorActionPreference = 'Stop'

$root = Resolve-Path "$PSScriptRoot\..\.."
$PackagePath = (Resolve-Path $PackagePath).Path
$patches = Join-Path $root 'windows\patches'
$copies = Join-Path $root 'windows\.build\patched'
New-Item -ItemType Directory -Force -Path $copies | Out-Null

# Windows PowerShell takes a native program's messages on stderr for errors, so only exit codes
# count.
$ErrorActionPreference = 'Continue'
# Runs a program, its output on the console, and stops with what couldn't be done if it fails.
function Run([string]$what) {
    $program = $args[0]
    $arguments = @($args | Select-Object -Skip 1)
    & $program @arguments | Out-Host
    if ($LASTEXITCODE) { throw "Couldn't $what (exit code $LASTEXITCODE)." }
}

# The package's dependencies as SwiftPM has them, resolved first if they aren't yet.
function Dependency([string]$name) {
    $state = Join-Path $PackagePath '.build\workspace-state.json'
    $found = if (Test-Path $state) {
        (Get-Content $state -Raw | ConvertFrom-Json).object.dependencies | Where-Object { $_.packageRef.identity -eq $name }
    }
    if (-not $found) {
        Run "resolve $PackagePath's packages" swift package --package-path $PackagePath resolve
        $found = (Get-Content $state -Raw | ConvertFrom-Json).object.dependencies | Where-Object { $_.packageRef.identity -eq $name }
    }
    if (-not $found) { throw "$PackagePath doesn't use $name, which windows\patches\$name patches." }
    $found
}

$pins = (Get-Content (Join-Path $PackagePath 'Package.resolved') -Raw | ConvertFrom-Json).pins
foreach ($folder in Get-ChildItem $patches -Directory) {
    $name = $folder.Name
    # The version the patches are for. Package.resolved pins it too, except after a build on
    # Windows, where SwiftPM leaves the packages it builds edited copies of out of the file.
    $version, $revision, $location = (Get-Content (Join-Path $folder.FullName 'VERSION') -Raw).Trim() -split '\s+'
    $pin = $pins | Where-Object { $_.identity -eq $name }
    if ($pin -and $pin.state.revision -ne $revision) {
        throw "Reqly pins $name $($pin.state.version), but windows\patches\$name is for $name $version. Update the patches, as windows\patches\README.md says."
    }
    $files = @(Get-ChildItem $folder.FullName -Filter '*.patch' | Sort-Object Name)
    $copy = Join-Path $copies $name

    # What the copy comes from: the version's revision, and each patch, by its contents.
    $stamp = (@("$location $revision") + @($files | ForEach-Object { "$($_.Name) $((Get-FileHash $_.FullName).Hash)" })) -join "`n"
    $stampFile = "$copy.stamp"
    if (-not ((Test-Path $copy) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw) -eq $stamp))) {
        "Patching $name $version for Windows, with $($files.Count) patches"
        if (Test-Path $copy) { Remove-Item $copy -Recurse -Force }
        if (Test-Path $stampFile) { Remove-Item $stampFile -Force }
        # Only that revision's files, with the line endings they have in the repository, which the
        # patches have too.
        Run "start a copy of $name" git init --quiet $copy
        Run "set up the copy of $name" git -C $copy config core.autocrlf false
        Run "download $name $version" git -C $copy fetch --quiet --depth 1 $location $revision
        Run "check out $name $version" git -C $copy -c advice.detachedHead=false checkout --quiet FETCH_HEAD
        foreach ($file in $files) {
            Run "apply windows\patches\$name\$($file.Name) to $name $version" `
                git -C $copy apply --whitespace=nowarn $file.FullName
        }
        [System.IO.File]::WriteAllText($stampFile, $stamp)
    }

    # The package builds with the copy. A package that builds with another copy of it, as one made
    # by hand would be, is left alone: SwiftPM's way back, unedit, could delete what the link
    # points at on Windows.
    $dependency = Dependency $name
    if ($dependency.state.name -eq 'edited') {
        $path = $dependency.state.path
        if ($path -and ([System.IO.Path]::GetFullPath($path).TrimEnd('\') -ieq [System.IO.Path]::GetFullPath($copy).TrimEnd('\'))) {
            continue
        }
        throw "$PackagePath builds with $name from $path. To build with windows\patches\$name instead, delete $PackagePath\.build and the link $PackagePath\Packages\$name (rmdir, which leaves what it points at), then build again."
    }
    # Editing a package also takes its pin out of Package.resolved, which belongs to the repository,
    # so the file goes back as it was. SwiftPM builds an edited package from its copy, whatever the
    # pin says. core.ps1 does the same after building, which does it too.
    $resolved = Join-Path $PackagePath 'Package.resolved'
    $pinned = [System.IO.File]::ReadAllBytes($resolved)
    try {
        Run "have $PackagePath build with the patched $name" swift package --package-path $PackagePath edit $name --path $copy
    }
    finally {
        [System.IO.File]::WriteAllBytes($resolved, $pinned)
    }
}
