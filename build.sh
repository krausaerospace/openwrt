#!/bin/sh
# Build the starlinkpnt Pi 5 image. On a fresh clone this bootstraps the
# feeds (pinned in feeds.conf.default) and seeds .config from
# config-starlinkpnt.seed, so `git clone` + `./build.sh` is all it takes.
# Extra args are passed to make (e.g. ./build.sh package/python3/compile).
set -eu
cd "$(dirname "$0")"

# Sanitized PATH: Windows entries in the default WSL PATH break the
# package/install step (find -execdir refuses to run).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ -d package/feeds ] || {
    ./scripts/feeds update -a
    ./scripts/feeds install -a
}

[ -f .config ] || {
    cp config-starlinkpnt.seed .config
    make defconfig
}

make -j"$(nproc)" V=s "$@"
