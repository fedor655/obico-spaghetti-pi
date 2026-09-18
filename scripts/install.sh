#!/usr/bin/env bash
# Deploys self-hosted Obico with spaghetti detection on a Raspberry Pi 4.
# Idempotent: re-running brings the install up to the expected state.
set -euo pipefail

UPSTREAM_COMMIT="49c0bc7001a3fd8d56297fc3032ba287bfe1d50b"
OBICO_DIR="${OBICO_DIR:-$HOME/obico-server}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -m)" = "aarch64" ] || die "a 64-bit OS is required, this is $(uname -m)"

avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb}G free on /, at least 10G is needed"

mem_mb=$(free -m | awk '/^Mem:/{print $2}')
[ "$mem_mb" -ge 3500 ] || echo "WARNING: ${mem_mb}M of RAM — this stack expects 4 GB"

if ! command -v docker >/dev/null; then
  echo "==> installing Docker"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Docker installed. Log out and back in (or run newgrp docker), then re-run this script."
  exit 0
fi
docker compose version >/dev/null 2>&1 || die "docker compose v2 is not available"

if [ ! -d "$OBICO_DIR/.git" ]; then
  echo "==> cloning obico-server into $OBICO_DIR"
  git clone https://github.com/TheSpaghettiDetective/obico-server.git "$OBICO_DIR"
fi

cd "$OBICO_DIR"
git fetch --all --tags
git checkout "$UPSTREAM_COMMIT"

echo "==> applying patches"
for p in "$HERE"/patches/*.patch; do
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"
    echo "    applied: $(basename "$p")"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    echo "    already applied, skipping: $(basename "$p")"
  else
    die "patch $(basename "$p") does not apply to $UPSTREAM_COMMIT"
  fi
done

cp "$HERE/config/docker-compose.override.yml" "$OBICO_DIR/docker-compose.override.yml"
echo "==> CPU limits in place"

echo "==> building and starting (the first build on a Pi 4 takes 40-90 minutes)"
docker compose up -d --build

echo
docker compose ps
echo
echo "Done. Web UI: http://$(hostname -I | awk '{print $1}'):3334"
echo "Next up is step 6 of the README: installing the moonraker-obico client on the printer."
