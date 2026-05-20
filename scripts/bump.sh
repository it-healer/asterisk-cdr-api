#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  Релиз новой версии Asterisk CDR API
#
#  Использование:
#    ./scripts/bump.sh patch   # 1.0.0 → 1.0.1  (бэгфиксы)
#    ./scripts/bump.sh minor   # 1.0.0 → 1.1.0  (новые фичи)
#    ./scripts/bump.sh major   # 1.0.0 → 2.0.0  (ломающие изменения)
#    ./scripts/bump.sh 1.2.3   # явная версия
#
#  Скрипт:
#    1. Меняет __version__ в asterisk_cdr_api/__init__.py
#    2. Делает git commit + tag vX.Y.Z
#    3. Пушит коммит и тег — GitHub Actions опубликует на PyPI
# ─────────────────────────────────────────────────────────────
set -euo pipefail

INIT_FILE="asterisk_cdr_api/__init__.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
error() { echo -e "${RED}[\xe2\x9c\x97]${NC} $*"; exit 1; }

[[ -f "$INIT_FILE" ]] || error "Запускайте из корня репозитория"
[[ $# -eq 1 ]]        || error "Использование: $0 patch|minor|major|X.Y.Z"

# Проверки рабочего дерева
if [[ -n "$(git status --porcelain)" ]]; then
    error "Рабочее дерево грязное. Закоммитьте или отстешьте изменения."
fi

CUR=$(grep -E '^__version__' "$INIT_FILE" | sed -E 's/.*"([^"]+)".*/\1/')
[[ -n "$CUR" ]] || error "Не нашёл __version__ в $INIT_FILE"

IFS='.' read -r MAJ MIN PAT <<< "$CUR"

case "$1" in
    patch) NEW="${MAJ}.${MIN}.$((PAT + 1))" ;;
    minor) NEW="${MAJ}.$((MIN + 1)).0" ;;
    major) NEW="$((MAJ + 1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
    *) error "Неверный аргумент. Используйте: patch | minor | major | X.Y.Z" ;;
esac

info "Версия: ${YELLOW}${CUR}${NC} → ${GREEN}${NEW}${NC}"

# Проверка, что тег ещё не существует
if git rev-parse "v${NEW}" >/dev/null 2>&1; then
    error "Тег v${NEW} уже существует"
fi

# Подтверждение
read -rp "Продолжить? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { info "Отменено"; exit 0; }

# Меняем версию
sed -i.bak -E "s/^__version__ *= *\"[^\"]+\"/__version__ = \"${NEW}\"/" "$INIT_FILE"
rm -f "${INIT_FILE}.bak"

# Коммит + тег
git add "$INIT_FILE"
git commit -m "release: ${NEW}"
git tag -a "v${NEW}" -m "Release ${NEW}"

info "Локально готово. Пушим..."
git push
git push origin "v${NEW}"

info "Тег v${NEW} запушен. GitHub Actions опубликует пакет на PyPI."
info "Прогресс: https://github.com/it-healer/asterisk-cdr-api/actions"
