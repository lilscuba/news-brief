"""Cluster items that describe the same story.

Pass 1 joins items sharing a canonical URL (Techmeme/HN items point at the original article).
Pass 2 joins items whose headlines share distinctive words. Words are weighted by IDF over the
day's headlines, so "Argon" or "Uncharted" count for far more than "Google" or "AI".
Related clusters that survive both passes are merged semantically by Claude in the summarize step.
"""
from __future__ import annotations

import math
from collections import Counter

from .models import Cluster, Item
from .normalize import title_tokens

# Calibrated on a day of live feeds (~200 headlines). Every pair these rules merged was the
# same story; e.g. "Gemini 4 Argon" (HN) + "Gemini 4 Argon: our next era of frontier
# intelligence" (DeepMind) + "Google announces Gemini 4 Argon AI model, but you can't use it yet".
# Shared-weight minimums are in units of the batch's max IDF (a word seen once), so they mean
# the same on a quiet 50-item day as on a busy 500-item one.
WEIGHTED_JACCARD = 0.3
CONTAINMENT = 0.6          # share of the shorter headline's weight found in the longer one
CONTAINMENT_MIN_MASS = 2.6  # ...with roughly three rare words' worth of shared weight
NEAR_SUBSET = 0.9          # shorter headline is (almost) contained in the longer one
NEAR_SUBSET_MIN_MASS = 1.1  # ...and shares more than one rare word's worth


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


def same_story(a: frozenset[str], b: frozenset[str], idf: dict[str, float],
               max_idf: float) -> bool:
    shared = a & b
    if len(shared) < 2:
        return False
    w_shared = sum(idf[t] for t in shared)
    w_union = sum(idf[t] for t in a | b)
    w_small = min(sum(idf[t] for t in a), sum(idf[t] for t in b))
    if w_union and w_shared / w_union >= WEIGHTED_JACCARD:
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
        for url in [it.canonical_url, *it.alt_urls]:
            if not url:
                continue
            if url in by_url:
                uf.union(i, by_url[url])
            else:
                by_url[url] = i

    tokens = [title_tokens(it.title) for it in items]
    # The +1 keeps a word that appears in every headline at a small positive weight.
    df = Counter(t for ts in tokens for t in ts)
    n = len(items)
    idf = {t: math.log((n + 1) / c) for t, c in df.items()}
    max_idf = math.log(n + 1)
    for i in range(n):
        for j in range(i + 1, n):
            if same_story(tokens[i], tokens[j], idf, max_idf):
                uf.union(i, j)

    groups: dict[int, list[Item]] = {}
    for i, it in enumerate(items):
        groups.setdefault(uf.find(i), []).append(it)
    return [Cluster(id=n, items=g) for n, g in enumerate(groups.values(), start=1)]
