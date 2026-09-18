# Custom OpenWrt Image — Changes vs. Stock OpenWrt

## Overview

This image is a customized build of OpenWrt v25.12.5 for the Raspberry Pi 5, purpose-built as the router for the field kit. Compared to a stock OpenWrt release image, it adds a fixed WAN jack with stable USB NIC naming, a pre-configured field-kit network and firewall layout, a GStreamer/ffmpeg media stack for the camera payload, and VPN connectivity (ZeroTier, Tailscale, CloudConnexa and IPsec). Networking is configured automatically on first boot.

Two variants are built from the same commit: `base`, the generic field-kit router, and `pnt`, which is `base` plus the Starlink-to-MAVLink position bridge with its LuCI control page (see "Build Variants" and "`pnt` Variant Only").

Only the Pi 5 (bcm2712) image is built. The Pi 4 (bcm2711) target that was used for bench testing has been dropped from the build.

## Build Variants

| | `base` | `pnt` |
|---|---|---|
| Build command | `./build.sh base` | `./build.sh pnt` |
| `.config` seed | `config.seed` | `config.seed` + `config-pnt.seed` |
| Starlink–MAVLink bridge, LuCI "Starlink PNT" page, `starlink-*` helpers | no | yes (`starlinkpnt` package) |
| Python 3 + pip, bundled wheels | no | yes |
| Everything else in this document | yes | yes |
| Sysupgrade image | `openwrt-base-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz` | `openwrt-pnt-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz` |

- `./build.sh base|pnt [make args]` builds the named variant. `./build.sh [make args]` with no variant reuses the last one (recorded in `tmp/.build-variant`); with no variant and no record it exits with a usage error.
- On a fresh clone `build.sh` bootstraps the feeds, then seeds `.config` from `config.seed` (base) plus `config-pnt.seed` (pnt only) and runs `make defconfig`.
- `build.sh` re-seeds when there is no `.config`; when the recorded variant differs from the requested one, which includes a missing `tmp/.build-variant` (the first run of this `build.sh` in an existing tree, or after `make dirclean` / `rm -rf tmp`); or when a seed file is newer than `.config` (a `git checkout` or pull that touches a seed triggers this). It prints the reason for the re-seed.
- A re-seed replaces `.config`: menuconfig changes that were never written back to a seed are dropped. The previous `.config` is always kept as a timestamped backup, `tmp/.config.before-reseed.<YYYYmmdd-HHMMSS>`, which never overwrites an earlier backup; `build.sh` prints its path. To keep a hand-tuned change permanently, fold it into `config.seed` (see below).
- `tmp/.build-variant` is removed before seeding and written again only after the variant assertion below passes, so a failed or interrupted `make defconfig`, or a failed assertion, always forces a clean re-seed on the next run.
- After resolving the config, `build.sh` asserts the variant: `pnt` must have `starlinkpnt` and `python3` selected; `base` must have neither.
- `config.seed` is the base diffconfig. `config-pnt.seed` is one hand-maintained line, `CONFIG_PACKAGE_starlinkpnt=y`; python3, python3-pip, rpcd, rpcd-mod-ucode, ucode-mod-uci/ubus/fs and luci-base come in through the package's dependencies. To refresh the base seed: `./build.sh base`, `make menuconfig`, then `./scripts/diffconfig.sh > config.seed`. Never run diffconfig from a pnt `.config`.
- `build.sh` passes `EXTRA_IMAGE_NAME=<variant>` to make, so every image filename carries the variant: `openwrt-base-…` / `openwrt-pnt-…` for the `-squashfs-` and `-ext4-` images, both `-sysupgrade` and `-factory`. The `.manifest` is tagged the same way.
- `sha256sums`, `profiles.json` and `config.buildinfo` reflect only the last build (`profiles.json` is deleted before each full build, including explicit `world`/`all` goals, so it does not merge variants).
- No clean is needed between variants: the rootfs is wiped and re-populated from `.config` on every build, and compiled packages stay cached, so both variants' images coexist in `bin/targets/bcm27xx/bcm2712/`.
- The shared top-level `files/` overlay holds only variant-neutral files and is copied into every image. PNT files belong in the `starlinkpnt` package, never in `files/`.

## Hardware Changes

- Adds a `noeee.dtbo` device-tree overlay (disables Energy-Efficient Ethernet on the onboard NIC) plus a `config.txt` adjustment.

## Extra Software Included (both variants, beyond stock defaults)

- Full GStreamer 1.x stack with RTSP client/server modules (including a `gst1-rtsp-server` package not in stock OpenWrt), V4L2 codecs, and camera support; ffmpeg.
- ZeroTier and Tailscale (GCS VPN paths), WireGuard, and OpenVPN with the LuCI OpenVPN app (CloudConnexa).
- IPsec: strongSwan 6 (`strongswan-default` plugin set plus the OpenSSL crypto backend, AES-GCM, and EAP-Identity/EAP-MSCHAPv2 for IKEv2 username logins), configured through `swanctl`, with the kernel IPsec modules (kmod-ipsec, kmod-ipsec4, kmod-ipsec6), route-based `xfrm` tunnel interfaces (kmod-xfrm-interface, luci-proto-xfrm) and the LuCI strongSwan page (luci-app-strongswan-swanctl, swanmon). No connections are preconfigured; peers are defined per deployment.
- `strongswan-charon-cmd` (the `charon-cmd` command-line IKE client, for one-off roadwarrior connections without a swanctl config) and the `kdf` plugin.
- `ip-full` replaces the stock `ip-tiny`, so the complete `ip` command set (including `ip xfrm` for inspecting IPsec state and policies) is available.
- LuCI web interface with firewall and package-manager apps.
- USB network drivers (cdc-ether, rndis, smsc95xx) and ethtool for the USB NIC ports.

## WAN Jacks

- The two USB Ethernet jacks are pinned to stable names (jack1/jack2) keyed on USB controller position, so physical jack labels stay correct across reboots (stock OpenWrt leaves eth1/eth2 assignment to random probe order).
- WAN (dhcp + dhcpv6) is fixed on jack2, where the upstream link is always cabled on this hardware; jack1 is an 'aux' interface for unrelated equipment. There is no runtime jack probing. The first-boot script is the generic `/etc/uci-defaults/99-wan-jacks`, shared by both variants.

## Network / Firewall Configuration (applied on first boot)

- LAN readdressed to 10.221.0.1/16 (stock default is 192.168.1.1/24).
- All VPN interfaces are treated as part of the LAN: ZeroTier (`zt+`), Tailscale (`tailscale0`) and CloudConnexa (OpenVPN `tun+`) are placed in the LAN zone with full LAN access (no separate management-only zone).
- ZeroTier and Tailscale are handled by `99-vpn-lan-zone`, which adds `zt+` and `tailscale0` to the LAN zone's device list and deletes the `gcsvpn` zone that older images created, so a sysupgrade that keeps its config ends up with the same layout as a fresh flash. CloudConnexa's `tun+` is moved by `99-cloudconnexa-firewall`. Earlier images documented this layout but still shipped the separate `gcsvpn` zone (input accepted, forwards rejected) for ZeroTier and did nothing for Tailscale.

## Operations / Field Support

- `/root/status.sh`: non-interactive field verification script that checks WAN state and jack roles, default route and internet reachability, and ZeroTier, and warns when the clock is not set. It is generic and contains no PNT text.
- `status.sh` sources drop-in sections from `/usr/share/kha-status.d/*.sh` in lexical order, so a package can add its own checks without editing the script. The base image ships no drop-ins.
- Pre-provisioned SSH: authorized keys are baked into the image.

## `pnt` Variant Only

Everything in this section is in the `pnt` image only. The `base` image contains none of it: no Python runtime, no MAVLink bridge, no bundled wheels, no LuCI "Starlink PNT" page, and no `starlink-*` helper commands.

Networking and installation are automatic on first boot; the bridge itself is started by an operator from the LuCI "Starlink PNT" page or with `starlink-start <FC-IP>`, or at boot once "Start at boot" is switched on.

### The `starlinkpnt` package

- The bridge is an OpenWrt package, `starlinkpnt` (version 1.0.0-r1, menuconfig category "KHA"), at `package/kha/starlinkpnt/`: a `Makefile` plus a `files/` tree that mirrors the on-device paths. On-device paths, file modes and bridge behaviour are identical to the earlier `files/`-overlay delivery.
- Dependencies pulled in by the package: python3 and python3-pip (Python 3 with asyncio is the bridge runtime), rpcd, rpcd-mod-ucode, ucode-mod-uci, ucode-mod-ubus, ucode-mod-fs and luci-base.
- All Python dependencies (grpcio, pymavlink, protobuf, lxml, etc.) ship as pre-built wheels inside the package (`/root/starlinkpnt/wheels/`), so installation is fully offline. The wheels are aarch64 musllinux binaries, so the package is arch-specific and restricted to bcm27xx/aarch64.
- `/etc/config/starlink_mavlink` is marked as a conffile.
- The Makefile normalises install modes: the 8 executables are 0755, everything else 0644.
- At image build the package's init script is only enabled; its boot-time start is still gated on uci `starlink_mavlink.main.autostart`, and the uci-defaults script still runs at first boot.

### Starlink → MAVLink Position Bridge (manual start)

- `/root/starlinkpnt/starlink_mavlink.py` polls the Starlink dish location over its gRPC API (192.168.100.1:9200) and sends `MAV_CMD_EXTERNAL_POSITION_ESTIMATE` to the flight controller over MAVLink, with optional auto-discovery of the FC on the network.
- The bridge service, its uci config, and the `starlink-start`/`starlink-stop` helper commands are in the image; a first-boot script installs the wheels with no user action (retrying on the next boot if it fails), and `starlink-start` installs them itself if that hook hasn't completed. The image works out of the box: flash, SSH in, `starlink-start <FC-IP>`.
- The bridge does not autostart by default. The image build enables every init script it finds, so the bridge's init script gates its boot-time start on `starlink_mavlink.main.autostart` (ships as `0`; switched on from the LuCI page). Otherwise an operator starts it from LuCI or over SSH with `starlink-start <FC-IP>` (UDP, optional port argument), `starlink-start /dev/ttyXXX [baud]` (serial), `starlink-start auto` (network scan), or bare `starlink-start` to reuse the last saved target. `starlink-stop` stops it. Interactive logins print a reminder whenever the bridge isn't running.
- The shipped uci config has no target preset; the LuCI page proposes one (see below) and the init script falls back to `auto` if started at boot with nothing saved.
- The dish is cabled to the WAN jack (jack2). Its web UI and gRPC API (192.168.100.1) are reached through the WAN lease, which carries a route to the dish. There is no static alias in the dish subnet, so the router (and the MAVLink bridge) can only talk to the dish once it has handed out a lease.
- LAN hosts reach the dish UI/API through normal WAN masquerade once the dish has handed out a lease.
- The package ships `/etc/uci-defaults/98-starlink-legacy-net`, which deletes the legacy `network.starlink_dish` and `network.dishmgmt` (static 192.168.100.2 alias) interfaces that older images created. It matters only when such a device is sysupgraded with its config kept; on a fresh flash it is a no-op. It runs before the shared `99-wan-jacks` and commits on its own; it lives in the package because `99-wan-jacks` is variant-neutral.

### LuCI "Starlink PNT" Page (Services > Starlink PNT)

- A custom LuCI page for the bridge, delivered by the `starlinkpnt` package: the view `/www/luci-static/resources/view/starlinkpnt.js`, the rpcd ucode backend `/usr/share/rpcd/ucode/starlinkpnt.uc` (ubus object `luci.starlinkpnt`), an ACL grant, and a menu entry.
- Status card polled every 5 s: bridge running/stopped, saved target, last discovered flight controller, whether the dish answers at 192.168.100.1, autostart flag, and the tail of the bridge log.
- Bridge configuration form: link mode (UDP to an FC IP, serial device + baud, auto-discover, or a raw pymavlink string), poll interval, GPS_INPUT mode, and the "Start at boot" flag. Save, Save & Start / Restart, and Stop buttons. Settings are written to the same uci config `starlink-start` uses, stored as the same pymavlink string, so the page and the SSH helpers never disagree; starting goes through `starlink-start` so its offline dependency self-heal applies too.
- The flight controller IP defaults to the board's own LAN address with 11 as the third octet: a router at 10.221.0.21 proposes 10.221.11.21, and the default follows the LAN address if it is changed. A saved IP is kept as-is.
- Flight controller GPS toggle (ported from the lawanda gps-web panel): Disable / Enable buttons send ArduPilot aux function 65 (GPS Disable) via `MAV_CMD_DO_AUX_FUNCTION` over MAVLink UDP, using the `/usr/sbin/starlink-gps-aux` helper (pymavlink, from the bundled wheels). Acts at once; not part of the saved settings.
- Every value the backend passes to a shell command is validated against a strict character set first. There is no authentication beyond the LuCI login.

### Status section

- The package ships `/usr/share/kha-status.d/50-starlinkpnt.sh`, a drop-in sourced by `/root/status.sh`. It adds a "Starlink dish" ping (192.168.100.1) and the "Starlink-MAVLink bridge" section (service state, last flight controller, log tail). The base image prints neither. The dish ping prints under its own "Starlink dish" heading after the ZeroTier section; on older images it was inside the WAN block.

### Known difference: live `apk add starlinkpnt`

- Installing the package on a running `base` device with `apk add starlinkpnt` (as opposed to building the `pnt` image) runs the first-boot dependency install immediately and starts the service, because the stock package postinst runs uci-defaults and enables and starts init scripts. In an image build the init script is only enabled and the bridge stays stopped until an operator starts it or "Start at boot" is on.

## Source

The image is built from the krausaerospace/openwrt fork (based on OpenWrt v25.12.5). The repository is self-contained: a fresh clone plus `./build.sh base` or `./build.sh pnt` reproduces the corresponding image.
