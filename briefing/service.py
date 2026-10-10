"""Shared-backend mode: one ingest run serves every app user.

Every 10 minutes (dispatched by the Worker's cron) `python -m briefing ingest`:
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
import time
from datetime import datetime, timedelta, timezone

import requests

from . import apns, state, story_summaries, summarize, translate
from .alerts import alert_lookback
from .config import ROOT, env, load_config
from .dedupe import cluster_items
from .digest import _apply_feed_caps
from .feeds import FetchResult, fetch_all, load_opml, settle_times
from .labels import is_opinion_story, label_cluster
from .models import Cluster, Feed, Item
from .normalize import canonical_url
from .rank import is_muted, rank

log = logging.getLogger(__name__)

FEED_VERSION = 1
FEED_WINDOW_HOURS = 48
CANDIDATE_WINDOW_HOURS = 12
SUMMARY_CHARS = 240


def story_id(cluster: Cluster) -> str:
    """Stable across runs: the cluster's earliest item, which doesn't change as coverage grows."""
    return min(cluster.items, key=lambda it: (it.published, it.id)).id


def _source_catalog(feeds: list[Feed], results: list[FetchResult], cfg: dict,
                    now: datetime) -> list[dict]:
    """Every source with its health. "status" says whether the fetch worked; "stale" whether a
    feed that answered has posted nothing for `[health] stale_days` (frozen or moved feeds)."""
    by_key = {r.feed.key: r for r in results}
    stale_after = timedelta(days=cfg.get("health", {}).get("stale_days", 14))
    out = []
    for f in feeds:
        r = by_key.get(f.key)
        newest = max((it.published for it in r.items), default=None) if r else None
        out.append({
            "key": f.key, "title": f.title, "category": f.category,
            "official": f.official, "trusted": f.trusted, "mirror": f.mirror,
            "status": "error" if (r and r.error) else "ok",
            "stale": bool(r and not r.error and newest and now - newest > stale_after),
            "latest": state.iso(newest) if newest else None,
        })
    if stale := [f"{s['key']} ({s['latest'][:10]})" for s in out if s["stale"]]:
        log.warning("%d feed(s) with nothing new for %s days: %s", len(stale), stale_after.days,
                    ", ".join(stale))
    return out


def _story(c: Cluster, summary: str | None = None) -> dict:
    # The headline item gives the title and is sources[0], the app's "Read article" target. The id
    # stays the earliest item's, so read state and push dedupe survive a headline change.
    head = c.headline_item
    rest = sorted((it for it in c.items if it is not head),
                  key=lambda it: (not it.feed.official, it.published))
    seen_urls: set[str] = set()
    sources = []
    for it in (head, *rest):
        url, outlet = it.url, it.source_name or it.feed.title
        if it.canonical_url in seen_urls:
            # A Techmeme post of an article already listed: keep its own page (the discussion).
            if not (it.source_name and it.alt_urls) or canonical_url(it.alt_urls[0]) in seen_urls:
                continue
            url, outlet = it.alt_urls[0], it.feed.title
            seen_urls.add(canonical_url(url))
        seen_urls.add(it.canonical_url)
        src = {"key": it.feed.key, "outlet": outlet, "title": it.title,
               "url": url, "official": it.feed.official, "published": state.iso(it.published)}
        if it.original_title:
            src["translatedFrom"] = it.feed.lang
            src["originalTitle"] = it.original_title
        sources.append(src)
    return {
        "id": story_id(c),
        "title": head.title,
        # The AI summary (top stories only) replaces the outlets' feed snippet.
        "summary": summary or c.snippet(SUMMARY_CHARS, first=head),
        **({"aiSummary": True} if summary else {}),
        "label": label_cluster(c),
        **({"opinion": True} if is_opinion_story(c) else {}),
        "category": c.category,
        "score": c.score,
        "official": c.official,
        "trusted": any(it.feed.trusted for it in c.items),
        "outletCount": len(c.outlets),
        "published": state.iso(c.newest),
        "sources": sources,
    }


def build_feed(results: list[FetchResult], feeds: list[Feed], cfg: dict, now: datetime,
               st: dict | None = None) -> dict:
    """The shared feed. With `st` (the ingest state), top stories get cached AI summaries."""
    window = now - timedelta(hours=FEED_WINDOW_HOURS)
    items = [it for r in results for it in r.items
             if it.published >= window and not is_muted(it.title, cfg) and translate.is_readable(it)]
    items = _apply_feed_caps(items)
    # Personal keyword boosts are applied on each phone, so the shared ranking ignores them.
    shared_cfg = {**cfg, "ranking": {**cfg["ranking"], "boosts": {}}}
    clusters = rank(cluster_items(items), shared_cfg, now)
    summaries: dict[str, str] = {}
    if st is not None:
        top_n = cfg.get("story_summaries", {}).get("top_n", 40)
        summaries = story_summaries.summarize_stories(
            [(story_id(c), c) for c in clusters[:top_n] if label_cluster(c) != "DEAL"], cfg, st, now)
    return {
        "version": FEED_VERSION,
        "generatedAt": state.iso(now),
        "windowHours": FEED_WINDOW_HOURS,
        "sections": cfg["digest"]["sections"],
        "sources": _source_catalog(feeds, results, cfg, now),
        "watchlist": [{"name": r["name"], "match": r["match"]} for r in cfg["alerts"]["watch"]],
        "stories": [_story(c, summaries.get(story_id(c))) for c in clusters],
    }


def alert_candidates(items: list[Item], seen: dict, cfg: dict, now: datetime,
                     last_run: str | None = None) -> list[dict]:
    """Clusters (over the last 12 h) that contain an item that is new since the last run."""
    lookback = alert_lookback(cfg, now, last_run)
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


def _post_worker(url: str, payload: dict, secret: str, timeout: int = 60) -> requests.Response:
    """POST to the Worker, once more after 5 s on a dropped connection, timeout or 5xx (a deploy
    or a KV/D1 blip); the ingest's work is too costly to throw away on one."""
    for attempt in (1, 2):
        try:
            resp = requests.post(url, json=payload, headers={"Authorization": f"Bearer {secret}"},
                                 timeout=timeout)
            if resp.status_code < 500 or attempt == 2:
                resp.raise_for_status()
                return resp
            reason = f"HTTP {resp.status_code}"
        except (requests.ConnectionError, requests.Timeout) as exc:
            if attempt == 2:
                raise
            reason = type(exc).__name__
        log.warning("worker %s on %s; retrying in 5s", reason, url)
        time.sleep(5)
    raise AssertionError("unreachable")


def run(dry_run: bool = False) -> dict:
    cfg = load_config()
    now = datetime.now(timezone.utc)
    path = ROOT / "state" / "ingest.json"
    st = state.load(path)
    seen: dict[str, str] = st.get("seen", {})
    first_run = not seen
    summarize.restore_cooldowns(st, now)  # skip Gemini models that failed in a recent run

    feeds = load_opml(ROOT / "feeds.opml")
    results = fetch_all(feeds, now)
    items = [it for r in results for it in r.items]
    # Undated items keep the time they were first seen instead of looking new on every run.
    settle_times(items, seen, now)
    # Translate before ranking so a foreign story clusters with English coverage of the same event.
    window = now - timedelta(hours=FEED_WINDOW_HOURS)
    translate.translate_items(_apply_feed_caps([it for it in items if it.published >= window]),
                              cfg, st, now)
    feed = build_feed(results, feeds, cfg, now, st)
    # On the very first run everything looks new; don't push a backlog to everyone.
    candidates = [] if first_run else alert_candidates(items, seen, cfg, now, st.get("last_run"))
    log.info("feed: %d stories from %d sources; %d alert candidates",
             len(feed["stories"]), len(feeds), len(candidates))

    if dry_run:
        return {"feed": feed, "candidates": candidates}

    try:
        worker, secret = env("WORKER_URL"), env("INGEST_SECRET")
        if not worker or not secret:
            raise SystemExit("WORKER_URL and INGEST_SECRET must be set (see server/README.md)")
        resp = _post_worker(f"{worker.rstrip('/')}/v1/internal/ingest",
                            {"feed": feed, "candidates": candidates}, secret)
        pushes = resp.json().get("pushes", [])
        log.info("worker returned %d push(es)", len(pushes))

        if pushes:
            invalid = apns.send_all(pushes)
            if invalid:
                try:
                    requests.post(f"{worker.rstrip('/')}/v1/internal/push-results",
                                  json={"invalidTokens": invalid},
                                  headers={"Authorization": f"Bearer {secret}"}, timeout=30)
                except requests.RequestException as exc:  # APNs reports them again next time
                    log.warning("couldn't report %d dead device token(s): %s", len(invalid), exc)

        # Only a delivered run moves these on, so a failed one's alerts are offered again. A
        # foreign headline still waiting for its translation batch isn't seen yet: it can only
        # join an alert once it reads in English.
        for it in items:
            if translate.is_readable(it):
                seen.setdefault(it.id, state.iso(now))
        # Undated items still in their feed keep their first-seen time past the usual 3 days.
        st["seen"] = state.prune(seen, now, keep_days=3,
                                 keep={it.id for it in items if not it.exact_time})
        st["last_run"] = state.iso(now)
    finally:
        # Keep what this run paid for (translations, summaries) and learned (Gemini cooldowns)
        # even when the upload failed.
        summarize.store_cooldowns(st, now)
        state.save(path, st)
    return {"stories": len(feed["stories"]), "candidates": len(candidates), "pushes": len(pushes)}
