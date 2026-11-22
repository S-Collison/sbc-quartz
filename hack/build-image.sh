#!/usr/bin/env bash
# Build bootable Talos images, upgrade installers and netboot (PXE) assets for
# Pine64 RK3566 boards, and verify them.
#
#   hack/build-image.sh [board ...]          # default: quartz64-a soquartz-blade soquartz-model-a
#
# Env:
#   TALOS_VERSION         Talos version (default: from the newest vX.Y.Z git tag)
#   FLAVOR                stock | media (default stock). "media" = custom kernel with Hantro/RGA;
#                         needs the images from .github/workflows/kernel.yaml
#   OVERLAY_IMAGE         overlay from this repo (default ghcr.io/s-collison/sbc-quartz:$(git describe))
#   IMAGER_IMAGE          default: ghcr.io/siderolabs/imager:$TALOS_VERSION (stock),
#                         ghcr.io/s-collison/talos-media/imager:$TALOS_VERSION (media)
#   BASE_INSTALLER_IMAGE  default: unset (stock), ghcr.io/s-collison/talos-media/installer-base:$TALOS_VERSION (media)
#   EXTENSIONS            official extensions to include, e.g. "drbd iscsi-tools" (default: none)
#   EXTENSION_IMAGES      other extension images to include
#   INSTALLER_REPO        also push ${INSTALLER_REPO}-<board>[-media]:${TALOS_VERSION}
#   FACTORY_REPO          also push ${FACTORY_REPO}/metal-installer/<schematic>:${TALOS_VERSION}, the same installer plus
#                         a marker with its schematic ID, named the way an Image Factory names it (topf, tuppr)
#   NETBOOT=1             also build the TFTP tree _out/netboot-<flavor>/ (+ .tar.gz) for U-Boot PXE
#   DOCKER_CONFIG         registry credentials dir passed to imager/crane (default ~/.docker)
#
# Disk images use the board's overlay profile (GRUB). Plain "metal" would pick
# systemd-boot on arm64, and so would an EFI netboot. The netboot tree therefore
# serves the *raw* kernel Image for U-Boot booti (no EFI), so a PXE install
# also writes GRUB.
set -euo pipefail

if [ -z "${TALOS_VERSION:-}" ]; then
  t="$(git -C "$(dirname "$0")" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  TALOS_VERSION="${t%-r[0-9]*}"
  [ -n "${TALOS_VERSION}" ] || { echo "set TALOS_VERSION (no vX.Y.Z tag found)" >&2; exit 2; }
fi
FLAVOR="${FLAVOR:-stock}"
TAG="$(git describe --tag --always --dirty --match 'v[0-9]*')"
OVERLAY_IMAGE="${OVERLAY_IMAGE:-ghcr.io/s-collison/sbc-quartz:${TAG}}"
EXTENSIONS="${EXTENSIONS:-}"
EXTENSION_IMAGES="${EXTENSION_IMAGES:-}"
INSTALLER_REPO="${INSTALLER_REPO:-}"
FACTORY_REPO="${FACTORY_REPO:-}"
NETBOOT="${NETBOOT:-0}"
# MODULE_SIG_ENFORCE=0: our own kernel does not trust the key Sidero signs extensions with, so Talos's
# module.sig_enforce=1 has to go. The disk image takes it as kernel arguments; the installer rebuilds the
# cmdline from the overlay's arguments on every upgrade, so there it is an overlay option.
MODULE_SIG_ENFORCE="${MODULE_SIG_ENFORCE:-1}"
KARGS=()
OVERLAY_OPTS=()
if [ "${MODULE_SIG_ENFORCE}" = 0 ]; then
  KARGS=(--extra-kernel-arg=-module.sig_enforce --extra-kernel-arg=module.sig_enforce=0)
  OVERLAY_OPTS=(--overlay-option=moduleSigEnforce=0)
fi
OUT="${PWD}/_out"
CRANE="gcr.io/go-containerregistry/crane:latest"

case "${FLAVOR}" in
  stock)
    IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/siderolabs/imager:${TALOS_VERSION}}"
    BASE_INSTALLER_IMAGE="${BASE_INSTALLER_IMAGE:-}"
    SUFFIX="" ;;
  media)
    IMAGER_IMAGE="${IMAGER_IMAGE:-ghcr.io/s-collison/talos-media/imager:${TALOS_VERSION}}"
    BASE_INSTALLER_IMAGE="${BASE_INSTALLER_IMAGE:-ghcr.io/s-collison/talos-media/installer-base:${TALOS_VERSION}}"
    SUFFIX="-media" ;;
  *) echo "FLAVOR must be stock or media" >&2; exit 1 ;;
esac

# Registry creds into containers only when stored in the file (CI). Docker
# Desktop's osxkeychain store can't be read from a container.
DOCKER_ARGS=()
CFG="${DOCKER_CONFIG:-${HOME}/.docker}"
if [ -f "${CFG}/config.json" ] && ! grep -q '"credsStore"' "${CFG}/config.json"; then
  DOCKER_ARGS+=(-v "${CFG}:/docker-config:ro" -e DOCKER_CONFIG=/docker-config)
fi

TABLE="$(awk '/^  boards:/{f=1;next} f&&/^    [a-z0-9-]+:/{print $1;next} f{exit}' Pkgfile)"
[ -n "${TABLE}" ] || { echo "could not read boards from Pkgfile" >&2; exit 1; }
if [ "$#" -eq 0 ]; then set -- quartz64-a soquartz-blade soquartz-model-a; fi

EXT_ARGS=()
if [ -n "${EXTENSIONS}" ]; then
  DIGESTS="$(docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} "${CRANE}" export "ghcr.io/siderolabs/extensions:${TALOS_VERSION}" - | tar x -O image-digests)"
  for e in ${EXTENSIONS}; do
    ref="$(printf '%s\n' "${DIGESTS}" | grep -E "^ghcr.io/siderolabs/${e}:" | head -n1 || true)"
    [ -n "${ref}" ] || { echo "extension ${e} not found for Talos ${TALOS_VERSION}" >&2; exit 1; }
    EXT_ARGS+=(--system-extension-image "${ref}")
  done
fi
for ref in ${EXTENSION_IMAGES}; do EXT_ARGS+=(--system-extension-image "${ref}"); done
[ -z "${BASE_INSTALLER_IMAGE}" ] || EXT_ARGS+=(--base-installer-image "${BASE_INSTALLER_IMAGE}")
for a in ${EXT_ARGS[@]+"${EXT_ARGS[@]}"}; do case "$a" in --*) ;; *) echo ">> input ${a}";; esac; done

# The schematic in Image Factory form; its sha256 is the schematic ID. The overlay tag is left out, so the ID
# stays the same across Talos versions and overlay builds and changes only with board, flavor or extensions.
schematic_yaml() { # BOARD
  printf 'overlay:\n    image: s-collison/sbc-quartz\n    name: %s\n    options:\n        flavor: %s\n' "$1" "${FLAVOR}"
  if [ -z "${EXTENSIONS}${EXTENSION_IMAGES}" ]; then printf 'customization: {}\n'; return; fi
  printf 'customization:\n    systemExtensions:\n        officialExtensions:\n'
  local e
  for e in ${EXTENSIONS}; do printf '            - siderolabs/%s\n' "${e}"; done | sort
  for e in ${EXTENSION_IMAGES}; do printf '            - %s\n' "${e%[:@]*}"; done | sort
}

# The marker extension an Image Factory adds: Talos reports its version as the node's schematic ID.
schematic_layer() { # BOARD ID OUT.tar
  schematic_yaml "$1" | python3 -I -c '
import io, json, sys, tarfile
sid, out = sys.argv[1:]
info = sys.stdin.read()
m = json.dumps({"version": "v1alpha1", "metadata": {
    "name": "schematic", "version": sid, "author": "sbc-quartz (https://ghcr.io/s-collison)",
    "description": "Schematic this image was built from.", "extra_info": info,
    "compatibility": {"talos": {"version": ">= 1.0.0"}}}}).encode()
with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    def add(name, data=None):
        i = tarfile.TarInfo(name)
        if data is None: i.type, i.mode = tarfile.DIRTYPE, 0o755
        else: i.size, i.mode = len(data), 0o644
        t.addfile(i, io.BytesIO(data or b""))
    add("manifest.yaml", m)
    d = "rootfs"
    for part in ("", "usr", "local", "share", "schematic"):
        d = d + "/" + part if part else d
        add(d)
    add(d + "/" + sid, b"")
' "$2" "$3"
}

# imager <outdir> <args...>
imager() {
  local out="$1"; shift
  mkdir -p "${out}"
  docker run --rm -t ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
    -v "${out}:/out" -v /dev:/dev --privileged \
    "${IMAGER_IMAGE}" "$@"
}

entry_for() { printf '%s\n' "${TABLE}" | grep "^$1:" || true; }

push_factory() {
  ID="$(schematic_yaml "${BOARD}" | sha256sum | cut -d' ' -f1)"
  REF="${FACTORY_REPO}/metal-installer/${ID}:${TALOS_VERSION}"
  MARK="${FACTORY_REPO}/schematic-marker:${ID}"
  echo ">> installer ${REF}"
  schematic_yaml "${BOARD}"
  rm -rf "${WORK}"; mkdir -p "${WORK}"
  schematic_layer "${BOARD}" "${ID}" "${WORK}/marker.tar" || return 1
  crane() { docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} -v "${WORK}:/out" "${CRANE}" "$@"; }
  crane append --new_layer /out/marker.tar --new_tag "${MARK}" || return 1
  crane mutate "${MARK}" --set-platform linux/arm64 --tag "${MARK}" || return 1
  imager "${WORK}" installer --arch arm64 ${OVERLAY_OPTS[@]+"${OVERLAY_OPTS[@]}"} \
    --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
    ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} --system-extension-image "${MARK}" || return 1
  crane push /out/installer-arm64.tar "${REF}" || return 1
  echo "${REF}" >> "${OUT}/installer-refs.txt"
}

build_one() {
BOARD="$1"
ENTRY="$(entry_for "${BOARD}")"
[ -n "${ENTRY}" ] || { echo "unknown board ${BOARD}; known: $(printf '%s\n' "${TABLE}" | cut -d: -f1 | tr '\n' ' ')" >&2; return 1; }
DTB="${ENTRY##*:}"
WORK="${OUT}/.work-${BOARD}"; rm -rf "${WORK}"

echo ">> [${FLAVOR}] imager ${IMAGER_IMAGE}  overlay ${OVERLAY_IMAGE}  board ${BOARD}"
imager "${WORK}" "${BOARD}" --arch arm64 ${KARGS[@]+"${KARGS[@]}"} \
  --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
  ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} || return 1

IMG="${OUT}/talos-${TALOS_VERSION}-${BOARD}${SUFFIX}.raw.xz"
NEW="$(ls "${WORK}"/*.raw.xz 2>/dev/null | head -n1)"
[ -n "${NEW}" ] || { echo "imager produced no .raw.xz" >&2; return 1; }
mv "${NEW}" "${IMG}" || return 1

echo ">> verifying ${IMG}"
TMP="$(mktemp)"
xz -dc "${IMG}" | head -c 300000000 > "${TMP}" || true   # first ~300MB covers u-boot + ESP
fail=0
if [ "$(dd if="${TMP}" bs=512 skip=64 count=1 2>/dev/null | head -c 4)" = "RKNS" ]; then
  echo "   ok  Rockchip idbloader at sector 64"
else
  echo "   BAD no idbloader at sector 64 (u-boot not written)"; fail=1
fi
if LC_ALL=C grep -aq 'BOOTAA64EFI' "${TMP}"; then
  echo "   ok  BOOTAA64.EFI present (arm64 EFI loader)"
else
  echo "   BAD no BOOTAA64.EFI — not an arm64 image"; fail=1
fi
if LC_ALL=C grep -aq 'LOADER     ' "${TMP}"; then
  echo "   BAD systemd-boot loader/ on ESP — built with the generic profile, expected GRUB"; fail=1
else
  echo "   ok  GRUB layout (no systemd-boot loader/ dir)"
fi
if LC_ALL=C grep -aq 'BOOTX64 EFI' "${TMP}"; then
  echo "   BAD BOOTX64.EFI present — this is an amd64 image"; fail=1
fi
if LC_ALL=C grep -aq "fdtfile=rockchip/${DTB}" "${TMP}"; then
  echo "   ok  U-Boot fdtfile matches ${BOARD}"
else
  echo "   BAD U-Boot fdtfile does not match ${BOARD}"; fail=1
fi
# YT8511 boards: the PHY id compatible must be in both device trees Linux can be given,
# U-Boot's built-in one (first 10 MiB) and the DTB on the boot partition (after it).
case "${DTB}" in rk3566-quartz64-a.dtb|rk3566-soquartz-*.dtb)
  dd if="${TMP}" of="${TMP}.ub" bs=1M count=10 2>/dev/null
  dd if="${TMP}" of="${TMP}.rest" bs=1M skip=10 2>/dev/null
  if LC_ALL=C grep -aq 'ethernet-phy-id0000.010a' "${TMP}.ub"; then
    echo "   ok  YT8511 PHY compatible in U-Boot's device tree"
  else
    echo "   BAD U-Boot's device tree lacks the YT8511 PHY compatible (Linux would bind Generic PHY)"; fail=1
  fi
  if LC_ALL=C grep -aq 'ethernet-phy-id0000.010a' "${TMP}.rest"; then
    echo "   ok  YT8511 PHY compatible in the boot partition DTB"
  else
    echo "   BAD boot partition DTB lacks the YT8511 PHY compatible (Linux would bind Generic PHY)"; fail=1
  fi
  rm -f "${TMP}.ub" "${TMP}.rest"
  ;;
esac
if LC_ALL=C grep -aq 'pxelinux.cfg' "${TMP}"; then
  echo "   info U-Boot can PXE boot (upstream default; local disks are tried first)"
fi
rm -f "${TMP}"
[ "${fail}" = 0 ] || { echo "image failed verification" >&2; return 1; }
echo ">> done: ${IMG}"

if [ -n "${INSTALLER_REPO}" ]; then
  REF="${INSTALLER_REPO}-${BOARD}${SUFFIX}:${TALOS_VERSION}"
  echo ">> installer ${REF}"
  imager "${WORK}" installer --arch arm64 ${OVERLAY_OPTS[@]+"${OVERLAY_OPTS[@]}"} \
    --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
    ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} || return 1
  docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} -v "${WORK}:/out" "${CRANE}" \
    push /out/installer-arm64.tar "${REF}" || return 1
  echo "${REF}" >> "${OUT}/installer-refs.txt"
fi

# Never fails the build: the plain installer is already pushed.
[ -z "${FACTORY_REPO}" ] || push_factory || echo "::warning::${BOARD}: Factory-style installer not published"
rm -rf "${WORK}"
}

# TFTP tree for U-Boot PXE (one tree serves every board: U-Boot's per-board
# ${fdtfile} picks the DTB from fdtdir):
#   talos/<flavor>/Image               raw arm64 kernel (extracted from EFI zboot) for booti
#   talos/<flavor>/initramfs-arm64.xz  initramfs incl. extensions
#   talos/<flavor>/dtb/rockchip/*.dtb  from the overlay
#   pxelinux.cfg/default               generated from netboot/pxelinux.cfg.default.in
#   u-boot/<board>/u-boot-rockchip.bin  to prime blank media (not needed by TFTP)
build_netboot() {
local board="$1" W="${OUT}/.work-netboot" T="${OUT}/netboot-${FLAVOR}"
rm -rf "${W}" "${T}"; mkdir -p "${W}/k" "${W}/i" "${W}/c" "${T}/talos/${FLAVOR}/dtb" "${T}/pxelinux.cfg"
local common=(--arch arm64 --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${board}" ${EXT_ARGS[@]+"${EXT_ARGS[@]}"})
echo ">> [${FLAVOR}] netboot assets"
# Built from the "iso" profile, not the board profile: only these outputs are taken from it,
# and its output format is raw. The board profile's .xz output format would be applied to
# them too (compressing the kernel, and failing on the already-.xz initramfs since 1.15).
imager "${W}/k" iso --output-kind kernel    "${common[@]}" || return 1
imager "${W}/i" iso --output-kind initramfs "${common[@]}" || return 1
imager "${W}/c" iso --output-kind cmdline   "${common[@]}" ${KARGS[@]+"${KARGS[@]}"} || return 1
local kern init cmd
kern="$(ls "${W}"/k/* | head -n1)"; init="$(ls "${W}"/i/* | head -n1)"; cmd="$(ls "${W}"/c/* | head -n1)"
python3 hack/zboot-extract.py "${kern}" "${T}/talos/${FLAVOR}/Image" || return 1
cp "${init}" "${T}/talos/${FLAVOR}/initramfs-arm64.xz"
docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} "${CRANE}" export --platform linux/arm64 "${OVERLAY_IMAGE}" - \
  | tar x -C "${W}" artifacts/arm64/dtb artifacts/arm64/u-boot || return 1
cp -r "${W}/artifacts/arm64/dtb/rockchip" "${T}/talos/${FLAVOR}/dtb/"
# U-Boot per board, for priming a blank SD/eMMC (dd at sector 64) or SPI (quartz64-a)
cp -r "${W}/artifacts/arm64/u-boot" "${T}/u-boot"
local cmdline; cmdline="$(tr -d '\n' < "${cmd}")"
echo "   cmdline: ${cmdline}"
sed -e "s#@FLAVOR@#${FLAVOR}#g" -e "s#@CMDLINE@#${cmdline}#" netboot/pxelinux.cfg.default.in > "${T}/pxelinux.cfg/default"
grep -q 'console=ttyS2,1500000n8' "${T}/pxelinux.cfg/default" || { echo "   BAD overlay console arg missing from cmdline" >&2; return 1; }
tar -C "${T}" -czf "${OUT}/netboot-${TALOS_VERSION}-${FLAVOR}.tar.gz" .
rm -rf "${W}"
echo ">> done: ${OUT}/netboot-${TALOS_VERSION}-${FLAVOR}.tar.gz"
}

rc=0
for b in "$@"; do build_one "$b" || rc=1; done
if [ "${NETBOOT}" = 1 ]; then build_netboot "$1" || rc=1; fi
exit "${rc}"
