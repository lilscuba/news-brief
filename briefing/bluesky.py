"""Bluesky accounts as feed sources, via the public AppView API (no account or key needed).

In feeds.opml a Bluesky account is an ordinary outline whose xmlUrl is the profile's RSS URL
(https://bsky.app/profile/<handle>/rss), so NetNewsWire and other readers can import it too.
The pipeline reads the same handle through app.bsky.feed.getAuthorFeed instead, which gives
proper timestamps, skips replies and reposts, and exposes the article a post links to, so a
journalist's post and the outlet's article cluster into one story.
"""
from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone

from .models import Feed, Item
from .normalize import canonical_url, clean_post_title, clean_snippet, is_web_url, snippet

API = "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed"
_PROFILE_RE = re.compile(r"^https://bsky\.app/profile/([^/]+)/rss/?$")
# A post without a link is kept only if it reads like news, which filters out the sports takes and
# "busy day in Tokyo" posts while keeping text-only scoops.
_NEWS_MARKERS = re.compile(
    r"\b(exclusive|breaking|scoop|confirmed|announced|report(?:s|ed|ing)?|sources?)\b|^new:",
    re.IGNORECASE,
)
# Links that aren't news (polls, tip jars, streams, GIFs).
_NON_NEWS_HOSTS = ("forms.gle", "patreon.com", "ko-fi.com", "twitch.tv", "linktr.ee",
                   "klipy.com", "tenor.com", "giphy.com")


def handle_for(feed_url: str) -> str | None:
    m = _PROFILE_RE.match(feed_url)
    return m.group(1) if m else None


def _post_link(post: dict) -> str | None:
    """The external article a post points at, if any: link card first, then links in the text."""
    embed = post.get("embed") or {}
    for e in (embed, embed.get("media") or {}):  # recordWithMedia nests the card under media
        ext = e.get("external")
        if ext and ext.get("uri"):
            return ext["uri"]
    for facet in post.get("record", {}).get("facets", []) or []:
        for feature in facet.get("features", []):
            if feature.get("$type") == "app.bsky.richtext.facet#link" and feature.get("uri"):
                return feature["uri"]
    return None


def _parse_time(value: str) -> datetime:
    # createdAt looks like 2026-10-01T09:12:44.123Z (fraction optional)
    value = value.replace("Z", "+00:00")
    return datetime.fromisoformat(value).astimezone(timezone.utc)


def parse_author_feed(feed: Feed, data: dict, now: datetime) -> list[Item]:
    items: list[Item] = []
    for entry in data.get("feed", []):
        if entry.get("reason"):  # a repost of someone else's post
            continue
        post = entry.get("post", {})
        record = post.get("record", {})
        if record.get("reply"):
            continue
        raw_text = record.get("text") or ""
        text = " ".join(raw_text.split())
        card = (post.get("embed") or {}).get("external") or {}
        if not text and not card.get("title"):
            continue
        handle = post.get("author", {}).get("handle", "")
        rkey = post.get("uri", "").rsplit("/", 1)[-1]
        post_url = f"https://bsky.app/profile/{handle}/post/{rkey}"
        link = _post_link(post)
        if link and (not is_web_url(link) or any(host in link for host in _NON_NEWS_HOSTS)):
            link = None
        if not link and not _NEWS_MARKERS.search(text):
            continue
        # The headline drops buff.ly links and "#ad"; labels still read the raw text (DEAL).
        title = clean_post_title(raw_text) or card.get("title", "") or text
        if len(title) > 200:
            title = snippet(title, 200)
        summary = card.get("title", "") if text and card.get("title") else ""
        published = min(_parse_time(record.get("createdAt") or post.get("indexedAt")), now)
        items.append(
            Item(
                id=hashlib.sha1(f"{feed.key}|{post.get('uri')}".encode()).hexdigest()[:16],
                feed=feed,
                title=title,
                url=link or post_url,
                canonical_url=canonical_url(link or post_url),
                summary=clean_snippet(summary, title),
                published=published,
                raw_title=text if text != title else None,
            )
        )
    return items


def fetch_author_feed(feed: Feed, now: datetime, get) -> list[Item]:
    """`get` is feeds._get bound to a session, so retries and headers stay consistent."""
    handle = handle_for(feed.url)
    resp = get(f"{API}?actor={handle}&limit=50&filter=posts_no_replies")
    return parse_author_feed(feed, resp.json(), now)
