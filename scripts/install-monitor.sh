#!/bin/bash
# Installs the always-on usage monitor as a per-user LaunchAgent.
#
#   ./scripts/install-monitor.sh              start monitoring (runs at login)
#   ./scripts/install-monitor.sh --stop       stop, keep the collected data
#   ./scripts/install-monitor.sh --uninstall  stop and remove the agent
#   ./scripts/install-monitor.sh --status     is it running, and what has it got
#
# No sudo: this is a user agent, not a system daemon. It cannot start before you
# log in, which is correct — there is nothing to measure when nobody is using it.

set -euo pipefail

LABEL="local.parasite.monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/Parasite.app/Contents/MacOS/Parasite"
LOGDIR="$HOME/Library/Application Support/Parasite/monitor"
UID_NUM="$(id -u)"

status() {
    if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
        local pid
        # Not awk with a \t literal: not every awk interprets that in a regex,
        # and it silently reported a running daemon as stopped.
        pid="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null \
               | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' | head -1)"
        if [[ -n "${pid:-}" ]]; then
            echo "Running (pid $pid)"
            ps -o pid,%cpu,rss,time -p "$pid" | tail -n +1
        else
            echo "Loaded but not running — check $LOGDIR/monitor.err"
        fi
    else
        echo "Not loaded."
    fi
    if [[ -f "$LOGDIR/state.json" ]]; then
        echo
        echo "Collected so far:"
        /usr/bin/python3 - "$LOGDIR/state.json" <<'PY'
import json, sys, datetime
s = json.load(open(sys.argv[1]))
started = datetime.datetime.fromisoformat(s["startedAt"].replace("Z", "+00:00"))
days = (datetime.datetime.now(datetime.timezone.utc) - started).total_seconds() / 86400
print(f"  started    {started.astimezone():%d %b %Y at %H:%M}  ({days:.1f} days ago)")
print(f"  samples    {s.get('totalSamples', 0)}")
print(f"  events     {s.get('totalEvents', 0)}")
print(f"  observed   {s.get('observedSeconds', 0)/3600:.1f} hours of awake time")
PY
    fi
}

case "${1:-}" in
    --status) status; exit 0 ;;
    --stop)
        launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
        echo "Stopped. Collected data is untouched."
        exit 0 ;;
    --uninstall)
        launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
        rm -f "$PLIST"
        echo "Removed $PLIST. Collected data in $LOGDIR is untouched."
        exit 0 ;;
esac

[[ -x "$APP" ]] || { echo "error: $APP not found. Run ./scripts/build.sh --install first." >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

cat > "$PLIST" <<PLIST_CONTENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP</string>
        <string>--monitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <!-- Background tells the scheduler this is not interactive work: macOS runs it
         on the efficiency cores and gives it the lowest priority band, so it
         competes with nothing you are actually doing. -->
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>10</integer>
    <key>LowPriorityIO</key>
    <true/>
    <key>LowPriorityBackgroundIO</key>
    <true/>
    <!-- Needs a logged-in GUI session: it reads the frontmost application and
         whether the screen is locked. -->
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardErrorPath</key>
    <string>$LOGDIR/monitor.err</string>
    <key>StandardOutPath</key>
    <string>$LOGDIR/monitor.out</string>
</dict>
</plist>
PLIST_CONTENT

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL"

echo "Installed $PLIST"
echo "Monitoring started. It will restart automatically at every login."
echo
sleep 2
status
