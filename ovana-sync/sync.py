#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import random
import sqlite3
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

import requests

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib  # type: ignore

PROGRAM_DATA = os.environ.get("PROGRAMDATA", r"C:\ProgramData")
OVANA_DIR = os.path.join(PROGRAM_DATA, "Ovana")
DB_PATH = os.path.join(OVANA_DIR, "sync.db")
LOG_DIR = os.path.join(OVANA_DIR, "logs")
LOG_FILE = os.path.join(LOG_DIR, "ovana-sync.log")
CONFIG_PATH = os.environ.get("OVANA_CONFIG", os.path.join(OVANA_DIR, "config.toml"))

LOCAL_API = os.environ.get("OVANA_LOCAL_API", "http://127.0.0.1:5600/api/0")
DEFAULT_BATCH_SIZE = 500
DEFAULT_INTERVAL = 60  # seconds
DEFAULT_BACKOFF_MAX = 900  # seconds
DEFAULT_JITTER_RATIO = 0.2
REQUEST_TIMEOUT = (5, 30)  # (connect, read) seconds

DEFAULT_REMOTE_INGEST_PATH = "/ingest/events"
DEFAULT_REMOTE_HEARTBEAT_PATH = "/agent/heartbeat"

def ensure_dirs() -> None:
    os.makedirs(OVANA_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)

def setup_logging(verbose: bool = False) -> None:
    ensure_dirs()
    logger = logging.getLogger()
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter(
        fmt="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO if not verbose else logging.DEBUG)
    ch.setFormatter(fmt)
    logger.addHandler(ch)
    fh = RotatingFileHandler(LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    logger.addHandler(fh)

def load_config() -> Dict[str, Any]:
    cfg: Dict[str, Any] = {
        "server": {"remote_url": "", "api_token": ""},
        "sync": {"interval": DEFAULT_INTERVAL, "batch_size": DEFAULT_BATCH_SIZE, "backoff_max": DEFAULT_BACKOFF_MAX, "jitter_ratio": DEFAULT_JITTER_RATIO},
        "privacy": {"collect_browser_history": True, "exclude_domains": ["*.banco.com", "*.salud.*"]},
    }
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "rb") as f:
            file_cfg = tomllib.load(f)
            for k, v in file_cfg.items():
                if isinstance(v, dict) and k in cfg and isinstance(cfg[k], dict):
                    cfg[k].update(v)
                else:
                    cfg[k] = v
    return cfg

def db_connect() -> sqlite3.Connection:
    ensure_dirs()
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS checkpoints (
            bucket   TEXT PRIMARY KEY,
            last_ts  TEXT,
            last_id  TEXT
        )
        """
    )
    conn.commit()
    return conn

def get_checkpoint(conn: sqlite3.Connection, bucket: str) -> Tuple[Optional[str], Optional[str]]:
    cur = conn.execute("SELECT last_ts, last_id FROM checkpoints WHERE bucket=?", (bucket,))
    row = cur.fetchone()
    return (row[0], row[1]) if row else (None, None)

def set_checkpoint(conn: sqlite3.Connection, bucket: str, last_ts: str, last_id: Optional[str]) -> None:
    conn.execute(
        "INSERT INTO checkpoints(bucket, last_ts, last_id) VALUES(?,?,?)\n         ON CONFLICT(bucket) DO UPDATE SET last_ts=excluded.last_ts, last_id=excluded.last_id",
        (bucket, last_ts, last_id),
    )
    conn.commit()

def http_get_json(url: str, headers: Dict[str, str] | None = None, params: Dict[str, Any] | None = None) -> Any:
    r = requests.get(url, headers=headers or {}, params=params or {}, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json()

def http_post_json(url: str, json_body: Any, headers: Dict[str, str]) -> requests.Response:
    r = requests.post(url, headers=headers, json=json_body, timeout=REQUEST_TIMEOUT)
    return r

def list_buckets() -> List[Dict[str, Any]]:
    url = f"{LOCAL_API}/buckets"
    data = http_get_json(url)
    if isinstance(data, dict) and "buckets" in data:
        return data["buckets"]
    return data  # some builds return a list directly

def fetch_events(bucket_id: str, start_iso: Optional[str], limit: int) -> List[Dict[str, Any]]:
    params: Dict[str, Any] = {"limit": limit}
    if start_iso:
        params["start"] = start_iso
    url = f"{LOCAL_API}/buckets/{bucket_id}/events"
    events = http_get_json(url, params=params)
    events.sort(key=lambda e: e.get("timestamp") or e.get("start") or "")
    return events

def compute_idempotency_key(bucket: str, first_ts: str, last_ts: str, count: int) -> str:
    base = f"{bucket}|{first_ts}|{last_ts}|{count}".encode("utf-8")
    return hashlib.sha256(base).hexdigest()

def post_batch(remote_url: str, api_token: str, bucket: str, events: List[Dict[str, Any]]) -> requests.Response:
    ingest_url = remote_url.rstrip("/") + DEFAULT_REMOTE_INGEST_PATH
    first_ts = events[0].get("timestamp") or events[0].get("start")
    last_ts = events[-1].get("timestamp") or events[-1].get("start")
    idem = compute_idempotency_key(bucket, first_ts, last_ts, len(events))
    headers = {"Content-Type": "application/json", "User-Agent": "ovana-sync/1.0", "Idempotency-Key": idem}
    if api_token:
        headers["Authorization"] = f"Bearer {api_token}"
    body = {"bucket": bucket, "events": events, "first_ts": first_ts, "last_ts": last_ts, "count": len(events), "source": "activitywatch", "schema": 1}
    return http_post_json(ingest_url, body, headers)

def heartbeat(remote_url: str, api_token: str, queue_size: int) -> None:
    if not remote_url:
        return
    hb_url = remote_url.rstrip("/") + DEFAULT_REMOTE_HEARTBEAT_PATH
    headers = {"Content-Type": "application/json", "User-Agent": "ovana-sync/1.0"}
    if api_token:
        headers["Authorization"] = f"Bearer {api_token}"
    payload = {"host": os.environ.get("COMPUTERNAME", "unknown"), "user": os.environ.get("USERNAME", "unknown"), "version": "1.0.0", "last_sync_ts": datetime.now(timezone.utc).isoformat(), "queue_size": queue_size, "os": "windows", "uptime": None}
    try:
        requests.post(hb_url, json=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    except Exception as e:
        logging.debug("heartbeat error: %s", e)

def sync_loop(verbose: bool = False) -> None:
    setup_logging(verbose)
    cfg = load_config()
    remote_url: str = (cfg.get("server") or {}).get("remote_url", "")
    api_token: str = (cfg.get("server") or {}).get("api_token", "")
    sync_cfg: Dict[str, Any] = cfg.get("sync", {})

    interval = int(sync_cfg.get("interval", DEFAULT_INTERVAL))
    batch_size = int(sync_cfg.get("batch_size", DEFAULT_BATCH_SIZE))
    backoff_max = int(sync_cfg.get("backoff_max", DEFAULT_BACKOFF_MAX))
    jitter_ratio = float(sync_cfg.get("jitter_ratio", DEFAULT_JITTER_RATIO))

    conn = db_connect()
    backoff = 5
    last_heartbeat = 0.0

    logging.info("ovana-sync iniciado. remote_url=%s interval=%ss batch=%s", remote_url or "<pendiente>", interval, batch_size)

    while True:
        try:
            buckets = list_buckets()
            total_pending = 0

            for b in buckets:
                bucket_id = b.get("id") or b.get("bucket_id") or b
                if not isinstance(bucket_id, str):
                    continue

                last_ts, last_id = get_checkpoint(conn, bucket_id)
                events = fetch_events(bucket_id, last_ts, batch_size)
                total_pending += len(events)

                if not events:
                    continue

                if not remote_url:
                    logging.debug("%s: %d eventos pendientes (sin remote_url)", bucket_id, len(events))
                    continue

                resp = post_batch(remote_url, api_token, bucket_id, events)
                if 200 <= resp.status_code < 300:
                    last_event = events[-1]
                    last_event_ts = last_event.get("timestamp") or last_event.get("start")
                    last_event_id = last_event.get("id") or None
                    set_checkpoint(conn, bucket_id, last_event_ts, last_event_id)
                    logging.info("%s: enviado %d eventos; checkpoint=%s", bucket_id, len(events), last_event_ts)
                    backoff = 5
                elif resp.status_code in (429, 502, 503, 504):
                    raise RuntimeError(f"remote {resp.status_code} backoff")
                else:
                    logging.error("%s: error %s: %s", bucket_id, resp.status_code, resp.text[:500])

            now = time.time()
            if now - last_heartbeat > 600:
                heartbeat(remote_url, api_token, total_pending)
                last_heartbeat = now

            time.sleep(interval)

        except (requests.ConnectionError, requests.Timeout) as e:
            sleep_s = min(backoff, backoff_max)
            jitter = sleep_s * jitter_ratio * (random.random() * 2 - 1)
            delay = max(3, int(sleep_s + jitter))
            logging.warning("red no disponible (%s). Reintentando en %ss", e.__class__.__name__, delay)
            time.sleep(delay)
            backoff = min(backoff * 2, backoff_max)
        except Exception as e:
            logging.exception("error en ciclo de sync: %s", e)
            time.sleep(min(backoff, backoff_max))
            backoff = min(backoff * 2, backoff_max)

def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Ovana Sync – offline→online")
    ap.add_argument("--verbose", action="store_true", help="Logs detallados en consola")
    return ap.parse_args()

def main() -> None:
    args = parse_args()
    sync_loop(verbose=args.verbose)

if __name__ == "__main__":
    main()
