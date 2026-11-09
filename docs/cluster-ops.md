# Running the cluster: install, storage, upgrades

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

## First install

1. Flash the release image for the board to SD (see README) and boot it. The node
   comes up in maintenance mode.
2. Generate the config with the board's patches:

   ```sh
   talosctl gen config homelab https://<vip-or-cp-ip>:6443 \
     --config-patch @talos/patches/drbd.yaml \
     --config-patch @talos/patches/tuppr.yaml
   talosctl apply-config --insecure -n <ip> -f controlplane.yaml \
     --config-patch @talos/patches/install-soquartz-blade.yaml
   ```

   `machine.install.image` must be **the board's own installer**. The stock
   `ghcr.io/siderolabs/installer` and Image Factory installers don't contain
   this overlay.

3. Choose the install disk: eMMC or SD. The RK3566 boot ROM cannot boot from
   NVMe, so keep the OS on eMMC/SD and give the M.2 SSD to storage.

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
