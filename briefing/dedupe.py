"""Cluster items that describe the same story.

Pass 1 joins items sharing a canonical URL (Techmeme/HN items point at the original article).
Pass 2 joins items whose headlines share distinctive words. Words are weighted by IDF over the
day's headlines, so "Argon" or "Uncharted" count for far more than "Google" or "AI".
Related clusters that survive both passes are merged semantically by Claude in the summarize step.

Headlines are compared as normalized words (normalize.title_tokens: "U.S. bombers" = "American
bomber", "six" = "6"). Linking is single-linkage, so one headline covering two stories would chain
them together. Roundups ("Europe Today: Russia hits Kyiv as Merz visits; Bolsonaro wins Brazil's
first round") therefore never link by title, live-blog URLs (one URL, a new headline every hour)
never link by URL, and a two-clause headline joins a story only when it doesn't bridge two.
"""
from __future__ import annotations

import math
import re
from collections import Counter

from .labels import DEAL_RE
from .models import Cluster, Item
from .normalize import canonical_url, title_tokens

# Calibrated on a day of live feeds (~200 headlines). Every pair these rules merged was the
# same story; e.g. "Gemini 4 Argon" (HN) + "Gemini 4 Argon: our next era of frontier
# intelligence" (DeepMind) + "Google announces Gemini 4 Argon AI model, but you can't use it yet".
# Shared-weight minimums are in units of the batch's max IDF (a word seen once), so they mean
# the same on a quiet 50-item day as on a busy 500-item one.
WEIGHTED_JACCARD = 0.3
# Four shared words are strong evidence even when long headlines dilute the overlap: "Nobel
# medicine prize goes to 3 scientists for research into brain activity" / "Nobel prize awarded
# for research into controlling brain cells with light". Not within one outlet, nor for deals:
# their posts share formula words ("AirPods Pro hit record low price during Prime Day").
WEIGHTED_JACCARD_4 = 0.28
# One outlet rarely runs one story twice under different headlines, but its headlines share
# house formulas ("Apple Mail added four new features in iOS 27" / "Apple Home adds two new
# features in iOS 27"). Its own updates ("(LEAD)", "2nd LD") keep nearly the same words.
SAME_OUTLET_JACCARD = 0.5
CONTAINMENT = 0.6          # share of the shorter headline's weight found in the longer one
CONTAINMENT_MIN_MASS = 2.6  # ...with roughly three rare words' worth of shared weight
NEAR_SUBSET = 0.9          # shorter headline is (almost) contained in the longer one
NEAR_SUBSET_MIN_MASS = 1.1  # ...and shares more than one rare word's worth

# Headlines that bundle several stories: newsletters, briefings, "this week in" columns.
ROUNDUP_RE = re.compile(
    r"^(?:europe today|the download|the briefing|week in \w+|this week in\b|today in .{0,40}history"
    r"|top headlines|latest news bulletin|(?:morning|evening|daily|weekly) (?:briefing|report|digest)"
    r"|[\w'’ -]{0,30}\b(?:briefing|newsletter|digest)\s*[:|]"
    # Daily podcasts and episode round-ups: "9to5Mac Daily: October 8, 2026 – iPad mini rumors".
    r"|[\w'’ -]{0,30}\b(?:daily|weekly|podcast)\s*(?:[:|]|[–—-]\s)|here's what happened today)",
    re.IGNORECASE)
# The Guardian, the NYT, the BBC and AP reuse one live-blog URL for a day of different stories.
_LIVE_BLOG_RE = re.compile(r"/(?:live|live-news|liveblog|live-updates)(?:/|$)|/live-?blog|-live-updates?\b")


def is_roundup(title: str) -> bool:
    return bool(ROUNDUP_RE.search(title))


def _two_clauses(title: str) -> bool:
    """'Euro weakens to 17-month low; Bolsonaro takes lead over Lula': two headlines in one."""
    parts = title.split(";")
    return len(parts) > 1 and sum(len(title_tokens(p)) >= 2 for p in parts) >= 2


class _UnionFind:
    def __init__(self, n: int):
        self.parent = list(range(n))

    def find(self, i: int) -> int:
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.parent[max(ra, rb)] = min(ra, rb)


def same_story(a: dict[str, float], b: dict[str, float], max_idf: float,
               loose: bool = False, same_outlet: bool = False) -> bool:
    """`a` and `b` map each headline's words to their IDF weights."""
    shared = a.keys() & b.keys()
    if len(shared) < 2:
        return False
    w_shared = sum(a[t] for t in shared)
    w_union = sum(a.values()) + sum(b.values()) - w_shared
    w_small = min(sum(a.values()), sum(b.values()))
    jaccard = w_shared / w_union if w_union else 0.0
    if same_outlet:
        return jaccard >= SAME_OUTLET_JACCARD
    if jaccard >= WEIGHTED_JACCARD or (
            loose and len(shared) >= 4 and jaccard >= WEIGHTED_JACCARD_4):
        return True
    contained = w_shared / w_small if w_small else 0.0
    rare_words = w_shared / max_idf
    return (contained >= CONTAINMENT and rare_words >= CONTAINMENT_MIN_MASS) or (
        contained >= NEAR_SUBSET and rare_words >= NEAR_SUBSET_MIN_MASS
    )


def cluster_items(items: list[Item]) -> list[Cluster]:
    uf = _UnionFind(len(items))

    by_url: dict[str, int] = {}
    for i, it in enumerate(items):
        for url in [it.canonical_url, *map(canonical_url, it.alt_urls)]:
            if not url or _LIVE_BLOG_RE.search(url):
                continue
            if url in by_url:
                uf.union(i, by_url[url])
            else:
                by_url[url] = i

    words = [title_tokens(it.title) for it in items]
    # The +1 keeps a word that appears in every headline at a small positive weight.
    df = Counter(t for ts in words for t in ts)
    n = len(items)
    idf = {t: math.log((n + 1) / c) for t, c in df.items()}
    max_idf = math.log(n + 1)
    tokens = [{t: idf[t] for t in ts} for ts in words]
    roundup = [is_roundup(it.title) for it in items]
    two = [_two_clauses(it.title) for it in items]
    loose = [not DEAL_RE.search(it.label_text) for it in items]  # may use WEIGHTED_JACCARD_4
    deferred: list[tuple[int, int]] = []
    for i in range(n):
        for j in range(i + 1, n):
            if roundup[i] or roundup[j]:
                if tokens[i].keys() == tokens[j].keys():
                    uf.union(i, j)  # the same roundup, carried by two feeds
                continue
            one_outlet = items[i].outlet == items[j].outlet
            if not same_story(tokens[i], tokens[j], max_idf, loose[i] and loose[j] and not one_outlet,
                              same_outlet=one_outlet):
                continue
            if two[i] or two[j]:
                deferred.append((i, j))
            else:
                uf.union(i, j)
    _join_two_clause(uf, deferred, two)

    groups: dict[int, list[Item]] = {}
    for i, it in enumerate(items):
        groups.setdefault(uf.find(i), []).append(it)
    return [Cluster(id=n, items=g) for n, g in enumerate(groups.values(), start=1)]


def _join_two_clause(uf: _UnionFind, links: list[tuple[int, int]], two: list[bool]) -> None:
    """Add title links that involve a two-clause headline without ever joining two stories: a
    headline whose matches belong to two different stories stays on its own."""
    def stories(i: int) -> set[int]:
        return {uf.find(k) for a, b in links if i in (a, b) for k in (a, b) if k != i and not two[k]}

    bridging = {i for i in {k for link in links for k in link} if two[i] and len(stories(i)) > 1}
    has_story = {uf.find(i): True for i in range(len(two)) if not two[i]}
    for i, j in links:
        ri, rj = uf.find(i), uf.find(j)
        if i in bridging or j in bridging or ri == rj or (has_story.get(ri) and has_story.get(rj)):
            continue
        uf.union(i, j)
        has_story[uf.find(i)] = has_story.get(ri, False) or has_story.get(rj, False)
