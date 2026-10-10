"""Short AI summaries for the top stories in the shared app feed.

A feed story's own summary is just the first outlet's RSS snippet, which is often empty or
boilerplate. For the highest-ranked stories this asks Gemini for a one- or two-sentence summary
written from the headlines and snippets of every outlet covering the story. Only text the feeds
already provide is sent, never article pages, so nothing is scraped.

Each story is summarized once and cached in the ingest state, and summarized again when its
coverage has grown well past what the summary was written from, so a breaking story's summary
keeps up with it. Failure is never fatal: with no key, a rate limit or a bad response the story
simply keeps its snippet (or its previous summary) and is retried on a later run.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta

from pydantic import BaseModel

from . import state
from .config import env
from .models import Cluster, Item
from .summarize import gemini_json, gemini_schema

log = logging.getLogger(__name__)

CACHE_KEY = "story_summaries"
CACHE_DAYS = 4
SNIPPET_CHARS = 300
MAX_SOURCES = 6
MAX_SUMMARY_CHARS = 400
# A new story this high in the feed is summarized at once instead of waiting for `min_new`.
URGENT_RANK = 10
# A summary is written again when the story has at least twice the outlets (and 3 more) and the
# summary is 2 h old, or when a top-15 story still gets coverage 6 h after it was written.
GROWN_MIN_AGE = timedelta(hours=2)
DEVELOPING_RANK = 15
DEVELOPING_AFTER = timedelta(hours=6)

SYSTEM_PROMPT = (
    "You write short summaries for a news app. For each story you get the headlines and snippets "
    "of the outlets covering it. Write one or two plain-English sentences (at most 45 words) "
    "saying what happened and why it matters. Use only facts stated in the input; if the input "
    "says little, say less rather than guess, and return an empty summary if it adds nothing to "
    "the headline. Do not repeat a headline word for word, name outlets, or use clickbait. "
    "Keep attribution on rumors, leaks, claims and allegations ('reportedly', 'according to', "
    "'says'); never state one as fact. Return every story with the same `i`."
)


class _Summary(BaseModel):
    i: int
    summary: str


class _Batch(BaseModel):
    items: list[_Summary]


def _sources(c: Cluster) -> list[Item]:
    """One item per outlet, newest first: the latest developments, not four items from one outlet."""
    picked: dict[str, Item] = {}
    for it in sorted(c.items, key=lambda it: it.published, reverse=True):
        picked.setdefault(it.outlet, it)
    return list(picked.values())[:MAX_SOURCES]


def _payload(batch: list[tuple[str, Cluster]]) -> str:
    stories = [{
        "i": n,
        "outlets": len(c.outlets),
        "official": c.official,
        "sources": [{"outlet": it.feed.title, "headline": it.title, "snippet": it.summary[:SNIPPET_CHARS]}
                    for it in _sources(c)],
    } for n, (_, c) in enumerate(batch)]
    return json.dumps(stories, ensure_ascii=False)


def _outgrown(entry: dict, c: Cluster, rank: int, now: datetime) -> bool:
    """Whether a cached summary was written from much less coverage than the story has now."""
    at = state.parse_iso(entry["at"])
    if "newest" in entry and c.newest <= state.parse_iso(entry["newest"]):
        return False  # nothing has arrived since
    cached = entry.get("outlets", 1)  # entries from before this was recorded
    grown = len(c.outlets) >= max(2 * cached, cached + 3) and now - at >= GROWN_MIN_AGE
    developing = rank < DEVELOPING_RANK and c.newest - at > DEVELOPING_AFTER
    return grown or developing


def _summarize_batch(batch: list[tuple[str, Cluster]], cfg: dict) -> dict[int, str]:
    text, usage = gemini_json(SYSTEM_PROMPT, _payload(batch), gemini_schema(_Batch), cfg, timeout=90,
                              models=cfg.get("story_summaries", {}).get("models"))
    out = {s.i: s.summary.strip()[:MAX_SUMMARY_CHARS] for s in _Batch.model_validate_json(text).items}
    log.info("summarized %d/%d stories (%s in, %s out tokens)", len(out), len(batch),
             usage.get("input_tokens"), usage.get("output_tokens"))
    return out


def summarize_stories(candidates: list[tuple[str, Cluster]], cfg: dict, st: dict,
                      now: datetime) -> dict[str, str]:
    """Summaries for `candidates` (story id, cluster; best first), as {story id: summary}.

    Uses and updates `st["story_summaries"]`. Stories whose summary is empty or still pending are
    left out of the result, so the caller keeps their snippet."""
    settings = cfg.get("story_summaries", {})
    if not candidates or not settings.get("enabled", True):
        return {}

    cutoff = now - timedelta(days=CACHE_DAYS)
    cache: dict = st.setdefault(CACHE_KEY, {})
    for key in [k for k, v in cache.items() if state.parse_iso(v["at"]) < cutoff]:
        del cache[key]

    new, outgrown = [], []
    for rank, (sid, c) in enumerate(candidates):
        if sid not in cache:
            new.append((rank, sid, c))
        elif _outgrown(cache[sid], c, rank, now):
            outgrown.append((rank, sid, c))
    # New stories first, then a few refreshes; each best-ranked first.
    pending = new + outgrown[:settings.get("max_refresh_per_run", 5)]
    # Wait until a few stories are ready (fewer calls, well inside the free-tier limits), unless
    # one of them is near the top of the feed.
    ready = len(pending) >= settings.get("min_new", 4) or any(r < URGENT_RANK for r, _, _ in pending)
    if pending and ready and env("GEMINI_API_KEY"):
        size = settings.get("batch_size", 20)
        for call, start in enumerate(range(0, len(pending), size)):
            if call >= settings.get("max_calls_per_run", 2):
                break
            batch = [(sid, c) for _, sid, c in pending[start:start + size]]
            try:
                results = _summarize_batch(batch, cfg)
            except Exception as exc:  # rate limit, network, malformed JSON: retry next run
                log.warning("story summaries failed (%s: %s); they wait for the next run",
                            type(exc).__name__, str(exc)[:200])
                break
            for n, (sid, c) in enumerate(batch):
                if n not in results:
                    continue
                entry = {"summary": results[n], "at": state.iso(now),
                         "outlets": len(c.outlets), "newest": state.iso(c.newest)}
                if not results[n] and cache.get(sid, {}).get("summary"):
                    # A refresh that came back empty keeps the summary the story already has
                    # (the new coverage still counts, so it isn't retried every run).
                    entry["summary"] = cache[sid]["summary"]
                cache[sid] = entry
    return {sid: cache[sid]["summary"] for sid, _ in candidates
            if sid in cache and cache[sid]["summary"]}
