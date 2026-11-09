# Running the cluster: install, storage, upgrades

## Planned topology (routed at the switch)

```
 Internet ── UniFi Express 7 ── LAN 192.168.1.0/24 (Wi-Fi mesh, onsite hardware)
                  │  uplink port: access port in the LAN only (cluster VLAN NOT trunked to the Express/mesh)
                  │
   USW-Enterprise-8-PoE (Layer 3)   LAN IP 192.168.1.2
        SVI 10.20.0.1/24  = cluster VLAN 20 (lives only on this switch)
        ├─ Raspberry Pi 5 16GB   10.20.0.10  control plane / API (rpi5 overlay)
        ├─ Quartz64 A            10.20.0.21  worker
        ├─ SOQuartz + Blade      10.20.0.22  worker
        ├─ SOQuartz + Model-A    10.20.0.23  worker
        └─ (optional) cameras / onsite gear in their own VLAN, also routed here
   Service VIPs (MetalLB/Cilium L2): 10.20.0.200-250
```

- In UniFi Network, create the cluster network with the **Enterprise 8 as its router**
  (a Layer 3 network on the switch). The switch does inter-VLAN routing at line rate.
  UniFi gives the Express 7 the return route, and NAT for internet access.
- Cluster broadcast and multicast (ARP, L2 VIP announcements, mDNS) stay on the
  switch. Only routed unicast to and from the LAN, and internet traffic, crosses the uplink.
- Onsite hardware on the LAN reaches the API (`10.20.0.10:6443`, `:50000`) and
  service VIPs through the switch. Restrict it with switch ACLs / UniFi firewall zones if needed.
- Routing doesn't carry **mDNS/SSDP discovery** (HomeKit, Chromecast, some cameras).
  Turn on UniFi's mDNS reflector for the two networks, or put that gear on the cluster VLAN.
- Outside access: on the Express 7, forward 443 to the ingress VIP (10.20.0.200), or use
  Cloudflare Tunnel (no open ports). TLS via cert-manager; OIDC via Pocket ID / Authelia / Authentik.
- Talos has no in-kernel NFS server (`nfsd`). For NFS from the Pi, run NFS-Ganesha in a pod pinned to the Pi.

## What CI publishes

`.github/workflows/images.yaml` runs on a tag, weekly, or by hand. It:

1. finds the latest Talos release (or the version you give it) and the kernel
   build it uses (`PKGS` in that release's Makefile), so the DTBs match the
   kernel that actually boots;
2. builds the overlay `ghcr.io/s-collison/sbc-quartz:<repo-tag>-<talos>`
   (linux/arm64 + amd64) on a native arm64 runner;
3. for `quartz64-a`, `soquartz-blade` and `soquartz-model-a`:
   - builds and verifies `talos-<talos>-<board>.raw.xz` with the `drbd` extension;
   - pushes the upgrade installer `ghcr.io/s-collison/talos-installer-<board>:<talos>`;
4. creates a GitHub Release `talos-<talos>-<repo-tag>` with the images and their checksums.

The weekly run skips a version that already has a release, so a new Talos
patch release gets built on the following Monday.

Add or remove boards in the `matrix.board` list. Add extensions in `env.EXTENSIONS`,
using official extension names such as `drbd` or `iscsi-tools`. The script pins
them to the digests published for that Talos version.

## First install (simplest bare-metal path)

**Write the release image straight onto the disk the board will boot from**,
then apply config. Don't boot the SD card and let Talos "install" to eMMC:
in install mode, Talos 1.14 auto-selects systemd-boot whenever U-Boot's UEFI
is present. These images deliberately use GRUB, which is what Sidero ships
for Rockchip boards. Upgrades keep whatever boot loader is already on the disk.

| board | boot disk | how to write it |
|---|---|---|
| Quartz64 A | eMMC module (recommended) or SD | eMMC: Pine64 USB eMMC adapter, then `dd` from the Mac |
| SOQuartz (Blade / Model-A) | eMMC on the module, or the baseboard SD | eMMC: rpiboot-style USB mass storage isn't available, so flash SD, or use a Pine64 eMMC module + adapter |

1. `xz -dc talos-<ver>-<board>.raw.xz | sudo dd of=/dev/rdiskN bs=4m` onto that disk, insert, power on.
   The node comes up in maintenance mode and gets a DHCP address.
2. Generate and apply the config. `install.disk` is the disk you just wrote, so
   Talos sees it's already installed and doesn't reinstall:

   ```sh
   talosctl gen config homelab https://<cp-ip>:6443 \
     --config-patch @talos/patches/drbd.yaml \
     --config-patch @talos/patches/tuppr.yaml
   talosctl apply-config --insecure -n <ip> -f worker.yaml \
     --config-patch @talos/patches/install-soquartz-blade.yaml
   ```

   `machine.install.image` must be **the board's own installer**. The stock
   `ghcr.io/siderolabs/installer` and Image Factory installers don't contain
   this overlay.
3. The RK3566 boot ROM can't boot NVMe directly. Keep Talos on eMMC/SD and give the M.2 SSD to storage.

## Network boot (later)

- The boot ROM can't do PXE. U-Boot can (Ethernet is enabled in all five
  defconfigs), but U-Boot has to come from SPI, eMMC or SD first.
- **Quartz64 A**: U-Boot builds `u-boot-rockchip-spi.bin`, shipped in the overlay
  under `artifacts/arm64/u-boot/quartz64-a/`. With it on the SPI flash, the board
  could boot entirely from the network.
- **SOQuartz**: no SPI flash in U-Boot, so U-Boot stays on eMMC/SD. Netbooting only
  saves you reflashing the OS, not the boot loader.
- A PXE install still has to finish by writing to the boot disk with the board
  installer, and it hits the same GRUB vs systemd-boot install-mode issue above.
  That's why direct flashing is the recommended path for now.

## M.2 SSD with DRBD / LINSTOR (Piraeus)

The images already contain the `drbd` extension and `drbd.yaml` loads it.

1. Leave the NVMe disk out of Talos volumes (no `UserVolumeConfig` on it), so LINSTOR can take it.
2. Install the operator:

   ```sh
   helm upgrade --install piraeus-op oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus \
     -n piraeus-datastore --create-namespace
   ```

3. Apply the Talos module-loader override from the Piraeus "Talos" guide
   (`LinstorSatelliteConfiguration` that removes the `drbd-module-loader` init
   container). Then create a `LinstorCluster` and a storage pool on `/dev/nvme0n1`.
4. Check: `talosctl -n <ip> read /proc/modules | grep drbd`.

## Upgrades

Manual:

```sh
talosctl -n <ip> upgrade --image ghcr.io/s-collison/talos-installer-soquartz-blade:v1.14.6
```

Automatic, GitOps-style, the nearest thing to the old CoreOS update agent (Omaha/Nebraska):

- install tuppr: `helm install tuppr oci://ghcr.io/home-operations/charts/tuppr -n system-upgrade --create-namespace`
- apply `talos/patches/tuppr.yaml` to every node
- apply `talos/tuppr/upgrades.yaml`, then bump `spec.talos.version` once CI has
  published installers for that version. Renovate can open that PR for you.

Each board's installer image differs only by repository, and its tag is the
Talos version. Check how your tuppr release chooses the image (keep each node's
`machine.install.image` repository and change the tag, or set it per node
group). Never let it fall back to the stock installer: that drops this overlay.

## Fleet managers / GUIs (free options)

| tool | cost / license | GUI | works with these boards? |
|---|---|---|---|
| **tuppr** | free, AGPL-3.0 | no (kubectl/GitOps) | yes; upgrades are driven by version, which our installer tags support |
| **holzkube-manager** | free, AGPL-3.0, alpha (0.8) | yes, web + mobile | runs outside the cluster on any arm64 box; talks to the Talos API. Custom installer images aren't documented, so test upgrades on one node |
| **Omni (self-hosted)** | free for home lab / non-production under BSL; hosted Hobby is paid | yes | builds images and installers through Image Factory, which doesn't have this overlay, so its upgrades would fight these boards |
| Kamaji | free | no | runs hosted control planes; not an OS fleet or upgrade manager |
| Headlamp | free | yes | Kubernetes GUI only (workloads), no Talos upgrades |

Suggested setup for a small, zero-cost cluster: tuppr for upgrades, CI for
images, and optionally holzkube-manager on a spare board for a dashboard.
