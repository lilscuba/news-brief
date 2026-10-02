from __future__ import annotations

import calendar
import hashlib
import logging
import re
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import feedparser
import requests

from . import bluesky
from .models import Feed, Item
from .normalize import canonical_url, clean_title, snippet

log = logging.getLogger(__name__)

USER_AGENT = "PersonalFeed/1.0 (personal RSS digest)"
_HREF_RE = re.compile(r'href="(https?://[^"]+)"')
_HN_POINTS_RE = re.compile(r"Points:\s*(\d+)")


@dataclass
class FetchResult:
    feed: Feed
    items: list[Item]
    error: str | None = None


def load_opml(path: Path) -> list[Feed]:
    root = ET.parse(path).getroot()
    feeds: list[Feed] = []
    for group in root.find("body"):
        folder = group.get("text") or "Other"
        for node in group.iter("outline"):
            url = node.get("xmlUrl")
            if not url:
                continue
            feeds.append(
                Feed(
                    key=node.get("pfKey") or hashlib.sha1(url.encode()).hexdigest()[:8],
                    title=node.get("text") or url,
                    url=url,
                    # pfCategory lets a reader folder like "Social" feed the Gaming section.
                    category=node.get("pfCategory") or folder,
                    official=node.get("pfOfficial") == "true",
                    alert_mode=node.get("pfAlert") or "watch",
                    mirror=node.get("pfMirror") == "true",
                    max_items=int(node.get("pfMaxItems")) if node.get("pfMaxItems") else None,
                    trusted=node.get("pfTrusted") == "true",
                    lang=node.get("pfLang") or "en",
                )
            )
    keys = [f.key for f in feeds]
    if len(keys) != len(set(keys)):
        raise ValueError(f"duplicate pfKey in {path}")
    return feeds


def _entry_time(entry, fallback: datetime) -> datetime:
    for attr in ("published_parsed", "updated_parsed", "created_parsed"):
        parsed = entry.get(attr)
        if parsed:
            return datetime.fromtimestamp(calendar.timegm(parsed), tz=timezone.utc)
    return fallback


def parse_feed(feed: Feed, content: bytes, now: datetime) -> list[Item]:
    parsed = feedparser.parse(content)
    items: list[Item] = []
    for entry in parsed.entries:
        title = clean_title(entry.get("title", ""))
        link = entry.get("link", "")
        if not title or not link:
            continue
        raw_summary = entry.get("summary", "") or ""
        guid = entry.get("id") or link
        # Undated entries get "now"; the seen-set keeps them from repeating on later runs.
        published = min(_entry_time(entry, now), now)
        alt_urls: list[str] = []
        if feed.outlet == "techmeme":
            # Techmeme items link to techmeme.com; the original story is inside the description.
            alt_urls = [canonical_url(u) for u in _HREF_RE.findall(raw_summary)
                        if "techmeme.com" not in u][:1]
        hn_points = None
        if feed.outlet == "hn":
            if m := _HN_POINTS_RE.search(raw_summary):
                hn_points = int(m.group(1))
            raw_summary = ""  # hnrss descriptions are just metadata
        items.append(
            Item(
                id=hashlib.sha1(f"{feed.key}|{guid}".encode()).hexdigest()[:16],
                feed=feed,
                title=title,
                url=link,
                canonical_url=canonical_url(link),
                summary=snippet(raw_summary),
                published=published,
                alt_urls=alt_urls,
                hn_points=hn_points,
            )
        )
    if not items and parsed.bozo:
        raise ValueError(f"unparseable feed: {parsed.bozo_exception}")
    return items


def _get(session: requests.Session, url: str) -> requests.Response:
    """GET with one retry for timeouts and 5xx; hnrss.org in particular blips often."""
    for attempt in (1, 2):
        try:
            resp = session.get(url, timeout=20, headers={"User-Agent": USER_AGENT})
            if resp.status_code < 500 or attempt == 2:
                resp.raise_for_status()
                return resp
        except (requests.ConnectionError, requests.Timeout):
            if attempt == 2:
                raise
        time.sleep(3)
    raise AssertionError("unreachable")


def fetch_feed(feed: Feed, now: datetime, session: requests.Session) -> FetchResult:
    try:
        if bluesky.handle_for(feed.url):
            return FetchResult(feed, bluesky.fetch_author_feed(feed, now, lambda u: _get(session, u)))
        resp = _get(session, feed.url)
        return FetchResult(feed, parse_feed(feed, resp.content, now))
    except Exception as exc:  # one broken feed must never sink the brief
        log.warning("feed %s failed: %s", feed.key, exc)
        return FetchResult(feed, [], error=f"{type(exc).__name__}: {exc}"[:200])


def fetch_all(feeds: list[Feed], now: datetime | None = None) -> list[FetchResult]:
    now = now or datetime.now(timezone.utc)
    with requests.Session() as session, ThreadPoolExecutor(max_workers=12) as pool:
        return list(pool.map(lambda f: fetch_feed(f, now, session), feeds))
