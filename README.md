# remna-geo-updater

Bash-скрипт для автоматического обновления `geoip/geosite` файлов и подключения их в `remnanode` через `docker-compose`.

## Что делает скрипт

- Находит compose-файл в одном из путей:
  - `/opt/remnanode/docker-compose.yml`
  - `/opt/remnanode/docker-compose.yaml`
  - `/opt/remnawave/docker-compose.yml`
  - `/opt/remnawave/docker-compose.yaml`
- Проверяет сервис `remnanode` и гарантирует наличие `volumes`:
  - `/opt/remnawave/xray/share/roscomvpn-geoip.dat:/usr/local/bin/roscomvpn-geoip.dat`
  - `/opt/remnawave/xray/share/roscomvpn-geosite.dat:/usr/local/bin/roscomvpn-geosite.dat`
- Скачивает файлы:
  - `https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat`
  - `https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat`
- Перезапускает `remnanode`, только если были реальные изменения.
- Может установить cron-запуск с учетом московского времени.

## Требования

- Linux-сервер с `bash`
- `docker` + (`docker compose` или `docker-compose`)
- `curl`
- `awk`
- `crontab` (только для `--install-cron`)
- root-права для записи в системные пути и перезапуска контейнера

## Установка

1. Скачайте скрипт:

```bash
sudo curl -fL "https://raw.githubusercontent.com/s-bug0ff/remna-geofile-updator/refs/heads/main/remna-geo-updater.sh" -o /usr/local/bin/remna-geo-updater.sh
sudo chmod +x /usr/local/bin/remna-geo-updater.sh
```

2. (Опционально) Проверьте, что файл на месте:

```bash
ls -l /usr/local/bin/remna-geo-updater.sh
```

3. Проверьте безопасно в dry-run:

```bash
sudo /usr/local/bin/remna-geo-updater.sh --dry-run
```

## Режимы запуска

### `--dry-run`

Проверка без изменений:
- не пишет файлы,
- не правит compose,
- не перезапускает контейнер.

```bash
sudo /usr/local/bin/remna-geo-updater.sh --dry-run
```

### `--run`

Один рабочий цикл:
1) проверка/добавление volumes,  
2) скачивание файлов,  
3) перезапуск сервиса при изменениях.

```bash
sudo /usr/local/bin/remna-geo-updater.sh --run
```

### `--install-cron`

Ставит cron-задачу, которая триггерится каждый час, а скрипт сам выполняется только в окне `05:00-05:14` по Москве и не более 1 раза в день.

```bash
sudo /usr/local/bin/remna-geo-updater.sh --install-cron
```

### `--scheduled-run`

Служебный режим для cron (обычно вручную не нужен):

```bash
sudo /usr/local/bin/remna-geo-updater.sh --scheduled-run
```

### `--all`

Сразу выполнить `--run` и затем `--install-cron`.

```bash
sudo /usr/local/bin/remna-geo-updater.sh --all
```

## Переменные окружения

Можно переопределить поведение без редактирования скрипта:

- `SERVICE_NAME` (default: `remnanode`)
- `SHARE_DIR` (default: `/opt/remnawave/xray/share`)
- `COMPOSE_FILE` (явный путь к compose)
- `SCRIPT_PATH` (default: `/usr/local/bin/remna-geo-updater.sh`)
- `LOCK_PATH` (default: `/var/lock/remna-geo-updater.lock`)
- `STATE_DIR` (default: `/var/lib/remna-geo-updater`)
- `CRON_LOG_FILE` (default: `/var/log/remna-geo-updater.log`)
- `RESTART_RETRIES` (default: `8`)
- `RESTART_RETRY_DELAY` (default: `15`)
- `RESTART_WAIT_TIMEOUT` (default: `180`)
- `ORIGINAL_BACKUP_SUFFIX` (default: `.original.bak`)
- `GEOIP_URL`, `GEOSITE_URL`, `GEOIP_NAME`, `GEOSITE_NAME`

Пример:

```bash
sudo COMPOSE_FILE=/opt/remnawave/docker-compose.yml SERVICE_NAME=remnanode /usr/local/bin/remna-geo-updater.sh --dry-run
```

## Логи и состояние

- Лог cron: `/var/log/remna-geo-updater.log`
- Маркер успешного ежедневного запуска: `/var/lib/remna-geo-updater/last-success-moscow-date`
- Одноразовый backup оригинального compose (до первого изменения): `docker-compose.yml.original.bak` (или `.yaml.original.bak`)
- Backup compose при каждом изменении: `docker-compose.*.bak.<timestamp>`

## Совместимость с watchtower

Если на хосте работает watchtower, скрипт учитывает это:

- перед `restart` проверяет, не находится ли контейнер в состоянии `restarting`;
- при конфликте с параллельным перезапуском делает ретраи `restart`;
- если `restart` неуспешен, делает ретраи `up -d`;
- все тайминги настраиваются через `RESTART_RETRIES`, `RESTART_RETRY_DELAY`, `RESTART_WAIT_TIMEOUT`.

Пример для более "мягкого" поведения на занятых хостах:

```bash
sudo RESTART_RETRIES=12 RESTART_RETRY_DELAY=20 RESTART_WAIT_TIMEOUT=300 /usr/local/bin/remna-geo-updater.sh --run
```

## Проверка после установки

1. Dry-run:
```bash
sudo /usr/local/bin/remna-geo-updater.sh --dry-run
```

2. Боевой запуск:
```bash
sudo /usr/local/bin/remna-geo-updater.sh --run
```

3. Проверка cron:
```bash
sudo crontab -l
```

## Частые проблемы

- `Не найден docker compose или docker-compose`  
  Установите Docker Compose Plugin или `docker-compose`.

- `В compose не найден сервис remnanode`  
  Укажите путь и сервис через env:
  ```bash
  sudo COMPOSE_FILE=/path/to/docker-compose.yml SERVICE_NAME=remnanode /usr/local/bin/remna-geo-updater.sh --dry-run
  ```

- `URL недоступен`  
  Проверьте сетевой доступ сервера к GitHub и DNS.

- `Проверка compose config не прошла`  
  Скрипт автоматически восстановит backup и завершится с ошибкой.
