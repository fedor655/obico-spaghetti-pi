# Spaghetti Detection on a Raspberry Pi — self-hosted Obico

Failed-print ("spaghetti") detection running entirely on a Raspberry Pi 4, with no
dependency on The Spaghetti Detective cloud. Camera → Klipper/Moonraker → local Obico
server → ML model on the Pi's own CPU. Nothing leaves the machine.

This is **not a fork** of [obico-server](https://github.com/TheSpaghettiDetective/obico-server).
It is the set of configs, patches and instructions that turn upstream into a working
install on a Pi.

Verified on: Raspberry Pi 4 Model B 4 GB · Debian 12 bookworm (aarch64) · Docker 29.6.1 ·
Python 3.11.2 · upstream commit `49c0bc7001a3fd8d56297fc3032ba287bfe1d50b`.

## How it fits together

```
USB camera
   └─ mjpg_streamer :8080  ──┬─→ ffmpeg → janus            (WebRTC preview)
                             └─→ moonraker-obico ──┐
Klipper (klippy) ── Moonraker :7125 ───────────────┤
                                                   ▼
                            Obico server (docker compose)
                              web     :3334  Django + daphne
                              ml_api  :3333  Flask + gunicorn ← the detector itself
                              tasks          celery worker + beat
                              redis          queue and cache
```

`ml_api` is the detector. It holds the YOLO model (`model.cfg` plus weights), takes a
frame over HTTP and returns spaghetti boxes with confidence scores. The positive-detection
threshold is `THRESH = 0.08` in `ml_api/server.py`. From there `web` accumulates those
detections into a rolling mean and decides whether to warn or pause the print.

Model weights are not stored in git — `ml_api/model/*.url` holds the links and the files
are fetched during the image build:

- ONNX (used on arm64): `model-weights-5a6b1be1fa.onnx`
- Darknet: `model-weights-ef79dacfd0051ab526f3002d5f5f9912.darknet`

## Requirements

- Raspberry Pi 4 with **4 GB** of RAM. The stack will not fit in 2 GB: web + ml_api +
  celery + redis sit at roughly 1.2 GB steady-state.
- **10+ GB of free disk.** The containerd layers for these images come to about 9 GB.
- A 64-bit OS (`uname -m` must report `aarch64`) and Docker with compose v2.
- A working Klipper + Moonraker setup (standard `printer_data` layout).
- A USB camera serving MJPEG at `http://127.0.0.1:8080/?action=stream`.

## Installation

### 1. Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 2. Obico server

```bash
cd ~
git clone https://github.com/TheSpaghettiDetective/obico-server.git
cd obico-server
git checkout 49c0bc7001a3fd8d56297fc3032ba287bfe1d50b   # the verified commit
```

### 3. Patches from this repository

```bash
git clone https://github.com/fedor655/obico-spaghetti-pi.git ~/obico-spaghetti-pi
cd ~/obico-server
git apply ~/obico-spaghetti-pi/patches/*.patch
cp ~/obico-spaghetti-pi/config/docker-compose.override.yml .
```

See the "Patches" section below for what each one does.

### 4. Build and start

```bash
cd ~/obico-server
docker compose up -d --build
```

The first build on a Pi 4 takes **40–90 minutes**: numpy and opencv are compiled for
arm64 and the model weights are downloaded. Do not interrupt it.

Check readiness:

```bash
docker compose ps          # all four services should report (healthy)
curl http://127.0.0.1:3333/hc/   # ml_api health check
```

### 5. Account

Open `http://<pi-ip>:3334` and sign up. The first user becomes the administrator.
Sign-up is closed after that first account by default (`ACCOUNT_ALLOW_SIGN_UP=False`
in `.env`).

### 6. Printer-side client

```bash
cd ~
git clone https://github.com/TheSpaghettiDetective/moonraker-obico.git
cd moonraker-obico
./install.sh
```

The installer asks for the server address — give it `http://127.0.0.1:3334`. Then add the
printer in the Obico web UI, get the six-digit code and enter it; that writes `auth_token`
into `~/printer_data/config/moonraker-obico.cfg`.

A sample config is in `config/moonraker-obico.cfg.example`. **Never commit your own
`auth_token`.**

### 7. Verify

```bash
sudo systemctl status moonraker-obico
tail -f ~/printer_data/logs/moonraker-obico.log
```

Start a print: the printer page should show a live preview with a "Failure detection"
gauge below it. To confirm the detector actually fires, hold a tangle of white filament
in front of the camera — the confidence should climb.

## Patches

### `01-escalating-factor.patch`

`backend/config/settings.py`, `FD_1ST_GEN_PARAMS['ESCALATING_FACTOR']`: `1.75 → 1.0`.

This is the factor by which a warning escalates into a print pause. With the stock `1.75`
the detector let dozens of layers of spaghetti pile up before stopping the print. `1.0`
pauses as soon as the threshold is reached. The trade-off is more false positives; if the
printer starts stopping for no reason, raise it back toward `1.3–1.5`.

### `02-relative-media-url.patch`

`backend/lib/fs_file_storage.py`: the external media URL becomes relative instead of an
absolute one built through `build_full_url_for_syndicate`.

Upstream bakes the full host, taken from server settings, into links to snapshots and
timelapses. On a home Pi with a DHCP address that means every image breaks as soon as the
IP changes. A relative URL is resolved by the browser against the current host, so it
works over `192.168.0.x`, over Tailscale, and from any other address.

### `docker-compose.override.yml`

Caps `web` and `ml_api` at 2.8 CPUs each. On a quad-core Pi 4 without a limit, detection
during a print consumed every core and Klipper began hitting serial-port timeouts, which
broke prints for no visible reason.

## Maintenance

Disk fills up quickly — timelapses and snapshots accumulate under
`backend/static_build/media/`, and old containerd layers are never cleaned up
automatically.

```bash
du -sh ~/obico-server/backend/static_build/media/*   # what has piled up
docker system prune -a                               # old images and layers
sudo journalctl --vacuum-size=100M                   # systemd logs
```

Detection logs:

```bash
docker compose logs -f ml_api
docker compose logs -f tasks     # celery: post-processing and timelapses
```

## License

The patches and documentation are MIT. obico-server itself is under its own license
(AGPL-3.0) and the model weights belong to Obico.
