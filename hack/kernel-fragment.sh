#!/usr/bin/env bash
# Print the kernel config fragment for a custom kernel flavor.
#   base  = kernel/base.config                      (Ethernet PHY driver only)
#   media = kernel/base.config + kernel/media.config (+ Hantro/RGA V4L)
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  base)  cat kernel/base.config ;;
  media) cat kernel/base.config kernel/media.config ;;
  *) echo "usage: $0 base|media" >&2; exit 2 ;;
esac
