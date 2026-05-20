#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  Установщик Asterisk CDR API
#  Поддерживаемые ОС: Debian 11/12, Ubuntu 22.04/24.04
# ─────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="/opt/asterisk-cdr-api"
SERVICE_NAME="asterisk-cdr-api"
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

# ── Зависимости ───────────────────────────────────────────────
info "Устанавливаем системные зависимости..."
apt-get update -qq
apt-get install -y -qq python3-venv python3-pip curl

# ── Директория ────────────────────────────────────────────────
info "Создаём $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

# ── Виртуальное окружение ─────────────────────────────────────
info "Создаём виртуальное окружение Python..."
python3 -m venv "$INSTALL_DIR/venv"

# ── Установка пакета ──────────────────────────────────────────
info "Устанавливаем $PYPI_PACKAGE из PyPI..."
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --quiet "$PYPI_PACKAGE"

# ── Systemd сервис ────────────────────────────────────────────
info "Устанавливаем systemd сервис..."

# Генерируем случайный API ключ
API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Asterisk CDR API
After=network.target mariadb.service mysql.service

[Service]
Type=simple
User=asterisk
Group=asterisk
Environment="CDR_API_KEY=${API_KEY}"
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
systemctl enable "$SERVICE_NAME"
systemctl start  "$SERVICE_NAME"

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
echo -e "${GREEN}  Asterisk CDR API установлен!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "  URL:      ${YELLOW}http://$(hostname -I | awk '{print $1}'):8000${NC}"
echo -e "  Swagger:  ${YELLOW}http://$(hostname -I | awk '{print $1}'):8000/docs${NC}"
echo -e "  API Key:  ${YELLOW}${API_KEY}${NC}"
echo ""
echo -e "  Сохраните API ключ! Он записан в:"
echo -e "  ${YELLOW}/etc/systemd/system/${SERVICE_NAME}.service${NC}"
echo ""
echo "  Управление сервисом:"
echo "    systemctl status  $SERVICE_NAME"
echo "    systemctl restart $SERVICE_NAME"
echo "    journalctl -u $SERVICE_NAME -f"
echo ""
echo "  Изменить API ключ:"
echo "    nano /etc/systemd/system/${SERVICE_NAME}.service"
echo "    systemctl daemon-reload && systemctl restart $SERVICE_NAME"
echo ""
