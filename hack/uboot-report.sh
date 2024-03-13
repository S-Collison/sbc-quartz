#!/usr/bin/env bash
# Markdown report of the U-Boot options that matter for these boards, from the
# resolved configs the overlay ships (artifacts/arm64/u-boot/<board>/u-boot.config).
#
#   hack/uboot-report.sh <overlay root>      e.g. _out/overlay
#
# Exit 1 if a board would not derive its MAC address from the chip ID.
set -euo pipefail
root="${1:?usage: $0 <overlay root>}"
dir="${root}/artifacts/arm64/u-boot"
ls "${dir}"/*/u-boot.config >/dev/null 2>&1 || { echo "no u-boot.config under ${dir}" >&2; exit 2; }

# option:wanted  (y = must be set, n = must be off, - = informational)
opts="MISC_INIT_R:y ROCKCHIP_OTP:y ROCKCHIP_EFUSE:n HASH:y SHA256:y NET:y CMD_NET:y CMD_DHCP:-
DWC_ETH_QOS_ROCKCHIP:y PHY_MOTORCOMM:- PHY_REALTEK:- EFI_LOADER:y OF_UPSTREAM:-"

boards=$(cd "${dir}" && ls -d */ | tr -d / | sort)
ver="$(sed -nE 's/^# (U-Boot [^ ]+) Configuration$/\1/p' "$(ls "${dir}"/*/u-boot.config | head -n1)")"
fail=0

echo "### U-Boot configuration (${ver:-unknown version})"
echo
printf '| option | wanted |'; for b in ${boards}; do printf ' %s |' "$b"; done; echo
printf '|---|---|'; for b in ${boards}; do printf -- '---|'; done; echo
for o in ${opts}; do
  name="${o%%:*}"; want="${o##*:}"
  printf '| `%s` | %s |' "${name}" "${want/-/info}"
  for b in ${boards}; do
    c="${dir}/${b}/u-boot.config"
    if grep -qx "CONFIG_${name}=y" "$c"; then v=y; else v=n; fi
    mark="$v"
    if [ "${want}" != - ]; then
      if [ "$v" = "${want}" ]; then mark="✅ $v"; else mark="❌ $v"; fail=1; fi
    fi
    printf ' %s |' "${mark}"
  done
  echo
done
echo
if [ "${fail}" = 0 ]; then
  echo "Every board derives a fixed MAC address from the chip ID (OTP → SHA256 → \`ethaddr\` → \`local-mac-address\`)."
else
  echo "**❌ At least one board would boot with a random MAC address.** See the options marked ❌."
fi
exit "${fail}"
