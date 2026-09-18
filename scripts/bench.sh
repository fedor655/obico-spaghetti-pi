#!/usr/bin/env bash
# Reproduces the numbers in BENCHMARKS.md on your own Pi.
#
# Serves a still JPEG over HTTP on the host, points ml_api at it, and times N
# sequential detection calls. A still image is used on purpose: mjpg_streamer
# only serves one client at a time, so pulling a live snapshot while ffmpeg
# holds the stream just blocks.
#
# Usage: ./scripts/bench.sh [runs] [path/to/frame.jpg]
set -euo pipefail

RUNS="${1:-20}"
FRAME="${2:-}"
PORT=8099
CONTAINER="${CONTAINER:-obico-server-ml_api-1}"
NETWORK="${NETWORK:-obico-server_default}"
WORK="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

sudo docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container $CONTAINER is not running"

if [ -n "$FRAME" ]; then
  cp "$FRAME" "$WORK/frame.jpg"
elif [ -f "$HOME/obico-server/test_snapshot.jpg" ]; then
  cp "$HOME/obico-server/test_snapshot.jpg" "$WORK/frame.jpg"
else
  die "no frame given and ~/obico-server/test_snapshot.jpg is missing; pass one as \$2"
fi

GW=$(sudo docker network inspect "$NETWORK" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
[ -n "$GW" ] || die "could not determine the gateway of network $NETWORK"

( cd "$WORK" && python3 -m http.server "$PORT" --bind 0.0.0.0 >/dev/null 2>&1 ) &
SERVER_PID=$!
sleep 2

IMG="http://$GW:$PORT/frame.jpg"

echo "== fetch overhead (no detection) =="
sudo docker exec "$CONTAINER" sh -c \
  "for i in 1 2 3; do curl -s -o /dev/null -w '%{time_total}\n' '$IMG'; done"

echo "== warm-up =="
sudo docker exec "$CONTAINER" curl -s -m 120 "http://127.0.0.1:3333/p/?img=$IMG" \
  | grep -c failure | xargs -I{} echo "detections on this frame: {}"

echo "== $RUNS detection runs (expect ~15 s each on a Pi 4) =="
sudo docker exec "$CONTAINER" sh -c \
  "for i in \$(seq 1 $RUNS); do curl -s -o /dev/null -m 120 -w '%{time_total}\n' 'http://127.0.0.1:3333/p/?img=$IMG'; done" \
  | tee "$WORK/times.txt"

echo
sort -n "$WORK/times.txt" | awk '
  {a[NR]=$1; s+=$1}
  END {
    printf "n=%d  min %.2fs  median %.2fs  mean %.2fs  p95 %.2fs  max %.2fs\n",
           NR, a[1], a[int(NR/2)+1], s/NR, a[int(NR*0.95)], a[NR]
    printf "throughput: %.3f frames/s (one frame every %.1f s)\n", NR/s, s/NR
  }'

echo
echo "== system state =="
vcgencmd measure_temp
vcgencmd get_throttled
cat /proc/loadavg
free -h | head -2
