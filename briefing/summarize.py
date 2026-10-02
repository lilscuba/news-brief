"""Turn ranked story clusters into the daily brief with one AI call (Gemini or Claude).

The model only ever sees cluster ids and returns cluster ids; every URL in the published brief
is attached here from the fetched feeds, so the model can't invent links.
"""
from __future__ import annotations

import json
import logging
import time
from datetime import datetime
from typing import Literal

import requests
from pydantic import BaseModel, ConfigDict

from .config import env
from .labels import label_cluster
from .models import Cluster

log = logging.getLogger(__name__)

# Models that accept Anthropic's server-side `fallbacks: "default"` refusal fallback.
_FALLBACK_MODELS = ("claude-opus-5", "claude-fable-5", "claude-sonnet-5-5")
GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
# "This model is currently experiencing high demand" (503) is usually a brief spike; a short
# retry rides it out. Anything still failing is retried by the next scheduled run.
GEMINI_RETRY_STATUS = {429, 500, 502, 503, 504}
GEMINI_RETRY_DELAYS = (3, 8)

Label = Literal["CONFIRMED", "REPORTED", "RUMOR-CREDIBLE", "RUMOR-UNVERIFIED", "DEAL"]


class LLMStory(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str
    summary: str
    importance: int
    label: Label
    cluster_ids: list[int]


class LLMSection(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str
    stories: list[LLMStory]


class LLMBrief(BaseModel):
    model_config = ConfigDict(extra="forbid")
    headline: str
    top: list[LLMStory]
    sections: list[LLMSection]


SYSTEM_PROMPT = """You are the editor of a personal morning news briefing covering AI, tech, \
video games, and world news. The reader is an iOS developer who follows AI labs (Anthropic, \
OpenAI, Google), Apple platforms, and the console/PC games industry, plus world news in the \
World, Europe, Japan and Korea sections. They are replacing Reddit with this brief, so it \
should tell them everything worth knowing today in a few minutes of reading.

You receive story clusters gathered from RSS feeds and journalists' Bluesky posts over the last \
day. Each cluster has a numeric id, a category guess, the outlets covering it, flags, and \
headlines with snippets. Clusters were grouped by URL and headline similarity, so several \
clusters may still describe the same event.

How to write the brief:
- Merge clusters about the same event into one story and list every merged id in cluster_ids.
- `top`: the 5 most important stories of the day across all categories. Weigh real-world impact, \
how many outlets covered it, official announcements, and the reader's interests above. Never \
put a deal in `top`.
- `sections`: one entry per section name given in the request, in that order. Put each remaining \
story worth reading in exactly one section; sales and discounts go only in the Deals section. \
A story in `top` must not appear again in a section. Aim for 6-12 stories per section (up to 8 \
deals; 4-8 for World, Europe, Japan and Korea, major news only); leave out minor items, \
listicles, and evergreen guides. A section may be empty.
- title: a plain, specific headline in your own words (no clickbait, no outlet names).
- summary: 1-2 sentences saying what happened and why it matters. State facts from the \
headlines and snippets only; if details are unclear, say less rather than guess.
- importance: 1 (minor) to 5 (major news everyone in the field will be talking about).
- label, exactly one of:
  CONFIRMED: an official / first-party source announced it (clusters flagged "official").
  REPORTED: an outlet reports it, not confirmed by the company.
  RUMOR-CREDIBLE: a leak or rumor from a source flagged "trusted", or several independent outlets.
  RUMOR-UNVERIFIED: a leak or rumor from a single source that isn't flagged "trusted".
  DEAL: a sale, discount or price drop.
  The "suggested label" on each cluster is a keyword guess; override it when the text says otherwise.
- Ordinary news reporting (politics, conflict, economy) is REPORTED, never a RUMOR label. \
Headlines from some outlets were machine-translated into English; write them as normal English.
- Write rumors as rumors ("reportedly", "according to a leak"), never as fact.
- headline: one sentence capturing the day as a whole.
- Only use cluster ids that appear in the input."""


def _render_clusters(clusters: list[Cluster]) -> str:
    lines: list[str] = []
    for c in clusters:
        flags = [f"suggested label {label_cluster(c)}"]
        if c.official:
            flags.append("official")
        if any(it.feed.trusted for it in c.items):
            flags.append("trusted")
        lines.append(
            f"[{c.id}] {c.category} | {len(c.outlets)} outlet(s): {', '.join(c.outlets)}"
            f" | {' | '.join(flags)}"
        )
        for i, it in enumerate(c.items[:4]):
            snippet = f" — {it.summary[:220]}" if i == 0 and it.summary else ""
            lines.append(f"  - {it.feed.title}: {it.title}{snippet}")
        if len(c.items) > 4:
            lines.append(f"  - (+{len(c.items) - 4} more)")
    return "\n".join(lines)


def _user_prompt(clusters: list[Cluster], cfg: dict, now: datetime) -> str:
    sections = cfg["digest"]["sections"]
    return (
        f"Today is {now:%A, %B %d, %Y}. Section names, in order: {', '.join(sections)}.\n\n"
        f"{len(clusters)} story clusters, highest-ranked first:\n\n{_render_clusters(clusters)}"
    )


def summarize(clusters: list[Cluster], cfg: dict, now: datetime) -> tuple[LLMBrief, dict]:
    """Return the structured brief and a small usage record. Raises on any API failure."""
    provider = cfg.get("ai", {}).get("provider", "gemini")
    user = _user_prompt(clusters, cfg, now)
    if provider == "gemini":
        brief, usage = _gemini(user, cfg)
    elif provider == "claude":
        brief, usage = _claude(user, cfg)
    else:
        raise ValueError(f"unknown ai.provider {provider!r} (use 'gemini' or 'claude')")
    log.info("AI usage: %s", usage)
    return brief, usage


# --- Gemini (Google AI Studio) ------------------------------------------------------------------

def gemini_schema(model: type[BaseModel]) -> dict:
    """Pydantic's JSON Schema, inlined into the OpenAPI subset generateContent's responseSchema
    accepts: no $defs/$ref, titles or additionalProperties."""
    raw = model.model_json_schema()
    defs = raw.pop("$defs", {})

    def walk(node):
        if isinstance(node, dict):
            if "$ref" in node:
                return walk(defs[node["$ref"].rsplit("/", 1)[-1]])
            out = {}
            for k, v in node.items():
                if k in ("title", "additionalProperties"):
                    continue
                # Property *names* stay even when one is called "title" (the story headline).
                out[k] = {n: walk(s) for n, s in v.items()} if k == "properties" else walk(v)
            return out
        if isinstance(node, list):
            return [walk(v) for v in node]
        return node

    return walk(raw)


def _post_gemini(model: str, key: str, body: dict, timeout: int, delays: tuple) -> requests.Response:
    """POST one generateContent request, retrying transient failures after each delay."""
    for attempt in range(len(delays) + 1):
        last = attempt == len(delays)
        try:
            # Header, not ?key=, so the key never shows up in logged URLs.
            resp = requests.post(GEMINI_URL.format(model=model), json=body, timeout=timeout,
                                 headers={"x-goog-api-key": key})
            if resp.status_code not in GEMINI_RETRY_STATUS or last:
                return resp
            reason = f"HTTP {resp.status_code}"
        except (requests.ConnectionError, requests.Timeout) as exc:
            if last:
                raise
            reason = type(exc).__name__
        log.info("Gemini %s on %s; retrying in %ss", reason, model, delays[attempt])
        time.sleep(delays[attempt])
    raise AssertionError("unreachable")


def gemini_json(system: str, user: str, schema: dict, cfg: dict,
                timeout: int = 300) -> tuple[str, dict]:
    """One structured-output generateContent call. Returns the JSON text and usage.

    The configured model is retried on transient errors; if it is still overloaded, each of
    `[gemini] fallback_models` gets one try. Client errors (bad request, bad key) never fall back."""
    key = env("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    models = [cfg["gemini"]["model"], *cfg["gemini"].get("fallback_models", [])]
    body = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [{"text": user}]}],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": schema,
        },
    }
    for n, model in enumerate(models):
        more = n < len(models) - 1
        try:
            resp = _post_gemini(model, key, body, timeout, GEMINI_RETRY_DELAYS if n == 0 else ())
        except (requests.ConnectionError, requests.Timeout):
            if not more:
                raise
            log.warning("Gemini %s unreachable; trying %s", model, models[n + 1])
            continue
        if resp.status_code in GEMINI_RETRY_STATUS and more:
            log.warning("Gemini %s returned HTTP %s; trying %s", model, resp.status_code, models[n + 1])
            continue
        break
    if resp.status_code != 200:
        raise RuntimeError(f"Gemini HTTP {resp.status_code}: {resp.text[:300]}")
    data = resp.json()
    candidates = data.get("candidates") or []
    if not candidates:
        raise RuntimeError(f"Gemini returned no candidates: {json.dumps(data)[:300]}")
    cand = candidates[0]
    if cand.get("finishReason") not in (None, "STOP"):
        raise RuntimeError(f"Gemini stopped early: {cand.get('finishReason')}")
    text = "".join(p.get("text", "") for p in cand.get("content", {}).get("parts", []))
    meta = data.get("usageMetadata", {})
    return text, {
        "model": data.get("modelVersion") or model,
        "input_tokens": meta.get("promptTokenCount"),
        "output_tokens": meta.get("candidatesTokenCount"),
    }


def _gemini(user: str, cfg: dict) -> tuple[LLMBrief, dict]:
    text, usage = gemini_json(SYSTEM_PROMPT, user, gemini_schema(LLMBrief), cfg)
    return LLMBrief.model_validate_json(text), usage


# --- Claude (Anthropic API) ---------------------------------------------------------------------

def _claude(user: str, cfg: dict) -> tuple[LLMBrief, dict]:
    import anthropic

    c = cfg["claude"]
    model: str = c["model"]
    output_config: dict = {
        "format": {"type": "json_schema", "schema": LLMBrief.model_json_schema()},
    }
    if not model.startswith("claude-haiku"):
        output_config["effort"] = c["effort"]

    kwargs: dict = {
        "model": model,
        "max_tokens": c["max_tokens"],
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user}],
        "output_config": output_config,
    }
    client = anthropic.Anthropic(max_retries=4)
    if model.startswith(_FALLBACK_MODELS):
        # If a safety classifier declines, re-run on Anthropic's recommended fallback model.
        stream_ctx = client.beta.messages.stream(
            **kwargs,
            betas=["server-side-fallback-2026-07-01"],
            extra_body={"fallbacks": "default"},
        )
    else:
        stream_ctx = client.messages.stream(**kwargs)

    # Streaming keeps a long thinking + output turn clear of HTTP timeouts.
    with stream_ctx as stream:
        message = stream.get_final_message()

    if message.stop_reason == "refusal":
        raise RuntimeError(f"Claude declined the request: {message.stop_details}")
    if message.stop_reason == "max_tokens":
        raise RuntimeError("Claude hit max_tokens before finishing the brief")

    text = next(b.text for b in message.content if b.type == "text")
    return LLMBrief.model_validate_json(text), {
        "model": message.model,
        "input_tokens": message.usage.input_tokens,
        "output_tokens": message.usage.output_tokens,
        "request_id": message._request_id,
    }


# --- No AI --------------------------------------------------------------------------------------

def list_brief(clusters: list[Cluster], cfg: dict, feeds_ok: int = 0) -> LLMBrief:
    """No-AI brief: every story listed under its feed's section, using the original headline and
    the feed's own snippet. Deals go to the Deals section; the 5 highest-ranked non-deal stories
    go on top. `clusters` must already be ranked."""
    def story(cl: Cluster) -> LLMStory:
        lead = cl.lead
        return LLMStory(
            title=lead.title,
            summary=lead.summary[:240],
            importance=min(5, max(1, len(cl.outlets))),
            label=label_cluster(cl),
            cluster_ids=[cl.id],
        )

    deals_section = "Deals" if "Deals" in cfg["digest"]["sections"] else None

    def section_of(cl: Cluster) -> str:
        if deals_section and label_cluster(cl) == "DEAL":
            return deals_section
        return cl.category

    news = [c for c in clusters if section_of(c) != deals_section]
    top = news[:5]
    top_ids = {c.id for c in top}
    rest = [c for c in clusters if c.id not in top_ids]
    # Configured sections first, then any OPML category that isn't listed, so nothing is dropped.
    names = list(cfg["digest"]["sections"])
    names += [section_of(c) for c in rest if section_of(c) not in names]
    sections = [
        LLMSection(name=name, stories=[story(c) for c in rest if section_of(c) == name])
        for name in dict.fromkeys(names)
    ]
    item_count = sum(len(c.items) for c in clusters)
    source = f" from {feeds_ok} feeds" if feeds_ok else ""
    return LLMBrief(
        headline=f"{item_count} new articles{source}, grouped into {len(clusters)} stories.",
        top=[story(c) for c in top],
        sections=sections,
    )
