# Measured results on a Raspberry Pi 4

Real numbers from a running install, not estimates. Reproduce them with
`scripts/bench.sh`.

**Hardware and conditions.** Raspberry Pi 4 Model B Rev 1.2, 4 GB RAM, Debian 12 bookworm
(aarch64), root on a USB SSD, **active cooling (fan)**. Measured on a live system with 11 days of
uptime: the full Obico stack, Klipper, Moonraker, mjpg_streamer, ffmpeg and janus were all
running, plus a desktop session with VNC. These are working-printer conditions, not a
clean-room benchmark.

## Detection latency

One 640×480 JPEG through `ml_api`'s `/p/` endpoint, 20 sequential requests, ONNX model on
CPU. Image fetch is excluded — served from the host over the bridge network, it measured
5 ms.

| | seconds |
|---|---|
| min | 14.68 |
| median | **15.49** |
| mean | 17.02 |
| p95 | 27.88 |
| max | 31.52 |

Eighteen of the twenty runs landed in a tight 14.7–16.8 s band. The two outliers (27.9 s
and 31.5 s) happened while other SSH commands were competing for CPU, which is a fair
illustration of what any background load does to this workload.

That works out to roughly **one frame every 15 seconds**, about 0.065 fps. The test frame
returned 9 `failure` boxes, top confidence 0.50.

**This is the headline result, and it is the thing to understand before self-hosting on a
Pi.** Obico's own guidance is that the server is not meant for a Raspberry Pi, and the
latency above is why. It still works for its purpose — spaghetti develops over minutes,
not milliseconds, so a 15-second detection interval catches a failing print long before it
becomes a blob. But it is not real-time, and it means the Pi is doing continuous heavy
work for the entire duration of every print.

## Memory

Total 3.7 GiB, 1.6 GiB in use, 2.1 GiB available, **swap untouched at 0 B** — no memory
pressure across 11 days of uptime.

Resident set by service:

| RSS | Service |
|---|---|
| 598 MB | celery (4 processes) — task workers |
| 413 MB | gunicorn — ml_api |
| 203 MB | daphne — websockets |
| 184 MB | python3 — moonraker-obico and helpers |
| 117 MB | python — klippy and moonraker |
| 205 MB | dockerd + containerd + shims |
| 52 MB | ffmpeg — webcam transcode |

The Obico stack alone accounts for more than 1.2 GB. A desktop session (labwc, wayvnc,
pcmanfm, panel) adds a further ~290 MB; on a headless printer host that is free to
reclaim.

## CPU and thermals

Four cores. Load average sat at 0.84 / 1.18 / 1.76 while idle-ish and rose to 1.43 under
detection — roughly a quarter to a third of the machine.

| | |
|---|---|
| Idle temperature | 40.4 °C |
| Under detection | 48.2 °C |
| Clock | 1500 MHz, no downclocking |
| `vcgencmd get_throttled` | `0x0` — never throttled |

These temperatures are with a fan. Do not read them as a case for passive cooling — a bare or heatsink-only Pi 4 running this workload will sit much hotter and is likely to throttle, which on a 15 s inference makes it slower still. Accumulated CPU time over 11 days shows the steady
background cost: xray 147 min, moonraker 113 min, ffmpeg 72 min, redis 73 min.

The `cpus: 2.8` cap in `docker-compose.override.yml` matters here. Without it, detection
saturated all four cores and Klipper started hitting serial-port timeouts, which aborted
prints.

## Disk

This is the real constraint on a Pi, more so than RAM or CPU.

| Size | What |
|---|---|
| 6.49 GB | `obico-server-ml_api` image |
| 3.09 GB | `obico-server-web` image |
| 3.09 GB | `obico-server-tasks` image |
| 58 MB | `redis:7.2-alpine` |
| **9.1 GB** | `/var/lib/containerd` total on disk |

On a 29 GB root filesystem that is roughly a third of the disk before a single print.
Media then grows on top: 152 timelapse videos plus their detection JSON reached 259 MB,
and detection snapshots another 88 MB. Note that every print produces **two** videos —
`N.mp4` and `N_tagged.mp4` with detection boxes drawn on.

Budget 10 GB free for the install and plan to prune periodically; see the maintenance
section of the README.

## Build

The first `docker compose up -d --build` takes 40–90 minutes on a Pi 4 — numpy and opencv
compile from source for arm64 and the model weights download. Subsequent starts are quick;
all four containers reported `healthy` and stayed up for the 11 days measured here.
