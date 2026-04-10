#!/usr/bin/env bash

set -euo pipefail

# User-overridable settings.
SERVICE_NAME="${SERVICE_NAME:-remnanode}"
SHARE_DIR="${SHARE_DIR:-/opt/remnawave/xray/share}"
GEOIP_URL="${GEOIP_URL:-https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat}"
GEOSITE_URL="${GEOSITE_URL:-https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat}"
GEOIP_NAME="${GEOIP_NAME:-roscomvpn-geoip.dat}"
GEOSITE_NAME="${GEOSITE_NAME:-roscomvpn-geosite.dat}"
SCRIPT_PATH="${SCRIPT_PATH:-/usr/local/bin/remna-geo-updater.sh}"
LOCK_PATH="${LOCK_PATH:-/var/lock/remna-geo-updater.lock}"
STATE_DIR="${STATE_DIR:-/var/lib/remna-geo-updater}"
CRON_LOG_FILE="${CRON_LOG_FILE:-/var/log/remna-geo-updater.log}"
COMPOSE_FILE_OVERRIDE="${COMPOSE_FILE:-}"
RESTART_RETRIES="${RESTART_RETRIES:-8}"
RESTART_RETRY_DELAY="${RESTART_RETRY_DELAY:-15}"
RESTART_WAIT_TIMEOUT="${RESTART_WAIT_TIMEOUT:-180}"
ORIGINAL_BACKUP_SUFFIX="${ORIGINAL_BACKUP_SUFFIX:-.original.bak}"

COMPOSE_CANDIDATES=(
  "/opt/remnanode/docker-compose.yml"
  "/opt/remnanode/docker-compose.yaml"
  "/opt/remnawave/docker-compose.yml"
  "/opt/remnawave/docker-compose.yaml"
)

GEOIP_FILE="${SHARE_DIR}/${GEOIP_NAME}"
GEOSITE_FILE="${SHARE_DIR}/${GEOSITE_NAME}"
GEOIP_TARGET="/usr/local/bin/${GEOIP_NAME}"
GEOSITE_TARGET="/usr/local/bin/${GEOSITE_NAME}"
CRON_BEGIN="# BEGIN REMNA_GEO_UPDATER"
CRON_END="# END REMNA_GEO_UPDATER"
CRON_MARKER_FILE="${STATE_DIR}/last-success-moscow-date"
LOCK_DIR_FALLBACK="${LOCK_PATH}.d"
LOCK_ACQUIRED=0
LAST_COMPOSE_BACKUP=""
DRY_RUN=0

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Скрипт нужно запускать от root."
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Не найдена обязательная команда: ${cmd}"
}

acquire_lock() {
  if [[ "${LOCK_ACQUIRED}" -eq 1 ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${LOCK_PATH}")"

  if command -v flock >/dev/null 2>&1; then
    exec 9>"${LOCK_PATH}"
    if ! flock -n 9; then
      die "Уже запущен другой экземпляр (${LOCK_PATH})."
    fi
  else
    # Fallback для систем без flock.
    if ! mkdir "${LOCK_DIR_FALLBACK}" 2>/dev/null; then
      die "Уже запущен другой экземпляр (${LOCK_DIR_FALLBACK})."
    fi
    trap 'rmdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || true' EXIT
  fi

  LOCK_ACQUIRED=1
}

detect_compose_file() {
  local path

  if [[ -n "${COMPOSE_FILE_OVERRIDE}" ]]; then
    [[ -f "${COMPOSE_FILE_OVERRIDE}" ]] || die "COMPOSE_FILE не найден: ${COMPOSE_FILE_OVERRIDE}"
    printf '%s\n' "${COMPOSE_FILE_OVERRIDE}"
    return 0
  fi

  for path in "${COMPOSE_CANDIDATES[@]}"; do
    if [[ -f "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done

  return 1
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=("docker" "compose")
  elif command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD=("docker-compose")
  else
    die "Не найден docker compose или docker-compose"
  fi
}

backup_file() {
  local src="$1"
  local dst="${src}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${src}" "${dst}"
  LAST_COMPOSE_BACKUP="${dst}"
}

ensure_original_backup_file() {
  local src="$1"
  local dst="${src}${ORIGINAL_BACKUP_SUFFIX}"
  if [[ -f "${dst}" ]]; then
    return 0
  fi
  cp "${src}" "${dst}"
  log "Создан backup оригинала compose: ${dst}"
}

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "${file}" | awk '{print $NF}'
  else
    die "Не найден инструмент для SHA256 (sha256sum/shasum/openssl)."
  fi
}

download_file_with_replace() {
  local url="$1"
  local dst="$2"
  local tmp_file old_hash new_hash

  mkdir -p "$(dirname "${dst}")"
  tmp_file="$(mktemp "${dst}.tmp.XXXXXX")"
  trap 'rm -f "${tmp_file}"' RETURN

  curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 300 "${url}" -o "${tmp_file}"

  [[ -s "${tmp_file}" ]] || die "Скачан пустой файл: ${url}"

  old_hash=""
  if [[ -f "${dst}" ]]; then
    old_hash="$(hash_file "${dst}")"
  fi
  new_hash="$(hash_file "${tmp_file}")"

  install -m 0644 "${tmp_file}" "${dst}"
  rm -f "${tmp_file}"
  trap - RETURN

  if [[ -n "${old_hash}" && "${old_hash}" == "${new_hash}" ]]; then
    log "Файл не изменился: ${dst}"
    return 1
  fi

  log "Файл обновлен: ${dst}"
  return 0
}

probe_url() {
  local url="$1"
  curl -fIL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 60 "${url}" >/dev/null
}

ensure_volumes_in_compose() {
  local compose_file="$1"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v service_name="${SERVICE_NAME}" \
      -v need_geoip="${GEOIP_FILE}:${GEOIP_TARGET}" \
      -v need_geosite="${GEOSITE_FILE}:${GEOSITE_TARGET}" '
  function indent_len(s, t) {
    t = s
    sub(/[^ ].*$/, "", t)
    return length(t)
  }
  function trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    return s
  }
  function spaces(n, s, i) {
    s = ""
    for (i = 0; i < n; i++) s = s " "
    return s
  }
  {
    lines[NR] = $0
  }
  END {
    n = NR
    service_idx = 0
    service_indent = -1

    for (i = 1; i <= n; i++) {
      t = trim(lines[i])
      if (t == service_name ":") {
        service_idx = i
        service_indent = indent_len(lines[i])
        break
      }
    }

    if (service_idx == 0) {
      print "В compose не найден сервис " service_name > "/dev/stderr"
      exit 2
    }

    service_end = n + 1
    for (i = service_idx + 1; i <= n; i++) {
      t = trim(lines[i])
      if (t == "" || substr(t, 1, 1) == "#") continue
      if (indent_len(lines[i]) <= service_indent) {
        service_end = i
        break
      }
    }

    vol_idx = 0
    vol_indent = -1
    for (i = service_idx + 1; i < service_end; i++) {
      t = trim(lines[i])
      if (t == "volumes:" && indent_len(lines[i]) > service_indent) {
        vol_idx = i
        vol_indent = indent_len(lines[i])
        break
      }
    }

    changed = 0

    if (vol_idx > 0) {
      vol_end = service_end
      for (i = vol_idx + 1; i < service_end; i++) {
        t = trim(lines[i])
        if (t == "" || substr(t, 1, 1) == "#") continue
        if (indent_len(lines[i]) <= vol_indent) {
          vol_end = i
          break
        }
      }

      has_geoip = 0
      has_geosite = 0
      for (i = vol_idx + 1; i < vol_end; i++) {
        if (index(lines[i], need_geoip) > 0) has_geoip = 1
        if (index(lines[i], need_geosite) > 0) has_geosite = 1
      }

      for (i = 1; i <= n; i++) {
        print lines[i]
        if (i == vol_end - 1) {
          if (!has_geoip) {
            print spaces(vol_indent + 2) "- " need_geoip
            changed = 1
          }
          if (!has_geosite) {
            print spaces(vol_indent + 2) "- " need_geosite
            changed = 1
          }
        }
      }
    } else {
      for (i = 1; i <= n; i++) {
        if (i == service_end) {
          print spaces(service_indent + 2) "volumes:"
          print spaces(service_indent + 4) "- " need_geoip
          print spaces(service_indent + 4) "- " need_geosite
          changed = 1
        }
        print lines[i]
      }
      if (service_end == n + 1) {
        print spaces(service_indent + 2) "volumes:"
        print spaces(service_indent + 4) "- " need_geoip
        print spaces(service_indent + 4) "- " need_geosite
        changed = 1
      }
    }

    if (changed == 0) {
      exit 0
    }
  }' "${compose_file}" > "${tmp_file}" || {
    rm -f "${tmp_file}"
    die "Не удалось обновить volumes в compose через awk."
  }

  if ! cmp -s "${compose_file}" "${tmp_file}"; then
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      rm -f "${tmp_file}"
      log "DRY-RUN: в ${compose_file} будут добавлены недостающие volumes."
      return 0
    fi
    ensure_original_backup_file "${compose_file}"
    backup_file "${compose_file}"
    mv "${tmp_file}" "${compose_file}"
    log "Обновлен compose: ${compose_file}"
    return 0
  fi

  rm -f "${tmp_file}"
  log "Нужные volumes уже присутствуют в ${compose_file}"
  return 1
}

validate_compose_config() {
  local compose_file="$1"
  "${DOCKER_COMPOSE_CMD[@]}" -f "${compose_file}" config -q
}

download_geo_files() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: проверяю доступность ${GEOIP_URL}"
    probe_url "${GEOIP_URL}" || die "URL недоступен: ${GEOIP_URL}"
    log "DRY-RUN: проверяю доступность ${GEOSITE_URL}"
    probe_url "${GEOSITE_URL}" || die "URL недоступен: ${GEOSITE_URL}"
    log "DRY-RUN: оба URL доступны."
    return 1
  fi

  local changed=1
  local geo_changed=1
  local site_changed=1

  log "Скачиваю ${GEOIP_NAME}"
  if download_file_with_replace "${GEOIP_URL}" "${GEOIP_FILE}"; then
    geo_changed=0
  fi

  log "Скачиваю ${GEOSITE_NAME}"
  if download_file_with_replace "${GEOSITE_URL}" "${GEOSITE_FILE}"; then
    site_changed=0
  fi

  if [[ ${geo_changed} -eq 0 || ${site_changed} -eq 0 ]]; then
    changed=0
  fi

  return "${changed}"
}

restart_service() {
  local compose_file="$1"
  local attempt
  local cid
  local status
  local waited

  attempt=1
  while [[ "${attempt}" -le "${RESTART_RETRIES}" ]]; do
    cid="$("${DOCKER_COMPOSE_CMD[@]}" -f "${compose_file}" ps -q "${SERVICE_NAME}" 2>/dev/null || true)"
    waited=0

    # Если watchtower уже перезапускает контейнер, ждем стабильного состояния.
    while [[ -n "${cid}" ]]; do
      status="$(docker inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || true)"
      if [[ "${status}" != "restarting" ]]; then
        break
      fi

      if [[ "${waited}" -ge "${RESTART_WAIT_TIMEOUT}" ]]; then
        log "Контейнер ${SERVICE_NAME} долго в restarting (watchtower?), продолжаю с ретраем."
        break
      fi

      log "Контейнер ${SERVICE_NAME} в restarting, жду ${RESTART_RETRY_DELAY}с (попытка ${attempt}/${RESTART_RETRIES})"
      sleep "${RESTART_RETRY_DELAY}"
      waited=$((waited + RESTART_RETRY_DELAY))
      cid="$("${DOCKER_COMPOSE_CMD[@]}" -f "${compose_file}" ps -q "${SERVICE_NAME}" 2>/dev/null || true)"
    done

    log "Перезапускаю контейнер ${SERVICE_NAME} (попытка ${attempt}/${RESTART_RETRIES})"
    if "${DOCKER_COMPOSE_CMD[@]}" -f "${compose_file}" restart "${SERVICE_NAME}"; then
      return 0
    fi

    log "restart не удался (возможен конфликт с watchtower), жду ${RESTART_RETRY_DELAY}с"
    sleep "${RESTART_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done

  attempt=1
  while [[ "${attempt}" -le "${RESTART_RETRIES}" ]]; do
    log "Пробую up -d ${SERVICE_NAME} (попытка ${attempt}/${RESTART_RETRIES})"
    if "${DOCKER_COMPOSE_CMD[@]}" -f "${compose_file}" up -d "${SERVICE_NAME}"; then
      return 0
    fi
    log "up -d не удался, жду ${RESTART_RETRY_DELAY}с"
    sleep "${RESTART_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done

  die "Не удалось перезапустить ${SERVICE_NAME} после ${RESTART_RETRIES} попыток (возможен конфликт с watchtower)."
}

recreate_service() {
  local compose_file="$1"
  local attempt=1

  while [[ "${attempt}" -le "${RESTART_RETRIES}" ]]; do
    log "Пересоздаю ${SERVICE_NAME} для применения нового compose (попытка ${attempt}/${RESTART_RETRIES})"
    if "${DOCKER_COMPOSE_CMD[@]}" -f "${compose_file}" up -d --no-deps --force-recreate "${SERVICE_NAME}"; then
      return 0
    fi

    log "Не удалось пересоздать ${SERVICE_NAME}, жду ${RESTART_RETRY_DELAY}с"
    sleep "${RESTART_RETRY_DELAY}"
    attempt=$((attempt + 1))
  done

  die "Не удалось пересоздать ${SERVICE_NAME} после ${RESTART_RETRIES} попыток."
}

moscow_date() {
  if TZ=Europe/Moscow date +%F >/dev/null 2>&1; then
    TZ=Europe/Moscow date +%F
    return 0
  fi
  if date -u -d "+3 hour" +%F >/dev/null 2>&1; then
    date -u -d "+3 hour" +%F
    return 0
  fi
  if date -u -v+3H +%F >/dev/null 2>&1; then
    date -u -v+3H +%F
    return 0
  fi
  die "Не удалось вычислить дату по Москве (нет TZ базы и fallback date)."
}

should_run_now_by_moscow_time() {
  local hh mm
  if TZ=Europe/Moscow date +%H >/dev/null 2>&1; then
    hh="$(TZ=Europe/Moscow date +%H)"
    mm="$(TZ=Europe/Moscow date +%M)"
  elif date -u -d "+3 hour" +%H >/dev/null 2>&1; then
    hh="$(date -u -d "+3 hour" +%H)"
    mm="$(date -u -d "+3 hour" +%M)"
  elif date -u -v+3H +%H >/dev/null 2>&1; then
    hh="$(date -u -v+3H +%H)"
    mm="$(date -u -v+3H +%M)"
  else
    die "Не удалось вычислить московское время (нет TZ базы и fallback date)."
  fi

  if [[ "${hh}" == "05" && "${mm}" -ge 0 && "${mm}" -lt 15 ]]; then
    return 0
  fi

  return 1
}

run_once() {
  require_root
  require_cmd curl
  require_cmd awk
  require_cmd docker

  mkdir -p "${STATE_DIR}"
  acquire_lock
  compose_cmd

  local compose_file
  local compose_changed=1
  local files_changed=1

  compose_file="$(detect_compose_file)" || die "Не найден docker-compose.yml/.yaml в /opt/remnanode или /opt/remnawave"

  if ensure_volumes_in_compose "${compose_file}"; then
    compose_changed=0
  fi

  if ! validate_compose_config "${compose_file}"; then
    if [[ -n "${LAST_COMPOSE_BACKUP}" && -f "${LAST_COMPOSE_BACKUP}" ]]; then
      cp "${LAST_COMPOSE_BACKUP}" "${compose_file}"
      die "Проверка compose config не прошла. Файл восстановлен из backup: ${LAST_COMPOSE_BACKUP}"
    fi
    die "Проверка compose config не прошла. Backup не найден, проверьте YAML вручную."
  fi

  if download_geo_files; then
    files_changed=0
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "DRY-RUN: проверки завершены, изменения не применялись."
    return 0
  fi

  # Если меняли compose, нужен recreate (restart не применяет новые volumes).
  if [[ ${compose_changed} -eq 0 ]]; then
    recreate_service "${compose_file}"
  elif [[ ${files_changed} -eq 0 ]]; then
    restart_service "${compose_file}"
  else
    log "Изменений нет, перезапуск не требуется."
  fi

  printf '%s\n' "$(moscow_date)" > "${CRON_MARKER_FILE}"
  log "Готово."
}

scheduled_run() {
  require_root
  mkdir -p "${STATE_DIR}"
  acquire_lock

  local today marker
  today="$(moscow_date)"
  marker=""

  if [[ -f "${CRON_MARKER_FILE}" ]]; then
    marker="$(<"${CRON_MARKER_FILE}")"
  fi

  if [[ "${marker}" == "${today}" ]]; then
    log "Сегодня уже выполнялось (${today}), пропускаю."
    exit 0
  fi

  if ! should_run_now_by_moscow_time; then
    log "Сейчас не окно запуска 05:00-05:14 МСК, пропускаю."
    exit 0
  fi

  run_once
}

install_cron() {
  require_root
  require_cmd crontab
  require_cmd awk

  local current_cron cleaned
  local cron_job

  cron_job="0 * * * * ${SCRIPT_PATH} --scheduled-run >> ${CRON_LOG_FILE} 2>&1"

  current_cron="$(crontab -l 2>/dev/null || true)"
  cleaned="$(printf '%s\n' "${current_cron}" | awk -v b="${CRON_BEGIN}" -v e="${CRON_END}" '
    BEGIN {skip=0}
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip==0 {print}
  ')"

  {
    printf '%s\n' "${cleaned}"
    [[ -n "${cleaned}" ]] && printf '\n'
    printf '%s\n' "${CRON_BEGIN}"
    printf '%s\n' "${cron_job}"
    printf '%s\n' "${CRON_END}"
  } | crontab -

  log "Cron установлен: запуск каждый час, фактическое выполнение 05:00-05:14 МСК 1 раз в день."
}

usage() {
  cat <<'EOF'
Использование:
  remna-geo-updater.sh --run
  remna-geo-updater.sh --dry-run
  remna-geo-updater.sh --scheduled-run
  remna-geo-updater.sh --install-cron
  remna-geo-updater.sh --all

Опции:
  --run            Один цикл: volumes -> download -> restart (если были изменения).
  --dry-run        Проверка без изменений на диске и без перезапуска контейнера.
  --scheduled-run  Режим для cron: выполняет работу только в 05:00-05:14 МСК, один раз в сутки.
  --install-cron   Установить cron-задачу с hourly trigger.
  --all            Выполнить --run и затем --install-cron.

Переменные окружения:
  SERVICE_NAME   (default: remnanode)
  SHARE_DIR      (default: /opt/remnawave/xray/share)
  COMPOSE_FILE   (явный путь к compose, если авто-детект не подходит)
  SCRIPT_PATH    (default: /usr/local/bin/remna-geo-updater.sh)
  RESTART_RETRIES      (default: 8)
  RESTART_RETRY_DELAY  (default: 15)
  RESTART_WAIT_TIMEOUT (default: 180)
EOF
}

main() {
  case "${1:-}" in
    --run)
      run_once
      ;;
    --dry-run)
      DRY_RUN=1
      run_once
      ;;
    --scheduled-run)
      scheduled_run
      ;;
    --install-cron)
      install_cron
      ;;
    --all)
      run_once
      install_cron
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "${@}"
