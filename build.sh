#!/bin/sh
# Build the Pi 5 image variants from this one tree:
#   base  no Starlink-PNT in the image
#   pnt   base + the starlinkpnt package (pulls in python3 etc.)
#
# Usage: ./build.sh                       builds both variants (base, then pnt)
#        ./build.sh all|base|pnt [make args]
#        ./build.sh [make args]           reuses the last variant
#   e.g. ./build.sh pnt package/starlinkpnt/compile
#
# On a fresh clone this bootstraps the feeds (pinned in feeds.conf.default)
# and seeds .config from config.seed (+ config-pnt.seed for pnt), so
# `git clone` + `./build.sh` is all it takes. Switching variant re-seeds
# .config; the old one is kept as tmp/.config.before-reseed.<timestamp>.
# Image files are tagged openwrt-<variant>-bcm27xx-... and filed into
# bin/targets/<board>/<subtarget>/<variant>/ after each build.
set -eu
cd "$(dirname "$0")"

# Sanitized PATH: Windows entries in the default WSL PATH break the
# package/install step (find -execdir refuses to run).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The last built variant lives in tmp/ (gitignored) so ./build.sh with only
# make args keeps building what is already in the tree.
marker=tmp/.build-variant

usage() {
    echo "usage: $0                          (builds base and pnt)" >&2
    echo "       $0 all|base|pnt [make args]" >&2
    echo "       $0 [make args]              (reuses the last variant; no valid one in $marker)" >&2
}

if [ "$#" -eq 0 ]; then
    variant=all
else
    case "$1" in
        all|base|pnt) variant=$1; shift ;;
        *) variant=$(cat "$marker" 2>/dev/null || true) ;;
    esac
fi
# Second check also rejects a corrupt marker.
case "$variant" in
    all|base|pnt) ;;
    *) usage; exit 2 ;;
esac

# Must run before any defconfig: without the feeds most seed symbols
# do not exist and defconfig would drop them.
[ -d package/feeds ] || {
    ./scripts/feeds update -a
    ./scripts/feeds install -a
}

# Seed .config for $1 if needed and assert the result is that variant.
configure() {
    v=$1
    seeds=config.seed
    if [ "$v" = pnt ]; then
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
    if [ "$last" != "$v" ]; then
        reseed=1
        why="variant changed from '${last:-none}' to '$v'"
    fi
    if [ ! -f .config ]; then
        reseed=1
        why="no .config"
    fi

    if [ "$reseed" = 1 ]; then
        mkdir -p tmp
        echo "==> re-seeding .config for variant '$v': $why"
        # Re-seeding discards menuconfig tweaks; keep every old .config
        # (never overwrite an earlier backup) to diff against.
        if [ -f .config ]; then
            backup=tmp/.config.before-reseed.$(date +%Y%m%d-%H%M%S)
            if [ -e "$backup" ]; then
                backup=$backup.$$
            fi
            cp -p .config "$backup"
            echo "    previous .config saved as $backup"
        fi
        # From here until the check below passes, .config may be a raw seed
        # (defconfig failed or was interrupted). Without a marker the next
        # run re-seeds instead of trusting it.
        rm -f "$marker"
        # shellcheck disable=SC2086 # $seeds is a deliberate word list
        cat $seeds > .config
        make defconfig
    fi

    # Always check that .config really is the requested variant. Catches
    # menuconfig drift, and a broken package Makefile: scan.mk silently
    # drops the package, then defconfig silently drops its seed line.
    if [ "$v" = pnt ]; then
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

    # Only recorded once .config is known good (it was removed before
    # seeding), so a failed defconfig or a failed check re-seeds next time.
    mkdir -p tmp
    echo "$v" > "$marker"
}

has() { grep -qx "CONFIG_PACKAGE_$1=y" .config; }
cfg() { sed -n "s/^CONFIG_$1=\"\(.*\)\"\$/\1/p" .config; }

# A full image build is one with no make targets, or only the goals world /
# all (-flags and VAR=value do not count).
full=1
for a in "$@"; do
    case "$a" in
        -*|*=*|world|all) ;;
        *) full=0 ;;
    esac
done

# Move $1's images out of the shared bin dir into its own subfolder.
# The make-level BIN_DIR stays shared on purpose: packages/ lives under it
# and is the feed both variants' images are assembled from.
collect() {
    v=$1
    bindir=bin/targets/$(cfg TARGET_BOARD)/$(cfg TARGET_SUBTARGET)
    dest=$bindir/$v
    [ -d "$bindir" ] || return 0
    files=$(find "$bindir" -maxdepth 1 -type f -name "openwrt-$v-*")
    [ -n "$files" ] || return 0
    mkdir -p "$dest"
    find "$bindir" -maxdepth 1 -type f -name "openwrt-$v-*" -exec mv -f {} "$dest/" \;
    # Per-build metadata describes this variant only; file it alongside.
    if [ "$full" = 1 ]; then
        for f in profiles.json config.buildinfo feeds.buildinfo version.buildinfo; do
            if [ -f "$bindir/$f" ]; then
                mv -f "$bindir/$f" "$dest/"
            fi
        done
        # The top-level sha256sums now points at moved files.
        rm -f "$bindir/sha256sums"
    fi
    (cd "$dest" && find . -maxdepth 1 -type f ! -name sha256sums -printf '%f\n' \
        | LC_ALL=C sort | xargs -r sha256sum --binary > sha256sums)
    echo "==> $v images are in $dest/"
}

build() {
    v=$1; shift
    echo "==> building variant '$v'"
    configure "$v"
    # scripts/json_overview_image_info.py merges entries across builds, so
    # a stale profiles.json would list the other variant's images. Only a
    # full image build regenerates it.
    if [ "$full" = 1 ]; then
        rm -f bin/targets/*/*/profiles.json
    fi
    # EXTRA_IMAGE_NAME must be on the command line: include/image.mk gives
    # that precedence when building the image prefix, while
    # CONFIG_EXTRA_IMAGE_NAME in a seed is discarded by defconfig unless
    # CONFIG_IMAGEOPT=y.
    make -j"$(nproc)" V=s EXTRA_IMAGE_NAME="$v" "$@"
    collect "$v"
}

if [ "$variant" = all ]; then
    build base "$@"
    build pnt "$@"
else
    build "$variant" "$@"
fi
