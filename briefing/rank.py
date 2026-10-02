from __future__ import annotations

import math
from datetime import datetime

from .models import Cluster


def score_cluster(cluster: Cluster, cfg: dict, now: datetime) -> float:
    r = cfg["ranking"]
    weight = r.get("category_weight", {}).get(cluster.category, 1.0)
    score = r["per_source"] * len(cluster.outlets) * weight
    if cluster.official:
        score += r["official_boost"]
    if "techmeme" in cluster.outlets:
        score += r["techmeme_boost"]
    points = max((it.hn_points or 0 for it in cluster.items), default=0)
    if points > 1:
        score += r["hn_points_weight"] * math.log10(points)
    text = " ".join(it.title for it in cluster.items).lower()
    score += sum(w for term, w in r["boosts"].items() if term.lower() in text)
    age_hours = max(0.0, (now - cluster.newest).total_seconds() / 3600)
    score -= r["age_penalty_per_hour"] * age_hours
    return round(score, 2)


def rank(clusters: list[Cluster], cfg: dict, now: datetime) -> list[Cluster]:
    for c in clusters:
        c.score = score_cluster(c, cfg, now)
    return sorted(clusters, key=lambda c: c.score, reverse=True)


def is_muted(title: str, cfg: dict) -> bool:
    lowered = title.lower()
    return any(term in lowered for term in cfg["digest"]["mute"])
