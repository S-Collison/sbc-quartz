#!/usr/bin/env bash
# Build a bootable Talos SD/eMMC image for a Pine64 RK3566 board and verify it.
#
#   hack/build-image.sh <board> [talos-version]
#
# board: quartz64-a | quartz64-b | soquartz-blade | soquartz-model-a | soquartz-cm4
#
# Env:
#   OVERLAY_IMAGE  overlay image built from this repo (default: ghcr.io/s-collison/sbc-quartz:$(git describe))
#   TALOS_VERSION  imager version if not given as $2 (default below)
#
# The previous image (_out/metal-amd64.raw.xz) was built WITHOUT --arch arm64,
# so it contained x86 GRUB (BOOTX64.EFI) — U-Boot on RK3566 has nothing to run
# and the board stays black. This script always passes --arch arm64 and refuses
# to hand back an image that lacks BOOTAA64.EFI or the Rockchip idbloader.
set -euo pipefail

BOARD="${1:?usage: $0 <board> [talos-version]}"
TALOS_VERSION="${2:-${TALOS_VERSION:-v1.14.5}}"
TAG="$(git describe --tag --always --dirty --match 'v[0-9]*')"
OVERLAY_IMAGE="${OVERLAY_IMAGE:-ghcr.io/s-collison/sbc-quartz:${TAG}}"
OUT="${PWD}/_out"

case "${BOARD}" in
  quartz64-a|quartz64-b|soquartz-blade|soquartz-model-a|soquartz-cm4) ;;
  *) echo "unknown board: ${BOARD}" >&2; exit 1 ;;
esac

mkdir -p "${OUT}"
rm -f "${OUT}/metal-arm64.raw.xz"

echo ">> imager ${TALOS_VERSION}  overlay ${OVERLAY_IMAGE}  board ${BOARD}"
docker run --rm -t \
  -v "${OUT}:/out" -v /dev:/dev --privileged \
  "ghcr.io/siderolabs/imager:${TALOS_VERSION}" \
  metal \
  --arch arm64 \
  --overlay-image "${OVERLAY_IMAGE}" \
  --overlay-name "${BOARD}"

IMG="${OUT}/talos-${TALOS_VERSION}-${BOARD}.raw.xz"
mv "${OUT}/metal-arm64.raw.xz" "${IMG}"

echo ">> verifying ${IMG}"
TMP="$(mktemp)"; trap 'rm -f "${TMP}"' EXIT
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
if LC_ALL=C grep -aq "fdtfile=rockchip/$(echo "${BOARD}" | sed 's/^/rk3566-/').dtb" "${TMP}"; then
  echo "   ok  U-Boot fdtfile matches ${BOARD}"
else
  echo "   BAD U-Boot fdtfile does not match ${BOARD}"; fail=1
fi

[ "${fail}" = 0 ] || { echo "image failed verification" >&2; exit 1; }
echo ">> done: ${IMG}"
echo "   flash:  xz -dc ${IMG} | sudo dd of=/dev/rdiskN bs=4m   (macOS; check the disk with 'diskutil list')"
