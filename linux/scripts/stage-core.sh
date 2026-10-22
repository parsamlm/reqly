#!/bin/bash
# Gathers libReqlyCore.so from a release build with the parts of Swift's runtime it needs, so that
# it starts on a computer without Swift, and loads its own copy on one with Swift:
#   linux/scripts/stage-core.sh <out-dir> [<build-dir>]
# <build-dir> is the release build's folder: windows/ReqlyCore/.build/release, or with
# `--scratch-path <scratch>`, <scratch>/release. <out-dir> has to be a new or empty folder, or an
# earlier stage: lib/, debug/ and test/ and nothing else, with lib/libReqlyCore.so. An earlier
# stage's three folders are replaced; nothing else is ever deleted. <out-dir> then gets:
# - lib/: libReqlyCore.so, the runtime's libraries it needs, followed from each file's NEEDED, and
#   swift-backtrace, which the runtime starts to write a crash's report. They go in one folder, as
#   in /usr/lib/reqly later, and each looks for libraries only beside itself (RUNPATH $ORIGIN).
#   They keep their function names, so crash reports name functions (strip --strip-debug).
# - debug/: the debug information of libReqlyCore.so and swift-backtrace, for reading crash
#   reports from this build, as Windows keeps its PDBs apart. Each names its file (.gnu_debuglink),
#   and reports give each library's build ID. Swift's own libraries come without any.
# - test/smoke: check-core.sh's test program, built from smoke.c. It isn't for packaging.
# Swift's runtime starts the swift-backtrace beside it, even where a toolchain has its own; the app
# can also name it, in SWIFT_BACKTRACE (swift-backtrace=/usr/lib/reqly/swift-backtrace).
# Run it where the build ran: it takes the runtime from the toolchain the swift on PATH belongs
# to, and uses readelf, objcopy, strip and clang, which Swift's images have. With xz or zstd, it
# also says how big the files get compressed. Nothing in it names an architecture; CI runs it on
# x64 and arm64.
set -euo pipefail

# An empty <out-dir> would have it replace /lib, /debug and /test.
[[ $# -ge 1 && $# -le 2 && -n $1 ]] || {
    echo "usage: linux/scripts/stage-core.sh <out-dir> [<build-dir>]" >&2
    exit 2
}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
build=${2:-$root/windows/ReqlyCore/.build/release}
[[ -f $build/libReqlyCore.so ]] || {
    echo "No libReqlyCore.so in $build. Build it first: linux/scripts/core.sh build --package ReqlyCore -c release" >&2
    exit 1
}
resources=$(swiftc -print-target-info | sed -n 's/.*"runtimeResourcePath": "\(.*\)".*/\1/p')
runtime=$resources/linux
backtracer=$resources/../../libexec/swift/linux/swift-backtrace
[[ -f $runtime/libswiftCore.so && -f $backtracer ]] || {
    echo "No Swift runtime in $runtime, or no swift-backtrace beside it." >&2
    exit 1
}

# Whether a folder holds nothing, or only an earlier stage's lib/, debug/ and test/.
isEmptyOrStage() (
    shopt -s dotglob nullglob
    for entry in "$1"/*; do
        case ${entry##*/} in
            lib | debug | test)
                [[ -d $entry && ! -L $entry && -f $1/lib/libReqlyCore.so ]] || return 1
                ;;
            *)
                return 1
                ;;
        esac
    done
)
out=$1
if [[ (-e $out || -L $out) && ! -d $out ]]; then
    echo "$out isn't a folder." >&2
    exit 1
fi
if [[ -d $out ]] && ! isEmptyOrStage "$out"; then
    echo "$out has other files in it. Stage into an empty folder, or over an earlier stage." >&2
    exit 1
fi
rm -rf "$out/lib" "$out/debug" "$out/test"
mkdir -p "$out/lib" "$out/debug" "$out/test"
lib=$(cd "$out/lib" && pwd)
debug=$(cd "$out/debug" && pwd)

needed() { readelf -d "$1" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }
runpath() { readelf -d "$1" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p'; }

# The runtime's libraries, from the toolchain, as each file needs them. Anything else comes from
# the system, and is listed at the end.
cp "$build/libReqlyCore.so" "$backtracer" "$lib/"
queue=("$lib/libReqlyCore.so" "$lib/swift-backtrace")
system=()
while [[ ${#queue[@]} -gt 0 ]]; do
    file=${queue[0]}
    queue=("${queue[@]:1}")
    for name in $(needed "$file"); do
        if [[ -f $runtime/$name ]]; then
            if [[ ! -f $lib/$name ]]; then
                cp "$runtime/$name" "$lib/"
                queue+=("$lib/$name")
            fi
        else
            system+=("$name")
        fi
    done
done

# swift-backtrace looks for the runtime in a toolchain's lib/swift/linux; the runtime's own
# libraries already look beside themselves. Swift's images have no patchelf, but $ORIGIN is
# shorter than the old RUNPATH, so it's written over it in place, with zeros after it.
old=$(runpath "$lib/swift-backtrace")
if [[ -n $old && $old != '$ORIGIN' ]]; then
    OLD=$old perl -0777 -pi -e '
        my $old = "$ENV{OLD}\0";
        die "Its RUNPATH is shorter than \$ORIGIN.\n" if length($old) < 8;
        my $count = () = /\Q$old\E/g;
        die "Its RUNPATH is in $ARGV $count times.\n" unless $count == 1;
        s/\Q$old\E/"\$ORIGIN" . "\0" x (length($old) - 7)/e;' "$lib/swift-backtrace"
fi

# Debug information goes to debug/, for each file that has some.
for file in "$lib"/*; do
    name=$(basename "$file")
    [[ $(readelf -S -W "$file") == *' .debug_info '* ]] || continue
    objcopy --only-keep-debug "$file" "$debug/$name.debug"
    strip --strip-debug "$file"
    objcopy --add-gnu-debuglink="$debug/$name.debug" "$file"
done

# libReqlyCore.so has to look for the runtime beside itself, as core.sh builds it: nothing above
# changes its RUNPATH. Every other file has to look there too, or have nothing to look for.
path=$(runpath "$lib/libReqlyCore.so")
if [[ $path != '$ORIGIN' ]]; then
    echo "libReqlyCore.so's RUNPATH is \"$path\", not \$ORIGIN. Build it with linux/scripts/core.sh." >&2
    exit 1
fi
for file in "$lib"/*; do
    path=$(runpath "$file")
    if [[ $(readelf -d "$file") == *'(RPATH)'* || (-n $path && $path != '$ORIGIN') ]]; then
        echo "$(basename "$file") looks for libraries outside its folder: $(readelf -d "$file" | grep PATH)" >&2
        exit 1
    fi
done
# swift-backtrace starts, on the runtime beside it.
if ! message=$("$lib/swift-backtrace" --help 2>&1 >/dev/null); then
    echo "lib/swift-backtrace doesn't start: $message" >&2
    exit 1
fi

clang -O2 -Wall -Wextra -I"$root/windows/ReqlyCore" -o "$out/test/smoke" "$here/smoke.c" -pthread

echo "In $out:"
megabytes() { awk '{ total += $1 } END { printf "%.1f MB", total / 1e6 }'; }
for file in $(cd "$out" && find lib debug -type f | sort); do
    printf '%9s  %s\n' "$(stat -c %s "$out/$file" | megabytes)" "$file"
done
echo "lib/: $(du -sb "$lib" | megabytes) on disk; debug/: $(du -sb "$debug" | megabytes)"
if command -v xz >/dev/null; then
    echo "lib/ with xz (tar -cJ): $(tar -C "$out" -cJf - lib | wc -c | megabytes)"
fi
if command -v zstd >/dev/null; then
    echo "lib/ with zstd -19: $(tar -C "$out" -cf - lib | zstd -19 -T0 -q | wc -c | megabytes)"
fi
echo "From the system: $(printf '%s\n' "${system[@]}" | sort -u | tr '\n' ' ')"
