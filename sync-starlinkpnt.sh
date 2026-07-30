#!/bin/sh
# Refresh the starlinkpnt app files in this buildroot's files/ overlay from
# the source repo (the repo is the source of truth). Run after changing any
# app file, then rebuild the image — or scp the files to a live device.
#
#   ./sync-starlinkpnt.sh [repo-path]      (default: ~/starlinkpnt)

set -eu
cd "$(dirname "$0")"

REPO=${1:-"$HOME/starlinkpnt"}
DEST=files/root/starlinkpnt

[ -f "$REPO/starlink_mavlink.py" ] || { echo "ERROR: repo not found at $REPO" >&2; exit 1; }

mkdir -p "$DEST"
cp "$REPO/starlink_mavlink.py" "$REPO/starlink_stream.py" \
   "$REPO/setup.sh" "$REPO/requirements-device.txt" "$DEST/"
chmod +x "$DEST/setup.sh" "$DEST/starlink_mavlink.py"

echo "==> Synced from $REPO:"
ls -1 "$DEST"
[ -d "$DEST/wheels" ] && echo "(wheels/ present — offline first boot)" \
                      || echo "(no wheels/ — run ./build_wheelhouse.sh for offline first boot)"
