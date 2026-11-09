# Provisioning (holzkube-manager) and upgrades (tuppr)

## 1. Get a node into maintenance mode: flash the image

```sh
xz -dc talos-v1.14.5-soquartz-blade.raw.xz | sudo dd of=/dev/rdiskN bs=4m   # SD, or eMMC via USB adapter
```

Boot it. With no config, Talos sits in **maintenance mode**: Talos API on :50000,
insecure, waiting for a config. That's the state holzkube-manager's provisioning
wizard looks for. It's the same as an ISO or PXE boot, so no PXE is needed.

The disk you flashed **is** the install. `machine.install.disk` must point at that
same disk so Talos doesn't reinstall. A fresh install from inside Talos (install mode)
would pick systemd-boot under U-Boot's UEFI, while these images use GRUB.

| node | image | role |
|---|---|---|
| Raspberry Pi 5 | Image Factory, official `rpi5` overlay (`sbc-raspberrypi`) | control plane / API |
| Quartz64 A | `talos-<ver>-quartz64-a.raw.xz` (this repo) | worker |
| SOQuartz + Blade | `talos-<ver>-soquartz-blade.raw.xz` | worker |
| SOQuartz + Model-A | `talos-<ver>-soquartz-model-a.raw.xz` | worker |

## 2. Assign configs with holzkube-manager

holzkube-manager provisions any maintenance-mode node: it checks the certificate
fingerprint, then writes the config. For each Quartz/SOQuartz node, include these
patches. They're in `talos/patches/`; paste them in holzkube's config patch / diff view,
or keep them on its machine class:

- `install-<board>.yaml`: **required**. Sets `machine.install.image` to the board's
  installer `ghcr.io/s-collison/talos-installer-<board>:<talos>`. Talos 1.14 fills an unset
  install image with the Image Factory's empty schematic, and upgrading to that would
  drop this overlay (U-Boot and DTB updates).
- `drbd.yaml`: loads DRBD for Piraeus/LINSTOR on the M.2 SSD.
- `tuppr.yaml`: lets tuppr call the Talos API from `system-upgrade`.
- Set `machine.install.disk` to the disk you flashed (`/dev/mmcblk0` or `/dev/mmcblk1`; check
  with `talosctl get disks --insecure -n <ip>`).

Control plane: the **Pi 5** (16 GB) is the API server and also runs Plex (direct
play), Blu-ray ripping and NFS. Apply the controlplane config with
`talos/patches/rpi5-controlplane.yaml` **on first apply**: it moves EPHEMERAL (etcd,
images, logs) off the microSD onto the SSD, makes the rest of the SSD a `media` user
volume (`/var/mnt/media`), allows workloads on the control plane, and reserves
CPU/RAM for etcd and the API server. Then bootstrap etcd there
(`talosctl bootstrap -n 10.20.0.10`). Every other node gets worker configs. The Pi
Zero stays outside the cluster (holzkube, etcd backup copies).

## 3. Upgrades: tuppr (not holzkube)

- **holzkube-manager's upgrades** always resolve the installer through an Image
  Factory (`IMAGE_FACTORY_URL`, from the node's schematic). The Factory only offers
  Sidero's signed overlays, so for these boards it would install an image without our
  U-Boot/DTB. **Don't upgrade Quartz/SOQuartz nodes from holzkube.** It's fine for the Pi 5,
  which is a Factory `rpi5` image.
- **tuppr** reads each node's own `machine.install.image` (or the 1.14
  `UnattendedInstallConfig`). For a non-Factory repository it upgrades to
  `<that repository>:<target version>`, which is exactly how CI tags the board installers.
  For the Pi 5's Factory image it keeps the schematic and swaps the version. So one
  `TalosUpgrade` handles the whole cluster:

  ```yaml
  apiVersion: tuppr.home-operations.com/v1alpha1
  kind: TalosUpgrade
  metadata: { name: talos }
  spec:
    talos: { version: v1.14.6 }    # bump only after the images workflow has published v1.14.6 installers
  ```

  Install: `helm install tuppr oci://ghcr.io/home-operations/charts/tuppr -n system-upgrade --create-namespace`.
  It drains, upgrades and health-checks one node at a time.
- **By hand:** `talosctl -n <ip> upgrade --image ghcr.io/s-collison/talos-installer-<board>:<ver>`.

Upgrade mode keeps the boot loader that's on disk (GRUB), and the overlay's installer
hook rewrites U-Boot and the DTB, so **U-Boot updates ride along with Talos upgrades**.

## Order of operations for a new Talos release

1. CI (`images.yaml`, weekly or manual) publishes `talos-installer-<board>:<new>` and the release images.
2. Bump `TalosUpgrade.spec.talos.version`. tuppr rolls the cluster.
