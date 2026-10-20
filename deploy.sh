#!/bin/sh
# Copy the plugin to a USB-connected, jailbroken Kindle that has KOReader.
# Usage: ./deploy.sh [/Volumes/Kindle]
set -e
KINDLE="${1:-/Volumes/Kindle}"
DEST="$KINDLE/koreader/plugins/profanitymask.koplugin"
if [ ! -d "$KINDLE/koreader/plugins" ]; then
    echo "KOReader not found at $KINDLE/koreader. Jailbreak and install KOReader first (see docs/SETUP.md)." >&2
    exit 1
fi
luajit tests/run.lua
mkdir -p "$DEST"
rm -f "$DEST"/._*
COPYFILE_DISABLE=1 cp -X profanitymask.koplugin/*.lua "$DEST/"
echo "Installed to $DEST"
echo "Eject the Kindle, then restart KOReader (menu > Exit > Restart KOReader)."
