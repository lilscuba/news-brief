"""Reliability labels for stories, so a rumor never reads like a confirmed announcement.

CONFIRMED         an official / first-party source published it
REPORTED          journalism from an outlet, not (yet) confirmed by the company
RUMOR-CREDIBLE    leak or rumor from a source with a strong track record, or several outlets
RUMOR-UNVERIFIED  leak or rumor from a single source without that track record
DEAL              a sale, discount or price drop

In AI mode the model assigns labels; these rules are the fallback and the list-mode labeler.
"""
from __future__ import annotations

import re

from .models import Cluster, Item

LABELS = ("CONFIRMED", "REPORTED", "RUMOR-CREDIBLE", "RUMOR-UNVERIFIED", "DEAL")

DEAL_TERMS = (
    "deal:", "deals:", "deal alert", "% off", "lowest price", "all-time low", "price drop",
    "on sale", "sale:", "save $", "discount", "coupon", "free to keep", "free this week",
    "prime day", "black friday", "cyber monday",
)
RUMOR_TERMS = ("rumor", "rumour", "leak", "allegedly", "datamine", "unannounced")
# "Keeper is $13.99 on Steam", "$45.65 at VGP", and Wario64's "#ad" affiliate posts.
# "EXCLUSIVE: ..." or "🚨 EXCLUSIVE 🚨 ..." at the start of a headline.
SCOOP_RE = re.compile(r"^\W*exclusive\b\s*(?:[:|\-–—]|\W*$|\W+\s)", re.IGNORECASE)
DEAL_RE = re.compile(r"\$\d[\d,]*(?:\.\d\d)?\s+(?:on|at|@|via)\s|#ad\b", re.IGNORECASE)


def _text(items: list[Item]) -> str:
    return " ".join(it.title for it in items).lower()


def label_cluster(cluster: Cluster) -> str:
    text = _text(cluster.items)
    if any(t in text for t in DEAL_TERMS) or DEAL_RE.search(text):
        return "DEAL"
    trusted = any(it.feed.trusted for it in cluster.items)
    if any(t in text for t in RUMOR_TERMS):
        credible = trusted or len(cluster.outlets) >= 2
        return "RUMOR-CREDIBLE" if credible else "RUMOR-UNVERIFIED"
    # An "EXCLUSIVE:" scoop from a proven leaker (billbil-kun, VGC) is a credible leak, not
    # confirmation. "Exclusive interview" or "PS5 exclusive" aren't scoops, hence the tag shape.
    scoop = any(SCOOP_RE.search(it.title) for it in cluster.items)
    if scoop and trusted and not cluster.official:
        return "RUMOR-CREDIBLE"
    if cluster.official:
        return "CONFIRMED"
    return "REPORTED"


def is_deal(cluster: Cluster) -> bool:
    return label_cluster(cluster) == "DEAL"
