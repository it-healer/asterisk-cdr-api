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
- Зарегистрирует и запустит systemd сервис

После установки в консоли будет выведен URL и API ключ.

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

| Переменная    | По умолчанию    | Описание              |
|---------------|-----------------|------------------------|
| `CDR_API_KEY` | `change-me-please` | Секретный ключ API  |
| `CDR_HOST`    | `0.0.0.0`       | Адрес для прослушивания |
| `CDR_PORT`    | `8000`          | Порт                  |

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

## Удаление

```bash
sudo bash scripts/uninstall.sh
```

Или одной строкой:

```bash
curl -fsSL https://raw.githubusercontent.com/it-healer/asterisk-cdr-api/main/scripts/uninstall.sh | sudo bash
```

---

## Публикация новой версии на PyPI

1. Обновите `version` в `pyproject.toml` и `asterisk_cdr_api/__init__.py`.
2. Создайте git-тег и пушните:

   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

3. GitHub Actions workflow `.github/workflows/publish.yml` сам соберёт пакет
   и опубликует его на PyPI через Trusted Publishing (без токенов).

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
