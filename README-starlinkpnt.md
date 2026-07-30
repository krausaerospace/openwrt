# Starlink → MAVLink bridge — image integration

This buildroot produces the Pi 5 field-router image with the Starlink→MAVLink
position bridge baked in and fully configured at first boot. App source of
truth: `~/starlinkpnt` (see its `SETUP.md` for the FC-side ArduPilot checklist
and how the bridge works).

## Layout

```
build.sh                                  image build (make)
build_wheelhouse.sh                       aarch64/musl wheels for the bridge deps
sync-starlinkpnt.sh                       pull latest app files from ~/starlinkpnt
files/root/status.sh                      field verification ladder (WAN, ZT, bridge)
files/root/starlinkpnt/                   bridge app + setup.sh + wheels/
files/etc/uci-defaults/99-starlink-mavlink   first-boot hook (offline install + start)
files/etc/hotplug.d/net/05-usbnic-name    pin USB NICs to jack1/jack2 by physical position
files/etc/uci-defaults/99-starlink-wan    WAN preset: wan=jack2, aux=jack1, dish mgmt alias
files/usr/sbin/starlink-portd             keep WAN on whichever jack the dish answers on
files/etc/init.d/starlink-portd           (service for the above; rc.d symlink shipped)
files/etc/uci-defaults/99-lan-ip          LAN preset
files/etc/uci-defaults/99-gcs-netmap      gcsvpn firewall zone (any zt* iface)
files/usr/share/nftables.d/               NETMAP zt<->lan: 10.222.x.y <-> 10.221.x.y
```

`.config` already includes `python3`, `python3-pip`, `openssh-sftp-server`,
`zerotier`. The feed's Python is **3.13** — if it ever bumps, rebuild the
wheelhouse with a matching `PYTHON_TAG`.

## Build

```bash
./sync-starlinkpnt.sh        # after any change in ~/starlinkpnt
./build_wheelhouse.sh        # after changing requirements-device.txt / Python bump
./build.sh                   # make -j$(nproc)
```

The wheelhouse builder uses docker when available, else a no-emulation
fallback (pip cross-download + host-built pure wheels) and verifies the
result resolves fully offline against the target platform.

## What happens on a flashed device

1. **First boot** (zero-touch): `99-lan-ip` sets LAN 10.221.0.1/16;
   the hotplug rename script pins the two USB NICs to `jack1`/`jack2` by
   physical position (raw lan78xx probe order is a coin toss, so kernel
   eth1/eth2 names are never referenced); `99-starlink-wan` puts WAN
   (dhcp + dhcpv6) on jack2 and the free-for-anything `aux` interface on
   jack1, plus a static alias 192.168.100.2/24 so the dish gRPC API is
   reachable even without a lease; `starlink-portd` swaps the roles if
   the dish (the only thing that answers 192.168.100.1 — never use that
   subnet on aux gear) is found on the other jack, so either jack works;
   `99-starlink-mavlink`
   installs the bundled wheels offline and registers + starts the bridge in
   FC auto-discovery mode. Position reporting needs nothing further.
   `99-gcs-netmap` creates the `gcsvpn` zone (any zt* iface, input ACCEPT
   so the router stays manageable over the VPN) and fw4 NETMAPs
   ZeroTier-ingress 10.222.x.y → the 10.221.x.y LAN equivalent
   (masqueraded), so the GCS reaches the autopilot on a second,
   path-distinct address: 10.221.x.y direct over the radio, its 10.222.x.y
   shadow over Starlink + ZeroTier only (no direct/WAN ingress).
   ZeroTier-side setup: managed route 10.222.0.0/16 via this router's ZT
   address, and **no** managed route for 10.221.0.0/16 (that /16 must stay
   owned by the GCS's radio NIC).
2. **ZeroTier** (remote management, optional): membership is managed from
   the controller app. Router-side join is one command —
   `zerotier-cli join <network-id>` — then authorize the node in the
   controller. To make this zero-touch too, bake the network ID into a
   uci-defaults script.
3. **Runtime**: the service waits for the dish, scans for a MAVLink FC
   (cached IP → broadcast → paced subnet sweep on UDP 14550), streams
   `MAV_CMD_EXTERNAL_POSITION_ESTIMATE`, re-discovers if the FC goes quiet.
   Field checks: `/root/status.sh` (WAN, dish, ZT, bridge),
   `starlink-setup` to pin a fixed FC address or serial port,
   logs in `/root/starlinkpnt/logs/`.

## Running on Ubuntu instead of the OpenWrt image

If the Pi runs stock Ubuntu (24.04) rather than this image, install the bridge
as a systemd service:

```bash
scp -r files/root/starlinkpnt ubuntu@<pi>:/tmp/
ssh -t ubuntu@<pi> sudo sh /tmp/starlinkpnt/install-ubuntu.sh   # auto FC discovery
```

`install-ubuntu.sh` creates a venv at `/root/starlinkpnt/venv` (deps from
PyPI — the bundled `wheels/` are musl/cp313-only and ignored; drop
manylinux_aarch64 wheels in `wheels-ubuntu/` for offline installs), writes
`/etc/systemd/system/starlink_mavlink.service` +
`/etc/default/starlink_mavlink`, and enables it at boot. Re-run with `--fc`
to pin a FC address or serial port.

None of the image's networking exists on Ubuntu — no LAN DHCP server, jack
pinning, starlink-portd, ZeroTier, or NETMAP. Minimum netplan for the bridge:
a `192.168.100.2/24` alias (+ dhcp4) on the Starlink-facing NIC so the dish
gRPC is reachable, and a static address on the FC subnet (e.g.
`10.221.0.1/16`) so auto discovery can find the autopilot.

## Device-specific config

This is a source buildroot: anything placed under `files/` lands in the image
verbatim — put harvested configs (e.g. from `sysupgrade -b` on a live router)
directly there. Don't bake a populated ZeroTier `secret` or shared dropbear
host keys into images cloned across devices.
