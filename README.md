# sbc-quartz

Talos Linux overlay for the Pine64 RK3566 family.

| overlay name       | board                                   | DTB                          |
|--------------------|-----------------------------------------|------------------------------|
| `quartz64-a`       | Quartz64 Model A                        | `rk3566-quartz64-a.dtb`      |
| `quartz64-b`       | Quartz64 Model B                        | `rk3566-quartz64-b.dtb`      |
| `soquartz-blade`   | SOQuartz on the Pine64 Blade baseboard  | `rk3566-soquartz-blade.dtb`  |
| `soquartz-model-a` | SOQuartz on the Pine64 Model-A baseboard| `rk3566-soquartz-model-a.dtb`|
| `soquartz-cm4`     | SOQuartz on a CM4-IO style carrier      | `rk3566-soquartz-cm4.dtb`    |

SOQuartz is one module with many possible baseboards. Each overlay name pairs a
U-Boot defconfig with a kernel DTB. The pairs are listed once, in `Pkgfile`
(`vars.boards`). Third-party CM4 carriers can reuse the `soquartz-cm4` pair
under their own name; see [docs/adding-a-baseboard.md](docs/adding-a-baseboard.md).

One overlay image (`ghcr.io/s-collison/sbc-quartz`) covers every board. The
separate `sbc-soquartz` folder isn't needed.

## Build

```sh
docker buildx create --name local --use            # once
echo "$GITHUB_TOKEN" | docker login ghcr.io -u s-collison --password-stdin

# 1. overlay image (linux/amd64 + linux/arm64) -> ghcr.io/s-collison/sbc-quartz:<git tag>
make sbc-quartz PUSH=true
#    The ghcr package must be public (or the imager can't pull it).

# 2. bootable image for one board (always --arch arm64, verified before it's returned)
hack/build-image.sh                       # quartz64-a, soquartz-blade, soquartz-model-a
hack/build-image.sh soquartz-cm4          # or name any boards
TALOS_VERSION=v1.14.5 hack/build-image.sh quartz64-a
```

Output: `_out/talos-<version>-<board>.raw.xz`.

## CI releases

`.github/workflows/images.yaml` builds images and upgrade installers for
quartz64-a, soquartz-blade and soquartz-model-a for the latest Talos release.
It runs weekly, on `v*` tags, or by hand, and publishes them as a GitHub Release.
Cluster setup, DRBD/LINSTOR on the M.2 SSD and upgrades are covered in
[docs/cluster-ops.md](docs/cluster-ops.md).

## Flash and first boot

```sh
diskutil list                               # find the SD card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
xz -dc _out/talos-v1.14.5-quartz64-a.raw.xz | sudo dd of=/dev/rdisk4 bs=4m
```

* The RK3566 boot ROM tries SPI -> eMMC -> SD. **Remove the eMMC module (or wipe
  its first 16 MiB) when booting from SD**, or an old bootloader on eMMC wins.
* Watch the UART2 debug header at **1500000 8N1** (3.3 V). U-Boot does not drive
  HDMI on RK3566, so a black HDMI screen during boot is expected; the node will
  show up on DHCP and answer `talosctl -n <ip> get links --insecure` in
  maintenance mode.

## Install to disk / upgrade

Use an installer image built with the same overlay:

```sh
docker run --rm -t -v $PWD/_out:/out ghcr.io/siderolabs/imager:v1.14.5 installer \
  --arch arm64 --overlay-image ghcr.io/s-collison/sbc-quartz:<tag> --overlay-name quartz64-a
```

then push `_out/installer-arm64.tar` to a registry and reference it in
`machine.install.image` / `talosctl upgrade --image`.
