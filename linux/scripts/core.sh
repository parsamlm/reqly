#!/bin/bash
# Builds or tests the core (ReqlyKit), or libReqlyCore.so, on Linux, with the system's SQLite and
# zlib (libsqlite3-dev and zlib1g-dev), as CI's container has them.
#   linux/scripts/core.sh build|test [--package core|ReqlyCore] [more swift options]
# A build of libReqlyCore.so looks for Swift's runtime only beside itself (RUNPATH $ORIGIN, which
# stage-core.sh checks), so Reqly loads the copy it ships, never a toolchain's under
# /usr/lib/swift. Tests run on the toolchain's runtime, as SwiftPM sets them up. For the files to
# ship, build with `-c release` and then run stage-core.sh. Nothing in it names an architecture;
# CI runs it on x64 and arm64.
set -euo pipefail

usage() {
    echo "usage: linux/scripts/core.sh build|test [--package core|ReqlyCore] [more swift options]" >&2
    exit 2
}

[[ $# -ge 1 && ($1 == build || $1 == test) ]] || usage
command=$1
shift
package=core
rest=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --package)
            [[ $# -ge 2 && ($2 == core || $2 == ReqlyCore) ]] || usage
            package=$2
            shift 2
            ;;
        *)
            rest+=("$1")
            shift
            ;;
    esac
done

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ $package == core ]]; then
    path=$root/core
else
    path=$root/windows/ReqlyCore
    if [[ $command == build ]]; then
        # SwiftPM puts $ORIGIN in RUNPATH, and Swift puts the toolchain's runtime folder first
        # unless told not to.
        rest=(-Xswiftc -no-toolchain-stdlib-rpath ${rest[@]+"${rest[@]}"})
    fi
fi
exec swift "$command" --package-path "$path" ${rest[@]+"${rest[@]}"}
