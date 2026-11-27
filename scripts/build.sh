#!/bin/bash
# Builds Parasite.app. SwiftPM alone cannot produce an app bundle, so this
# compiles the executable and assembles the bundle around it.
#
#   ./scripts/build.sh            release build into ./build/Parasite.app
#   ./scripts/build.sh --debug    faster build, no optimisation
#   ./scripts/build.sh --install  also copy into /Applications
#   ./scripts/build.sh --run      launch it when done

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
RUN=0
for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG=debug ;;
        --install) INSTALL=1 ;;
        --run)     RUN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 64 ;;
    esac
done

APP="build/Parasite.app"
echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --disable-sandbox

BINARY="$(swift build -c "$CONFIG" --show-bin-path)/Parasite"
[[ -f "$BINARY" ]] || { echo "error: built binary not found at $BINARY" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Parasite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Enough for a locally built app; it is never distributed, so
# there is no Developer ID or notarisation involved.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    && echo "Signed (ad-hoc)." \
    || echo "warning: ad-hoc signing failed; the app will still run."

echo "Built $APP"

if [[ $INSTALL -eq 1 ]]; then
    rm -rf /Applications/Parasite.app
    cp -R "$APP" /Applications/Parasite.app
    echo "Installed /Applications/Parasite.app"
    [[ $RUN -eq 1 ]] && open /Applications/Parasite.app
elif [[ $RUN -eq 1 ]]; then
    open "$APP"
fi
