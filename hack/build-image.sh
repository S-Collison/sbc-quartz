#!/usr/bin/env bash
# Build bootable Talos SD/eMMC images for Pine64 RK3566 boards and verify them.
#
#   hack/build-image.sh [board ...]
#
# With no boards it builds: quartz64-a soquartz-blade soquartz-model-a
# Valid boards are the overlay names in Pkgfile vars.boards.
#
# Env:
#   TALOS_VERSION  imager version (default v1.14.5)
#   OVERLAY_IMAGE  overlay image built from this repo (default: ghcr.io/s-collison/sbc-quartz:$(git describe))
#
# The original broken image (_out/metal-amd64.raw.xz) was built WITHOUT
# --arch arm64, so it held x86 GRUB (BOOTX64.EFI) and U-Boot had nothing to
# run. This script always passes --arch arm64 and refuses any image that lacks
# BOOTAA64.EFI, the Rockchip idbloader, or the board's fdtfile.
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:-v1.14.5}"
TAG="$(git describe --tag --always --dirty --match 'v[0-9]*')"
OVERLAY_IMAGE="${OVERLAY_IMAGE:-ghcr.io/s-collison/sbc-quartz:${TAG}}"
OUT="${PWD}/_out"

# board table: lines "<name>:<defconfig>:<dtb>" from the Pkgfile boards var
TABLE="$(awk '/^  boards:/{f=1;next} f&&/^    [a-z0-9-]+:/{print $1;next} f{exit}' Pkgfile)"
[ -n "${TABLE}" ] || { echo "could not read boards from Pkgfile" >&2; exit 1; }

if [ "$#" -eq 0 ]; then set -- quartz64-a soquartz-blade soquartz-model-a; fi

build_one() {
BOARD="$1"
ENTRY="$(printf '%s\n' "${TABLE}" | grep "^${BOARD}:" || true)"
[ -n "${ENTRY}" ] || { echo "unknown board ${BOARD}; known: $(printf '%s\n' "${TABLE}" | cut -d: -f1 | tr '\n' ' ')" >&2; return 1; }
DTB="${ENTRY##*:}"

mkdir -p "${OUT}"
rm -f "${OUT}/metal-arm64.raw.xz"

echo ">> imager ${TALOS_VERSION}  overlay ${OVERLAY_IMAGE}  board ${BOARD}"
docker run --rm -t \
  -v "${OUT}:/out" -v /dev:/dev --privileged \
  "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
  metal \
  --arch arm64 \
  --overlay-image "${OVERLAY_IMAGE}" \
  --overlay-name "${BOARD}" || return 1

IMG="${OUT}/talos-${TALOS_VERSION}-${BOARD}.raw.xz"
mv "${OUT}/metal-arm64.raw.xz" "${IMG}" || return 1

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
if LC_ALL=C grep -aq 'BOOTX64 EFI' "${TMP}"; then
  echo "   BAD BOOTX64.EFI present — this is an amd64 image"; fail=1
fi
if LC_ALL=C grep -aq "fdtfile=rockchip/${DTB}" "${TMP}"; then
  echo "   ok  U-Boot fdtfile matches ${BOARD}"
else
  echo "   BAD U-Boot fdtfile does not match ${BOARD}"; fail=1
fi

rm -f "${TMP}"
[ "${fail}" = 0 ] || { echo "image failed verification" >&2; return 1; }
echo ">> done: ${IMG}"
echo "   flash:  xz -dc ${IMG} | sudo dd of=/dev/rdiskN bs=4m   (macOS; check the disk with 'diskutil list')"
}

rc=0
for b in "$@"; do build_one "$b" || rc=1; done
exit "${rc}"
