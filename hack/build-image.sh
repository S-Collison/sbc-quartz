#!/usr/bin/env bash
# Build bootable Talos images (and optionally upgrade installers) for Pine64
# RK3566 boards, and verify them.
#
#   hack/build-image.sh [board ...]
#
# With no boards it builds: quartz64-a soquartz-blade soquartz-model-a
# Valid boards are the overlay names in Pkgfile vars.boards.
#
# Env:
#   TALOS_VERSION   imager version (default v1.14.5)
#   OVERLAY_IMAGE   overlay built from this repo (default ghcr.io/s-collison/sbc-quartz:$(git describe))
#   EXTENSIONS      space-separated official extension names, e.g. "drbd iscsi-tools".
#                   Resolved to pinned digests for TALOS_VERSION.
#   INSTALLER_REPO  if set, also build the upgrade installer and push it as
#                   ${INSTALLER_REPO}-<board>:${TALOS_VERSION}
#                   (tag == Talos version, which is what tuppr / talosctl upgrade expect)
#   DOCKER_CONFIG   registry credentials dir passed to imager/crane (default ~/.docker)
#
# The original broken image (_out/metal-amd64.raw.xz) was built WITHOUT
# --arch arm64, so it held x86 GRUB (BOOTX64.EFI) and U-Boot had nothing to
# run. This script always passes --arch arm64 and refuses any image that lacks
# BOOTAA64.EFI, the Rockchip idbloader, or the board's fdtfile.
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:-v1.14.5}"
TAG="$(git describe --tag --always --dirty --match 'v[0-9]*')"
OVERLAY_IMAGE="${OVERLAY_IMAGE:-ghcr.io/s-collison/sbc-quartz:${TAG}}"
EXTENSIONS="${EXTENSIONS:-}"
INSTALLER_REPO="${INSTALLER_REPO:-}"
OUT="${PWD}/_out"
CRANE="gcr.io/go-containerregistry/crane:latest"

# Pass registry creds into containers only if they're stored in the file
# (CI). Docker Desktop's osxkeychain store can't be read from a container,
# so on a Mac the overlay package must be public.
DOCKER_ARGS=()
CFG="${DOCKER_CONFIG:-${HOME}/.docker}"
if [ -f "${CFG}/config.json" ] && ! grep -q '"credsStore"' "${CFG}/config.json"; then
  DOCKER_ARGS+=(-v "${CFG}:/docker-config:ro" -e DOCKER_CONFIG=/docker-config)
fi

# board table: lines "<name>:<defconfig>:<dtb>" from the Pkgfile boards var
TABLE="$(awk '/^  boards:/{f=1;next} f&&/^    [a-z0-9-]+:/{print $1;next} f{exit}' Pkgfile)"
[ -n "${TABLE}" ] || { echo "could not read boards from Pkgfile" >&2; exit 1; }

if [ "$#" -eq 0 ]; then set -- quartz64-a soquartz-blade soquartz-model-a; fi

# Resolve extension names -> pinned refs from the extensions catalog for this Talos version.
EXT_ARGS=()
if [ -n "${EXTENSIONS}" ]; then
  DIGESTS="$(docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} "${CRANE}" export "ghcr.io/siderolabs/extensions:${TALOS_VERSION}" - | tar x -O image-digests)"
  for e in ${EXTENSIONS}; do
    ref="$(printf '%s\n' "${DIGESTS}" | grep -E "^ghcr.io/siderolabs/${e}:" | head -n1 || true)"
    [ -n "${ref}" ] || { echo "extension ${e} not found for Talos ${TALOS_VERSION}" >&2; exit 1; }
    echo ">> extension ${ref}"
    EXT_ARGS+=(--system-extension-image "${ref}")
  done
fi

imager() {
  docker run --rm -t ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} \
    -v "${OUT}:/out" -v /dev:/dev --privileged \
    "ghcr.io/siderolabs/imager:${TALOS_VERSION}" "$@"
}

build_one() {
BOARD="$1"
ENTRY="$(printf '%s\n' "${TABLE}" | grep "^${BOARD}:" || true)"
[ -n "${ENTRY}" ] || { echo "unknown board ${BOARD}; known: $(printf '%s\n' "${TABLE}" | cut -d: -f1 | tr '\n' ' ')" >&2; return 1; }
DTB="${ENTRY##*:}"

mkdir -p "${OUT}"
rm -f "${OUT}/metal-arm64.raw.xz" "${OUT}/installer-arm64.tar"

echo ">> imager ${TALOS_VERSION}  overlay ${OVERLAY_IMAGE}  board ${BOARD}"
imager metal --arch arm64 \
  --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
  ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} || return 1

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

if [ -n "${INSTALLER_REPO}" ]; then
  REF="${INSTALLER_REPO}-${BOARD}:${TALOS_VERSION}"
  echo ">> installer ${REF}"
  imager installer --arch arm64 \
    --overlay-image "${OVERLAY_IMAGE}" --overlay-name "${BOARD}" \
    ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} || return 1
  docker run --rm ${DOCKER_ARGS[@]+"${DOCKER_ARGS[@]}"} -v "${OUT}:/out" "${CRANE}" \
    push /out/installer-arm64.tar "${REF}" || return 1
  rm -f "${OUT}/installer-arm64.tar"
fi
}

rc=0
for b in "$@"; do build_one "$b" || rc=1; done
exit "${rc}"
