#!/bin/sh
# setup.sh — one-shot installer/launcher for the Starlink -> MAVLink position bridge.
#
# Run as root on the companion computer (OpenWrt Pi), from a copy of this repo:
#
#   sh setup.sh                         interactive: installs everything, asks for
#                                       the flight controller address (Enter =
#                                       automatic discovery), starts the bridge now
#   sh setup.sh --fc auto               non-interactive, auto-discover the FC
#   sh setup.sh --fc 10.221.11.71       non-interactive UDP (default port 14550)
#   sh setup.sh --fc /dev/ttyAMA10 --baud 921600
#   sh setup.sh --preinstall            install the Python deps, no prompts, does
#                                       NOT start anything (used by the custom
#                                       OpenWrt image's first-boot hook)
#
# The bridge never autostarts at boot: after every reboot an operator starts it
# by hand with 'starlink-start <FC-IP>' (or 'starlink-start auto').
#
# This script does NOT create the service or helper files. Those are plain
# files baked into the image and maintained in the buildroot repo (the single
# source of truth):
#   files/etc/init.d/starlink_mavlink   files/etc/config/starlink_mavlink
#   files/usr/sbin/starlink-start       files/usr/sbin/starlink-stop
# On a device not flashed from this image, copy them into place first.
#
# Idempotent: re-run any time to change the FC address or push a new copy of
# starlink_mavlink.py. On OpenWrt the procd service (started only by
# starlink-start, never at boot) is already baked into the image; on other
# Linux (apt) this installs deps and runs in the foreground instead.
#
# Offline install: if a wheels/ directory sits next to this script (built by
# openwrt/build_wheelhouse.sh), pip installs from it without touching the network.

set -eu

INSTALL_DIR=/root/starlinkpnt
PYDEPS="grpcio grpcio-reflection protobuf pymavlink"
DEFAULT_PORT=14550
DEFAULT_SERIAL_BAUD=921600

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SELF="$SCRIPT_DIR/$(basename -- "$0")"

FC_TARGET=""
FC_PORT=$DEFAULT_PORT
FC_BAUD=""
PREINSTALL=0
MAVLINK_CONN=""

die() { echo "ERROR: $*" >&2; exit 1; }
msg() { echo ""; echo "==> $*"; }

usage() {
    cat <<'EOF'
Usage: sh setup.sh [options]

  (no options)          interactive setup: install deps, prompt for the flight
                        controller address, start the bridge now (manual start
                        again after a reboot — it never autostarts)
  --fc <target>         FC target: 'auto' (discover on the network), an IP (UDP),
                        a serial device (/dev/...), or a full pymavlink string
                        (udpout:10.221.11.71:14550)
  --port <n>            UDP port when --fc is an IP (default 14550)
  --baud <n>            serial baud when --fc is a /dev/ device (default 921600)
  --preinstall          install the Python deps, but don't ask for an FC
                        address or start anything (image first-boot hook)
  -h, --help            show this help
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fc)         FC_TARGET=${2:?--fc needs a value}; shift 2 ;;
        --port)       FC_PORT=${2:?--port needs a value}; shift 2 ;;
        --baud)       FC_BAUD=${2:?--baud needs a value}; shift 2 ;;
        --preinstall) PREINSTALL=1; shift ;;
        -h|--help)    usage 0 ;;
        *)            echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || die "must run as root"

IS_OPENWRT=0
if [ -f /etc/openwrt_release ] && command -v uci >/dev/null 2>&1; then
    IS_OPENWRT=1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

prompt() { # $1 = text, $2 = default (may be empty). Result in $REPLY.
    while :; do
        if [ -n "$2" ]; then
            printf "%s [%s]: " "$1" "$2"
        else
            printf "%s: " "$1"
        fi
        read -r REPLY || die "no interactive terminal — use --fc <ip|device> for unattended setup"
        if [ -z "$REPLY" ]; then
            REPLY=$2
        fi
        if [ -n "$REPLY" ]; then
            return 0
        fi
        echo "  (a value is required)"
    done
}

resolve_conn() {
    # Turn FC_TARGET (+ FC_PORT / FC_BAUD) into a pymavlink connection string.
    case "$FC_TARGET" in
        auto)
            MAVLINK_CONN=auto
            ;;
        /dev/*)
            MAVLINK_CONN=$FC_TARGET
            if [ -z "$FC_BAUD" ]; then
                FC_BAUD=$DEFAULT_SERIAL_BAUD
            fi
            ;;
        *:*)
            MAVLINK_CONN=$FC_TARGET     # already a full connection string
            ;;
        *)
            MAVLINK_CONN="udpout:${FC_TARGET}:${FC_PORT}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Ask for the FC address first (so the rest can run unattended)
# ---------------------------------------------------------------------------

if [ "$PREINSTALL" -eq 0 ] && [ -z "$FC_TARGET" ]; then
    if [ ! -t 0 ]; then
        echo "No interactive terminal — defaulting to automatic FC discovery" >&2
        FC_TARGET=auto
    fi
fi

if [ "$PREINSTALL" -eq 0 ] && [ -z "$FC_TARGET" ]; then
    current=""
    if [ "$IS_OPENWRT" -eq 1 ]; then
        current=$(uci -q get starlink_mavlink.main.mavlink 2>/dev/null || true)
    fi

    echo ""
    echo "Where should Starlink position reports be sent?"
    echo "  - 'auto' scans the network for a MAVLink flight controller (recommended)"
    echo "  - flight controller IP for UDP          e.g. 10.221.11.71"
    echo "  - serial device wired to the FC         e.g. /dev/ttyAMA10"
    echo "  - full pymavlink connection string      e.g. udpout:10.221.11.71:14550"
    prompt "Flight controller address" "${current:-auto}"
    FC_TARGET=$REPLY

    case "$FC_TARGET" in
        auto)
            : ;;
        /dev/*)
            prompt "Serial baud rate" "${FC_BAUD:-$DEFAULT_SERIAL_BAUD}"
            FC_BAUD=$REPLY
            ;;
        *:*)
            : ;;    # full string, nothing more to ask
        *)
            prompt "MAVLink UDP port" "$FC_PORT"
            FC_PORT=$REPLY
            ;;
    esac
fi

if [ "$PREINSTALL" -eq 0 ]; then
    resolve_conn
fi

# ---------------------------------------------------------------------------
# 2. Python interpreter + pip
# ---------------------------------------------------------------------------

msg "Checking Python ..."
if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
    echo "python3 + pip already present ($(python3 -V 2>&1))"
else
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add python3 python3-pip
    elif command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install python3 python3-pip
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y python3 python3-pip
    else
        die "no supported package manager (apk/opkg/apt-get) — install python3 + pip manually"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Python dependencies (bundled wheels if available, else PyPI)
# ---------------------------------------------------------------------------

msg "Checking Python dependencies ..."
if python3 -c "import grpc, grpc_reflection, google.protobuf, pymavlink" >/dev/null 2>&1; then
    echo "already installed"
else
    PIPFLAGS=""
    if python3 -m pip install --help 2>/dev/null | grep -q -- --break-system-packages; then
        PIPFLAGS="--break-system-packages"
    fi
    if [ -d "$SCRIPT_DIR/wheels" ]; then
        echo "installing from bundled wheels (offline)"
        # shellcheck disable=SC2086
        python3 -m pip install $PIPFLAGS --no-index --find-links "$SCRIPT_DIR/wheels" $PYDEPS
    else
        echo "installing from PyPI (needs internet)"
        # shellcheck disable=SC2086
        python3 -m pip install $PIPFLAGS $PYDEPS
    fi
    python3 -c "import grpc, grpc_reflection, google.protobuf, pymavlink" \
        || die "Python dependencies failed to import after install"
fi

# ---------------------------------------------------------------------------
# 4. Install project files
# ---------------------------------------------------------------------------

msg "Installing to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/logs"
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    [ -f "$SCRIPT_DIR/starlink_mavlink.py" ] || die "starlink_mavlink.py not found next to setup.sh"
    cp "$SCRIPT_DIR/starlink_mavlink.py" "$INSTALL_DIR/"
    if [ -f "$SCRIPT_DIR/starlink_stream.py" ]; then
        cp "$SCRIPT_DIR/starlink_stream.py" "$INSTALL_DIR/"
    fi
    cp "$SELF" "$INSTALL_DIR/setup.sh"
fi
chmod +x "$INSTALL_DIR/starlink_mavlink.py" "$INSTALL_DIR/setup.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Non-OpenWrt fallback: no procd, run in the foreground
# ---------------------------------------------------------------------------

if [ "$IS_OPENWRT" -eq 0 ]; then
    if [ "$PREINSTALL" -eq 1 ]; then
        msg "Preinstall complete (non-OpenWrt system: no boot service installed)"
        exit 0
    fi
    msg "Non-OpenWrt system — starting in the foreground (Ctrl-C to stop)"
    set -- --mavlink "$MAVLINK_CONN" --log-dir "$INSTALL_DIR/logs"
    if [ -n "$FC_BAUD" ]; then
        set -- "$@" --baud "$FC_BAUD"
    fi
    exec python3 "$INSTALL_DIR/starlink_mavlink.py" "$@"
fi

# ---------------------------------------------------------------------------
# 6. OpenWrt: verify the baked-in service files (this script creates nothing)
# ---------------------------------------------------------------------------

msg "Checking service files ..."
for f in /etc/init.d/starlink_mavlink /usr/sbin/starlink-start /usr/sbin/starlink-stop; do
    [ -x "$f" ] || die "$f missing — this device wasn't flashed from the custom image.
Copy files/etc/init.d/starlink_mavlink, files/etc/config/starlink_mavlink and
files/usr/sbin/starlink-{start,stop} from the buildroot repo into place first."
done
# Never autostart: clear any boot enablement from earlier installs.
/etc/init.d/starlink_mavlink disable 2>/dev/null || true
ln -sf "$INSTALL_DIR/setup.sh" /usr/sbin/starlink-setup

if [ "$PREINSTALL" -eq 1 ]; then
    msg "Preinstall complete. Dependencies are installed; the bridge is NOT started."
    echo "To start it: starlink-start <FC-IP>   (or 'starlink-start auto' to scan)"
    exit 0
fi

msg "Saving configuration and starting (via starlink-start) ..."
if [ -n "$FC_BAUD" ]; then
    /usr/sbin/starlink-start "$MAVLINK_CONN" "$FC_BAUD"
else
    /usr/sbin/starlink-start "$MAVLINK_CONN"
fi

LOG="$INSTALL_DIR/logs/starlink_mavlink.log"
if [ -f "$LOG" ]; then
    echo ""
    echo "--- last log lines ---"
    tail -n 15 "$LOG"
fi

cat <<EOF

Done. The bridge is running now but does NOT autostart at boot:
after a reboot, run 'starlink-start' (reuses this FC target).

  start      : starlink-start [<FC-IP>|auto|/dev/...]
  stop       : starlink-stop
  status     : /etc/init.d/starlink_mavlink status
  live log   : tail -f $LOG
  positions  : $INSTALL_DIR/logs/positions.csv
  change FC  : starlink-start <new-target>   (or starlink-setup to reinstall)
EOF
