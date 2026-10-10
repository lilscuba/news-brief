from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta

from .normalize import clean_snippet, title_tokens

# Feeds that point at or repost other outlets' stories (and social posts): fine as coverage, poor
# as a story's headline or "Read article" link.
AGGREGATOR_OUTLETS = frozenset({"techmeme", "hn", "yahoo"})
# A headline must be this close to a story's newest item, so it follows a developing story.
HEADLINE_WINDOW = timedelta(hours=12)


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
    time_zone: str | None = None  # IANA zone for item times written without an offset (NL Times)

    @property
    def outlet(self) -> str:
        # "verge-ai" and "verge" are the same outlet; coverage counts outlets, not feeds.
        return self.key.split("-", 1)[0]

    @property
    def aggregator(self) -> bool:
        return self.outlet in AGGREGATOR_OUTLETS or "bsky.app/profile/" in self.url


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
    raw_title: str | None = None  # the headline as published, when cleaning changed it
    source_name: str | None = None  # shown instead of the feed's title, e.g. "Bloomberg via Techmeme"
    # How much `published` can be trusted: "exact" (the feed gave a time), "date" (only a day) or
    # "none" (no usable time; feeds.settle_times puts in when the pipeline first saw the item).
    time_quality: str = "exact"

    @property
    def exact_time(self) -> bool:
        return self.time_quality == "exact"

    @property
    def outlet(self) -> str:
        return self.feed.outlet

    @property
    def label_text(self) -> str:
        """What labels are judged on: the headline as published (a Bluesky deal keeps its '#ad'),
        or the English one when it was machine-translated."""
        if self.original_title is not None:
            return self.title
        return self.raw_title or self.title


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
        from .topics import category  # topics reads cluster titles; it doesn't import models

        return category(self)

    @property
    def newest(self) -> datetime:
        return max(it.published for it in self.items)

    @property
    def lead(self) -> Item:
        """The earliest item (official sources first): who broke the story. An item whose time is
        only an estimate (an undated feed) never counts as earliest over one with a real time."""
        return min(self.items, key=lambda it: (not it.feed.official, not it.exact_time, it.published))

    @property
    def headline_item(self) -> Item:
        """The item whose headline and link represent the story now: an official source if there
        is one; otherwise, among items with a real time from outlets that report rather than
        aggregate, published within 12 h of the newest, the headline sharing the most words with
        the other outlets' (the consensus wording, not one outlet's angle); else the lead."""
        from .labels import is_opinion  # labels imports this module

        official = [it for it in self.items if it.feed.official]
        if official:
            return min(official, key=lambda it: (not it.exact_time, it.published, it.id))
        newest = self.newest
        pool = [it for it in self.items
                if it.exact_time and not it.feed.aggregator and not is_opinion(it)
                and newest - it.published <= HEADLINE_WINDOW]
        if not pool:
            return self.lead
        words: dict[str, set[str]] = {}  # per outlet, so one outlet's two feeds count once
        for it in self.items:
            words.setdefault(it.outlet, set()).update(title_tokens(it.title))
        if len(words) < 3:
            # One other outlet is no consensus to measure: the newest headline is the most current.
            return max(pool, key=lambda it: (it.published, it.id))

        def representative(it: Item) -> float:
            tokens = title_tokens(it.title)
            others = [w for outlet, w in words.items() if outlet != it.outlet]
            if not tokens:
                return 0.0
            # Share of the other outlets using each word, damped so long headlines don't win by size.
            return sum(t in w for t in tokens for w in others) / len(others) / len(tokens) ** 0.5

        return max(pool, key=lambda it: (round(representative(it), 6), it.published, it.id))

    def snippet(self, limit: int, first: Item | None = None) -> str:
        """A readable feed snippet for the story: `first`'s (default: the headline item's), else the
        first other item, official sources and earliest first, that has a usable one."""
        first = first or self.headline_item
        rest = sorted((it for it in self.items if it is not first),
                      key=lambda it: (not it.feed.official, it.published))
        for it in (first, *rest):
            if text := clean_snippet(it.summary, it.title, limit):
                return text
        return ""
