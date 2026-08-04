# Custom OpenWrt Image — Changes vs. Stock OpenWrt

## Overview

This image is a customized build of OpenWrt v25.12.5 for the Raspberry Pi 5, purpose-built as the router for the Starlink PNT field kit. Compared to a stock OpenWrt release image, it adds a Starlink-to-MAVLink position bridge, automatic Starlink WAN detection on either USB jack, a pre-configured field-kit network and firewall layout, and VPN connectivity (ZeroTier and CloudConnexa). Networking and installation are automatic on first boot; the bridge itself is started manually by an operator (`starlink-start <FC-IP>`) after each boot.

## Hardware Changes

- Adds a `noeee.dtbo` device-tree overlay (disables Energy-Efficient Ethernet on the onboard NIC) plus a `config.txt` adjustment.

## Extra Software Included (beyond stock defaults)

- Python 3 with asyncio (runtime for the Starlink–MAVLink bridge).
- Full GStreamer 1.x stack with RTSP client/server modules (including a `gst1-rtsp-server` package not in stock OpenWrt), V4L2 codecs, and camera support; ffmpeg.
- ZeroTier (GCS VPN path) and OpenVPN with the LuCI OpenVPN app (CloudConnexa).
- LuCI web interface with firewall and package-manager apps.
- USB network drivers (cdc-ether, rndis, smsc95xx) and ethtool for the USB NIC ports.

## Starlink → MAVLink Position Bridge (manual start)

- `/root/starlinkpnt/starlink_mavlink.py` polls the Starlink dish location over its gRPC API (192.168.100.1:9200) and sends `MAV_CMD_EXTERNAL_POSITION_ESTIMATE` to the flight controller over MAVLink, with optional auto-discovery of the FC on the network.
- All Python dependencies (grpcio, pymavlink, protobuf, lxml, etc.) ship as pre-built wheels inside the image, so installation is fully offline.
- The bridge service, its uci config, and the `starlink-start`/`starlink-stop` helper commands are baked into the image; a first-boot script installs the wheels with no user action (retrying on the next boot if it fails), and `starlink-start` installs them itself if that hook hasn't completed. The image works out of the box: flash, SSH in, `starlink-start <FC-IP>`.
- The bridge never autostarts. After each boot an operator SSHes in and runs `starlink-start <FC-IP>` (UDP, optional port argument), `starlink-start /dev/ttyXXX [baud]` (serial), `starlink-start auto` (network scan), or bare `starlink-start` to reuse the last saved target. `starlink-stop` stops it. Interactive logins print a reminder whenever the bridge isn't running.

## Starlink WAN Auto-Detection

- The two USB Ethernet jacks are pinned to stable names (jack1/jack2) keyed on USB controller position, so physical jack labels stay correct across reboots (stock OpenWrt leaves eth1/eth2 assignment to random probe order).
- The `starlink-portd` service detects which jack the Starlink dish is actually plugged into (only the dish answers 192.168.100.1), points wan/wan6/dishmgmt at that jack, and assigns the other jack to an 'aux' interface for unrelated equipment. Assignments are committed, so a unit settles onto its cabling. Aux equipment must not use 192.168.100.0/24 — that subnet is what identifies the dish.
- A static dishmgmt alias (192.168.100.2/24) keeps the dish UI and gRPC API reachable from boot, even while the dish has no connectivity.

## Network / Firewall Configuration (applied on first boot)

- LAN readdressed to 10.221.0.1/16 (stock default is 192.168.1.1/24).
- A `gcsvpn` firewall zone covers any ZeroTier interface (`zt+`), accepting management access (SSH/LuCI) over the VPN while rejecting all forwards.
- CloudConnexa (OpenVPN `tun+`) interfaces are placed in the LAN zone.
- The dish management subnet is in the WAN zone with masquerade, so LAN hosts can reach the dish UI/API through the router.

## Operations / Field Support

- `/root/status.sh`: non-interactive field verification script that checks WAN state and jack roles, default route and internet reachability, ZeroTier, and the Starlink–MAVLink bridge.
- Pre-provisioned SSH: authorized keys are baked into the image.
- `/root/starlinkpnt/install-ubuntu.sh`: alternative installer that runs the same Starlink bridge as a systemd service on a stock Ubuntu Pi.

## Source

The image is built from the krausaerospace/openwrt fork (based on OpenWrt v25.12.5). The repository is self-contained: a fresh clone plus `./build.sh` reproduces this image.
