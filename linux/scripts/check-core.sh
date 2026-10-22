#!/bin/bash
# Checks that a staged libReqlyCore.so starts on this computer. Run it on each supported system,
# in a clean container with only libsqlite3-0, zlib1g and libstdc++6 added, and no Swift:
#   linux/scripts/check-core.sh <stage-dir>
# <stage-dir> is what stage-core.sh made. The check fails unless:
# - every file in lib/ finds each library it needs, each one that's in lib/ there, and none in a
#   Swift toolchain;
# - nothing needs libxml2, which isn't named the same everywhere (libxml2.so.2 on Ubuntu 24.04 and
#   Debian 13, libxml2.so.16 on Ubuntu 26.04 and Debian 14), or Foundation's XML, which links it;
# - test/smoke loads libReqlyCore.so, opens a session, sends a request through it and closes it,
#   with Swift's runtime from lib/, within a minute;
# - when the core crashes, lib/swift-backtrace writes the crash's report, within a minute.
# Nothing in it names an architecture; CI runs it on x64 and arm64.
set -euo pipefail

[[ $# -eq 1 && -f $1/lib/libReqlyCore.so && -x $1/test/smoke ]] || {
    echo "usage: linux/scripts/check-core.sh <stage-dir>, a folder stage-core.sh made" >&2
    exit 2
}
# ldd and the loader give real paths, without symlinks, so the stage's is compared in that form.
stage=$(cd "$1" && pwd -P)
lib=$stage/lib
. /etc/os-release
echo "$PRETTY_NAME, $(uname -m), $(getconf GNU_LIBC_VERSION)"

# Each problem is told once, with the files in lib/ that need the library, each once: ldd lists
# what a file needs through the others too, so one missing library shows many times.
problems=()
declare -A neededBy=()
problem() {
    [[ -n ${neededBy[$1]+set} ]] || problems+=("$1")
    [[ ", ${neededBy[$1]-}, " == *", $2, "* ]] || neededBy[$1]+=${neededBy[$1]:+, }$2
}
system=()
for file in "$lib"/*; do
    name=$(basename "$file")
    if [[ $name == libFoundationXML.so ]]; then
        problems+=("lib/ has libFoundationXML.so, Foundation's XML, which needs libxml2")
    fi
    # Each line is "<library> => <path> (<address>)" or "<library> => not found"; the loader's and
    # the kernel's own lines have no "=>".
    while read -r line; do
        if [[ $line =~ ^([^ ]+)\ =\>\ not\ found$ ]]; then
            needed=${BASH_REMATCH[1]}
            path=
        elif [[ $line =~ ^([^ ]+)\ =\>\ (.+)\ \(0x[0-9a-f]+\)$ ]]; then
            needed=${BASH_REMATCH[1]}
            path=${BASH_REMATCH[2]}
        else
            continue
        fi
        if [[ $needed == libxml2.* ]]; then
            problem "$needed is libxml2, which nothing may need" "$name"
        elif [[ -z $path ]]; then
            problem "$needed isn't in lib/ or on this system" "$name"
        elif [[ -f $lib/$needed ]]; then
            [[ $(realpath "$path") == "$lib/$needed" ]] || problem "$needed loads from $path, not lib/" "$name"
        elif [[ $path == */swift/* ]]; then
            problem "$needed loads from a Swift toolchain: $path" "$name"
        else
            system+=("$needed")
        fi
    done < <(ldd "$file" || true)
done
echo "From the system: $(printf '%s\n' ${system[@]+"${system[@]}"} | sort -u | tr '\n' ' ')"

if [[ ${#problems[@]} -eq 0 ]]; then
    "$stage/test/smoke" "$lib/libReqlyCore.so" || problems+=("The smoke test failed")
fi
if [[ ${#problems[@]} -eq 0 ]]; then
    # Swift's backtracer, set up much as the app sets it up, with the reports in a folder. The
    # crash is on purpose, so the shell's own notice of it goes.
    reports=$(mktemp -d)
    settings="enable=yes,interactive=no,color=no,format=json,output-to=$reports,swift-backtrace=$lib/swift-backtrace"
    status=$({
        SWIFT_BACKTRACE=$settings "$stage/test/smoke" "$lib/libReqlyCore.so" --crash >/dev/null 2>"$reports/stderr" \
            && echo 0 || echo $?
    } 2>/dev/null)
    report=$(find "$reports" -name '*.json' -print -quit)
    if [[ $status -le 128 ]]; then
        problems+=("The crash test didn't crash (exit status $status): $(tr '\n' ' ' <"$reports/stderr")")
    elif [[ -z $report ]] || ! grep -qF "\"$lib/libReqlyCore.so\"" "$report"; then
        problems+=("swift-backtrace wrote no report of the crash: $(tr '\n' ' ' <"$reports/stderr")")
    else
        echo "The crash's report: $(wc -c <"$report") bytes, from lib/swift-backtrace"
    fi
    rm -rf "$reports"
fi

if [[ ${#problems[@]} -gt 0 ]]; then
    for text in "${problems[@]}"; do
        echo "Failed: $text${neededBy[$text]+ (needed by ${neededBy[$text]})}" >&2
    done
    exit 1
fi
echo "libReqlyCore.so starts here."
