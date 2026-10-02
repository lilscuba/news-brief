"""The daily brief: fetch -> filter -> cluster -> rank -> Claude -> brief.json + HTML."""
from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from . import deliver, render, state
from .config import ROOT, env
from .dedupe import cluster_items
from .feeds import fetch_all, load_opml
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


def _sources(clusters: list[Cluster]) -> list[dict]:
    seen: set[str] = set()
    out = []
    items = [it for c in clusters for it in c.items]
    items.sort(key=lambda it: (not it.feed.official, it.published))
    for it in items:
        if it.canonical_url in seen:
            continue
        seen.add(it.canonical_url)
        out.append({"outlet": it.feed.title, "title": it.title, "url": it.url,
                    "official": it.feed.official})
    return out


def _story(s: LLMStory, by_id: dict[int, Cluster], section: str | None) -> dict | None:
    clusters = [by_id[i] for i in dict.fromkeys(s.cluster_ids) if i in by_id]
    if not clusters:
        return None
    key = "|".join(sorted(c.lead.canonical_url for c in clusters))
    return {
        "id": hashlib.sha1(key.encode()).hexdigest()[:12],
        "title": s.title.strip(),
        "summary": s.summary.strip(),
        "importance": min(5, max(1, s.importance)),
        "label": s.label,
        "category": section or clusters[0].category,
        "published": state.iso(max(c.newest for c in clusters)),
        "outlet_count": len({o for c in clusters for o in c.outlets}),
        "sources": _sources(clusters),
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


def run(no_llm: bool = False, dry_run: bool = False, out_dir: Path | None = None,
        cfg: dict | None = None) -> dict:
    from .config import load_config

    cfg = cfg or load_config()
    out_dir = out_dir or ROOT / "docs"
    state_path = ROOT / "state" / "digest.json"
    now = datetime.now(timezone.utc)
    tz = ZoneInfo(cfg["digest"].get("timezone", "UTC"))

    st = state.load(state_path)
    seen: dict[str, str] = st.get("seen", {})

    feeds = load_opml(ROOT / "feeds.opml")
    results = fetch_all(feeds, now)
    window_start = now - timedelta(hours=cfg["digest"]["window_hours"])
    all_items = [it for r in results for it in r.items]
    fresh = [it for it in all_items
             if it.published >= window_start and it.id not in seen
             and not is_muted(it.title, cfg)]
    fresh = _apply_feed_caps(fresh)
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
    st["seen"] = state.prune(seen, now, keep_days=4)
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
    for old in index[ARCHIVE_DAYS:]:
        for ext in ("json", "html"):
            (archive / f"{old['date']}.{ext}").unlink(missing_ok=True)
    state.save(index_path, {"briefs": index[:ARCHIVE_DAYS]})

    html = render.brief_html(brief, archive_link="archive/")
    (out_dir / "index.html").write_text(html, encoding="utf-8")
    (archive / f"{date}.html").write_text(render.brief_html(brief, archive_link="./"), encoding="utf-8")
    (archive / "index.html").write_text(render.archive_html(index[:ARCHIVE_DAYS]), encoding="utf-8")
    (out_dir / ".nojekyll").touch()


def notify(brief: dict) -> None:
    page = env("PAGES_URL")
    top = brief["top"][0]["title"] if brief["top"] else brief["headline"]
    if deliver.push_channels():
        deliver.push("Your brief is ready", f"{brief['headline']}\n\nTop: {top}",
                     url=page, priority=2, tags="newspaper")
    if deliver.email_configured():
        deliver.send_email(f"Daily brief: {brief['date']}",
                           render.brief_html(brief, archive_link=(page or "") + "archive/"),
                           render.brief_text(brief))
