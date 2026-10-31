#!/bin/bash
# Runs Reqly's self-check headless, as `linux/scripts/app.sh self-check` does in its container:
#   linux/scripts/self-check.sh <program> [reqly options]
# Reqly runs with a new scratch folder as its home and every XDG folder, on a session bus of its
# own (dbus-run-session), on a virtual X screen (xvfb-run), with GSettings in memory, and with its
# own files and stand-ins for everything of yours it could change: your desktop's proxy settings,
# its certificate's trust and key, and the secrets. It captures only on 127.0.0.1, and lets no
# devices on the network in. The options given here come after those, so they can choose the
# parts, such as --smoke-parts window,events, or change any of them. Prints the report, and exits
# with Reqly's status: 0 when every part passed.
set -euo pipefail

if [[ $# -lt 1 || $1 == -h || $1 == --help ]]; then
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
    exit 2
fi
program=$1
shift

scratch=$(mktemp -d "${TMPDIR:-/tmp}/reqly-self-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
export HOME=$scratch/home XDG_CONFIG_HOME=$scratch/config XDG_DATA_HOME=$scratch/data \
    XDG_STATE_HOME=$scratch/state XDG_CACHE_HOME=$scratch/cache XDG_RUNTIME_DIR=$scratch/runtime
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
# Nothing of a desktop this may run in: its bus, its screens or its settings.
unset DBUS_SESSION_BUS_ADDRESS DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
export GSETTINGS_BACKEND=memory GDK_BACKEND=x11

report=$scratch/report.txt
status=0
dbus-run-session -- xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24 -nolisten tcp" \
    "$program" --smoke "$report" \
    --settings-file "$scratch/Settings.json" --rules-file "$scratch/Rules.json" \
    --connections-file "$scratch/Connections.json" --protobuf-file "$scratch/Protobuf.json" \
    --devices-file "$scratch/Devices.json" --sessions-folder "$scratch/Sessions" \
    --crash-reports-folder "$scratch/Crashes" \
    --proxy-settings-stand-in "$scratch/ProxySettings.json" --proxy-restore-file "$scratch/ProxyRestore.json" \
    --root-stand-in "$scratch/Root.dat" --root-file "$scratch/Certificate.dat" \
    --secrets-stand-in "$scratch/Secrets.json" \
    --allows-network-devices no --checks-for-updates no --has-seen-welcome yes --port 9191 \
    "$@" || status=$?
if [[ -s $report ]]; then
    cat "$report"
else
    echo "self-check.sh: Reqly wrote no report, and ended with status $status" >&2
    ((status != 0)) || status=1
fi
exit "$status"
