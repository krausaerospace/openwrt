#!/bin/sh
# Build the aarch64/musl Python wheelhouse for the starlinkpnt bridge into
# files/root/starlinkpnt/wheels, so first boot pip-installs fully offline.
#
# Strategies (tried in order):
#   1. docker  — exact-environment build inside python:<tag>-alpine on arm64
#                (needs docker + binfmt arm64 emulation)
#   2. no docker — pip cross-downloads prebuilt musllinux/pure wheels from
#                PyPI for the target platform. No emulation needed. All deps
#                (incl. pymavlink) currently ship suitable wheels; if one ever
#                goes sdist-only, build a pure wheel into the wheelhouse first
#                (pip wheel --no-deps -w <wheels> <pkg>) and re-run.
#
# PYTHON_TAG must match the image's python3 minor version:
#   grep PYTHON3_VERSION feeds/packages/lang/python/python3-version.mk
#
# Re-run after changing requirements-device.txt (sync-starlinkpnt.sh first).

set -eu
cd "$(dirname "$0")"

PYTHON_TAG=${PYTHON_TAG:-3.13}
APPDIR=$PWD/files/root/starlinkpnt
REQS=$APPDIR/requirements-device.txt
WHEELS=$APPDIR/wheels
PLATFORM=musllinux_1_2_aarch64

[ -f "$REQS" ] || { echo "ERROR: $REQS not found — run ./sync-starlinkpnt.sh first" >&2; exit 1; }
mkdir -p "$WHEELS"

# ---------------------------------------------------------------------------
# Strategy 1: docker
# ---------------------------------------------------------------------------
if docker info >/dev/null 2>&1; then
    echo "==> Building wheels in python:${PYTHON_TAG}-alpine (linux/arm64) via docker"
    docker run --rm --platform linux/arm64 \
        -e DISABLE_MAVNATIVE=True \
        -v "$APPDIR":/w -w /w \
        "python:${PYTHON_TAG}-alpine" sh -c "
            apk add --no-cache build-base linux-headers libxml2-dev libxslt-dev >/dev/null
            pip wheel --wheel-dir wheels -r requirements-device.txt
            chown -R $(id -u):$(id -g) wheels
        "
else
    # -----------------------------------------------------------------------
    # Strategy 2: pip cross-download (no docker/emulation required)
    # -----------------------------------------------------------------------
    echo "==> docker unavailable — using pip cross-download for $PLATFORM / cp${PYTHON_TAG%.*}${PYTHON_TAG#*.}"

    if python3 -m pip --version >/dev/null 2>&1; then
        PIP="python3 -m pip"
    else
        echo "==> host has no pip — bootstrapping a venv"
        [ -x .wheelhouse-venv/bin/pip ] || python3 -m venv .wheelhouse-venv
        PIP=".wheelhouse-venv/bin/pip"
    fi

    # Download prebuilt wheels for the target platform. --find-links lets the
    # resolver also use any locally pre-built wheels already in the wheelhouse.
    echo "==> Downloading target-platform wheels"
    $PIP download \
        --only-binary=:all: \
        --platform "$PLATFORM" \
        --python-version "$PYTHON_TAG" \
        --implementation cp \
        --find-links "$WHEELS" \
        -d "$WHEELS" \
        -r "$REQS"

    # Prove the wheelhouse is complete for the target: full offline resolution.
    echo "==> Verifying offline resolution against $PLATFORM / Python $PYTHON_TAG"
    $PIP install --dry-run --no-index \
        --find-links "$WHEELS" \
        --only-binary=:all: \
        --platform "$PLATFORM" \
        --python-version "$PYTHON_TAG" \
        --implementation cp \
        --target "$(mktemp -d)" \
        -r "$REQS" >/dev/null
    echo "==> Verification OK — wheelhouse resolves completely offline"
fi

echo ""
echo "==> Wheelhouse contents ($WHEELS):"
ls -1 "$WHEELS"
