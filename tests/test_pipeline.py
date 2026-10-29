from datetime import datetime, timedelta, timezone

import pytest

from briefing import alerts, render
from briefing.dedupe import cluster_items
from briefing.digest import _apply_feed_caps, assemble
from briefing.feeds import parse_feed
from briefing.models import Feed, Item
from briefing.normalize import canonical_url, clean_title, title_tokens
from briefing.rank import rank
from briefing.summarize import LLMBrief, LLMSection, LLMStory, list_brief

NOW = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)

CFG = {
    "digest": {"sections": ["AI", "Tech", "Gaming"], "mute": ["deals:"]},
    "ranking": {"per_source": 3.0, "official_boost": 2.5, "techmeme_boost": 3.0,
                "hn_points_weight": 1.5, "age_penalty_per_hour": 0.08, "boosts": {"claude": 3.0}},
    "alerts": {"max_per_day": 5, "lookback_minutes": 90, "min_sources": 2, "watch": [
        {"name": "Gemini launch", "match": [["gemini"], ["launch", "release", "announce"]]},
        {"name": "Nintendo Direct", "match": [["nintendo direct"]]},
    ]},
}

# Unrelated headlines so IDF weights resemble a real day's batch.
FILLER = [
    "Valve updates Steam Deck firmware with battery fixes",
    "Samsung foldable sales slow in Europe this quarter",
    "Netflix raises subscription prices in three countries",
    "Ubisoft delays Assassin's Creed remake into next year",
    "Microsoft patches Windows zero-day exploited in the wild",
    "Tesla recalls Cybertruck over loose trim panel",
    "Epic Games Store adds wishlist sharing feature",
    "Intel announces new Arc graphics driver for older games",
    "Spotify tests lossless audio tier with select users",
    "Amazon expands drone delivery to two new cities",
    "Meta cuts price of Quest headset ahead of holidays",
    "Sony confirms PlayStation Portal firmware update",
]


def feed(key, category="Tech", official=False, alert_mode="watch", max_items=None, trusted=False):
    return Feed(key=key, title=key.title(), url=f"https://{key}.example/feed", category=category,
                official=official, alert_mode=alert_mode, max_items=max_items, trusted=trusted)


def item(f, title, minutes_ago=30, url=None, n=[0]):
    n[0] += 1
    url = url or f"https://{f.key}.example/{n[0]}"
    return Item(id=f"{f.key}-{n[0]}", feed=f, title=title, url=url,
                canonical_url=canonical_url(url), summary="", published=NOW - timedelta(minutes=minutes_ago))


def filler_items():
    f = feed("misc")
    return [item(f, t, url=f"https://misc.example/{i}") for i, t in enumerate(FILLER)]


def test_canonical_url_strips_tracking_and_www():
    a = canonical_url("https://www.theverge.com/2026/10/1/story/?utm_source=rss&utm_medium=feed#x")
    b = canonical_url("http://theverge.com/2026/10/1/story")
    assert a == b


def test_clean_title_drops_outlet_suffix():
    assert clean_title("Big news happens - The Verge") == "Big news happens"
    assert "gemini" in title_tokens("Gemini 4 Argon: our next era")


def test_rewritten_headlines_cluster_together():
    deepmind, hn, ars = feed("deepmind", "AI", official=True), feed("hn"), feed("ars")
    items = filler_items() + [
        item(deepmind, "Gemini 4 Argon: our next era of frontier intelligence"),
        item(hn, "Gemini 4 Argon"),
        item(ars, "Google announces Gemini 4 Argon AI model, but you can't use it yet"),
    ]
    clusters = cluster_items(items)
    gemini = [c for c in clusters if any("Argon" in it.title for it in c.items)]
    assert len(gemini) == 1
    assert sorted(gemini[0].outlets) == ["ars", "deepmind", "hn"]
    assert len(clusters) == len(FILLER) + 1  # nothing else got merged


def test_shared_url_clusters_even_with_different_titles():
    a, b = feed("verge"), feed("techmeme")
    items = [item(a, "Apple ships iOS 26.1", url="https://theverge.com/x?utm_source=a"),
             item(b, "Apple releases update with bug fixes", url="https://theverge.com/x")]
    assert len(cluster_items(items)) == 1


def test_rank_prefers_multi_outlet_and_boosts():
    deepmind, hn, ars, misc = feed("deepmind", official=True), feed("hn"), feed("ars"), feed("misc")
    items = filler_items() + [
        item(deepmind, "Gemini 4 Argon: our next era of frontier intelligence"),
        item(ars, "Google announces Gemini 4 Argon AI model, but you can't use it yet"),
        item(hn, "Gemini 4 Argon"),
        item(misc, "Claude gets a new mobile widget"),
    ]
    ranked = rank(cluster_items(items), CFG, NOW)
    assert "Argon" in ranked[0].lead.title
    assert "Claude" in ranked[1].lead.title  # single source, but boosted above filler


def test_feed_caps_keep_newest():
    arxiv = feed("arxiv", max_items=2)
    items = [item(arxiv, f"Paper {i}", minutes_ago=i) for i in range(5)] + filler_items()
    kept = _apply_feed_caps(items)
    assert [it.title for it in kept if it.feed.key == "arxiv"] == ["Paper 0", "Paper 1"]
    assert len(kept) == 2 + len(FILLER)


def test_parse_feed_extracts_hn_points_and_techmeme_link():
    rss = b"""<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>
      <item><title>Show HN: Thing</title><link>https://example.com/thing</link>
        <description>&lt;p&gt;Points: 321&lt;/p&gt;</description>
        <pubDate>Wed, 01 Oct 2026 10:00:00 GMT</pubDate></item></channel></rss>"""
    [it] = parse_feed(feed("hn"), rss, NOW)
    assert it.hn_points == 321 and it.summary == ""
    tm = b"""<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>
      <item><title>Story</title><link>https://www.techmeme.com/261001/p1</link>
        <description>&lt;a href="https://www.theverge.com/a?utm_source=tm"&gt;x&lt;/a&gt;</description>
      </item></channel></rss>"""
    [it] = parse_feed(feed("techmeme"), tm, NOW)
    assert it.alt_urls == ["https://theverge.com/a"]
    assert it.published == NOW  # undated -> now


def _rss(*items: str) -> bytes:
    body = "".join(f"<item><title>T{i}</title><link>https://example.com/{i}</link>{x}</item>"
                   for i, x in enumerate(items))
    return (f'<?xml version="1.0"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" '
            f'xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>t</title>'
            f"{body}</channel></rss>").encode()


def test_parse_feed_finds_each_articles_picture():
    rss = _rss(
        # largest media:content image wins; video and the small thumbnail don't
        '<media:content url="https://i.example/v.mp4" medium="video" width="1920"/>'
        '<media:content url="https://i.example/a-140.jpg" width="140"/>'
        '<media:content url="https://i.example/a-460.jpg" width="460"/>'
        '<media:thumbnail url="https://i.example/a-thumb.jpg" width="240"/>',
        '<enclosure url="https://i.example/b.jpg" type="image/jpeg" length="1"/>',
        # tracking pixel and tiny icon skipped; entities decoded; http upgraded for iOS
        '<content:encoded><![CDATA[<img src="https://feeds.feedburner.com/~r/x/~4/1" width="1">'
        '<img src="https://i.example/icon.png" width="32">'
        '<img src="http://i.example/c.jpg?w=800&amp;q=80" width="800"></p>]]></content:encoded>',
        "<description><![CDATA[<p><img src='//i.example/d image.jpg'/>Hi</p>]]></description>",
        "<description>No picture here</description>",
        '<media:thumbnail url="https://i.example/small.jpg" width="240"/>',
    )
    images = [it.image for it in parse_feed(feed("verge"), rss, NOW)]
    assert images == ["https://i.example/a-460.jpg", "https://i.example/b.jpg",
                      "https://i.example/c.jpg?w=800&q=80", "https://i.example/d%20image.jpg",
                      None, None]
    [tm] = parse_feed(feed("techmeme"), _rss('<media:content url="https://i.example/tm.jpg"/>'), NOW)
    assert tm.image is None


def test_parse_feed_skips_pixels_and_small_repeats_and_upsizes_bbc():
    pixel = "<img src='https://media.npr.org/include/images/tracking/npr-rss-pixel.png?story=nx-1' />"
    small = "https://e.example/70x70/sky.jpg"
    rss = _rss(
        f"<content:encoded><![CDATA[<p>Body</p>{pixel}]]></content:encoded>",
        f"<content:encoded><![CDATA[<img src='https://media.npr.org/assets/img/lead.jpg'/>"
        f"<p>Body</p>{pixel}]]></content:encoded>",
        # one picture in three tags, its size given only on the thumbnail
        f'<enclosure url="{small}" type="image/jpeg"/><media:thumbnail url="{small}" width="70"/>'
        f'<media:content type="image/jpeg" url="{small}"/>',
        # the same picture declared small and large: the large declaration wins
        '<media:content url="https://e.example/full.jpg" width="1200"/>'
        '<media:thumbnail url="https://e.example/full.jpg" width="150"/>',
        '<media:thumbnail width="240" height="135" '
        'url="https://ichef.bbci.co.uk/ace/standard/240/cpsprodpb/x/live/a.jpg"/>',
        # already bigger than a card needs: left alone
        '<media:content width="1536" url="https://ichef.bbci.co.uk/news/1536/cpsprodpb/b.jpg"/>',
    )
    images = [it.image for it in parse_feed(feed("bbc"), rss, NOW)]
    assert images == [None, "https://media.npr.org/assets/img/lead.jpg", None,
                      "https://e.example/full.jpg",
                      "https://ichef.bbci.co.uk/ace/standard/976/cpsprodpb/x/live/a.jpg",
                      "https://ichef.bbci.co.uk/news/1536/cpsprodpb/b.jpg"]


def test_assemble_drops_unknown_ids_and_repeats():
    a, b = feed("a", "AI"), feed("b", "Gaming")
    clusters = cluster_items([item(a, "OpenAI ships a thing"), item(b, "Nintendo Direct dated")])
    llm = LLMBrief(
        headline="Day",
        top=[LLMStory(title="T1", summary="S", importance=9, label="REPORTED", cluster_ids=[1, 99])],
        sections=[
            LLMSection(name="ai", stories=[LLMStory(title="dupe", summary="", importance=2, label="REPORTED", cluster_ids=[1])]),
            LLMSection(name="Gaming", stories=[LLMStory(title="ND", summary="", importance=3, label="CONFIRMED", cluster_ids=[2])]),
        ],
    )
    brief = assemble(llm, clusters, CFG, {"date": "2026-10-01"})
    assert [s["title"] for s in brief["top"]] == ["T1"]
    assert brief["top"][0]["importance"] == 5  # clamped
    assert brief["sections"][0] == {"name": "AI", "stories": []}  # repeat of a top story removed
    assert brief["sections"][1]["stories"] == []  # "Tech" got nothing
    assert brief["sections"][2]["stories"][0]["sources"][0]["url"].startswith("https://b.example/")


def test_list_brief_shape():
    clusters = rank(cluster_items(filler_items()), CFG, NOW)
    brief = list_brief(clusters, CFG)
    assert len(brief.top) == 5 and [s.name for s in brief.sections] == ["AI", "Tech", "Gaming"]


def test_list_brief_includes_every_story():
    gaming, other = feed("ign", "Gaming"), feed("blog", "Science")
    items = filler_items() + [item(gaming, f"Patch {w} released for Halo") for w in
                              ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]]
    items.append(item(other, "Telescope spots distant comet"))
    clusters = rank(cluster_items(items), CFG, NOW)
    brief = assemble(list_brief(clusters, CFG, feeds_ok=3), clusters, CFG, {"date": "2026-10-01"})
    listed = len(brief["top"]) + sum(len(s["stories"]) for s in brief["sections"])
    assert listed == len(clusters)
    assert [s["name"] for s in brief["sections"]][-1] == "Science"
    assert brief["headline"].startswith(f"{len(items)} new articles from 3 feeds")


def test_render_escapes_html():
    a = feed("a")
    clusters = cluster_items([item(a, "<script>alert(1)</script> news")])
    brief = assemble(list_brief(clusters, CFG), clusters, CFG, {
        "date": "2026-10-01", "model": None, "feed_health": [],
        "stats": {"items": 1, "clusters": 1, "feeds_ok": 1, "feeds_failed": 0}})
    html = render.brief_html(brief)
    assert "<script>" not in html and "&lt;script&gt;" in html


@pytest.mark.parametrize("title,expected", [
    ("Google announces Gemini 5 release date", True),
    ("Gemini tips and tricks", False),
    ("Nintendo Direct announced for tomorrow", True),
])
def test_rule_matches(title, expected):
    rules = {r["name"]: r for r in CFG["alerts"]["watch"]}
    rule = rules["Nintendo Direct"] if "Nintendo" in title else rules["Gemini launch"]
    assert alerts.rule_matches(rule, title) is expected


def test_alert_needs_corroboration():
    verge, ars = feed("verge"), feed("ars")
    one = [item(verge, "Google announces Gemini 5 launch")]
    assert alerts.find_alerts(one, {}, {}, CFG, NOW) == []
    two = one + [item(ars, "Gemini 5 release is here", minutes_ago=200)]
    [alert] = alerts.find_alerts(two, {}, {}, CFG, NOW)
    assert alert.rule == "Gemini launch" and alert.tier == 3 and "Verge" in alert.message


def test_official_source_counts_double_and_cooldown_applies():
    gn = feed("gonintendo", official=True)
    items = [item(gn, "Nintendo Direct announced for tomorrow")]
    assert len(alerts.find_alerts(items, {}, {}, CFG, NOW)) == 1
    cooldowns = {"Nintendo Direct": (NOW - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    assert alerts.find_alerts(items, {}, cooldowns, CFG, NOW) == []


def test_alert_all_feed_fires_once_and_respects_seen():
    openai = feed("openai", official=True, alert_mode="all")
    it = item(openai, "Introducing our new safety report")
    [alert] = alerts.find_alerts([it], {}, {}, CFG, NOW)
    assert alert.title == "Openai [CONFIRMED]" and alert.tier == 1
    assert alerts.find_alerts([it], {it.id: "2026-10-01T11:00:00Z"}, {}, CFG, NOW) == []
    old = item(openai, "Old post", minutes_ago=600)
    assert alerts.find_alerts([old], {}, {}, CFG, NOW) == []
