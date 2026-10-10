"""Small JSON state files: which items were already briefed/alerted, and per-feed health."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path


def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def prune(seen: dict[str, str], now: datetime, keep_days: int,
          keep: set[str] | frozenset[str] = frozenset()) -> dict[str, str]:
    """Drop entries older than `keep_days`, except the ids in `keep` (items still in their feed
    whose only time is when they were first seen: forgetting it would make them new again)."""
    cutoff = now - timedelta(days=keep_days)
    return {k: v for k, v in seen.items() if k in keep or parse_iso(v) >= cutoff}


def update_feed_health(health: dict, results, now: datetime, known_ids: set[str]) -> dict:
    """Record per feed when it last fetched OK and when it last produced an unseen item."""
    for r in results:
        h = health.setdefault(r.feed.key, {"first_seen": iso(now)})
        if r.error:
            h["last_error"] = r.error
            h["last_error_at"] = iso(now)
            continue
        h["last_ok"] = iso(now)
        h.pop("last_error", None)
        newest = max((it.published for it in r.items if it.id not in known_ids), default=None)
        if newest is not None:
            h["last_new"] = iso(max(newest, parse_iso(h.get("last_new", iso(newest)))))
    return health


def stale_feeds(health: dict, feeds, now: datetime, stale_days: int) -> list[dict]:
    """Feeds that are erroring or have produced nothing new for `stale_days`."""
    out = []
    cutoff = now - timedelta(days=stale_days)
    for f in feeds:
        h = health.get(f.key)
        if not h:
            continue
        if h.get("last_error"):
            out.append({"key": f.key, "title": f.title, "status": "error", "detail": h["last_error"]})
            continue
        last_new = h.get("last_new")
        tracked_since = parse_iso(h["first_seen"])
        if tracked_since < cutoff and (not last_new or parse_iso(last_new) < cutoff):
            detail = f"no new items since {last_new[:10]}" if last_new else "never produced items"
            if f.mirror:
                detail += " (unofficial mirror; it may have broken)"
            out.append({"key": f.key, "title": f.title, "status": "stale", "detail": detail})
    return out
