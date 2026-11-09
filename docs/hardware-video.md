# Hardware video (MPP / RKMPP) on Talos: what's possible

**Short version: Rockchip MPP cannot run on Talos.** Neither `/dev/mpp_service`
nor `h264_rkmpp` / `hevc_rkmpp` will exist on these nodes.

## Why

- MPP is a split stack. The kernel driver behind `/dev/mpp_service` exists only
  in Rockchip's vendor (BSP) kernels (4.19 / 5.10 / 6.1). `libmpp.so` and the
  `ffmpeg-rockchip` fork both need that device.
- Talos boots a mainline kernel (Linux 6.18 in Talos 1.14), built by
  siderolabs/pkgs. It has no `CONFIG_ROCKCHIP_MPP`, and you can't swap in a BSP kernel.
- The mainline alternatives (V4L2 stateless) are **disabled** in the Talos
  arm64 config: `CONFIG_VIDEO_HANTRO`, `CONFIG_VIDEO_ROCKCHIP_VDEC` and
  `CONFIG_VIDEO_ROCKCHIP_RGA` are all "not set". Even enabled, mainline on RK3566
  gives decode only (Hantro G1 / rkvdec). H.264/HEVC **encode** is not upstream.
- `hostPath` with `/opt/ffmpeg-rockchip` doesn't fit Talos either. The root
  filesystem is immutable, there's no compiler on the host, and there's no `/opt`.

What *is* enabled: `DRM_ROCKCHIP` (display), `DRM_PANFROST` (Mali GPU),
`DMABUF_HEAPS_SYSTEM`, and all the storage, network and PMIC drivers these boards need.

## Options

| option | effort | result |
|---|---|---|
| **Software ffmpeg in Scrypted** on a Quartz64 / Pi 5 node | none | Fine for rebroadcast (no transcode). Motion/object detection on a few low-res substreams works; many cameras won't |
| **Custom Talos kernel** (fork siderolabs/pkgs, enable HANTRO/VDEC/RGA, build your own installer-base + imager inputs; rebuild drbd for that kernel) | high, ongoing per Talos release | V4L2 *decode* only, via an ffmpeg with v4l2-request patches. Still no hardware encode |
| **One RK3566 board off Talos** running a vendor-kernel distro (Armbian vendor / Ubuntu Rockchip) with libmpp + ffmpeg-rockchip, running Scrypted directly | medium | Full MPP encode/decode. That board isn't Talos-managed |
| **Intel N100/N150 mini-PC as a Talos worker** + official `i915` extension | low (hardware cost) | Quick Sync decode/encode for Scrypted *and* Plex, inside the cluster |

If you do build a custom Scrypted image (the K8s-native path from the MPP
guides), it only works on a node whose kernel exposes the device, so it
pairs with the "off Talos" option, not with these Talos nodes.
