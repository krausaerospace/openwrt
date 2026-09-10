# Custom OpenWrt Image — Changes vs. Stock OpenWrt

## Overview

This image is a customized build of OpenWrt v25.12.5 for the Raspberry Pi 5, purpose-built as the router for the Starlink PNT field kit. Compared to a stock OpenWrt release image, it adds a Starlink-to-MAVLink position bridge with a LuCI control page, a fixed Starlink WAN jack, a pre-configured field-kit network and firewall layout, and VPN connectivity (ZeroTier and CloudConnexa). Networking and installation are automatic on first boot; the bridge itself is started by an operator from the LuCI "Starlink PNT" page or with `starlink-start <FC-IP>`, or at boot once "Start at boot" is switched on.

Only the Pi 5 (bcm2712) image is built. The Pi 4 (bcm2711) target that was used for bench testing has been dropped from the build.

## Hardware Changes

- Adds a `noeee.dtbo` device-tree overlay (disables Energy-Efficient Ethernet on the onboard NIC) plus a `config.txt` adjustment.

## Extra Software Included (beyond stock defaults)

- Python 3 with asyncio (runtime for the Starlink–MAVLink bridge).
- Full GStreamer 1.x stack with RTSP client/server modules (including a `gst1-rtsp-server` package not in stock OpenWrt), V4L2 codecs, and camera support; ffmpeg.
- ZeroTier (GCS VPN path) and OpenVPN with the LuCI OpenVPN app (CloudConnexa).
- LuCI web interface with firewall and package-manager apps, plus a custom "Starlink PNT" page (see below).
- USB network drivers (cdc-ether, rndis, smsc95xx) and ethtool for the USB NIC ports.

## Starlink → MAVLink Position Bridge (manual start)

- `/root/starlinkpnt/starlink_mavlink.py` polls the Starlink dish location over its gRPC API (192.168.100.1:9200) and sends `MAV_CMD_EXTERNAL_POSITION_ESTIMATE` to the flight controller over MAVLink, with optional auto-discovery of the FC on the network.
- All Python dependencies (grpcio, pymavlink, protobuf, lxml, etc.) ship as pre-built wheels inside the image, so installation is fully offline.
- The bridge service, its uci config, and the `starlink-start`/`starlink-stop` helper commands are baked into the image; a first-boot script installs the wheels with no user action (retrying on the next boot if it fails), and `starlink-start` installs them itself if that hook hasn't completed. The image works out of the box: flash, SSH in, `starlink-start <FC-IP>`.
- The bridge does not autostart by default. The image build enables every init script it finds, so the bridge's init script gates its boot-time start on `starlink_mavlink.main.autostart` (ships as `0`; switched on from the LuCI page). Otherwise an operator starts it from LuCI or over SSH with `starlink-start <FC-IP>` (UDP, optional port argument), `starlink-start /dev/ttyXXX [baud]` (serial), `starlink-start auto` (network scan), or bare `starlink-start` to reuse the last saved target. `starlink-stop` stops it. Interactive logins print a reminder whenever the bridge isn't running.
- The shipped uci config has no target preset; the LuCI page proposes one (see below) and the init script falls back to `auto` if started at boot with nothing saved.

## LuCI "Starlink PNT" Page (Services > Starlink PNT)

- A custom LuCI page for the bridge, delivered as plain files under `files/` (no extra package): the view `/www/luci-static/resources/view/starlinkpnt.js`, the rpcd ucode backend `/usr/share/rpcd/ucode/starlinkpnt.uc` (ubus object `luci.starlinkpnt`), an ACL grant, and a menu entry.
- Status card polled every 5 s: bridge running/stopped, saved target, last discovered flight controller, whether the dish answers at 192.168.100.1, autostart flag, and the tail of the bridge log.
- Bridge configuration form: link mode (UDP to an FC IP, serial device + baud, auto-discover, or a raw pymavlink string), poll interval, GPS_INPUT mode, and the "Start at boot" flag. Save, Save & Start / Restart, and Stop buttons. Settings are written to the same uci config `starlink-start` uses, stored as the same pymavlink string, so the page and the SSH helpers never disagree; starting goes through `starlink-start` so its offline dependency self-heal applies too.
- The flight controller IP defaults to the board's own LAN address with 11 as the third octet: a router at 10.221.0.21 proposes 10.221.11.21, and the default follows the LAN address if it is changed. A saved IP is kept as-is.
- Flight controller GPS toggle (ported from the lawanda gps-web panel): Disable / Enable buttons send ArduPilot aux function 65 (GPS Disable) via `MAV_CMD_DO_AUX_FUNCTION` over MAVLink UDP, using the new `/usr/sbin/starlink-gps-aux` helper (pymavlink, from the bundled wheels). Acts at once; not part of the saved settings.
- Every value the backend passes to a shell command is validated against a strict character set first. There is no authentication beyond the LuCI login.

## Starlink WAN

- The two USB Ethernet jacks are pinned to stable names (jack1/jack2) keyed on USB controller position, so physical jack labels stay correct across reboots (stock OpenWrt leaves eth1/eth2 assignment to random probe order).
- WAN (dhcp + dhcpv6) is fixed on jack2, where the Starlink dish is always cabled on this hardware; jack1 is an 'aux' interface for unrelated equipment. There is no runtime jack probing.
- The dish's web UI and gRPC API (192.168.100.1) are reached through the WAN lease, which carries a route to the dish. There is no static alias in the dish subnet, so the router (and the MAVLink bridge) can only talk to the dish once it has handed out a lease.

## Network / Firewall Configuration (applied on first boot)

- LAN readdressed to 10.221.0.1/16 (stock default is 192.168.1.1/24).
- All VPN interfaces are treated as part of the LAN: ZeroTier (`zt+`), Tailscale (`tailscale0`) and CloudConnexa (OpenVPN `tun+`) are placed in the LAN zone with full LAN access (no separate management-only zone).
- LAN hosts reach the dish UI/API through normal WAN masquerade once the dish has handed out a lease.

## Operations / Field Support

- `/root/status.sh`: non-interactive field verification script that checks WAN state and jack roles, default route and internet reachability, ZeroTier, and the Starlink–MAVLink bridge.
- Pre-provisioned SSH: authorized keys are baked into the image.
- `/root/starlinkpnt/install-ubuntu.sh`: alternative installer that runs the same Starlink bridge as a systemd service on a stock Ubuntu Pi.

## Source

The image is built from the krausaerospace/openwrt fork (based on OpenWrt v25.12.5). The repository is self-contained: a fresh clone plus `./build.sh` reproduces this image.
