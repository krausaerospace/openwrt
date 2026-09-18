![OpenWrt logo](include/logo.png)

# KHA field-router image (krausaerospace/openwrt)

This repository is a fork of OpenWrt v25.12.5 that builds the Raspberry Pi 5
(bcm27xx/bcm2712) field-kit router image. Everything below the "OpenWrt
Project" heading is the upstream README, kept unchanged. The full list of
differences from stock OpenWrt is in [IMAGE-CHANGES.md](IMAGE-CHANGES.md).

## Two image variants, one branch

Both variants are built from the same commit on `main`.

| Variant | Contents | Image filenames |
|---|---|---|
| `base` | The router only: WAN/LAN presets, VPNs (ZeroTier, Tailscale, WireGuard, OpenVPN/CloudConnexa, IPsec/strongSwan), LuCI, GStreamer/ffmpeg. No Python and nothing Starlink-related. | `openwrt-base-bcm27xx-bcm2712-rpi-5-*` |
| `pnt` | `base` plus the `starlinkpnt` package: the Starlink-to-MAVLink position bridge, its Python 3 runtime and offline wheels, and the LuCI "Starlink PNT" page. | `openwrt-pnt-bcm27xx-bcm2712-rpi-5-*` |

The only difference between the two is one package. All Starlink PNT content
lives in [package/kha/starlinkpnt](package/kha/starlinkpnt/README.md); the
shared `files/` overlay is copied into every image and holds only
variant-neutral files, so put PNT files in the package, never in `files/`.

## Building

```
git clone https://github.com/krausaerospace/openwrt.git && cd openwrt
./build.sh base        # or: ./build.sh pnt
./build.sh             # reuses the last variant
./build.sh pnt package/starlinkpnt/compile    # extra args go to make
```

On a fresh clone `build.sh` bootstraps the feeds and seeds `.config` from
`config.seed`, plus `config-pnt.seed` for `pnt`. Switching variants needs no
clean: compiled packages stay cached and only the root filesystem and images
are rebuilt, so both variants' images sit side by side in
`bin/targets/bcm27xx/bcm2712/`.

A re-seed replaces `.config`. It happens when there is no `.config`, when the
variant changes, or when a seed file is newer than `.config`. The previous
`.config` is always kept as `tmp/.config.before-reseed.<timestamp>`, and
`build.sh` prints the path. To keep a menuconfig change, fold it into the
seed: `./build.sh base`, `make menuconfig`, then
`./scripts/diffconfig.sh > config.seed`. Never regenerate `config.seed` from a
`pnt` configuration.

## Releases

Tagged images are published on the
[releases page](https://github.com/krausaerospace/openwrt/releases) as
`kha-<YYYY.MM.DD>`. Each release carries both variants:

- `*-squashfs-factory.img.gz` or `*-ext4-factory.img.gz` for a fresh SD card.
- `*-sysupgrade.img.gz` for an existing unit.
- The `.manifest` package list for each variant, and `sha256sums`.

Pick `openwrt-base-...` for a plain router and `openwrt-pnt-...` for a Starlink
PNT kit. A unit can move between variants with a sysupgrade.

## Network defaults

- LAN is 10.221.0.1/16. WAN (DHCP and DHCPv6) is fixed on USB jack 2, and jack 1
  is a free `aux` interface.
- **VPN interfaces join the LAN zone.** ZeroTier (`zt+`), Tailscale
  (`tailscale0`) and CloudConnexa (`tun+`) are added to the LAN firewall zone
  on first boot, so VPN peers get the same access as wired LAN hosts. The
  separate `gcsvpn` zone that older images created is removed.
- SSH keys are pre-provisioned, and `/root/status.sh` is the field check script.

---

# OpenWrt Project

OpenWrt Project is a Linux operating system targeting embedded devices. Instead
of trying to create a single, static firmware, OpenWrt provides a fully
writable filesystem with package management. This frees you from the
application selection and configuration provided by the vendor and allows you
to customize the device through the use of packages to suit any application.
For developers, OpenWrt is the framework to build an application without having
to build a complete firmware around it; for users this means the ability for
full customization, to use the device in ways never envisioned.

Sunshine!

## Download

Built firmware images are available for many architectures and come with a
package selection to be used as WiFi home router. To quickly find a factory
image usable to migrate from a vendor stock firmware to OpenWrt, try the
*Firmware Selector*.

* [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/)

If your device is supported, please follow the **Info** link to see install
instructions or consult the support resources listed below.

## 

An advanced user may require additional or specific package. (Toolchain, SDK, ...) For everything else than simple firmware download, try the wiki download page:

* [OpenWrt Wiki Download](https://openwrt.org/downloads)

## Development

To build your own firmware you need a GNU/Linux, BSD or macOS system (case
sensitive filesystem required). Cygwin is unsupported because of the lack of a
case sensitive file system.

### Requirements

You need the following tools to compile OpenWrt, the package names vary between
distributions. A complete list with distribution specific packages is found in
the [Build System Setup](https://openwrt.org/docs/guide-developer/build-system/install-buildsystem)
documentation.

```
binutils bzip2 diff find flex gawk gcc-6+ getopt grep install libc-dev libz-dev
make4.1+ perl python3.7+ rsync subversion unzip which
```

### Quickstart

1. Run `./scripts/feeds update -a` to obtain all the latest package definitions
   defined in feeds.conf / feeds.conf.default

2. Run `./scripts/feeds install -a` to install symlinks for all obtained
   packages into package/feeds/

3. Run `make menuconfig` to select your preferred configuration for the
   toolchain, target system & firmware packages.

4. Run `make` to build your firmware. This will download all sources, build the
   cross-compile toolchain and then cross-compile the GNU/Linux kernel & all chosen
   applications for your target system.

### Related Repositories

The main repository uses multiple sub-repositories to manage packages of
different categories. All packages are installed via the OpenWrt package
manager called `opkg`. If you're looking to develop the web interface or port
packages to OpenWrt, please find the fitting repository below.

* [LuCI Web Interface](https://github.com/openwrt/luci): Modern and modular
  interface to control the device via a web browser.

* [OpenWrt Packages](https://github.com/openwrt/packages): Community repository
  of ported packages.

* [OpenWrt Routing](https://github.com/openwrt/routing): Packages specifically
  focused on (mesh) routing.

* [OpenWrt Video](https://github.com/openwrt/video): Packages specifically
  focused on display servers and clients (Xorg and Wayland).

## Support Information

For a list of supported devices see the [OpenWrt Hardware Database](https://openwrt.org/supported_devices)

### Documentation

* [Quick Start Guide](https://openwrt.org/docs/guide-quick-start/start)
* [User Guide](https://openwrt.org/docs/guide-user/start)
* [Developer Documentation](https://openwrt.org/docs/guide-developer/start)
* [Technical Reference](https://openwrt.org/docs/techref/start)

### Support Community

* [Forum](https://forum.openwrt.org): For usage, projects, discussions and hardware advise.
* [Support Chat](https://webchat.oftc.net/#openwrt): Channel `#openwrt` on **oftc.net**.

### Developer Community

* [Bug Reports](https://bugs.openwrt.org): Report bugs in OpenWrt
* [Dev Mailing List](https://lists.openwrt.org/mailman/listinfo/openwrt-devel): Send patches
* [Dev Chat](https://webchat.oftc.net/#openwrt-devel): Channel `#openwrt-devel` on **oftc.net**.

## License

OpenWrt is licensed under GPL-2.0
