# asterisk-cdr-api

[![PyPI](https://img.shields.io/pypi/v/asterisk-cdr-api.svg)](https://pypi.org/project/asterisk-cdr-api/)
[![Python](https://img.shields.io/pypi/pyversions/asterisk-cdr-api.svg)](https://pypi.org/project/asterisk-cdr-api/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

REST API для Asterisk CDR — список звонков с фильтрами, сортировкой и скачиванием записей.

Доступы к БД читаются **автоматически** из конфигов Asterisk:
`/etc/asterisk/cdr_adaptive_odbc.conf` → `res_odbc.conf` → `/etc/odbc.ini`

---

## Быстрая установка (Debian/Ubuntu)

```bash
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/install.sh | sudo bash
```

Скрипт сам:
- Установит Python-зависимости
- Создаст virtualenv в `/opt/asterisk-cdr-api/`
- Сгенерирует случайный API ключ
- Спросит IP и порт HTTP сервера (по умолчанию `0.0.0.0:8000`) и сохранит их в systemd сервис
- Зарегистрирует и запустит systemd сервис

После установки в консоли будет выведен URL и API ключ.

### Неинтерактивная установка

Если запускаете через пайп (`curl … | sudo bash`), интерактивный ввод недоступен — передайте параметры через переменные окружения:

```bash
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/install.sh \
  | sudo CDR_HOST=127.0.0.1 CDR_PORT=9000 bash
```

Без переменных будут использованы значения по умолчанию `0.0.0.0:8000`.

Изменить IP/порт после установки:

```bash
sudo nano /etc/systemd/system/asterisk-cdr-api.service
# Измените строки:
#   Environment="CDR_HOST=0.0.0.0"
#   Environment="CDR_PORT=8000"
sudo systemctl daemon-reload && sudo systemctl restart asterisk-cdr-api
```

---

## Установка вручную

```bash
# 1. Системные зависимости
sudo apt-get install python3-venv python3-pip -y

# 2. Виртуальное окружение
sudo mkdir -p /opt/asterisk-cdr-api
sudo python3 -m venv /opt/asterisk-cdr-api/venv

# 3. Установка пакета с PyPI
sudo /opt/asterisk-cdr-api/venv/bin/pip install asterisk-cdr-api

# 4. Запуск для проверки
sudo CDR_API_KEY="мой-ключ" /opt/asterisk-cdr-api/venv/bin/asterisk-cdr-api
```

---

## Настройка systemd

Скопировать сервис-файл:

```bash
sudo cp debian/asterisk-cdr-api.service /etc/systemd/system/
```

Задать API ключ:

```bash
sudo nano /etc/systemd/system/asterisk-cdr-api.service
# Изменить строку:
# Environment="CDR_API_KEY=change-me-please"
```

Запустить:

```bash
sudo systemctl daemon-reload
sudo systemctl enable asterisk-cdr-api
sudo systemctl start  asterisk-cdr-api
sudo systemctl status asterisk-cdr-api
```

Логи:

```bash
journalctl -u asterisk-cdr-api -f
```

---

## Переменные окружения

| Переменная       | По умолчанию       | Описание                                          |
|------------------|--------------------|---------------------------------------------------|
| `CDR_API_KEY`    | `change-me-please` | Секретный ключ API                                |
| `CDR_HOST`       | `0.0.0.0`          | Адрес для прослушивания                           |
| `CDR_PORT`       | `8000`             | Порт                                              |
| `CDR_ROOT_PATH`  | (пусто)            | URL-префикс за reverse-proxy, например `/asterisk-cdr-api` |

---

## API

Все запросы (кроме `/health`) требуют заголовок `X-Api-Key`.

### Swagger UI

```
http://SERVER:8000/docs
```

### Эндпоинты

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/calls` | Список звонков с фильтрами |
| GET | `/calls/{id}` | Один звонок |
| GET | `/calls/{id}/download` | Скачать MP3 |
| GET | `/stats` | Статистика |
| GET | `/config` | Текущая конфигурация |
| GET | `/health` | Проверка работы |

### Параметры `/calls`

| Параметр | Описание | Пример |
|---|---|---|
| `src` | Номер звонящего | `613610` |
| `dst` | Номер назначения | `7903` |
| `disposition` | Статус | `ANSWERED` |
| `date_from` | Дата от | `2026-05-01` |
| `date_to` | Дата до | `2026-05-20` |
| `has_recording` | Есть запись | `true` |
| `order_by` | Сортировка | `calldate`, `billsec` |
| `order_dir` | Направление | `asc`, `desc` |
| `limit` | Записей на стр. | `50` |
| `offset` | Смещение | `0` |

### Примеры запросов

```bash
# Список отвеченных звонков за май
curl -H "X-Api-Key: мой-ключ" \
  "http://SERVER:8000/calls?disposition=ANSWERED&date_from=2026-05-01"

# Звонки с конкретного номера, с записями
curl -H "X-Api-Key: мой-ключ" \
  "http://SERVER:8000/calls?src=613610&has_recording=true"

# Скачать запись звонка с id=42
curl -H "X-Api-Key: мой-ключ" \
  "http://SERVER:8000/calls/42/download" -o call_42.mp3

# Статистика за неделю
curl -H "X-Api-Key: мой-ключ" \
  "http://SERVER:8000/stats?date_from=2026-05-13"

# Что прочиталось из конфигов
curl -H "X-Api-Key: мой-ключ" \
  "http://SERVER:8000/config"
```

---

## Обновление на боевом сервере

После того как новая версия опубликована на PyPI:

```bash
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/update.sh | sudo bash
```

Скрипт `install.sh` тоже идемпотентен — если запустить его повторно на уже установленной системе, он обновит пакет, сохранит существующий API ключ и подхватит существующие `CDR_HOST`/`CDR_PORT`/`CDR_ROOT_PATH` как дефолты. Это удобно, если нужно одновременно обновить версию и поменять конфигурацию (например, добавить URL-префикс):

```bash
# Сменить только префикс, остальное оставить как есть
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/install.sh \
  | sudo CDR_ROOT_PATH=/asterisk-cdr-api bash

# Или сменить всё сразу
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/install.sh \
  | sudo CDR_HOST=127.0.0.1 CDR_PORT=9000 CDR_ROOT_PATH=/asterisk-cdr-api bash
```

Или вручную:

```bash
sudo /opt/asterisk-cdr-api/venv/bin/pip install --upgrade asterisk-cdr-api
sudo systemctl restart asterisk-cdr-api
```

Проверить установленную версию:

```bash
curl -s http://localhost:8000/health
# {"status":"ok","service":"Asterisk CDR API","version":"1.0.1"}
```

---

## Удаление

```bash
sudo bash scripts/uninstall.sh
```

Или одной строкой:

```bash
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/uninstall.sh | sudo bash
```

---

## Выпуск новой версии (для разработчика)

Версия пакета — единственный источник истины в `asterisk_cdr_api/__init__.py` (`__version__`); `pyproject.toml` подтягивает её через `dynamic`.

Самый простой путь — скрипт `scripts/bump.sh`:

```bash
./scripts/bump.sh patch   # 1.0.0 → 1.0.1
./scripts/bump.sh minor   # 1.0.0 → 1.1.0
./scripts/bump.sh major   # 1.0.0 → 2.0.0
./scripts/bump.sh 1.2.3   # явная версия
```

Скрипт:
1. Поднимает `__version__`.
2. Делает `git commit -m "release: X.Y.Z"`.
3. Создаёт тег `vX.Y.Z` и пушит его.

GitHub Actions workflow `.github/workflows/publish.yml` подхватывает тег, собирает пакет и публикует его на PyPI через Trusted Publishing (без токенов).

Первоначальная настройка Trusted Publisher на PyPI: `Account → Publishing → Add a new pending publisher`

| Поле | Значение |
|---|---|
| PyPI Project Name | `asterisk-cdr-api` |
| Owner | `it-healer` |
| Repository name | `asterisk-cdr-api` |
| Workflow name | `publish.yml` |
| Environment name | `pypi` |

---

## Локальная сборка пакета

```bash
python -m pip install --upgrade build
python -m build
# В каталоге dist/ появятся файлы:
#   asterisk_cdr_api-1.0.0-py3-none-any.whl
#   asterisk_cdr_api-1.0.0.tar.gz
```

---

## Лицензия

MIT — см. [LICENSE](LICENSE).
