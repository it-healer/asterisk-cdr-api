#!/usr/bin/env bash
# Удаление Asterisk CDR API
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Нужен root"; exit 1; }

systemctl stop    asterisk-cdr-api 2>/dev/null || true
systemctl disable asterisk-cdr-api 2>/dev/null || true
rm -f /etc/systemd/system/asterisk-cdr-api.service
systemctl daemon-reload

rm -rf /opt/asterisk-cdr-api

echo "Asterisk CDR API удалён."
