"""Short AI summaries for the top stories in the shared app feed.

A feed story's own summary is just the first outlet's RSS snippet, which is often empty or
boilerplate. For the highest-ranked stories this asks Gemini for a one- or two-sentence summary
written from the headlines and snippets of every outlet covering the story. Only text the feeds
already provide is sent, never article pages, so nothing is scraped.

Each story is summarized once and cached in the ingest state. Failure is never fatal: with no key,
a rate limit or a bad response the story simply keeps its snippet and is retried on a later run.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta

from pydantic import BaseModel

from . import state
from .config import env
from .models import Cluster
from .summarize import gemini_json, gemini_schema

log = logging.getLogger(__name__)

CACHE_KEY = "story_summaries"
CACHE_DAYS = 4
SNIPPET_CHARS = 300
MAX_SOURCES = 4
MAX_SUMMARY_CHARS = 400

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


def _payload(batch: list[tuple[str, Cluster]]) -> str:
    stories = [{
        "i": n,
        "outlets": len(c.outlets),
        "official": c.official,
        "sources": [{"outlet": it.feed.title, "headline": it.title, "snippet": it.summary[:SNIPPET_CHARS]}
                    for it in c.items[:MAX_SOURCES]],
    } for n, (_, c) in enumerate(batch)]
    return json.dumps(stories, ensure_ascii=False)


def _summarize_batch(batch: list[tuple[str, Cluster]], cfg: dict) -> dict[int, str]:
    text, usage = gemini_json(SYSTEM_PROMPT, _payload(batch), gemini_schema(_Batch), cfg, timeout=90)
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

    pending = [(sid, c) for sid, c in candidates if sid not in cache]
    # Wait until a few stories are ready: fewer calls, well inside the free-tier limits.
    if len(pending) >= settings.get("min_new", 4) and env("GEMINI_API_KEY"):
        size = settings.get("batch_size", 20)
        for call, start in enumerate(range(0, len(pending), size)):
            if call >= settings.get("max_calls_per_run", 2):
                break
            batch = pending[start:start + size]
            try:
                results = _summarize_batch(batch, cfg)
            except Exception as exc:  # rate limit, network, malformed JSON: retry next run
                log.warning("story summaries failed (%s: %s); they wait for the next run",
                            type(exc).__name__, str(exc)[:200])
                break
            for n, (sid, _) in enumerate(batch):
                if n in results:
                    cache[sid] = {"summary": results[n], "at": state.iso(now)}
    return {sid: cache[sid]["summary"] for sid, _ in candidates
            if sid in cache and cache[sid]["summary"]}
