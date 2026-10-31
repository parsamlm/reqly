#!/bin/bash
# Builds or tests Reqly for Linux's package (linux/), with the core and the core interface, in
# reqly-linux-dev:noble (linux/docker/Dockerfile): Ubuntu 24.04, the oldest system Reqly supports,
# with Swift 6.4.1 and the development packages it builds against.
#   linux/scripts/app.sh [options] build|test [more swift options]
# Where Docker is, such as on the Mac, the repository is mounted read-only in the image, the three
# packages are copied into the container, and the build stays in a Docker volume, so a later build
# only redoes what changed. Without Docker, such as in CI's container of the same image, it builds
# in place, in linux/.build.
#   linux/scripts/app.sh build --target LinuxDesktop     one module and what it uses
#   linux/scripts/app.sh test --filter LinuxDesktopTests one test target's tests
# Options:
#   --volume NAME       the build volume (default reqly-linux-build). One build at a time uses it:
#                       the container is named after it, so a second one is refused.
#   --seed VOLUME       when the build volume doesn't exist yet, start it as a copy of this one,
#                       whose packages are resolved (GitHub sometimes refuses these containers'
#                       clones of GRDB's SQLiteLib). Default: reqly-linux-build, for other volumes.
#   --time-limit MIN    stop the build after this many minutes (default 60)
#   --in-place          build in this checkout with this computer's Swift, even where Docker is
# The build uses 6 jobs unless the swift options say otherwise. If this script is stopped, its
# container stops too; if it's killed, `docker kill <volume>-run` stops the container. Tests run
# on a session bus of their own that starts no services (linux/scripts/test-bus.conf), with
# GSettings in memory, so they never reach a desktop's settings or keyring.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
    exit 2
}

image=reqly-linux-dev:noble
volume=reqly-linux-build
seed=
minutes=60
inPlace=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --volume) [[ $# -ge 2 ]] || usage; volume=$2; shift 2 ;;
        --seed) [[ $# -ge 2 ]] || usage; seed=$2; shift 2 ;;
        --time-limit) [[ $# -ge 2 && $2 =~ ^[0-9]+$ ]] || usage; minutes=$2; shift 2 ;;
        --in-place) inPlace=true; shift ;;
        -h | --help) usage ;;
        *) break ;;
    esac
done
[[ $# -ge 1 && ($1 == build || $1 == test) ]] || usage
command=$1
shift
rest=("$@")

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if $inPlace || ! command -v docker >/dev/null; then
    # The tests' bus, then swift with GSettings in memory, as TestEnvironment expects.
    before=()
    if [[ $command == test ]]; then
        before=(dbus-run-session "--config-file=$root/linux/scripts/test-bus.conf" --
            env GSETTINGS_BACKEND=memory REQLY_TEST_BUS=1)
    fi
    exec timeout --kill-after=30s "${minutes}m" ${before[@]+"${before[@]}"} swift "$command" \
        --package-path "$root/linux" ${rest[@]+"${rest[@]}"}
fi

# Colima shares only the home folder with its VM.
case $root/ in
    "$HOME"/*) ;;
    *)
        echo "$root isn't under $HOME, which is all Colima shares with its VM." >&2
        exit 1
        ;;
esac
docker image inspect "$image" >/dev/null 2>&1 || {
    echo "There's no $image. Build it with: docker build -t $image linux/docker" >&2
    exit 1
}
if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    [[ -n $seed || $volume == reqly-linux-build ]] || seed=reqly-linux-build
    if [[ -n $seed ]]; then
        echo "app.sh: starting $volume as a copy of $seed" >&2
        docker volume inspect "$seed" >/dev/null
        docker volume create "$volume" >/dev/null
        docker run --rm -v "$seed:/a:ro" -v "$volume:/b" "$image" cp -a /a/. /b/
    fi
fi

jobs=(--jobs 6)
for arg in ${rest[@]+"${rest[@]}"}; do
    [[ $arg != -j && $arg != --jobs && $arg != --jobs=* ]] || jobs=()
done

# In the container: the packages are copied with their files' times, to the nanosecond in tar's
# POSIX format, so a build in a volume that built them before only redoes what changed. Build
# products and the Mac's litter stay behind.
read -r -d '' inside <<'EOF' || true
set -euo pipefail
mkdir -p /work
for path in core core-interface linux; do
    tar -C /src --format=posix --exclude=.build --exclude=.swiftpm --exclude=.DS_Store -cf - "$path" |
        tar -C /work -xf -
done
cd /work/linux
minutes=$1
shift
before=()
if [[ $1 == test ]]; then
    before=(dbus-run-session --config-file=/work/linux/scripts/test-bus.conf --
        env GSETTINGS_BACKEND=memory REQLY_TEST_BUS=1)
fi
exec timeout --kill-after=30s "$minutes" ${before[@]+"${before[@]}"} swift "$@"
EOF

tty=()
[[ ! -t 0 || ! -t 1 ]] || tty=(-it)
exec docker run --rm --init "${tty[@]+"${tty[@]}"}" --name "$volume-run" \
    -v "$root:/src:ro" -v "$volume:/build" "$image" \
    bash -c "$inside" app.sh "${minutes}m" "$command" --scratch-path /build \
    ${jobs[@]+"${jobs[@]}"} ${rest[@]+"${rest[@]}"}
