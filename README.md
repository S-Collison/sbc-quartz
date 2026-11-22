# sbc-quartz

Talos Linux for Pine64 Quartz64 and SOQuartz boards (Rockchip RK3566).

This repository builds the Talos overlay for these boards and publishes disk images and upgrade installers for
each Talos release. It is a community project, not affiliated with Sidero Labs, and its overlay is not available
from the Image Factory.

## Supported boards

| Overlay name       | Board                                   | Published images |
| ------------------ | --------------------------------------- | ---------------- |
| `quartz64-a`       | Quartz64 Model A                        | yes              |
| `quartz64-b`       | Quartz64 Model B                        | build it yourself |
| `soquartz-blade`   | SOQuartz on the Pine64 Blade            | yes              |
| `soquartz-model-a` | SOQuartz on the Pine64 Model-A          | yes              |
| `soquartz-cm4`     | SOQuartz on a CM4-IO style carrier      | build it yourself |

For another carrier, see [Adding a board](docs/adding-a-board.md).

Each release has two images per board:

* `talos-<version>-<board>.raw.xz`, the standard image.
* `talos-<version>-<board>-media.raw.xz`, which adds [hardware video decoding](docs/hardware-video.md).

## Installing

You need [`talosctl`](https://docs.siderolabs.com/talos/v1.14/getting-started/talosctl) and an SD card or an eMMC
module with a USB adapter.

### Download the image

```bash
VERSION=v1.14.6
IMAGE=talos-${VERSION}-soquartz-blade.raw.xz
curl -LO https://github.com/S-Collison/sbc-quartz/releases/download/${VERSION}/${IMAGE}
curl -LO https://github.com/S-Collison/sbc-quartz/releases/download/${VERSION}/${IMAGE}.sha256
sha256sum -c ${IMAGE}.sha256
```

### Write the image

Write it to the disk the board boots from. Everything on that disk is lost.

```bash
xz -dc ${IMAGE} | sudo dd of=/dev/sdX bs=4M conv=fsync
```

On macOS, use `shasum -a 256 -c`, `/dev/rdiskN` and `bs=4m`.

The boot ROM tries SPI, eMMC and then SD. If you boot from SD, remove the eMMC module or make sure it has no
bootloader on it. The board cannot boot from NVMe.

### Boot the board

The board gets an address from DHCP and waits in maintenance mode:

```bash
talosctl get disks --insecure --nodes <ip>
```

The screen stays black while it boots. The serial console is UART2 at 1500000 8N1, 3.3 V.

### Configure the node

Use the installer built for your board. The standard Talos installers lack the Ethernet driver, and a node
upgraded with one loses its network. Save this as `install.yaml`:

```yaml
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/s-collison/talos-installer-soquartz-blade:v1.14.6
provisioning:
  diskSelector:
    match: disk.transport == "mmc" && disk.size > 10u * GB
```

For the media image, the installer is `talos-installer-soquartz-blade-media`. Generate and apply the machine
configuration as usual:

```bash
talosctl gen config <cluster-name> https://<endpoint>:6443 --config-patch @install.yaml
talosctl apply-config --insecure --nodes <ip> --file controlplane.yaml
```

Continue with [Getting Started](https://docs.siderolabs.com/talos/v1.14/getting-started/getting-started) in the
Talos documentation.

## Upgrading

```bash
talosctl upgrade --nodes <ip> --image ghcr.io/s-collison/talos-installer-soquartz-blade:<version>
```

This also updates U-Boot and the device tree. Do not use an Image Factory installer, or a tool that selects one.

## Differences from upstream Talos

* The kernel includes the Motorcomm YT8511 Ethernet driver.
* Kernel module signatures are not enforced (`module.sig_enforce=0`), so that extensions signed by Sidero Labs load.
* The console dashboard is disabled (`talos.dashboard.disabled=1`).

Wi-Fi and Bluetooth are not available, as in upstream Talos.

## Known issues

* **Quartz64 Model A, gigabit Ethernet.** On some boards the default transmit timing corrupts frames, which shows
  up as CRC errors on the switch port. Set the port to 100 Mbps and please report it.

## Building

```bash
make sbc-quartz PUSH=true              # overlay image
hack/build-image.sh soquartz-blade     # disk image, in _out/
```

Component versions are in [`Pkgfile`](Pkgfile) and the [`Makefile`](Makefile). Both commands need Docker with
buildx, and the first a login to the registry.

Releases are tagged with the Talos version. A fix to this repository rebuilds the current release under the same
tag. To build a pre-release or an older version, run the `images` workflow by hand.

## License

[Mozilla Public License 2.0](LICENSE)
