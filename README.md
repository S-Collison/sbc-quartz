# sbc-quartz

Talos Linux overlay for the Pine64 RK3566 family.

| overlay name       | board                                   | DTB                          |
|--------------------|-----------------------------------------|------------------------------|
| `quartz64-a`       | Quartz64 Model A                        | `rk3566-quartz64-a.dtb`      |
| `quartz64-b`       | Quartz64 Model B                        | `rk3566-quartz64-b.dtb`      |
| `soquartz-blade`   | SOQuartz on the Pine64 Blade baseboard  | `rk3566-soquartz-blade.dtb`  |
| `soquartz-model-a` | SOQuartz on the Pine64 Model-A baseboard| `rk3566-soquartz-model-a.dtb`|
| `soquartz-cm4`     | SOQuartz on a CM4-IO style carrier      | `rk3566-soquartz-cm4.dtb`    |

Each board gets its own U-Boot (`<board>-rk3566_defconfig`, mainline TF-A BL31 +
rkbin rk3566 DDR blob) and its own installer binary.

## Build

```sh
docker buildx create --name local --use            # once
echo "$GITHUB_TOKEN" | docker login ghcr.io -u s-collison --password-stdin

# 1. overlay image (linux/amd64 + linux/arm64) -> ghcr.io/s-collison/sbc-quartz:<git tag>
make sbc-quartz PUSH=true
#    The ghcr package must be public (or the imager can't pull it).

# 2. bootable image for one board (always --arch arm64, verified before it's returned)
hack/build-image.sh quartz64-a            # optional 2nd arg: Talos version, default v1.14.5
hack/build-image.sh soquartz-blade
```

Output: `_out/talos-<version>-<board>.raw.xz`.

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
