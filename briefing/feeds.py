from __future__ import annotations

import calendar
import hashlib
import html
import logging
import re
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo

import feedparser
import requests

from . import bluesky, state
from .models import Feed, Item
from .normalize import canonical_url, clean_snippet, clean_title, is_web_url, strip_html

log = logging.getLogger(__name__)

USER_AGENT = "PersonalFeed/1.0 (personal RSS digest)"
_HREF_RE = re.compile(r'href="(https?://[^"]+)"', re.IGNORECASE)
# The bold link around the headline is the article itself; the attribution link before it is the
# outlet's home page, and the thumbnail link is missing when Techmeme has no image.
_TM_HEADLINE_RE = re.compile(r'<b>\s*<a [^>]*href="(https?://[^"]+)"', re.IGNORECASE)
_HN_POINTS_RE = re.compile(r"Points:\s*(\d+)")
# Techmeme descriptions: "<permalink icon></a> Author / <a>Outlet</a>:<br/> <b>headline</b> — text".
_TM_ATTRIBUTION_RE = re.compile(r'title="Techmeme permalink".*?</a>(.*?):\s*<br', re.S | re.I)
_TM_BYLINE_RE = re.compile(r"\s*\(([^()]{2,80})\)$")
_TM_BODY_RE = re.compile(r"</b>\s*(?:</span>)?(?:\s|&nbsp;)*(?:&mdash;|—)(?:\s|&nbsp;)*(.*)$", re.S | re.I)
# Outlets whose descriptions are the lead photo's caption ("Sen. X departs the lunch meeting in
# the Capitol on June 24."), which reads like a summary but isn't one.
_CAPTION_FEEDS = frozenset({"rollcall"})
# Item times feedparser can't read, written in the feed's own zone (pfTimeZone): NL Times'
# "5 October 2026 - 14:09".
_LOCAL_TIME_FORMATS = ("%d %B %Y - %H:%M",)
# Every item stamped with one time this close to the fetch: the feed's build time, not when each
# item was published (The Korea Times). Older shared stamps are left alone: those are real.
BUILD_STAMP_WINDOW = timedelta(hours=2)
# A bare date ("2026-10-04") parses as midnight UTC, but in a US outlet's zone that day runs
# until the next morning UTC: a date-only item's estimated time stays within this of it.
DATE_ONLY_SPAN = timedelta(hours=36)
_HTML_RE = re.compile(rb"\s*(?:<!doctype html|<html)", re.I)


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
                    time_zone=node.get("pfTimeZone"),
                )
            )
    keys = [f.key for f in feeds]
    if len(keys) != len(set(keys)):
        raise ValueError(f"duplicate pfKey in {path}")
    return feeds


def _entry_time(entry, fallback: datetime, time_zone: str | None = None) -> tuple[datetime, str]:
    """When the entry was published, and how well the feed says so (see Item.time_quality).
    Undated entries get `fallback` until settle_times knows when they were first seen."""
    for attr in ("published", "updated", "created"):
        if parsed := entry.get(f"{attr}_parsed"):
            raw = entry.get(attr) or ""
            # "2026-10-04" or "Sun, 04 Oct 2026": a day with no time of day.
            quality = "date" if raw and ":" not in raw else "exact"
            return datetime.fromtimestamp(calendar.timegm(parsed), tz=timezone.utc), quality
    if time_zone:
        raw = (entry.get("published") or entry.get("updated") or "").strip()
        for fmt in _LOCAL_TIME_FORMATS:
            try:
                local = datetime.strptime(raw, fmt).replace(tzinfo=ZoneInfo(time_zone))
            except ValueError:
                continue
            return local.astimezone(timezone.utc), "exact"
    return fallback, "none"


def _mark_build_stamps(items: list[Item], now: datetime) -> None:
    """A feed whose every item (3 or more) carries one recent time is stamped with its build time:
    those times say nothing about the items, so they count as undated."""
    if len(items) < 3 or not all(it.exact_time for it in items):
        return
    stamps = {it.published for it in items}
    if len(stamps) == 1 and now - stamps.pop() <= BUILD_STAMP_WINDOW:
        for it in items:
            it.time_quality = "none"


def settle_times(items: list[Item], seen: dict[str, str], now: datetime) -> None:
    """Replace the times a feed doesn't really state with when this pipeline first saw the item.

    `seen` maps item id -> first-seen ISO time (the caller's state file); items missing from it
    are being seen now. Nothing was published after it was first seen, so undated items get that
    time, date-only items too unless it falls after their stated day, and a stated time later
    than it (a feed that re-stamps its items or dates them ahead of the clock) gives way to it."""
    for it in items:
        first = state.parse_iso(seen[it.id]) if it.id in seen else now
        if it.time_quality == "none":
            it.published = first
        elif it.time_quality == "date":
            it.published = min(first, it.published + DATE_ONLY_SPAN)
        else:
            it.published = min(it.published, first)


def _techmeme(raw_summary: str, title: str) -> tuple[str, str | None, str | None, str]:
    """Techmeme items: (headline without the "(Author/Outlet)" byline, outlet, original article
    URL, description after the headline). The description reads "Author / Outlet: headline — text"."""
    def article(u: str) -> str | None:
        u = html.unescape(u)
        return u if "techmeme.com" not in u and urlsplit(u).path not in ("", "/") else None

    original = article(m.group(1)) if (m := _TM_HEADLINE_RE.search(raw_summary)) else None
    original = original or next(filter(None, map(article, _HREF_RE.findall(raw_summary))), None)
    outlet = None
    if m := _TM_ATTRIBUTION_RE.search(raw_summary):
        outlet = strip_html(m.group(1)).rsplit("/", 1)[-1].strip() or None
    if m := _TM_BYLINE_RE.search(title):
        byline = m.group(1)
        named = byline.rsplit("/", 1)[-1].strip()
        # Only a real byline: "(Scott Patterson/Bloomberg)", or "(Vanity Fair)" matching the source.
        if "/" in byline or (outlet and named.casefold() == outlet.casefold()):
            title = title[: m.start()].rstrip()
            outlet = outlet or named
    body = m.group(1) if (m := _TM_BODY_RE.search(raw_summary)) else raw_summary
    return title, outlet, original, body


def parse_feed(feed: Feed, content: bytes, now: datetime) -> list[Item]:
    parsed = feedparser.parse(content)
    items: list[Item] = []
    for entry in parsed.entries:
        raw_title = strip_html(entry.get("title", ""))
        title = clean_title(raw_title)
        link = entry.get("link", "")
        if not title or not is_web_url(link):
            continue
        raw_summary = entry.get("summary", "") or ""
        guid = entry.get("id") or link
        stated, time_quality = _entry_time(entry, now, feed.time_zone)
        published = min(stated, now)
        url, alt_urls, source_name = link, [], None
        if feed.outlet == "techmeme":
            # Techmeme items link to techmeme.com; the original story is inside the description.
            # Readers go straight to the article, and the permalink still clusters by URL.
            title, outlet, original, raw_summary = _techmeme(raw_summary, title)
            if original:
                url, alt_urls = original, [link]  # as written: its #anchor finds the story in the river
                source_name = f"{outlet} via {feed.title}" if outlet else None
        hn_points = None
        if feed.outlet == "hn":
            if m := _HN_POINTS_RE.search(raw_summary):
                hn_points = int(m.group(1))
            raw_summary = ""  # hnrss descriptions are just metadata
        if feed.outlet in _CAPTION_FEEDS:
            raw_summary = ""
        items.append(
            Item(
                id=hashlib.sha1(f"{feed.key}|{guid}".encode()).hexdigest()[:16],
                feed=feed,
                title=title,
                url=url,
                canonical_url=canonical_url(url),
                summary=clean_snippet(raw_summary, title),
                published=published,
                alt_urls=alt_urls,
                hn_points=hn_points,
                raw_title=raw_title if raw_title != title else None,
                source_name=source_name,
                time_quality=time_quality,
            )
        )
    if not items and parsed.bozo:
        if _HTML_RE.match(content):
            # Some hosts answer automated requests with a challenge page now and then.
            raise ValueError("not a feed: the site answered with a web page (often a bot check)")
        raise ValueError(f"unparseable feed: {parsed.bozo_exception}")
    _mark_build_stamps(items, now)
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
