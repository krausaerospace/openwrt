#!/bin/sh
# Build a Pi 5 image variant from this one tree:
#   base  no Starlink-PNT in the image
#   pnt   base + the starlinkpnt package (pulls in python3 etc.)
#
# Usage: ./build.sh base|pnt [make args]
#        ./build.sh [make args]          reuses the last variant
#   e.g. ./build.sh pnt package/starlinkpnt/compile
#
# On a fresh clone this bootstraps the feeds (pinned in feeds.conf.default)
# and seeds .config from config.seed (+ config-pnt.seed for pnt), so
# `git clone` + `./build.sh pnt` is all it takes. Switching variant re-seeds
# .config; the old one is kept as tmp/.config.before-reseed.<timestamp>.
# Image files are tagged openwrt-<variant>-bcm27xx-...
set -eu
cd "$(dirname "$0")"

# Sanitized PATH: Windows entries in the default WSL PATH break the
# package/install step (find -execdir refuses to run).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage() {
    echo "usage: $0 base|pnt [make args]" >&2
    echo "       $0 [make args]    (reuses the last variant; no valid one in $marker)" >&2
}

# The last built variant lives in tmp/ (gitignored) so a bare ./build.sh
# keeps building what is already in the tree.
marker=tmp/.build-variant
case "${1:-}" in
    base|pnt) variant=$1; shift ;;
    *) variant=$(cat "$marker" 2>/dev/null || true) ;;
esac
# Second check also rejects a corrupt marker.
case "$variant" in
    base|pnt) ;;
    *) usage; exit 2 ;;
esac

# Must run before any defconfig: without the feeds most seed symbols
# do not exist and defconfig would drop them.
[ -d package/feeds ] || {
    ./scripts/feeds update -a
    ./scripts/feeds install -a
}

seeds=config.seed
if [ "$variant" = pnt ]; then
    seeds="$seeds config-pnt.seed"
fi

# Re-seed when there is no .config, the variant changed, or a seed was
# edited since .config was generated. $why ends up in the notice below.
last=$(cat "$marker" 2>/dev/null || true)
reseed=0
why=
for s in $seeds; do
    if [ "$s" -nt .config ]; then
        reseed=1
        why="seed $s is newer than .config"
    fi
done
if [ "$last" != "$variant" ]; then
    reseed=1
    why="variant changed from '${last:-none}' to '$variant'"
fi
if [ ! -f .config ]; then
    reseed=1
    why="no .config"
fi

if [ "$reseed" = 1 ]; then
    mkdir -p tmp
    echo "==> re-seeding .config for variant '$variant': $why"
    # Re-seeding discards menuconfig tweaks; keep every old .config (never
    # overwrite an earlier backup) to diff against.
    if [ -f .config ]; then
        backup=tmp/.config.before-reseed.$(date +%Y%m%d-%H%M%S)
        if [ -e "$backup" ]; then
            backup=$backup.$$
        fi
        cp -p .config "$backup"
        echo "    previous .config saved as $backup"
    fi
    # From here until the check below passes, .config may be a raw seed
    # (defconfig failed or was interrupted). Without a marker the next run
    # re-seeds instead of trusting it.
    rm -f "$marker"
    # shellcheck disable=SC2086 # $seeds is a deliberate word list
    cat $seeds > .config
    make defconfig
fi

# Always check that .config really is the requested variant. Catches
# menuconfig drift, and a broken package Makefile: scan.mk silently drops
# the package, then defconfig silently drops its seed line.
has() { grep -qx "CONFIG_PACKAGE_$1=y" .config; }
if [ "$variant" = pnt ]; then
    if ! has starlinkpnt || ! has python3; then
        echo "error: pnt variant resolved without starlinkpnt/python3 in .config;" >&2
        echo "       the package was probably dropped - see logs/package/kha/starlinkpnt/dump.txt" >&2
        exit 1
    fi
else
    if has starlinkpnt || has python3; then
        echo "error: base variant resolved with python3/starlinkpnt - something selects it" >&2
        exit 1
    fi
fi

# Only recorded once .config is known good (it was removed before seeding),
# so a failed defconfig or a failed check re-seeds on the next run.
mkdir -p tmp
echo "$variant" > "$marker"

# scripts/json_overview_image_info.py merges entries across builds, so a
# stale profiles.json would list the other variant's images. Only a full
# image build (no make targets, or the goals world / all; -flags and
# VAR=value do not count) regenerates it.
full=1
for a in "$@"; do
    case "$a" in
        -*|*=*|world|all) ;;
        *) full=0 ;;
    esac
done
if [ "$full" = 1 ]; then
    rm -f bin/targets/*/*/profiles.json
fi

# EXTRA_IMAGE_NAME must be on the command line: include/image.mk gives that
# precedence when building the image prefix, while CONFIG_EXTRA_IMAGE_NAME
# in a seed is discarded by defconfig unless CONFIG_IMAGEOPT=y.
make -j"$(nproc)" V=s EXTRA_IMAGE_NAME="$variant" "$@"
