#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  Установщик Asterisk CDR API
#  Поддерживаемые ОС: Debian 11/12, Ubuntu 22.04/24.04
#  Идемпотентный: повторный запуск обновляет пакет и
#  переконфигурирует сервис, сохраняя существующий API ключ.
# ─────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="/opt/asterisk-cdr-api"
SERVICE_NAME="asterisk-cdr-api"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
PYPI_PACKAGE="asterisk-cdr-api"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Проверки ──────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Запустите скрипт от root: sudo bash install.sh"

command -v python3 >/dev/null || error "python3 не найден"
PY_VER=$(python3 -c 'import sys; print(sys.version_info.minor)')
[[ $PY_VER -ge 9 ]] || error "Нужен Python 3.9+, установлен 3.$PY_VER"

# ── Существующая установка ────────────────────────────────────
# Извлекаем значение Environment="KEY=VAL" из существующего unit-файла.
extract_env() {
    local key="$1"
    [[ -f "$SERVICE_FILE" ]] || return 0
    sed -n "s/^Environment=\"${key}=\(.*\)\"\$/\1/p" "$SERVICE_FILE" | head -n1
}

IS_UPGRADE=0
if [[ -f "$SERVICE_FILE" ]]; then
    IS_UPGRADE=1
    info "Обнаружена существующая установка — режим обновления"
fi

EXISTING_API_KEY=$(extract_env CDR_API_KEY || true)
EXISTING_HOST=$(extract_env CDR_HOST       || true)
EXISTING_PORT=$(extract_env CDR_PORT       || true)
EXISTING_ROOT_PATH=$(extract_env CDR_ROOT_PATH || true)

# ── Параметры HTTP сервера ────────────────────────────────────
# Дефолт = существующее значение из unit, иначе — заводская настройка.
DEFAULT_HOST="${EXISTING_HOST:-0.0.0.0}"
DEFAULT_PORT="${EXISTING_PORT:-8000}"
DEFAULT_ROOT_PATH="${EXISTING_ROOT_PATH:-}"

# Можно задать заранее через переменные окружения CDR_HOST / CDR_PORT / CDR_ROOT_PATH.
# Используется специальный синтаксис `${VAR-}` чтобы отличить "не задано" от "задано пустым".
CDR_HOST="${CDR_HOST-__unset__}"
CDR_PORT="${CDR_PORT-__unset__}"
CDR_ROOT_PATH="${CDR_ROOT_PATH-__unset__}"

# Спрашиваем только если есть терминал и значение не пришло через env
if [[ -t 0 ]]; then
    if [[ "$CDR_HOST" == "__unset__" ]]; then
        read -r -p "IP для прослушивания HTTP [${DEFAULT_HOST}]: " CDR_HOST || true
    fi
    if [[ "$CDR_PORT" == "__unset__" ]]; then
        read -r -p "Порт HTTP сервера [${DEFAULT_PORT}]: " CDR_PORT || true
    fi
    if [[ "$CDR_ROOT_PATH" == "__unset__" ]]; then
        prompt_default="${DEFAULT_ROOT_PATH:-пусто = нет}"
        read -r -p "URL-префикс за reverse-proxy, например /asterisk-cdr-api [${prompt_default}]: " CDR_ROOT_PATH || true
    fi
fi

# Если значение всё ещё "__unset__" (нет терминала и env не задан) или пустое после Enter — берём дефолт
[[ "$CDR_HOST" == "__unset__" || -z "$CDR_HOST" ]] && CDR_HOST="$DEFAULT_HOST"
[[ "$CDR_PORT" == "__unset__" || -z "$CDR_PORT" ]] && CDR_PORT="$DEFAULT_PORT"
[[ "$CDR_ROOT_PATH" == "__unset__"           ]] && CDR_ROOT_PATH="$DEFAULT_ROOT_PATH"

# Нормализация префикса: ведущий /, без концевого /
if [[ -n "$CDR_ROOT_PATH" ]]; then
    [[ "$CDR_ROOT_PATH" == /* ]] || CDR_ROOT_PATH="/$CDR_ROOT_PATH"
    CDR_ROOT_PATH="${CDR_ROOT_PATH%/}"
fi

# Валидация порта
if ! [[ "$CDR_PORT" =~ ^[0-9]+$ ]] || (( CDR_PORT < 1 || CDR_PORT > 65535 )); then
    error "Неверный порт: $CDR_PORT (допустимо 1–65535)"
fi

info "HTTP сервер: ${CDR_HOST}:${CDR_PORT}${CDR_ROOT_PATH:+, префикс ${CDR_ROOT_PATH}}"

# ── Зависимости ───────────────────────────────────────────────
info "Устанавливаем системные зависимости..."
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip curl

# ── Директория ────────────────────────────────────────────────
info "Готовим $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

# ── Виртуальное окружение ─────────────────────────────────────
if [[ ! -x "$INSTALL_DIR/venv/bin/pip" ]]; then
    info "Создаём виртуальное окружение Python..."
    python3 -m venv "$INSTALL_DIR/venv"
fi

# ── Установка / обновление пакета ─────────────────────────────
info "Устанавливаем/обновляем $PYPI_PACKAGE из PyPI..."
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade "$PYPI_PACKAGE"

# ── Systemd сервис ────────────────────────────────────────────
info "Записываем systemd сервис..."

# API ключ: сохраняем существующий, иначе генерируем новый
if [[ -n "$EXISTING_API_KEY" ]]; then
    API_KEY="$EXISTING_API_KEY"
    API_KEY_KEPT=1
else
    API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    API_KEY_KEPT=0
fi

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Asterisk CDR API
After=network.target mariadb.service mysql.service

[Service]
Type=simple
User=asterisk
Group=asterisk
Environment="CDR_API_KEY=${API_KEY}"
Environment="CDR_HOST=${CDR_HOST}"
Environment="CDR_PORT=${CDR_PORT}"
Environment="CDR_ROOT_PATH=${CDR_ROOT_PATH}"
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/asterisk-cdr-api
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
systemctl restart "$SERVICE_NAME"

# ── Проверка ──────────────────────────────────────────────────
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Сервис запущен успешно!"
else
    warn "Сервис не запустился. Смотрите логи: journalctl -u $SERVICE_NAME -n 50"
fi

# ── Итог ──────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
if (( IS_UPGRADE )); then
    echo -e "${GREEN}  Asterisk CDR API обновлён!${NC}"
else
    echo -e "${GREEN}  Asterisk CDR API установлен!${NC}"
fi
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
if [[ "$CDR_HOST" == "0.0.0.0" || "$CDR_HOST" == "::" ]]; then
    DISPLAY_HOST=$(hostname -I | awk '{print $1}')
else
    DISPLAY_HOST="$CDR_HOST"
fi
echo -e "  URL:      ${YELLOW}http://${DISPLAY_HOST}:${CDR_PORT}${CDR_ROOT_PATH}${NC}"
echo -e "  Swagger:  ${YELLOW}http://${DISPLAY_HOST}:${CDR_PORT}${CDR_ROOT_PATH}/docs${NC}"
if (( API_KEY_KEPT )); then
    echo -e "  API Key:  ${YELLOW}${API_KEY}${NC} (сохранён из существующей установки)"
else
    echo -e "  API Key:  ${YELLOW}${API_KEY}${NC}"
    echo ""
    echo -e "  Сохраните API ключ! Он записан в:"
    echo -e "  ${YELLOW}${SERVICE_FILE}${NC}"
fi
echo ""
echo "  Управление сервисом:"
echo "    systemctl status  $SERVICE_NAME"
echo "    systemctl restart $SERVICE_NAME"
echo "    journalctl -u $SERVICE_NAME -f"
echo ""
echo "  Изменить настройки:"
echo "    nano $SERVICE_FILE"
echo "    systemctl daemon-reload && systemctl restart $SERVICE_NAME"
echo ""
