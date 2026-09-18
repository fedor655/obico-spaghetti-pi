# Spaghetti Detection на Raspberry Pi — self-hosted Obico

Детектор «спагетти» (провалов 3D-печати) целиком на своей Raspberry Pi 4, без облака
The Spaghetti Detective. Камера → Klipper/Moonraker → локальный Obico-сервер → ML-модель
на CPU самой малины. Наружу ничего не уходит.

Это **не форк** [obico-server](https://github.com/TheSpaghettiDetective/obico-server), а
набор конфигов, патчей и инструкция, которые превращают upstream в рабочую установку на Pi.

Проверено на: Raspberry Pi 4 Model B 4 ГБ · Debian 12 bookworm (aarch64) · Docker 29.6.1 ·
Python 3.11.2 · upstream-коммит `49c0bc7001a3fd8d56297fc3032ba287bfe1d50b`.

## Как это устроено

```
USB-камера
   └─ mjpg_streamer :8080  ──┬─→ ffmpeg → janus            (WebRTC-превью)
                             └─→ moonraker-obico ──┐
Klipper (klippy) ── Moonraker :7125 ───────────────┤
                                                   ▼
                            Obico server (docker compose)
                              web     :3334  Django + daphne
                              ml_api  :3333  Flask + gunicorn ← детекция спагетти
                              tasks          celery worker + beat
                              redis          очередь и кеш
```

`ml_api` — и есть сам детектор. Он держит YOLO-модель (`model.cfg` + веса), принимает
кадр по HTTP и возвращает боксы «спагетти» с уверенностью. Порог положительной
детекции — `THRESH = 0.08` в `ml_api/server.py`. Дальше `web` копит эти детекции в
скользящее среднее и решает, слать предупреждение или ставить печать на паузу.

Веса модели не лежат в гите — в `ml_api/model/*.url` записаны ссылки, файлы тянутся при
сборке образа:

- ONNX (используется на arm64): `model-weights-5a6b1be1fa.onnx`
- Darknet: `model-weights-ef79dacfd0051ab526f3002d5f5f9912.darknet`

## Требования

- Raspberry Pi 4 с **4 ГБ** RAM. На 2 ГБ стек не влезет: web+ml_api+celery+redis
  устойчиво занимают ~1.2 ГБ.
- **10+ ГБ свободного места.** Слои containerd под эти образы — около 9 ГБ.
- 64-битная ОС (`uname -m` должен дать `aarch64`), Docker с compose v2.
- Уже настроенные Klipper + Moonraker (стандартный `printer_data`).
- USB-камера, отдающая MJPEG на `http://127.0.0.1:8080/?action=stream`.

## Установка

### 1. Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

### 2. Obico-сервер

```bash
cd ~
git clone https://github.com/TheSpaghettiDetective/obico-server.git
cd obico-server
git checkout 49c0bc7001a3fd8d56297fc3032ba287bfe1d50b   # проверенный коммит
```

### 3. Патчи из этого репозитория

```bash
git clone https://github.com/fedor655/obico-spaghetti-pi.git ~/obico-spaghetti-pi
cd ~/obico-server
git apply ~/obico-spaghetti-pi/patches/*.patch
cp ~/obico-spaghetti-pi/config/docker-compose.override.yml .
```

Что делают патчи — см. раздел «Патчи» ниже.

### 4. Сборка и запуск

```bash
cd ~/obico-server
docker compose up -d --build
```

Первая сборка на Pi 4 занимает **40–90 минут**: компилируются numpy/opencv под arm64 и
качаются веса модели. Не прерывайте.

Готовность:

```bash
docker compose ps          # все четыре сервиса должны быть (healthy)
curl http://127.0.0.1:3333/hc/   # health-check ml_api
```

### 5. Аккаунт

Откройте `http://<IP-малины>:3334`, зарегистрируйтесь. Первый пользователь становится
администратором. Регистрация по умолчанию закрыта после первого аккаунта
(`ACCOUNT_ALLOW_SIGN_UP=False` в `.env`).

### 6. Клиент на принтере

```bash
cd ~
git clone https://github.com/TheSpaghettiDetective/moonraker-obico.git
cd moonraker-obico
./install.sh
```

Инсталлятор спросит адрес сервера — укажите `http://127.0.0.1:3334`. Затем на веб-морде
Obico добавьте принтер, получите шестизначный код и введите его — в
`~/printer_data/config/moonraker-obico.cfg` пропишется `auth_token`.

Образец конфига — `config/moonraker-obico.cfg.example`. **Свой `auth_token` в гит не
кладите.**

### 7. Проверка

```bash
sudo systemctl status moonraker-obico
tail -f ~/printer_data/logs/moonraker-obico.log
```

Запустите печать — на странице принтера появится живое превью, а под ним шкала
«Failure detection». Чтобы убедиться, что детектор реально работает, поднесите к камере
комок белой филаментной «лапши»: уверенность должна поползти вверх.

## Патчи

### `01-escalating-factor.patch`

`backend/config/settings.py`, `FD_1ST_GEN_PARAMS['ESCALATING_FACTOR']`: `1.75 → 1.0`.

Фактор, с которым предупреждение перерастает в паузу печати. Со стоковым `1.75` детектор
на нашей камере успевал намотать полсотни слоёв спагетти, прежде чем остановить печать.
`1.0` = пауза сразу по достижении порога. Побочный эффект — больше ложных срабатываний;
если принтер стал вставать на ровном месте, поднимайте обратно к `1.3–1.5`.

### `02-relative-media-url.patch`

`backend/lib/fs_file_storage.py`: внешний URL медиа стал относительным вместо
абсолютного, построенного через `build_full_url_for_syndicate`.

Upstream зашивает в ссылки на снимки и таймлапсы полный хост, взятый из настроек
сервера. На домашней малине с DHCP-адресом это значит, что после смены IP все картинки
отваливаются. Относительный URL браузер резолвит от текущего хоста — работает и по
`192.168.0.x`, и через Tailscale, и с любого другого адреса.

### `docker-compose.override.yml`

Ограничивает `web` и `ml_api` до 2.8 CPU каждый. На четырёхъядерной Pi 4 без лимита
детекция во время печати сжирала все ядра и Klipper начинал ловить таймауты по
последовательному порту — печать рвалась на ровном месте.

## Обслуживание

Место кончается быстро — таймлапсы и снимки копятся в
`backend/static_build/media/`, а старые слои containerd не чистятся сами.

```bash
du -sh ~/obico-server/backend/static_build/media/*   # что накопилось
docker system prune -a                               # старые образы и слои
sudo journalctl --vacuum-size=100M                   # логи systemd
```

Логи детекции:

```bash
docker compose logs -f ml_api
docker compose logs -f tasks     # celery: постобработка и таймлапсы
```

## Лицензия

Патчи и документация — MIT. Сам obico-server под своей лицензией (AGPL-3.0), веса модели
принадлежат Obico.
