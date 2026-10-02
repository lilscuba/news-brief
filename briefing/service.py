"""Shared-backend mode: one ingest run serves every app user.

Every 15 minutes `python -m briefing ingest`:
  1. fetches all sources once,
  2. builds the shared feed: the last 48 h of clustered, labelled, globally ranked stories plus
     the source catalog and the default watchlist (each phone personalizes it locally),
  3. builds alert candidates: story clusters that gained a new item since the last run,
  4. posts both to the Cloudflare Worker, which stores the feed and decides, per user, which
     candidates to push (their topics, sources, alert tiers, keywords, daily cap),
  5. sends the pushes the Worker returns through APNs and reports dead device tokens back.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

import requests

from . import apns, state, translate
from .config import ROOT, env, load_config
from .dedupe import cluster_items
from .digest import _apply_feed_caps
from .feeds import FetchResult, fetch_all, load_opml
from .labels import label_cluster
from .models import Cluster, Feed, Item
from .rank import is_muted, rank

log = logging.getLogger(__name__)

FEED_VERSION = 1
FEED_WINDOW_HOURS = 48
CANDIDATE_WINDOW_HOURS = 12


def story_id(cluster: Cluster) -> str:
    """Stable across runs: the cluster's earliest item, which doesn't change as coverage grows."""
    return min(cluster.items, key=lambda it: (it.published, it.id)).id


def _source_catalog(feeds: list[Feed], results: list[FetchResult]) -> list[dict]:
    by_key = {r.feed.key: r for r in results}
    out = []
    for f in feeds:
        r = by_key.get(f.key)
        newest = max((it.published for it in r.items), default=None) if r else None
        out.append({
            "key": f.key, "title": f.title, "category": f.category,
            "official": f.official, "trusted": f.trusted, "mirror": f.mirror,
            "status": "error" if (r and r.error) else "ok",
            "latest": state.iso(newest) if newest else None,
        })
    return out


def _story(c: Cluster) -> dict:
    lead = c.lead
    items = sorted(c.items, key=lambda it: (not it.feed.official, it.published))
    seen_urls: set[str] = set()
    sources = []
    for it in items:
        if it.canonical_url in seen_urls:
            continue
        seen_urls.add(it.canonical_url)
        src = {"key": it.feed.key, "outlet": it.feed.title, "title": it.title,
               "url": it.url, "official": it.feed.official, "published": state.iso(it.published)}
        if it.original_title:
            src["translatedFrom"] = it.feed.lang
            src["originalTitle"] = it.original_title
        sources.append(src)
    return {
        "id": story_id(c),
        "title": lead.title,
        "summary": lead.summary[:240],
        "label": label_cluster(c),
        "category": c.category,
        "score": c.score,
        "official": c.official,
        "trusted": any(it.feed.trusted for it in c.items),
        "outletCount": len(c.outlets),
        "published": state.iso(c.newest),
        "sources": sources,
    }


def build_feed(results: list[FetchResult], feeds: list[Feed], cfg: dict, now: datetime) -> dict:
    window = now - timedelta(hours=FEED_WINDOW_HOURS)
    items = [it for r in results for it in r.items
             if it.published >= window and not is_muted(it.title, cfg) and translate.is_readable(it)]
    items = _apply_feed_caps(items)
    # Personal keyword boosts are applied on each phone, so the shared ranking ignores them.
    shared_cfg = {**cfg, "ranking": {**cfg["ranking"], "boosts": {}}}
    clusters = rank(cluster_items(items), shared_cfg, now)
    return {
        "version": FEED_VERSION,
        "generatedAt": state.iso(now),
        "windowHours": FEED_WINDOW_HOURS,
        "sections": cfg["digest"]["sections"],
        "sources": _source_catalog(feeds, results),
        "watchlist": [{"name": r["name"], "match": r["match"]} for r in cfg["alerts"]["watch"]],
        "stories": [_story(c) for c in clusters],
    }


def alert_candidates(items: list[Item], seen: dict, cfg: dict, now: datetime) -> list[dict]:
    """Clusters (over the last 12 h) that contain an item that is new since the last run."""
    lookback = timedelta(minutes=cfg["alerts"]["lookback_minutes"])
    recent = [it for it in items
              if now - it.published <= timedelta(hours=CANDIDATE_WINDOW_HOURS)
              and it.feed.alert_mode != "never" and not is_muted(it.title, cfg)
              and translate.is_readable(it)]
    new_ids = {it.id for it in recent if it.id not in seen and now - it.published <= lookback}
    out = []
    for c in cluster_items(recent):
        fresh = [it for it in c.items if it.id in new_ids]
        if not fresh:
            continue
        lead = c.lead
        out.append({
            "id": story_id(c),
            "title": lead.title,
            "url": lead.url,
            "outlet": lead.feed.title,
            "category": c.category,
            "label": label_cluster(c),
            "corroboration": len(c.outlets) + (1 if c.official else 0),
            "official": c.official,
            "trustedNew": any(it.feed.trusted for it in fresh),
            "alertAllNew": any(it.feed.alert_mode == "all" for it in fresh),
            "sourceKeys": sorted({it.feed.key for it in c.items}),
            "titles": [it.title for it in c.items][:10],
        })
    return out


def run(dry_run: bool = False) -> dict:
    cfg = load_config()
    now = datetime.now(timezone.utc)
    path = ROOT / "state" / "ingest.json"
    st = state.load(path)
    seen: dict[str, str] = st.get("seen", {})
    first_run = not seen

    feeds = load_opml(ROOT / "feeds.opml")
    results = fetch_all(feeds, now)
    items = [it for r in results for it in r.items]
    # Translate before ranking so a foreign story clusters with English coverage of the same event.
    window = now - timedelta(hours=FEED_WINDOW_HOURS)
    translate.translate_items(_apply_feed_caps([it for it in items if it.published >= window]),
                              cfg, st, now)
    feed = build_feed(results, feeds, cfg, now)
    # On the very first run everything looks new; don't push a backlog to everyone.
    candidates = [] if first_run else alert_candidates(items, seen, cfg, now)
    log.info("feed: %d stories from %d sources; %d alert candidates",
             len(feed["stories"]), len(feeds), len(candidates))

    if dry_run:
        return {"feed": feed, "candidates": candidates}

    worker, secret = env("WORKER_URL"), env("INGEST_SECRET")
    if not worker or not secret:
        raise SystemExit("WORKER_URL and INGEST_SECRET must be set (see server/README.md)")
    resp = requests.post(f"{worker.rstrip('/')}/v1/internal/ingest",
                         json={"feed": feed, "candidates": candidates},
                         headers={"Authorization": f"Bearer {secret}"}, timeout=60)
    resp.raise_for_status()
    pushes = resp.json().get("pushes", [])
    log.info("worker returned %d push(es)", len(pushes))

    if pushes:
        invalid = apns.send_all(pushes)
        if invalid:
            requests.post(f"{worker.rstrip('/')}/v1/internal/push-results",
                          json={"invalidTokens": invalid},
                          headers={"Authorization": f"Bearer {secret}"}, timeout=30)

    for it in items:
        seen.setdefault(it.id, state.iso(now))
    st["seen"] = state.prune(seen, now, keep_days=3)
    st["last_run"] = state.iso(now)
    state.save(path, st)
    return {"stories": len(feed["stories"]), "candidates": len(candidates), "pushes": len(pushes)}
