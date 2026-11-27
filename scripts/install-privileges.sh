#!/bin/bash
# Grants Parasite passwordless access to thermal/power/GPU telemetry.
#
# Run once, with sudo:   sudo ./scripts/install-privileges.sh
# Undo at any time with: sudo ./scripts/install-privileges.sh --uninstall
#
# What it grants, precisely: your user may run ONE root-owned wrapper script that
# runs powermetrics with a fixed sampler set and no file output. It does not grant
# general sudo, and it does not grant powermetrics itself (which could write files
# as root via -o and would therefore be an escalation path).

set -euo pipefail

WRAPPER_SRC="$(cd "$(dirname "$0")" && pwd)/parasite-powermetrics"
WRAPPER_DST="/usr/local/libexec/parasite-powermetrics"
SUDOERS="/etc/sudoers.d/parasite"

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root — try: sudo $0" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "error: could not determine the invoking user; run via sudo as yourself" >&2
    exit 1
fi

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$SUDOERS" "$WRAPPER_DST"
    echo "Removed $SUDOERS and $WRAPPER_DST"
    exit 0
fi

[[ -f "$WRAPPER_SRC" ]] || { echo "error: wrapper not found at $WRAPPER_SRC" >&2; exit 1; }

install -d -o root -g wheel -m 0755 /usr/local/libexec
install -o root -g wheel -m 0755 "$WRAPPER_SRC" "$WRAPPER_DST"
echo "Installed $WRAPPER_DST (root:wheel 0755)"

# Write via a temp file and validate before moving into place. A malformed file in
# /etc/sudoers.d breaks sudo for the whole machine, so this must never be
# installed unvalidated.
TMP="$(mktemp)"
cat > "$TMP" <<SUDOERS_CONTENT
# Installed by Parasite (local system diagnostics utility).
# Allows only the fixed-argument powermetrics wrapper — not powermetrics itself.
$TARGET_USER ALL=(root) NOPASSWD: $WRAPPER_DST
SUDOERS_CONTENT

chmod 0440 "$TMP"
chown root:wheel "$TMP"

if visudo -cf "$TMP" >/dev/null; then
    mv "$TMP" "$SUDOERS"
    chmod 0440 "$SUDOERS"
    chown root:wheel "$SUDOERS"
    echo "Installed $SUDOERS for user '$TARGET_USER'"
else
    rm -f "$TMP"
    echo "error: sudoers syntax validation failed; nothing was changed" >&2
    exit 1
fi

echo
echo "Verifying..."
if sudo -u "$TARGET_USER" sudo -n "$WRAPPER_DST" 1 500 >/dev/null 2>&1; then
    echo "OK — Parasite can now read thermal, power and per-process GPU data."
else
    echo "WARNING: the grant is installed but the test invocation failed."
    echo "Parasite will still work, without thermal/power detail."
fi
