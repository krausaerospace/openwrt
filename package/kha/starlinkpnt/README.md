# Starlink → MAVLink bridge — the `starlinkpnt` package

This buildroot produces two Pi 5 field-router images from the same commit:
`base` (no Starlink-PNT anywhere in the image) and `pnt` (base + the
Starlink→MAVLink position bridge). The bridge is this OpenWrt package,
`starlinkpnt` (menuconfig category "KHA"). Flash the `pnt` image and it works
out of the box: the service, uci config, and `starlink-start`/`starlink-stop`
helpers are in the image itself, and the Python deps install offline at first
boot (with `starlink-start` self-healing if that hook hasn't run). The bridge
does not autostart by default — an operator starts it from the LuCI page
(Services > Starlink PNT) or runs `starlink-start <FC-IP>` (or
`starlink-start auto`) after every boot; "Start at boot" can be switched on
from that page. The bridge app ships in
`package/kha/starlinkpnt/files/root/starlinkpnt/` (see the app's `SETUP.md`
for the FC-side ArduPilot checklist and how the bridge works).

Image-level changes for both variants are documented in
[`IMAGE-CHANGES.md`](../../../IMAGE-CHANGES.md) at the repo root.

Clone-and-build:

```bash
git clone https://github.com/krausaerospace/openwrt.git && cd openwrt
./build.sh pnt
```

## Layout

Paths are relative to the repo root.

Repo root:

```
build.sh                                  image build: ./build.sh base|pnt (feeds + .config bootstrap, make)
build_wheelhouse.sh                       aarch64/musl wheels for the bridge deps
sync-starlinkpnt.sh                       refresh the app files from the app repo (local, gitignored)
config.seed                               base diffconfig seeding .config on fresh clones
config-pnt.seed                           pnt addition: CONFIG_PACKAGE_starlinkpnt=y
```

Shared `files/` overlay (variant-neutral, copied into every image):

```
files/root/status.sh                      field verification ladder (WAN, ZT) + /usr/share/kha-status.d drop-ins
files/etc/dropbear/authorized_keys        pre-provisioned SSH keys
files/etc/hotplug.d/net/05-usbnic-name    pin USB NICs to jack1/jack2 by physical position
files/etc/uci-defaults/99-wan-jacks       WAN preset: wan=jack2, aux=jack1
files/etc/uci-defaults/99-lan-ip          LAN preset
files/etc/uci-defaults/99-vpn-lan-zone    ZeroTier zt+ and Tailscale tailscale0 into the LAN zone
files/etc/uci-defaults/99-cloudconnexa-firewall   CloudConnexa tun+ into the LAN zone
```

This package (`pnt` image only):

```
package/kha/starlinkpnt/Makefile          package definition (DEPENDS, install modes, conffile)
package/kha/starlinkpnt/files/root/starlinkpnt/                    bridge app + requirements-device.txt + wheels/
package/kha/starlinkpnt/files/etc/uci-defaults/98-starlink-legacy-net  drop legacy starlink_dish/dishmgmt interfaces (sysupgrade from older images)
package/kha/starlinkpnt/files/etc/uci-defaults/99-starlink-mavlink first-boot hook (offline wheel install; no start)
package/kha/starlinkpnt/files/etc/init.d/starlink_mavlink          bridge service (boot start gated on uci autostart, default off)
package/kha/starlinkpnt/files/etc/config/starlink_mavlink          bridge uci config (FC target etc.; conffile)
package/kha/starlinkpnt/files/etc/profile.d/starlink-hint.sh       login hint when the bridge isn't running
package/kha/starlinkpnt/files/usr/sbin/starlink-install-deps       offline install of the Python deps from wheels/
package/kha/starlinkpnt/files/usr/sbin/starlink-start              set FC target + start the bridge
package/kha/starlinkpnt/files/usr/sbin/starlink-stop               stop the bridge
package/kha/starlinkpnt/files/usr/sbin/starlink-gps-aux            FC GPS enable/disable over MAVLink (LuCI GPS buttons)
package/kha/starlinkpnt/files/www/luci-static/resources/view/starlinkpnt.js   LuCI "Starlink PNT" page
package/kha/starlinkpnt/files/usr/share/rpcd/ucode/starlinkpnt.uc             its rpcd backend (ubus luci.starlinkpnt)
package/kha/starlinkpnt/files/usr/share/rpcd/acl.d/luci-app-starlinkpnt.json  ACL grant for the page
package/kha/starlinkpnt/files/usr/share/luci/menu.d/luci-app-starlinkpnt.json menu entry (Services > Starlink PNT)
package/kha/starlinkpnt/files/usr/share/kha-status.d/50-starlinkpnt.sh        status.sh drop-in (dish ping, bridge section)
```

The package's `files/` tree mirrors the on-device paths. The Makefile
normalises install modes (the 8 executables 0755, everything else 0644). The
package is arch-specific — the wheels are aarch64 musllinux binaries — and
restricted to bcm27xx/aarch64.

`config.seed` is the base seed and contains no Python. `config-pnt.seed` is
one hand-maintained line, `CONFIG_PACKAGE_starlinkpnt=y`; `python3`,
`python3-pip`, `rpcd`, `rpcd-mod-ucode`, `ucode-mod-uci`/`ubus`/`fs` and `luci-base`
come in through this package's DEPENDS. The feed's Python is **3.13** — if it
ever bumps, rebuild the wheelhouse with a matching `PYTHON_TAG`.

## Build

```bash
./build.sh pnt               # bootstraps feeds + .config on first run, then make
./build.sh base              # the same commit without the bridge
./build.sh                   # no variant: reuse the last one
./build_wheelhouse.sh        # only after changing requirements-device.txt / Python bump
./sync-starlinkpnt.sh        # only after changing the app in the app repo (default ~/starlinkpnt)
```

Images are named by variant
(`openwrt-pnt-bcm27xx-bcm2712-rpi-5-squashfs-sysupgrade.img.gz`,
`openwrt-base-…`), and no clean is needed between variants; see
`IMAGE-CHANGES.md` for the details.

The wheelhouse output
(`package/kha/starlinkpnt/files/root/starlinkpnt/wheels/`) is committed, so a
fresh clone builds fully offline-installable images without running
`build_wheelhouse.sh`. After changing the image config via `make menuconfig`,
refresh the committed base seed: `./build.sh base`, `make menuconfig`, then
`./scripts/diffconfig.sh > config.seed`. Never run diffconfig from a pnt
`.config`; `config-pnt.seed` is maintained by hand.

`build.sh` re-seeds `.config` from the seed file(s) when:

- there is no `.config`;
- the recorded variant (`tmp/.build-variant`) differs from the requested one —
  including a missing marker: the first run of this `build.sh` in an existing
  tree, or after `make dirclean` / `rm -rf tmp`;
- a seed file is newer than `.config` (a `git checkout` or pull that touches a
  seed triggers this).

A re-seed replaces `.config`, so menuconfig changes that were never written
back to a seed are dropped. The previous `.config` is always kept as a
timestamped backup, `tmp/.config.before-reseed.<YYYYmmdd-HHMMSS>` (earlier
backups are never overwritten); `build.sh` prints the backup path and the
reason for the re-seed. To keep a hand-tuned change permanently, fold it into
`config.seed` as above. The marker is removed before seeding and written again
only after the resolved-config assertion passes, so a failed or interrupted
`make defconfig`, or a failed assertion, forces a clean re-seed on the next
run. `profiles.json` is removed before full builds, including explicit
`world`/`all` goals.

The wheelhouse builder uses docker when available, else a no-emulation
fallback (pip cross-download + host-built pure wheels) and verifies the
result resolves fully offline against the target platform.

## What happens on a flashed device

1. **First boot** (zero-touch): `99-lan-ip` sets LAN 10.221.0.1/16;
   the hotplug rename script pins the two USB NICs to `jack1`/`jack2` by
   physical position (raw lan78xx probe order is a coin toss, so kernel
   eth1/eth2 names are never referenced); `99-wan-jacks` puts WAN
   (dhcp + dhcpv6) on jack2 — the dish is always cabled there on this
   hardware — and the free-for-anything `aux` interface on jack1. The dish
   (192.168.100.1) is reached through the WAN lease, which carries a route
   to it, so the gRPC API is only reachable once the dish has handed out a
   lease; `98-starlink-legacy-net` (this package) removes the legacy
   `starlink_dish`/`dishmgmt` interfaces that a device sysupgraded from an
   older image still carries — a no-op on a fresh flash; `99-starlink-mavlink`
   installs the bundled wheels offline. The bridge service, uci config, and
   `starlink-start`/`starlink-stop` are files in this package, installed into
   the image — the packaged files are the single source of truth;
   `starlink-install-deps` only installs the Python deps and never
   (re)creates them. Nothing starts the bridge.
   `99-vpn-lan-zone` and `99-cloudconnexa-firewall` put the VPN interfaces
   (ZeroTier `zt+`, Tailscale `tailscale0`, CloudConnexa `tun+`) into the
   LAN zone, so VPN peers reach the router and the LAN like wired hosts;
   see "Network / Firewall Configuration" in `IMAGE-CHANGES.md`.
2. **ZeroTier** (remote management, optional): membership is managed from
   the controller app. Router-side join is one command —
   `zerotier-cli join <network-id>` — then authorize the node in the
   controller. To make this zero-touch too, bake the network ID into a
   uci-defaults script.
3. **Starting the bridge** (manual unless "Start at boot" is on): open LuCI
   at Services > Starlink PNT, pick the FC link (the FC IP defaults to the
   LAN address with 11 as the third octet, e.g. 10.221.0.21 → 10.221.11.21)
   and press Save & Start — or SSH in and run `starlink-start <FC-IP>`,
   `starlink-start auto` to scan the network, `starlink-start /dev/ttyAMA10
   [baud]` for serial, or bare `starlink-start` to reuse the last saved
   target. Both write the same uci config. The page also has Disable/Enable
   GPS buttons for the FC. The login shell prints a reminder whenever the
   bridge isn't running; `starlink-stop` (or the page's Stop) stops it.
4. **Runtime**: once started, the service waits for the dish, scans for a
   MAVLink FC if in auto mode (cached IP → broadcast → paced subnet sweep on
   UDP 14550), streams `MAV_CMD_EXTERNAL_POSITION_ESTIMATE`, re-discovers if
   the FC goes quiet.
   Field checks: `/root/status.sh` (WAN, ZT; on the `pnt` image the
   `50-starlinkpnt.sh` drop-in adds the dish ping and the bridge section),
   logs in `/root/starlinkpnt/logs/`.

## Installing on a running base device

A live `apk add starlinkpnt` on a running `base` device behaves differently
from an image build: the stock package postinst runs uci-defaults and enables
and starts init scripts, so the first-boot dependency install runs immediately
and the service is started. In an image build the init script is only enabled
(boot start still gated on uci `starlink_mavlink.main.autostart`) and
uci-defaults run at first boot.

## Device-specific config

This is a source buildroot: anything placed under the top-level `files/`
lands in every image (both variants) verbatim — put harvested configs (e.g.
from `sysupgrade -b` on a live router) directly there. PNT files go in this
package (`package/kha/starlinkpnt/files/`), never in the top-level `files/`.
Don't bake a populated ZeroTier `secret` or shared dropbear host keys into
images cloned across devices.
