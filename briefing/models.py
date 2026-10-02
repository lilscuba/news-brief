from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime


@dataclass(frozen=True)
class Feed:
    key: str
    title: str
    url: str
    category: str
    official: bool = False
    alert_mode: str = "watch"  # "all" | "watch" | "never"
    mirror: bool = False
    max_items: int | None = None  # cap per brief for firehose feeds (arXiv, Steam)
    trusted: bool = False  # strong scoop track record: its rumors are RUMOR-CREDIBLE, alerts solo
    lang: str = "en"  # ISO 639-1 code; anything but "en" is machine-translated at ingest

    @property
    def outlet(self) -> str:
        # "verge-ai" and "verge" are the same outlet; coverage counts outlets, not feeds.
        return self.key.split("-", 1)[0]


@dataclass
class Item:
    id: str
    feed: Feed
    title: str
    url: str
    canonical_url: str
    summary: str
    published: datetime
    alt_urls: list[str] = field(default_factory=list)
    hn_points: int | None = None
    original_title: str | None = None  # set when title/summary were machine-translated

    @property
    def outlet(self) -> str:
        return self.feed.outlet


@dataclass
class Cluster:
    id: int
    items: list[Item]
    score: float = 0.0

    @property
    def outlets(self) -> list[str]:
        seen: dict[str, None] = {}
        for it in self.items:
            seen.setdefault(it.outlet, None)
        return list(seen)

    @property
    def official(self) -> bool:
        return any(it.feed.official for it in self.items)

    @property
    def category(self) -> str:
        counts: dict[str, int] = {}
        for it in self.items:
            counts[it.feed.category] = counts.get(it.feed.category, 0) + 1
        return max(counts, key=counts.get)

    @property
    def newest(self) -> datetime:
        return max(it.published for it in self.items)

    @property
    def lead(self) -> Item:
        """The item used as the cluster's headline: prefer official sources, then the earliest."""
        return min(self.items, key=lambda it: (not it.feed.official, it.published))
