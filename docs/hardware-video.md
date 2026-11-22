# Hardware video decoding

The media image enables the RK3566 video blocks that mainline Linux supports. The drivers load on their own; no
machine configuration is needed.

| Block        | Driver         | Use                           |
| ------------ | -------------- | ----------------------------- |
| Hantro G1    | `hantro_vpu`   | H.264, VP8 and MPEG-2 decode  |
| Hantro VEPU  | `hantro_vpu`   | JPEG encode                   |
| RGA2         | `rockchip_rga` | Scaling and colour conversion |

Not available: H.264 encode, and HEVC or VP9 decode. Rockchip's own MPP stack needs the vendor kernel and does not
run on Talos.

## Using it

Check that the devices exist:

```bash
talosctl --nodes <ip> ls /dev | grep -E 'video|media'
```

These are stateless V4L2 decoders, which need FFmpeg with V4L2 Request support. That work is not in an FFmpeg
release yet, so two container images are built here with
[Kwiboo's branch](https://github.com/Kwiboo/FFmpeg/tree/v4l2-request-n8.1):

| Image                                   | Contents                                    |
| --------------------------------------- | ------------------------------------------- |
| `ghcr.io/s-collison/ffmpeg-v4l2request` | FFmpeg on Debian                            |
| `ghcr.io/s-collison/scrypted-rk3566`    | [Scrypted](https://www.scrypted.app) with FFmpeg added |

FFmpeg is at `/opt/ffmpeg-v4l2request/bin/ffmpeg`. The container needs access to `/dev/video*` and `/dev/media*`.
Decode with:

```bash
ffmpeg -hwaccel v4l2request -hwaccel_output_format drm_prime -i <input> ...
```

## How it is built

`kernel/media.config` is added to the Talos kernel configuration, and the modules are added to the list that Talos
ships. See [`.github/workflows/kernel.yaml`](../.github/workflows/kernel.yaml).
