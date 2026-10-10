"""The daily brief: fetch -> filter -> cluster -> rank -> Claude -> brief.json + HTML."""
from __future__ import annotations

import hashlib
import json
import logging
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from . import deliver, render, state, translate
from .config import ROOT, env
from .dedupe import cluster_items
from .feeds import fetch_all, load_opml, settle_times
from .labels import is_opinion_story
from .models import Cluster, Item
from .rank import is_muted, rank
from .summarize import LLMBrief, LLMStory, list_brief, summarize

log = logging.getLogger(__name__)

SCHEMA_VERSION = 1
ARCHIVE_DAYS = 60


def _apply_feed_caps(items: list[Item]) -> list[Item]:
    """Keep only the newest `max_items` per capped feed, preserving everything else."""
    counts: dict[str, int] = {}
    kept = []
    for it in sorted(items, key=lambda it: it.published, reverse=True):
        cap = it.feed.max_items
        if cap is not None:
            if counts.get(it.feed.key, 0) >= cap:
                continue
            counts[it.feed.key] = counts.get(it.feed.key, 0) + 1
        kept.append(it)
    return kept


# "The Guardian: World" and "The Guardian: Europe" are one outlet; "CNA: World (Singapore)" is CNA.
_FEED_SECTION_RE = re.compile(r": [^()]*?(?=\s*\(|$)")


def _direct(it: Item) -> bool:
    """Links to the article itself: not an aggregator, or a Techmeme item that already points at
    the original story."""
    return not it.feed.aggregator or bool(it.source_name)


def _primary(clusters: list[Cluster], title: str | None = None) -> Item:
    """The article a story's headline links to. A list-mode headline is an item's own, so it opens
    that article; an AI-written one opens the lead cluster's headline item (an official post, else
    a current report). An aggregator only when nothing else covers the story."""
    items = [it for c in clusters for it in c.items]
    if same := next((it for it in items if it.title == title and _direct(it)), None):
        return same
    head = clusters[0].headline_item
    if _direct(head):
        return head
    ranked = sorted(items, key=lambda it: (not it.feed.official, not it.exact_time, it.published))
    return next((it for it in ranked if _direct(it)), head)


def _article(it: Item) -> dict:
    out = {"title": it.title, "url": it.url, "published": state.iso(it.published)}
    if it.original_title:
        out["translated_from"] = it.feed.lang
        out["original_title"] = it.original_title
    return out


def _sources(clusters: list[Cluster], primary: Item | None = None) -> list[dict]:
    """One entry per outlet, so three Eurogamer articles are one chip. The entry links the
    primary article for the headline's outlet, else the outlet's newest; its other articles are
    in `also`, newest first. Order: the headline's outlet, official sources, then who reported
    first."""
    primary = primary or _primary(clusters)
    items = sorted((it for c in clusters for it in c.items),
                   key=lambda it: (it is not primary, not it.feed.official, it.published))
    seen: set[str] = set()
    outlets: dict[str, list[Item]] = {}
    for it in items:
        if it.canonical_url in seen:
            continue
        seen.add(it.canonical_url)
        # "Bloomberg via Techmeme" and "WSJ via Techmeme" are different outlets.
        key = it.source_name.casefold() if it.source_name else it.outlet
        outlets.setdefault(key, []).append(it)
    out = []
    for group in outlets.values():
        head = group[0] if group[0] is primary else max(group, key=lambda it: it.published)
        rest = sorted((it for it in group if it is not head), key=lambda it: it.published,
                      reverse=True)
        src = {"outlet": head.source_name or _FEED_SECTION_RE.sub("", head.feed.title),
               **_article(head), "official": head.feed.official}
        if rest:
            src["also"] = [_article(it) for it in rest]
        out.append(src)
    return out


def _story(s: LLMStory, by_id: dict[int, Cluster], section: str | None) -> dict | None:
    clusters = [by_id[i] for i in dict.fromkeys(s.cluster_ids) if i in by_id]
    if not clusters:
        return None
    key = "|".join(sorted(c.lead.canonical_url for c in clusters))
    title = s.title.strip()
    return {
        "id": hashlib.sha1(key.encode()).hexdigest()[:12],
        "title": title,
        "summary": s.summary.strip(),
        "importance": min(5, max(1, s.importance)),
        "label": s.label,
        **({"opinion": True} if all(is_opinion_story(c) for c in clusters) else {}),
        "category": section or clusters[0].category,
        "published": state.iso(max(c.newest for c in clusters)),
        "outlet_count": len({o for c in clusters for o in c.outlets}),
        "sources": _sources(clusters, _primary(clusters, title)),
    }


def assemble(llm: LLMBrief, clusters: list[Cluster], cfg: dict, meta: dict) -> dict:
    by_id = {c.id: c for c in clusters}
    used: set[int] = set()

    def take(s: LLMStory, section: str | None) -> dict | None:
        # A cluster appears in at most one story, so top stories never repeat in sections.
        ids = [i for i in s.cluster_ids if i not in used]
        if not ids:
            return None
        story = _story(s.model_copy(update={"cluster_ids": ids}), by_id, section)
        if story:
            used.update(ids)
        return story

    top = [st for s in llm.top if (st := take(s, None))]
    wanted = list(cfg["digest"]["sections"])
    llm_sections = {sec.name.strip().lower(): sec for sec in llm.sections}
    # List mode can add sections for OPML categories that aren't in the config; keep them.
    wanted += [sec.name for sec in llm.sections if sec.name.lower() not in {w.lower() for w in wanted}]
    sections = []
    for name in wanted:
        sec = llm_sections.get(name.lower())
        stories = [st for s in (sec.stories if sec else []) if (st := take(s, name))]
        sections.append({"name": name, "stories": stories})
    return {
        "version": SCHEMA_VERSION,
        "headline": llm.headline.strip(),
        "top": top,
        "sections": sections,
        **meta,
    }


def sent_today(st: dict, now: datetime, tz: ZoneInfo) -> bool:
    """Whether the last delivered brief was built on today's local date."""
    try:
        last = state.parse_iso(st["last_run"]["at"])
    except (KeyError, TypeError, ValueError):
        return False
    return last.astimezone(tz).date() == now.astimezone(tz).date()


def run(no_llm: bool = False, dry_run: bool = False, out_dir: Path | None = None,
        cfg: dict | None = None, skip_if_sent: bool = False) -> dict | None:
    """Build, publish and deliver today's brief. With `skip_if_sent`, return None without fetching
    anything when today's brief already went out: the Worker cron and GitHub's backstop schedule
    both start this job, and the reader should get one brief a day."""
    from .config import load_config

    cfg = cfg or load_config()
    out_dir = out_dir or ROOT / "docs"
    state_path = ROOT / "state" / "digest.json"
    now = datetime.now(timezone.utc)
    tz = ZoneInfo(cfg["digest"].get("timezone", "UTC"))

    st = state.load(state_path)
    if skip_if_sent and sent_today(st, now, tz):
        log.info("today's brief already went out at %s; skipping", st["last_run"]["at"])
        return None
    seen: dict[str, str] = st.get("seen", {})

    feeds = load_opml(ROOT / "feeds.opml")
    results = fetch_all(feeds, now)
    window_start = now - timedelta(hours=cfg["digest"]["window_hours"])
    all_items = [it for r in results for it in r.items]
    # Undated items count from when they were first seen; date-only ones aren't midnight UTC.
    settle_times(all_items, seen, now)
    fresh = [it for it in all_items
             if it.published >= window_start and it.id not in seen
             and not is_muted(it.title, cfg)]
    fresh = _apply_feed_caps(fresh)
    translate.translate_items(fresh, cfg, st, now)
    # Mute again on the English headline, and leave out anything that is still untranslated.
    fresh = [it for it in fresh if translate.is_readable(it) and not is_muted(it.title, cfg)]
    log.info("%d items fetched, %d fresh in window", len(all_items), len(fresh))

    clusters = rank(cluster_items(fresh), cfg, now)
    for n, c in enumerate(clusters, start=1):  # renumber so ids follow rank (easier to read)
        c.id = n
    feeds_ok = sum(1 for r in results if not r.error)

    use_ai = cfg["digest"].get("summarize", False) and not no_llm and clusters
    usage = None
    listed = clusters
    if use_ai:
        listed = clusters[: cfg["digest"]["max_clusters_for_llm"]]
        try:
            llm, usage = summarize(listed, cfg, now)
        except Exception as exc:
            log.exception("Claude summary failed; publishing the plain article list")
            listed = clusters
            llm = list_brief(listed, cfg, feeds_ok)
            usage = {"error": f"{type(exc).__name__}: {exc}"[:300]}
    else:
        llm = list_brief(listed, cfg, feeds_ok)

    health = state.update_feed_health(st.get("feeds", {}), results, now, set(seen))
    local_date = now.astimezone(tz).date().isoformat()
    meta = {
        "date": local_date,
        "generated_at": state.iso(now),
        # The page shows times in the reader's zone and says how far back the brief looks.
        "timezone": tz.key,
        "window_hours": cfg["digest"]["window_hours"],
        "mode": "ai" if usage and "error" not in usage else "list",
        "model": usage.get("model") if usage else None,
        "stats": {
            "items": len(fresh),
            "clusters": len(clusters),
            "feeds_ok": feeds_ok,
            "feeds_failed": sum(1 for r in results if r.error),
        },
        "feed_health": state.stale_feeds(health, feeds, now, cfg["health"]["stale_days"]),
    }
    brief = assemble(llm, listed, cfg, meta)
    if usage and "error" in usage:
        brief["note"] = "AI summary failed; showing the plain article list."

    if dry_run:
        print(json.dumps(brief, indent=2, ensure_ascii=False)[:6000])
        return brief

    publish(brief, out_dir)
    for it in fresh:
        seen[it.id] = state.iso(now)
    # An undated item still in its feed stays briefed, or it would come back as new.
    st["seen"] = state.prune(seen, now, keep_days=4,
                             keep={it.id for it in all_items if not it.exact_time})
    st["feeds"] = health
    st["last_run"] = {"at": state.iso(now), "usage": usage}
    state.save(state_path, st)

    notify(brief)
    return brief


def publish(brief: dict, out_dir: Path) -> None:
    archive = out_dir / "archive"
    archive.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(brief, indent=1, ensure_ascii=False)
    date = brief["date"]
    (out_dir / "brief.json").write_text(payload, encoding="utf-8")
    (archive / f"{date}.json").write_text(payload, encoding="utf-8")

    index_path = archive / "index.json"
    index = state.load(index_path).get("briefs", [])
    index = [e for e in index if e["date"] != date]
    index.insert(0, {"date": date, "headline": brief["headline"],
                     "story_count": len(brief["top"]) + sum(len(s["stories"]) for s in brief["sections"])})
    index.sort(key=lambda e: e["date"], reverse=True)
    pruned = index[ARCHIVE_DAYS:]
    for old in pruned:
        for ext in ("json", "html"):
            (archive / f"{old['date']}.{ext}").unlink(missing_ok=True)
    state.save(index_path, {"briefs": index[:ARCHIVE_DAYS]})

    dates = [e["date"] for e in index[:ARCHIVE_DAYS]]

    def neighbours(day: str) -> tuple[str | None, str | None]:
        """(previous, next) day with a brief; `dates` is newest first."""
        if day not in dates:
            return None, None
        i = dates.index(day)
        return (dates[i + 1] if i + 1 < len(dates) else None), (dates[i - 1] if i else None)

    prev, nxt = neighbours(date)
    (out_dir / "index.html").write_text(
        render.brief_html(brief, archive_link="archive/", prev_date=prev, latest=True),
        encoding="utf-8")
    (archive / f"{date}.html").write_text(
        render.brief_html(brief, archive_link="./", prev_date=prev, next_date=nxt,
                          latest_link="../"), encoding="utf-8")

    def rerender(day: str) -> None:
        """Rewrites an older day's page so its prev/next links match the archive as it is now."""
        if not (older := state.load(archive / f"{day}.json")):
            return
        older.setdefault("timezone", brief.get("timezone"))  # briefs from before times were shown
        before, after = neighbours(day)
        try:
            html = render.brief_html(older, archive_link="./", prev_date=before, next_date=after,
                                     latest_link="../")
        except (KeyError, TypeError, ValueError) as exc:
            log.warning("couldn't re-render the %s page: %s", day, exc)
        else:
            (archive / f"{day}.html").write_text(html, encoding="utf-8")

    # The day before gains its "next" link, and when old days were pruned the oldest one left
    # loses its "prev" link to a deleted page. Other pages' neighbours haven't changed.
    if prev:
        rerender(prev)
    if pruned and dates and dates[-1] not in (date, prev):
        rerender(dates[-1])
    (archive / "index.html").write_text(render.archive_html(index[:ARCHIVE_DAYS]), encoding="utf-8")
    (out_dir / ".nojekyll").touch()


def notify(brief: dict) -> None:
    page = env("PAGES_URL")
    top = brief["top"][0]["title"] if brief["top"] else brief["headline"]
    if deliver.push_channels():
        deliver.push("Your brief is ready", f"{brief['headline']}\n\nTop: {top}",
                     url=page, priority=2, tags="newspaper")
    if deliver.email_configured():
        # Archive links only work as absolute URLs in a mail client, so they need PAGES_URL.
        # "View in browser" opens this day's page: the home page moves on to tomorrow's brief.
        site = page.rstrip("/") + "/" if page else None
        day_page = site and f"{site}archive/{brief['date']}.html"
        deliver.send_email(f"Daily brief: {brief['date']}",
                           render.brief_html(brief, archive_link=site and site + "archive/",
                                             email=True, web_url=day_page),
                           render.brief_text(brief, web_url=day_page))
