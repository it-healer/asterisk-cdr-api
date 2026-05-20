#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  Обновление Asterisk CDR API до последней версии с PyPI
# ─────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR="/opt/asterisk-cdr-api"
SERVICE_NAME="asterisk-cdr-api"
PYPI_PACKAGE="asterisk-cdr-api"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[\xe2\x9c\x97]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Запустите скрипт от root: sudo bash update.sh"
[[ -x "$INSTALL_DIR/venv/bin/pip" ]] || error "$INSTALL_DIR/venv не найден — сначала install.sh"

# Текущая версия
CUR_VER=$("$INSTALL_DIR/venv/bin/pip" show "$PYPI_PACKAGE" 2>/dev/null | awk '/^Version:/ {print $2}')
info "Текущая версия: ${CUR_VER:-неизвестна}"

# Обновление
info "Скачиваем последнюю версию с PyPI..."
"$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade "$PYPI_PACKAGE"

NEW_VER=$("$INSTALL_DIR/venv/bin/pip" show "$PYPI_PACKAGE" | awk '/^Version:/ {print $2}')
info "Установленная версия: ${NEW_VER}"

if [[ "$CUR_VER" == "$NEW_VER" ]]; then
    info "Уже последняя версия — перезапуск не требуется."
    exit 0
fi

info "Перезапускаем сервис..."
systemctl restart "$SERVICE_NAME"

sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Готово: $CUR_VER → $NEW_VER"
else
    warn "Сервис не запустился. journalctl -u $SERVICE_NAME -n 50"
    exit 1
fi
