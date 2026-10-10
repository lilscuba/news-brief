"""Machine-translate headlines and snippets from non-English feeds into English, once.

Feeds marked pfLang="de" (etc.) in feeds.opml are sent to Gemini in batches. Results are cached in
the pipeline's state file by item id, so an item is translated a single time. Translated items keep
their original headline (`original_title`) so the app can show it.

Failure is never fatal: with no key, a rate limit or a bad response the items stay untranslated,
are left out of the feed (`is_readable`) rather than shown in the wrong language, and are retried
on the next run.

The ingest runs every 10 minutes, so headlines are collected into batches (`min_batch`) rather
than sent one or two at a time; none waits longer than `max_wait_minutes`. Translation runs on
its own model list (`[translate] models`, Flash-Lite first), leaving the main model's free-tier
quota for summaries.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta

from pydantic import BaseModel

from . import state
from .config import env
from .models import Item
from .normalize import clean_title
from .summarize import gemini_json, gemini_schema

log = logging.getLogger(__name__)

CACHE_KEY = "translations"
CACHE_DAYS = 4
SNIPPET_CHARS = 240

SYSTEM_PROMPT = (
    "You translate news headlines and short article snippets into natural, neutral English for "
    "a news reader. Translate faithfully: never add, drop, soften or sharpen a fact. Keep names, "
    "numbers and quoted speech, and use the conventional English form of place names and "
    "organisations. Headlines should read like English headlines, not word-for-word translations. "
    "Return every input item with the same `i`. If a snippet is empty, return an empty summary."
)


class _Translated(BaseModel):
    i: int
    title: str
    summary: str


class _Batch(BaseModel):
    items: list[_Translated]


def is_readable(item: Item) -> bool:
    """English items, and foreign ones that have been translated. Untranslated foreign items
    would show up in the wrong language, so callers leave them out until they are."""
    return item.feed.lang == "en" or item.original_title is not None


def _apply(item: Item, title: str, summary: str) -> None:
    item.original_title = item.title
    item.title = clean_title(title) or item.title
    item.summary = summary.strip()


def _translate_batch(batch: list[Item], cfg: dict) -> dict[int, _Translated]:
    payload = [{"i": n, "lang": it.feed.lang, "title": it.title, "summary": it.summary[:SNIPPET_CHARS]}
               for n, it in enumerate(batch)]
    text, usage = gemini_json(SYSTEM_PROMPT, json.dumps(payload, ensure_ascii=False),
                              gemini_schema(_Batch), cfg, timeout=90,
                              models=cfg.get("translate", {}).get("models"))
    out = {t.i: t for t in _Batch.model_validate_json(text).items if t.title.strip()}
    log.info("translated %d/%d items (%s in, %s out tokens)", len(out), len(batch),
             usage.get("input_tokens"), usage.get("output_tokens"))
    return out


def translate_items(items: list[Item], cfg: dict, st: dict, now: datetime) -> int:
    """Translate the non-English `items` in place, using and updating `st["translations"]`.
    Returns how many items now carry a translation."""
    settings = cfg.get("translate", {})
    foreign = [it for it in items if it.feed.lang != "en" and it.original_title is None]
    if not foreign or not settings.get("enabled", True):
        return 0

    cutoff = now - timedelta(days=CACHE_DAYS)
    cache: dict = st.setdefault(CACHE_KEY, {})
    for key in [k for k, v in cache.items() if state.parse_iso(v["at"]) < cutoff]:
        del cache[key]

    translated, pending = 0, []
    for it in foreign:
        if hit := cache.get(it.id):
            _apply(it, hit["title"], hit["summary"])
            translated += 1
        else:
            pending.append(it)
    # Newest first, so a backlog (first run, an outage) never delays today's headlines.
    pending.sort(key=lambda it: it.published, reverse=True)

    if pending and not env("GEMINI_API_KEY"):
        log.warning("%d headlines need translating but GEMINI_API_KEY is not set", len(pending))
        return translated
    # A short batch waits for the next run, unless its oldest headline (the last) has waited enough.
    max_wait = timedelta(minutes=settings.get("max_wait_minutes", 20))
    if pending and len(pending) < settings.get("min_batch", 10) and now - pending[-1].published < max_wait:
        log.info("%d headline(s) wait for a fuller translation batch", len(pending))
        return translated

    size = settings.get("batch_size", 40)
    max_calls = settings.get("max_calls_per_run", 3)
    for call, start in enumerate(range(0, len(pending), size)):
        if call >= max_calls:
            log.info("translation call limit reached; %d items wait for the next run",
                     len(pending) - start)
            break
        batch = pending[start:start + size]
        try:
            results = _translate_batch(batch, cfg)
        except Exception as exc:  # rate limit, network, malformed JSON: retry next run
            log.warning("translation failed (%s: %s); those items wait for the next run",
                        type(exc).__name__, str(exc)[:200])
            break
        for n, it in enumerate(batch):
            if (r := results.get(n)) is None:
                continue
            cache[it.id] = {"title": r.title, "summary": r.summary, "at": state.iso(now)}
            _apply(it, r.title, r.summary)
            translated += 1
    return translated
