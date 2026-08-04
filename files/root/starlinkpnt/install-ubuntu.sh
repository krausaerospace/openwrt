#!/bin/sh
# install-ubuntu.sh — install the Starlink -> MAVLink position bridge as a
# systemd boot service on Ubuntu/Debian (e.g. a Pi 5 running Ubuntu 24.04),
# replacing the procd service the custom OpenWrt image ships.
#
# Copy this whole directory to the Pi and run as root:
#
#   sudo sh install-ubuntu.sh                      auto FC discovery (recommended)
#   sudo sh install-ubuntu.sh --fc 10.221.11.71    fixed FC over UDP (port 14550)
#   sudo sh install-ubuntu.sh --fc /dev/ttyAMA0 --baud 921600
#
# Idempotent: re-run any time to change the FC target or push new code.
# Options live in /etc/default/starlink_mavlink — edit that file and
# `systemctl restart starlink_mavlink` for manual tweaks.
#
# The wheels/ directory next to this script is musl/OpenWrt-only and is
# ignored here. Deps install from PyPI into a venv (needs internet once);
# for a fully offline install put manylinux_aarch64 wheels matching the
# system Python into wheels-ubuntu/ instead.

set -eu

INSTALL_DIR=/root/starlinkpnt
VENV=$INSTALL_DIR/venv
PYDEPS="grpcio grpcio-reflection protobuf pymavlink"
DEFAULT_PORT=14550
DEFAULT_SERIAL_BAUD=921600

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

die() { echo "ERROR: $*" >&2; exit 1; }
msg() { echo ""; echo "==> $*"; }

usage() {
    cat <<'EOF'
Usage: sudo sh install-ubuntu.sh [options]

  (no options)          install + enable the boot service with automatic FC
                        discovery
  --fc <target>         FC target: 'auto', an IP (UDP), a serial device
                        (/dev/...), or a full pymavlink string
                        (udpout:10.221.11.71:14550)
  --port <n>            UDP port when --fc is an IP (default 14550)
  --baud <n>            serial baud when --fc is a /dev/ device (default 921600)
  -h, --help            show this help
EOF
    exit "${1:-0}"
}

FC_TARGET=auto
FC_PORT=$DEFAULT_PORT
FC_BAUD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fc)      FC_TARGET=${2:?--fc needs a value}; shift 2 ;;
        --port)    FC_PORT=${2:?--port needs a value}; shift 2 ;;
        --baud)    FC_BAUD=${2:?--baud needs a value}; shift 2 ;;
        -h|--help) usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || die "must run as root (sudo sh install-ubuntu.sh)"
command -v systemctl >/dev/null 2>&1 || die "no systemd here — use setup.sh instead"

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

# ---------------------------------------------------------------------------
# 1. Project files
# ---------------------------------------------------------------------------

msg "Installing to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/logs"
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    [ -f "$SCRIPT_DIR/starlink_mavlink.py" ] || die "starlink_mavlink.py not found next to install-ubuntu.sh"
    cp "$SCRIPT_DIR/starlink_mavlink.py" "$INSTALL_DIR/"
    if [ -f "$SCRIPT_DIR/starlink_stream.py" ]; then
        cp "$SCRIPT_DIR/starlink_stream.py" "$INSTALL_DIR/"
    fi
    cp "$SCRIPT_DIR/$(basename -- "$0")" "$INSTALL_DIR/install-ubuntu.sh"
fi
chmod +x "$INSTALL_DIR/starlink_mavlink.py" "$INSTALL_DIR/install-ubuntu.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Python venv + dependencies
# ---------------------------------------------------------------------------

msg "Setting up Python venv ..."
if ! python3 -m venv "$VENV" 2>/dev/null; then
    apt-get update
    apt-get install -y python3-venv
    python3 -m venv "$VENV"
fi

msg "Checking Python dependencies ..."
if "$VENV/bin/python3" -c "import grpc, grpc_reflection, google.protobuf, pymavlink" >/dev/null 2>&1; then
    echo "already installed"
else
    if [ -d "$SCRIPT_DIR/wheels-ubuntu" ]; then
        echo "installing from wheels-ubuntu/ (offline)"
        # shellcheck disable=SC2086
        "$VENV/bin/pip" install --no-index --find-links "$SCRIPT_DIR/wheels-ubuntu" $PYDEPS
    else
        echo "installing from PyPI (needs internet)"
        # shellcheck disable=SC2086
        "$VENV/bin/pip" install $PYDEPS
    fi
    "$VENV/bin/python3" -c "import grpc, grpc_reflection, google.protobuf, pymavlink" \
        || die "Python dependencies failed to import after install"
fi

# ---------------------------------------------------------------------------
# 3. systemd boot service
# ---------------------------------------------------------------------------

msg "Installing boot service ..."
cat > /etc/default/starlink_mavlink <<EOF
# Options for starlink_mavlink.service — written by install-ubuntu.sh.
# Edit and run: systemctl restart starlink_mavlink
# 'auto' discovers the FC on all connected subnets; see starlink_mavlink.py --help.
STARLINK_MAVLINK_OPTS="--mavlink $MAVLINK_CONN${FC_BAUD:+ --baud $FC_BAUD} --interval 2.0 --log-dir $INSTALL_DIR/logs --no-console"
EOF

cat > /etc/systemd/system/starlink_mavlink.service <<EOF
[Unit]
Description=Starlink -> MAVLink position bridge
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
EnvironmentFile=/etc/default/starlink_mavlink
ExecStart=$VENV/bin/python3 $INSTALL_DIR/starlink_mavlink.py \$STARLINK_MAVLINK_OPTS
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable starlink_mavlink.service
systemctl restart starlink_mavlink.service
sleep 3
systemctl --no-pager --full status starlink_mavlink.service || true

cat <<EOF

Done. The bridge starts automatically on every boot.

  status     : systemctl status starlink_mavlink
  live log   : journalctl -fu starlink_mavlink   (or tail -f $INSTALL_DIR/logs/starlink_mavlink.log)
  positions  : $INSTALL_DIR/logs/positions.csv
  change FC  : re-run this script, or edit /etc/default/starlink_mavlink
  stop       : systemctl stop starlink_mavlink
  disable    : systemctl disable starlink_mavlink

The bridge needs a route to the dish (192.168.100.1) — e.g. a 192.168.100.2/24
alias on the Starlink-facing NIC in netplan — and, for auto discovery, an
address on the flight controller's subnet.
EOF
