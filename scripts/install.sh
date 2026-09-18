#!/usr/bin/env bash
# Разворачивает self-hosted Obico со spaghetti detection на Raspberry Pi 4.
# Идемпотентен: повторный запуск доводит установку до нужного состояния.
set -euo pipefail

UPSTREAM_COMMIT="49c0bc7001a3fd8d56297fc3032ba287bfe1d50b"
OBICO_DIR="${OBICO_DIR:-$HOME/obico-server}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

[ "$(uname -m)" = "aarch64" ] || die "нужна 64-битная ОС, сейчас $(uname -m)"

avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$avail_gb" -ge 10 ] || die "на / свободно ${avail_gb}G, нужно минимум 10G"

mem_mb=$(free -m | awk '/^Mem:/{print $2}')
[ "$mem_mb" -ge 3500 ] || echo "ВНИМАНИЕ: ${mem_mb}M RAM — стек рассчитан на 4 ГБ"

if ! command -v docker >/dev/null; then
  echo "==> ставлю Docker"
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Docker установлен. Перелогиньтесь (или newgrp docker) и запустите скрипт снова."
  exit 0
fi
docker compose version >/dev/null 2>&1 || die "нет docker compose v2"

if [ ! -d "$OBICO_DIR/.git" ]; then
  echo "==> клонирую obico-server в $OBICO_DIR"
  git clone https://github.com/TheSpaghettiDetective/obico-server.git "$OBICO_DIR"
fi

cd "$OBICO_DIR"
git fetch --all --tags
git checkout "$UPSTREAM_COMMIT"

echo "==> накатываю патчи"
for p in "$HERE"/patches/*.patch; do
  if git apply --check "$p" 2>/dev/null; then
    git apply "$p"
    echo "    применён: $(basename "$p")"
  elif git apply --reverse --check "$p" 2>/dev/null; then
    echo "    уже применён, пропускаю: $(basename "$p")"
  else
    die "патч $(basename "$p") не ложится на $UPSTREAM_COMMIT"
  fi
done

cp "$HERE/config/docker-compose.override.yml" "$OBICO_DIR/docker-compose.override.yml"
echo "==> лимиты CPU установлены"

echo "==> собираю и поднимаю (на Pi 4 первая сборка 40-90 минут)"
docker compose up -d --build

echo
docker compose ps
echo
echo "Готово. Веб-интерфейс: http://$(hostname -I | awk '{print $1}'):3334"
echo "Дальше — шаг 6 из README: установка клиента moonraker-obico на принтере."
