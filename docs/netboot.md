# Network boot

Network boot is optional. A flashed image is the simpler way to install.

U-Boot tries local disks first and then PXE, so a board with Talos on its eMMC or SD never reaches the network.
The boot files are only built when the `images` workflow is run by hand with `netboot` enabled, which produces
`netboot-<version>-<image>.tar.gz`.

## Server

Serve the archive over TFTP from the machine that answers DHCP:

```bash
sudo mkdir -p /srv/tftp
sudo tar -xzf netboot-<version>-stock.tar.gz -C /srv/tftp
```

With dnsmasq:

```ini
enable-tftp
tftp-root=/srv/tftp
```

Do not set `dhcp-boot`. U-Boot would fetch and start that file through EFI, and Talos would then install
systemd-boot in place of GRUB.

`pxelinux.cfg/default` serves every board: U-Boot picks the device tree that matches the board it runs on. Add
`pxelinux.cfg/01-<mac-with-dashes>` to give one board a different image.

## Board

The board needs U-Boot on its boot disk. Write it to blank media from `u-boot/<board>/` in the archive:

```bash
sudo dd if=u-boot-rockchip.bin of=/dev/sdX bs=512 seek=64 conv=notrunc
```

Power it on and it starts Talos in maintenance mode. Configure it as described in the [README](../README.md).
