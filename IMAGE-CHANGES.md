# Custom OpenWrt Image — Changes vs. Stock OpenWrt

## Overview

This image is a customized build of OpenWrt v25.12.5 for the Raspberry Pi 5, purpose-built as the router for the field kit. Compared to a stock OpenWrt release image, it adds a fixed WAN jack with stable USB NIC naming, a pre-configured field-kit network and firewall layout, a GStreamer/ffmpeg media stack for the camera payload, and VPN connectivity (ZeroTier, Tailscale, CloudConnexa and IPsec). Networking is configured automatically on first boot.

Two variants are built from the same commit: `base`, the generic field-kit router, and `pnt`, which is `base` plus the Starlink-to-MAVLink position bridge with its LuCI control page (see "Build Variants" and "`pnt` Variant Only").

Only the Pi 5 (bcm2712) image is built. The Pi 4 (bcm2711) target that was used for bench testing has been dropped from the build.

## Build Variants

| | `base` | `pnt` |
|---|---|---|
| Build command | `./build.sh base` (or `./build.sh` for both) | `./build.sh pnt` (or `./build.sh` for both) |
| `.config` seed | `config.seed` | `config.seed` + `config-pnt.seed` |
| Starlink–MAVLink bridge, LuCI "Starlink PNT" page, `starlink-*` helpers | no | yes (`starlinkpnt` package) |
| Python 3 + pip, bundled wheels | no | yes |
| Everything else in this document | yes | yes |
| Sysupgrade image | `base/openwrt-base-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz` | `pnt/openwrt-pnt-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz` |

- `./build.sh` with no arguments builds both variants, `base` then `pnt`, and stops at the first failure. `./build.sh all [make args]` does the same with make args. `./build.sh base|pnt [make args]` builds the named variant. `./build.sh [make args]` with no variant reuses the last one (recorded in `tmp/.build-variant`); with no variant and no record it exits with a usage error. A bare `./build.sh` used to rebuild the last variant only.
- On a fresh clone `build.sh` bootstraps the feeds, then seeds `.config` from `config.seed` (base) plus `config-pnt.seed` (pnt only) and runs `make defconfig`.
- `build.sh` re-seeds when there is no `.config`; when the recorded variant differs from the requested one, which includes a missing `tmp/.build-variant` (the first run of this `build.sh` in an existing tree, or after `make dirclean` / `rm -rf tmp`); or when a seed file is newer than `.config` (a `git checkout` or pull that touches a seed triggers this). It prints the reason for the re-seed.
- A re-seed replaces `.config`: menuconfig changes that were never written back to a seed are dropped. A bare `./build.sh` switches variant twice per run, so it re-seeds every time. The previous `.config` is always kept as a timestamped backup, `tmp/.config.before-reseed.<YYYYmmdd-HHMMSS>`, which never overwrites an earlier backup; `build.sh` prints its path. To keep a hand-tuned change permanently, fold it into `config.seed` (see below).
- `tmp/.build-variant` is removed before seeding and written again only after the variant assertion below passes, so a failed or interrupted `make defconfig`, or a failed assertion, always forces a clean re-seed on the next run.
- After resolving the config, `build.sh` asserts the variant: `pnt` must have `starlinkpnt` and `python3` selected; `base` must have neither.
- `config.seed` is the base diffconfig. `config-pnt.seed` is one hand-maintained line, `CONFIG_PACKAGE_starlinkpnt=y`; python3, python3-pip, rpcd, rpcd-mod-ucode, ucode-mod-uci/ubus/fs and luci-base come in through the package's dependencies. To refresh the base seed: `./build.sh base`, `make menuconfig`, then `./scripts/diffconfig.sh > config.seed`. Never run diffconfig from a pnt `.config`.
- `build.sh` passes `EXTRA_IMAGE_NAME=<variant>` to make, so every image filename carries the variant: `openwrt-base-…` / `openwrt-pnt-…` for the `-squashfs-` and `-ext4-` images, both `-sysupgrade` and `-factory`. The `.manifest` is tagged the same way.
- After each build, `build.sh` moves that variant's `openwrt-<variant>-*` files (images, `.manifest`, SBOM) out of `bin/targets/bcm27xx/bcm2712/` into its own subfolder, `bin/targets/bcm27xx/bcm2712/base/` or `bin/targets/bcm27xx/bcm2712/pnt/`, overwriting files of the same name. After a full build it also moves `profiles.json` and the `*.buildinfo` files there and deletes the top-level `sha256sums`, which listed the moved files. Each subfolder gets its own `sha256sums` covering every file in it. `packages/` stays at the top level: both variants' images are assembled from that one package feed.
- `profiles.json` is deleted before each full build, including explicit `world`/`all` goals, so it does not merge variants. A partial build (for example `./build.sh pnt package/starlinkpnt/compile`) only moves image files, if any were produced.
- No clean is needed between variants: the rootfs is wiped and re-populated from `.config` on every build, and compiled packages stay cached.
- The shared top-level `files/` overlay holds only variant-neutral files and is copied into every image. PNT files belong in the `starlinkpnt` package, never in `files/`.

## Hardware Changes

- Adds a `noeee.dtbo` device-tree overlay (disables Energy-Efficient Ethernet on the onboard NIC) plus a `config.txt` adjustment.

## Extra Software Included (both variants, beyond stock defaults)

- Full GStreamer 1.x stack with RTSP client/server modules (including a `gst1-rtsp-server` package not in stock OpenWrt), V4L2 codecs, and camera support; ffmpeg.
- Built with `CONFIG_BUILD_PATENTED=y` ("Compile with support for patented functionality", off in stock OpenWrt), set in `config.seed` so both variants keep it. Packages with optional patented features, such as the media encoders and decoders, are built with them enabled instead of having them stripped.
- ZeroTier (with a LuCI page, see "ZeroTier LuCI Page") and Tailscale (GCS VPN paths), WireGuard, and OpenVPN with the LuCI OpenVPN app (CloudConnexa).
- IPsec: strongSwan 6 (`strongswan-default` plugin set plus the OpenSSL crypto backend, AES-GCM, and EAP-Identity/EAP-MSCHAPv2 for IKEv2 username logins), configured through `swanctl`, with the kernel IPsec modules (kmod-ipsec, kmod-ipsec4, kmod-ipsec6), route-based `xfrm` tunnel interfaces (kmod-xfrm-interface, luci-proto-xfrm) and the LuCI strongSwan page (luci-app-strongswan-swanctl, swanmon). No connections are preconfigured; peers are defined per deployment.
- `strongswan-charon-cmd` (the `charon-cmd` command-line IKE client, for one-off roadwarrior connections without a swanctl config) and the `kdf` plugin.
- `ip-full` replaces the stock `ip-tiny`, so the complete `ip` command set (including `ip xfrm` for inspecting IPsec state and policies) is available.
- `/usr/libexec/gstreamer-1.0/gst-plugin-scanner` is a symlink to `/usr/lib/gstreamer-1.0/gst-plugin-scanner` (shipped in the `files/` overlay). The OpenWrt `libgstreamer1` package installs the scanner under `/usr/lib`, but GStreamer looks for it under `/usr/libexec`. Without the link every `gst-launch-1.0` that rebuilds the plugin registry warns "External plugin loader failed" and loads all plugins in-process.
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
- `status.sh` sources drop-in sections from `/usr/share/kha-status.d/*.sh` in lexical order, so a package can add its own checks without editing the script. Both variants ship `40-rtspforwarder.sh` (see below); `pnt` adds `50-starlinkpnt.sh`.
- Pre-provisioned SSH: authorized keys are baked into the image.

## RTSP Forwarder (both variants)

The `rtspforwarder` package (`package/kha/rtspforwarder`, selected in `config.seed`) pushes an MPEG-TS stream received over UDP to an RTSP server with GStreamer. The whole transport stream is sent untouched as one RTP stream (MP2T payload), so the video, KLV metadata and anything else in it reach the server together. With the shipped settings and an endpoint URL set, it runs:

```
gst-launch-1.0 -e \
  udpsrc address=0.0.0.0 port=15004 buffer-size=4194304 \
    caps="video/mpegts,systemstream=(boolean)true,packetsize=(int)188" \
  ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=2000000000 \
  ! tsparse set-timestamps=true \
  ! rtspclientsink location="<url>" protocols=tcp
```

- LuCI page under Services > RTSP Forwarder. The top of the page shows whether the forwarder is running, the saved endpoint, the exact running command line and the last 40 log lines, with Start / Stop / Restart buttons. The General tab holds the RTSP endpoint URL (empty by default) and "Start at boot". The Advanced tab holds the listen IP (`0.0.0.0`, every interface), UDP port (`15004`), receive buffer (4194304 bytes), queue (2000 ms), RTSP transport (TCP), restart delay (5 s) and the GStreamer log level (warning, set through `GST_DEBUG`).
- With the default listen IP `0.0.0.0` the forwarder accepts the UDP stream on every interface. The firewall still applies: senders on the LAN and on the VPNs in the LAN zone (ZeroTier, Tailscale, CloudConnexa) reach UDP 15004, while the WAN zone rejects input, so a sender on the WAN side needs a firewall rule. Set `127.0.0.1` to accept only streams generated on the router itself.
- Settings live in uci `/etc/config/rtspforwarder` (a conffile), so they persist across reboots and are kept by sysupgrade.
- The forwarder is a procd service, `/etc/init.d/rtspforwarder start|stop|restart`. It does nothing until an endpoint URL is saved; the URL must start with `rtsp://` or `rtsps://` and must not contain spaces, quotes or backslashes. "Start at boot" ships on, so once a URL is saved the forwarder starts on every boot. Turn it off on the page to start it by hand only.
- procd restarts the pipeline whenever it exits (for example when the RTSP server drops the connection or refuses the stream), after the restart delay and with no retry limit.
- Save & Apply on the page restarts a running forwarder with the new settings. It never starts a stopped one, and clearing the URL stops it.
- Stopping sends SIGTERM, which ends `gst-launch-1.0` without an RTSP TEARDOWN; the server sees the TCP connection close instead.
- `gst-launch-1.0` runs as `/usr/libexec/rtspforwarder`, a symlink to `/usr/bin/gst-launch-1.0`, so its syslog lines are tagged `rtspforwarder[pid]`. `logread -e rtspforwarder` shows them.
- `/root/status.sh` prints an "RTSP forwarder" section: endpoint, service state and the last log lines.
- The package depends on `gstreamer1-utils` (`gst-launch-1.0`), `gst1-mod-udp`, `gst1-mod-mpegtsdemux` (`tsparse`), `gst1-mod-rtp` (`rtpmp2tpay`, picked automatically by `rtspclientsink`), `gst1-mod-rtpmanager` and `gst1-mod-rtspclientsink`.
- Version 1.x of the package ran ffmpeg (`-c copy -f rtsp`). ffmpeg drops the KLV stream: its RTSP output sends each stream as separate RTP, and its RTP muxer has no KLV support. `/etc/uci-defaults/95-rtspforwarder-gst` removes the ffmpeg-only options (`fifo_size`, `overrun_nonfatal`, `realtime`, `input_timeout`, `probesize`, `analyzeduration`) from a config kept by sysupgrade and maps the `quiet`/`verbose` log levels to `error`/`info`. The new options (`buffer_size`, `queue_time`) take their defaults until saved from the page.

## ZeroTier LuCI Page (both variants)

Stock OpenWrt has no LuCI page for ZeroTier: the LuCI feed carries no ZeroTier app, so it is configured by editing `/etc/config/zerotier` over SSH. This image adds one with the `zerotier-luci` package (`package/kha/zerotier-luci`, selected in `config.seed`).

- LuCI page under VPN > ZeroTier, delivered as the view `/www/luci-static/resources/view/zerotier.js`, the rpcd ucode backend `/usr/share/rpcd/ucode/zerotier.uc` (ubus object `luci.zerotier`), an ACL grant (`luci-app-zerotier`) and a menu entry.
- The status section refreshes every 5 seconds. It shows the service state (running, stopped or disabled), this router's ZeroTier node ID (the ID to authorize on the network controller), whether the node is online (with a note when it is on the TCP relay fallback), the ZeroTier version and UDP port, and the last 30 ZeroTier log lines. It has Start / Stop / Restart buttons. Start and Restart refuse while ZeroTier is disabled in uci.
- The joined-networks table lists each network's ID, name, status (an `ACCESS_DENIED` network says to authorize the node on the controller), interface with its UP/DOWN state, assigned addresses and type. A ZeroTier interface that is DOWN drops traffic without any error, the same condition `/root/status.sh` checks for.
- The peers table lists network members first, then the ZeroTier roots, each with its active direct path ("relayed" when there is none), latency and version.
- The settings form edits the stock `/etc/config/zerotier`: Enable and listen port (`zerotier.global`), and a table of networks to join, each with its 16-digit ID and the controller permissions Managed IPs (default on), Global IPs, Default route and DNS (default off). Removing a network from the table makes the router leave it. The identity secret is not shown on the page.
- Save & Apply restarts ZeroTier through the stock init script's uci reload trigger, which briefly drops every ZeroTier connection, including a LuCI session reached over ZeroTier.
- The form rejects the public "Earth" network (`8056c2e21c000001`). The stock `zerotier` package ships that network in its default config (disabled). On this image `zt+` is in the LAN zone, so joining Earth would give every Earth member full LAN access. On a router still carrying the stock config, the Earth entry is flagged and must be removed or replaced before the form saves.
- The stock `zerotier` package and its init script are unchanged.

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

The image is built from the krausaerospace/openwrt fork (based on OpenWrt v25.12.5). The repository is self-contained: a fresh clone plus `./build.sh` reproduces both images (`./build.sh base` or `./build.sh pnt` for one).
