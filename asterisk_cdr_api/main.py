"""
Asterisk CDR API Service
Читает доступы к БД автоматически из конфигов Asterisk.
"""

from fastapi import FastAPI, Query, HTTPException, Depends, Header
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from typing import Optional
from datetime import datetime, date
import configparser
import pymysql
import pymysql.cursors
import os

from . import __version__


# ══════════════════════════════════════════════════════════════
#  Чтение конфигов Asterisk
# ══════════════════════════════════════════════════════════════

def _ini(path: str) -> configparser.ConfigParser:
    """Загружает INI-файл, приводя синтаксис Asterisk (=>) к стандартному."""
    content = ""
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                content += line.replace(" => ", " = ", 1)
    except FileNotFoundError:
        pass
    parser = configparser.ConfigParser()
    parser.read_string(content)
    return parser


def _find_cdr_connection() -> str:
    cfg = _ini("/etc/asterisk/cdr_adaptive_odbc.conf")
    for section in cfg.sections():
        conn = cfg.get(section, "connection", fallback=None)
        if conn:
            return conn.strip()
    return "asterisk"


def _find_cdr_table() -> str:
    cfg = _ini("/etc/asterisk/cdr_adaptive_odbc.conf")
    for section in cfg.sections():
        tbl = cfg.get(section, "table", fallback=None)
        if tbl:
            return tbl.strip()
    return "cdr"


def _resolve_dsn(conn_name: str) -> str:
    cfg = _ini("/etc/asterisk/res_odbc.conf")
    for s in cfg.sections():
        if s.lower() == conn_name.lower():
            return cfg.get(s, "dsn", fallback=conn_name).strip()
    return conn_name


def _read_odbc_ini(dsn: str) -> dict:
    cfg = _ini("/etc/odbc.ini")
    for s in cfg.sections():
        if s.lower() == dsn.lower():
            return {k: v for k, v in cfg.items(s)}
    return {}


def _read_res_odbc_creds(conn_name: str) -> dict:
    cfg = _ini("/etc/asterisk/res_odbc.conf")
    for s in cfg.sections():
        if s.lower() == conn_name.lower():
            return {
                "username": cfg.get(s, "username", fallback=None),
                "password": cfg.get(s, "password", fallback=None),
            }
    return {}


def _find_recordings_dir() -> str:
    cfg = _ini("/etc/asterisk/asterisk.conf")
    spool = cfg.get("directories", "astspooldir", fallback="/var/spool/asterisk")
    return os.path.join(spool.strip(), "monitor")


def load_db_config() -> dict:
    conn_name = _find_cdr_connection()
    dsn_name  = _resolve_dsn(conn_name)
    odbc      = _read_odbc_ini(dsn_name)
    creds     = _read_res_odbc_creds(conn_name)

    host     = odbc.get("server", odbc.get("host", "127.0.0.1")).strip()
    database = odbc.get("database", odbc.get("dbname", "asterisk")).strip()
    port_raw = odbc.get("port", "3306").strip().lstrip("#").strip()
    port     = int(port_raw) if port_raw.isdigit() else 3306
    user     = (creds.get("username") or odbc.get("username") or "asterisk").strip()
    password = (creds.get("password") or odbc.get("password") or "").strip()

    return {
        "host":      host,
        "port":      port,
        "user":      user,
        "password":  password,
        "database":  database,
        "table":     _find_cdr_table(),
        "rec_dir":   _find_recordings_dir(),
        "conn_name": conn_name,
        "dsn_name":  dsn_name,
    }


# ══════════════════════════════════════════════════════════════
#  Инициализация при старте
# ══════════════════════════════════════════════════════════════

DB_CFG  = load_db_config()
API_KEY = os.environ.get("CDR_API_KEY", "change-me-please")


def _detect_schema(cfg: dict) -> dict:
    """
    Определяет фактические колонки CDR-таблицы и подбирает имена для:
      - первичного ключа (id | uniqueid)
      - колонки имени файла записи (recordingfile | filename | userfield)
    Разные сборки Asterisk (чистый, FreePBX, AsteriskNOW) используют разные схемы.
    """
    conn = pymysql.connect(
        host=cfg["host"], port=cfg["port"],
        user=cfg["user"], password=cfg["password"],
        database=cfg["database"],
        cursorclass=pymysql.cursors.DictCursor,
        charset="utf8mb4",
    )
    try:
        with conn.cursor() as cur:
            cur.execute(f"SHOW COLUMNS FROM `{cfg['table']}`")
            cols = {row["Field"] for row in cur.fetchall()}
    finally:
        conn.close()

    pk = "id" if "id" in cols else "uniqueid"

    rec_col = None
    for candidate in ("recordingfile", "filename", "userfield"):
        if candidate in cols:
            rec_col = candidate
            break

    return {"columns": cols, "pk": pk, "recording_col": rec_col}


try:
    SCHEMA = _detect_schema(DB_CFG)
except Exception as e:
    print(f"  [!] Не удалось прочитать схему CDR-таблицы: {e}")
    SCHEMA = {"columns": set(), "pk": "uniqueid", "recording_col": None}


print("=" * 55)
print("  Asterisk CDR API")
print("=" * 55)
print(f"  host      : {DB_CFG['host']}:{DB_CFG['port']}")
print(f"  database  : {DB_CFG['database']}")
print(f"  user      : {DB_CFG['user']}")
print(f"  table     : {DB_CFG['table']}")
print(f"  recordings: {DB_CFG['rec_dir']}")
print(f"  pk column : {SCHEMA['pk']}")
print(f"  rec column: {SCHEMA['recording_col'] or '(не найдена)'}")
if API_KEY == "change-me-please":
    print("  [!] CDR_API_KEY не задан — установите переменную окружения!")
print("=" * 55)


# ══════════════════════════════════════════════════════════════
#  FastAPI
# ══════════════════════════════════════════════════════════════

app = FastAPI(
    title="Asterisk CDR API",
    description="REST API для CDR Asterisk — список звонков, фильтры, скачивание записей",
    version=__version__,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db():
    conn = pymysql.connect(
        host=DB_CFG["host"],
        port=DB_CFG["port"],
        user=DB_CFG["user"],
        password=DB_CFG["password"],
        database=DB_CFG["database"],
        cursorclass=pymysql.cursors.DictCursor,
        charset="utf8mb4",
    )
    try:
        yield conn
    finally:
        conn.close()


def verify_api_key(x_api_key: str = Header(..., description="Секретный ключ API")):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


# ─────────────────────────────────────────
#  GET /calls
# ─────────────────────────────────────────
@app.get("/calls", summary="Список звонков", dependencies=[Depends(verify_api_key)])
def get_calls(
    src: Optional[str]            = Query(None, description="Номер звонящего (частичное совпадение)"),
    dst: Optional[str]            = Query(None, description="Номер назначения (частичное совпадение)"),
    disposition: Optional[str]    = Query(None, description="ANSWERED | NO ANSWER | BUSY | FAILED"),
    date_from: Optional[date]     = Query(None, description="Дата от (YYYY-MM-DD)"),
    date_to: Optional[date]       = Query(None, description="Дата до (YYYY-MM-DD)"),
    has_recording: Optional[bool] = Query(None, description="true — только с записью"),
    order_by:  str = Query("calldate", description="calldate | duration | billsec | src | dst"),
    order_dir: str = Query("desc",     description="asc | desc"),
    limit:  int = Query(50, ge=1, le=500, description="Записей на страницу"),
    offset: int = Query(0,  ge=0,         description="Смещение для пагинации"),
    db=Depends(get_db),
):
    allowed = {"calldate", "duration", "billsec", "src", "dst"}
    if order_by not in allowed:
        raise HTTPException(400, f"order_by: допустимы {allowed}")
    direction = "DESC" if order_dir.lower() == "desc" else "ASC"
    table   = DB_CFG["table"]
    pk      = SCHEMA["pk"]
    rec_col = SCHEMA["recording_col"]

    where, params = ["1=1"], []
    if src:
        where.append("src LIKE %s");          params.append(f"%{src}%")
    if dst:
        where.append("dst LIKE %s");          params.append(f"%{dst}%")
    if disposition:
        where.append("disposition = %s");     params.append(disposition.upper())
    if date_from:
        where.append("DATE(calldate) >= %s"); params.append(str(date_from))
    if date_to:
        where.append("DATE(calldate) <= %s"); params.append(str(date_to))
    if has_recording is True:
        if rec_col:
            where.append(f"`{rec_col}` IS NOT NULL AND `{rec_col}` != ''")
        else:
            where.append("0=1")  # колонки записи в схеме нет — пустой результат
    elif has_recording is False:
        if rec_col:
            where.append(f"(`{rec_col}` IS NULL OR `{rec_col}` = '')")

    # Список колонок для SELECT — только те, что реально есть
    base_cols = ["calldate", "src", "dst", "duration", "billsec",
                 "disposition", "channel", "dstchannel", "uniqueid"]
    select_cols = [pk] + [c for c in base_cols if c in SCHEMA["columns"] and c != pk]
    if rec_col:
        select_cols.append(rec_col)
    select_list = ", ".join(f"`{c}`" for c in select_cols)

    w = " AND ".join(where)
    with db.cursor() as cur:
        cur.execute(f"SELECT COUNT(*) as total FROM `{table}` WHERE {w}", params)
        total = cur.fetchone()["total"]
        cur.execute(f"""
            SELECT {select_list}
            FROM `{table}` WHERE {w}
            ORDER BY {order_by} {direction}
            LIMIT %s OFFSET %s
        """, params + [limit, offset])
        rows = cur.fetchall()

    for row in rows:
        if isinstance(row.get("calldate"), datetime):
            row["calldate"] = row["calldate"].isoformat()
        # Унифицированные поля для клиента
        row["id"] = row.get(pk)
        row["recording_file"] = row.get(rec_col) if rec_col else None
        row["has_recording"]  = bool(row["recording_file"])

    return {"total": total, "limit": limit, "offset": offset, "calls": rows}


# ─────────────────────────────────────────
#  GET /calls/{id}
# ─────────────────────────────────────────
@app.get("/calls/{call_id}", summary="Один звонок", dependencies=[Depends(verify_api_key)])
def get_call(call_id: str, db=Depends(get_db)):
    pk = SCHEMA["pk"]
    with db.cursor() as cur:
        cur.execute(f"SELECT * FROM `{DB_CFG['table']}` WHERE `{pk}` = %s", (call_id,))
        row = cur.fetchone()
    if not row:
        raise HTTPException(404, "Звонок не найден")
    if isinstance(row.get("calldate"), datetime):
        row["calldate"] = row["calldate"].isoformat()
    row["id"] = row.get(pk)
    rec_col = SCHEMA["recording_col"]
    row["recording_file"] = row.get(rec_col) if rec_col else None
    row["has_recording"]  = bool(row["recording_file"])
    return row


# ─────────────────────────────────────────
#  GET /calls/{id}/download
# ─────────────────────────────────────────
@app.get("/calls/{call_id}/download", summary="Скачать запись", dependencies=[Depends(verify_api_key)])
def download_recording(call_id: str, db=Depends(get_db)):
    rec_col = SCHEMA["recording_col"]
    if not rec_col:
        raise HTTPException(404, "В CDR-таблице нет колонки имени файла записи")
    pk = SCHEMA["pk"]

    with db.cursor() as cur:
        cur.execute(
            f"SELECT `{rec_col}` AS rec FROM `{DB_CFG['table']}` WHERE `{pk}` = %s",
            (call_id,),
        )
        row = cur.fetchone()
    if not row:
        raise HTTPException(404, "Звонок не найден")
    rec_name = row.get("rec")
    if not rec_name:
        raise HTTPException(404, "Запись для этого звонка отсутствует")

    filepath = os.path.join(DB_CFG["rec_dir"], rec_name)
    if not os.path.exists(filepath):
        raise HTTPException(404, f"Файл не найден: {rec_name}")

    ext = os.path.splitext(filepath)[1].lower()
    media_type = {
        ".wav": "audio/wav",
        ".mp3": "audio/mpeg",
        ".ogg": "audio/ogg",
        ".gsm": "audio/gsm",
    }.get(ext, "application/octet-stream")

    return FileResponse(
        path=filepath,
        media_type=media_type,
        filename=os.path.basename(filepath),
    )


# ─────────────────────────────────────────
#  GET /stats
# ─────────────────────────────────────────
@app.get("/stats", summary="Статистика звонков", dependencies=[Depends(verify_api_key)])
def get_stats(
    date_from: Optional[date] = Query(None),
    date_to:   Optional[date] = Query(None),
    db=Depends(get_db),
):
    table = DB_CFG["table"]
    where, params = ["1=1"], []
    if date_from:
        where.append("DATE(calldate) >= %s"); params.append(str(date_from))
    if date_to:
        where.append("DATE(calldate) <= %s"); params.append(str(date_to))
    w = " AND ".join(where)

    with db.cursor() as cur:
        cur.execute(f"""
            SELECT
                COUNT(*)  as total,
                SUM(CASE WHEN disposition='ANSWERED'  THEN 1 ELSE 0 END) as answered,
                SUM(CASE WHEN disposition='FAILED'    THEN 1 ELSE 0 END) as failed,
                SUM(CASE WHEN disposition='BUSY'      THEN 1 ELSE 0 END) as busy,
                SUM(CASE WHEN disposition='NO ANSWER' THEN 1 ELSE 0 END) as no_answer,
                AVG(CASE WHEN disposition='ANSWERED'  THEN billsec END)  as avg_duration,
                MAX(billsec) as max_duration,
                SUM(billsec) as total_billsec
            FROM `{table}` WHERE {w}
        """, params)
        stats = cur.fetchone()

    if stats.get("avg_duration"):
        stats["avg_duration"] = round(float(stats["avg_duration"]), 1)
    return stats


# ─────────────────────────────────────────
#  GET /config  — что прочитали из конфигов
# ─────────────────────────────────────────
@app.get("/config", summary="Текущая конфигурация", dependencies=[Depends(verify_api_key)])
def show_config():
    return {
        "source_files":     [
            "/etc/asterisk/cdr_adaptive_odbc.conf",
            "/etc/asterisk/res_odbc.conf",
            "/etc/odbc.ini",
            "/etc/asterisk/asterisk.conf",
        ],
        "connection_name":  DB_CFG["conn_name"],
        "dsn_name":         DB_CFG["dsn_name"],
        "db_host":          DB_CFG["host"],
        "db_port":          DB_CFG["port"],
        "db_name":          DB_CFG["database"],
        "db_user":          DB_CFG["user"],
        "cdr_table":        DB_CFG["table"],
        "recordings_dir":   DB_CFG["rec_dir"],
        "pk_column":        SCHEMA["pk"],
        "recording_column": SCHEMA["recording_col"],
        "cdr_columns":      sorted(SCHEMA["columns"]),
    }


# ─────────────────────────────────────────
#  GET /health
# ─────────────────────────────────────────
@app.get("/health", summary="Проверка работы")
def health():
    return {"status": "ok", "service": "Asterisk CDR API", "version": __version__}


# ─────────────────────────────────────────
#  Точка входа для CLI
# ─────────────────────────────────────────
def run():
    import uvicorn
    host = os.environ.get("CDR_HOST", "0.0.0.0")
    port = int(os.environ.get("CDR_PORT", "8000"))
    uvicorn.run("asterisk_cdr_api.main:app", host=host, port=port, reload=False)


if __name__ == "__main__":
    run()
