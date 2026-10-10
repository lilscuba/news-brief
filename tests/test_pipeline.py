import json
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path

import pytest

from briefing import alerts, digest, render, state
from briefing.config import ROOT, load_config
from briefing.dedupe import cluster_items
from briefing.digest import _apply_feed_caps, assemble
from briefing.feeds import FetchResult, load_opml, parse_feed, settle_times
from briefing.models import Cluster, Feed, Item
from briefing.normalize import canonical_url, clean_snippet, clean_title, title_tokens
from briefing.rank import is_muted, rank
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


@lru_cache(maxsize=1)
def _snapshot() -> tuple[dict, ...]:
    data = json.loads((Path(__file__).parent / "fixtures" / "feed-2026-10-05.json").read_text())
    return tuple({"key": k, "title": t, "url": u, "published": p} for k, t, u, p in data["items"])


def snapshot_items() -> list[Item]:
    """The 1,102 headlines of the live shared feed on 2026-10-05 06:16Z, as fresh Items with
    their real feeds (folders), so clustering and topics see a real day's word statistics."""
    feeds = {f.key: f for f in load_opml(ROOT / "feeds.opml")}
    out = []
    for n, row in enumerate(_snapshot()):
        f = feeds.get(row["key"]) or Feed(row["key"], row["key"], f"https://{row['key']}.example/", "World")
        out.append(Item(id=f"s{n}", feed=f, title=clean_title(row["title"]), url=row["url"],
                        canonical_url=canonical_url(row["url"]), summary="",
                        published=datetime.fromisoformat(row["published"].replace("Z", "+00:00"))))
    return out


def cluster_of(clusters, title: str):
    return next(c for c in clusters if any(it.title.startswith(title) for it in c.items))


def test_canonical_url_strips_tracking_and_www():
    a = canonical_url("https://www.theverge.com/2026/10/1/story/?utm_source=rss&utm_medium=feed#x")
    b = canonical_url("http://theverge.com/2026/10/1/story")
    assert a == b


def test_clean_title_drops_outlet_suffix():
    assert clean_title("Big news happens - The Verge") == "Big news happens"
    # ...but not the second clause of a headline.
    for kept in ["The Iran war is hitting America's school buses — and kids are paying the price",
                 "Instinct was the buzziest AI agent around — can it survive Muse?",
                 "Mamdani Gives His Definition Of Socialism — And No One's Buying It"]:
        assert clean_title(kept) == kept
    assert clean_title("ICE officer shoots man in New York City – video") == "ICE officer shoots man in New York City"
    assert "gemini4" in title_tokens("Gemini 4 Argon: our next era")


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


def test_techmeme_without_an_image_links_the_article_not_the_outlets_home_page():
    desc = ('&lt;P&gt;&lt;A HREF="https://www.techmeme.com/261009/p18#a261009p18" TITLE="Techmeme permalink"&gt;'
            '&lt;/A&gt; Rebecca Torrence / &lt;A HREF="https://www.bloomberg.com/"&gt;Bloomberg&lt;/A&gt;:&lt;BR&gt;'
            '&lt;SPAN&gt;&lt;B&gt;&lt;A HREF="https://www.bloomberg.com/news/articles/ramp?a=1&amp;amp;b=2"&gt;'
            'Sources: Ramp raised about $1.85B&lt;/A&gt;&lt;/B&gt;&lt;/SPAN&gt; — Ramp ...')
    rss = f"""<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>
      <item><title>Sources: Ramp raised about $1.85B (Rebecca Torrence/Bloomberg)</title>
        <link>https://www.techmeme.com/261009/p18#a261009p18</link><description>{desc}</description>
      </item></channel></rss>""".encode()
    [it] = parse_feed(feed("techmeme"), rss, NOW)
    assert it.url == "https://www.bloomberg.com/news/articles/ramp?a=1&b=2"


def test_a_description_that_continues_the_headline_is_kept_whole():
    from briefing.normalize import clean_snippet
    text = "OpenAI partners with Cerebras to add 750MW of high-speed AI compute, reducing inference latency."
    assert clean_snippet(text, "OpenAI partners with Cerebras").startswith("OpenAI partners with Cerebras to add")
    copied = "Valve ships the Steam Deck 2. The new handheld has an OLED screen and costs $549."
    assert clean_snippet(copied, "Valve ships the Steam Deck 2").startswith("The new handheld")


def test_parse_feed_skips_entries_that_dont_link_to_a_web_page():
    rss = b"""<rss><channel>
      <item><title>Real story</title><link>https://verge.example/a</link></item>
      <item><title>Script link</title><link>javascript:alert(1)</link></item>
      <item><title>Data link</title><link>data:text/html,hi</link></item>
    </channel></rss>"""
    assert [it.title for it in parse_feed(feed("verge"), rss, NOW)] == ["Real story"]


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
    # Readers go straight to the article; the permalink still clusters other Techmeme links to it.
    assert it.url == "https://www.theverge.com/a?utm_source=tm"
    assert it.canonical_url == "https://theverge.com/a"
    assert it.alt_urls == ["https://www.techmeme.com/261001/p1"]
    assert it.published == NOW  # undated -> now


TECHMEME_RSS = """<?xml version="1.0"?><rss version="2.0"><channel><title>Techmeme</title><item>
  <title>Billionaires Index: tech billionaires account for all of the $845B in wealth gains so far in 2026 (Kristine Owram/Bloomberg)</title>
  <link>https://www.techmeme.com/261005/p14#a261005p14</link>
  <description><![CDATA[<A HREF="https://www.bloomberg.com/news/2026-10-05/ai-billionaires"><IMG SRC="http://www.techmeme.com/261005/i14.jpg"></A>
<P><A HREF="https://www.techmeme.com/261005/p14#a261005p14" TITLE="Techmeme permalink"><IMG WIDTH=11 HEIGHT=12 SRC="http://www.techmeme.com/img/pml.png"></A> Kristine Owram / <A HREF="https://www.bloomberg.com/">Bloomberg</A>:<BR>
<SPAN STYLE="font-size:1.3em;"><B><A HREF="https://www.bloomberg.com/news/2026-10-05/ai-billionaires">Billionaires Index: tech billionaires account for all of the $845B in wealth gains so far in 2026</A></B></SPAN>&nbsp; &mdash;&nbsp; AI brings a staggering new peak in wealth - and signs we just passed it. &hellip; </P>]]></description>
  <pubDate>Mon, 05 Oct 2026 07:50:48 -0400</pubDate></item>
<item><title>Q&amp;A with Sam Altman on the midterms (Vanity Fair)</title>
  <link>https://www.techmeme.com/261005/p13#a261005p13</link>
  <description><![CDATA[<P><A HREF="https://www.techmeme.com/261005/p13#a261005p13" TITLE="Techmeme permalink"><IMG SRC="http://www.techmeme.com/img/pml.png"></A> <A HREF="http://www.vanityfair.com/">Vanity Fair</A>:<BR>
<SPAN><B><A HREF="https://www.vanityfair.com/story/sam-altman">Q&amp;A with Sam Altman</A></B></SPAN>&nbsp; &mdash;&nbsp; The OpenAI CEO discusses the midterms.</P>]]></description>
  <pubDate>Mon, 05 Oct 2026 07:40:01 -0400</pubDate></item>
</channel></rss>"""


def test_techmeme_items_drop_the_byline_and_link_the_original_article():
    tm = Feed("techmeme", "Techmeme", "https://www.techmeme.com/feed.xml", "Tech")
    bloomberg, vf = parse_feed(tm, TECHMEME_RSS.encode(), NOW)
    assert bloomberg.title == ("Billionaires Index: tech billionaires account for all of the $845B "
                               "in wealth gains so far in 2026")
    assert bloomberg.url == "https://www.bloomberg.com/news/2026-10-05/ai-billionaires"
    assert bloomberg.source_name == "Bloomberg via Techmeme"
    assert bloomberg.alt_urls == ["https://www.techmeme.com/261005/p14#a261005p14"]  # anchor kept
    # The description after the repeated headline, not "Kristine Owram / Bloomberg: Billionaires...".
    assert bloomberg.summary == "AI brings a staggering new peak in wealth - and signs we just passed it. …"
    assert vf.title == "Q&A with Sam Altman on the midterms" and vf.source_name == "Vanity Fair via Techmeme"


def test_photo_caption_feeds_have_no_snippet():
    rss = b"""<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>
      <item><title>Employee question could stall Senate college sports bill</title>
        <link>https://rollcall.com/2026/10/05/college-sports-bill/</link>
        <description>President Donald Trump departs the Senate Republicans' lunch meeting in the
          Capitol on June 24.</description>
        <pubDate>Mon, 05 Oct 2026 10:00:00 GMT</pubDate></item></channel></rss>"""
    [it] = parse_feed(feed("rollcall", "US"), rss, NOW)
    assert it.summary == ""  # Roll Call's descriptions are photo captions, not summaries


def test_summary_is_cut_on_a_word_boundary():
    words = "Officials in the capital said the second bridge was struck overnight by drones " * 4
    out = clean_snippet(words, limit=240)
    assert len(out) <= 240 and out.endswith("…")
    assert words.startswith(out[:-1]) and words[len(out) - 1] == " "  # whole words only
    # A sentence that ends in the second half of the window is kept whole instead.
    first = ("Officials said the second bridge across the Dnipro was hit twice overnight by drones and "
             "that repairs will take weeks, according to Mayor Vitali Klitschko.")
    text = first + " Mr. Klitschko said engineers from three countries would assess the damaged span on Tuesday."
    assert len(text) > 240
    assert clean_snippet(text, limit=240) == first  # not "... Mr." (an abbreviation)
    assert clean_snippet("Short and complete", limit=240) == "Short and complete"


@pytest.mark.parametrize("raw,expected", [
    # WordPress footer (Insider Gaming, live)
    ('<p>Behaviour Interactive is currently working on a new unannounced AAA sci-fi FPS with a "high '
     'realism bar".</p>\n<p>The post <a href="https://insider-gaming.com/x/">Behaviour Interactive Is '
     'Working on an “Unannounced AAA Sci-Fi FPS With a High Realism Bar”</a> appeared first on '
     '<a href="https://insider-gaming.com">Insider Gaming</a>.</p>',
     'Behaviour Interactive is currently working on a new unannounced AAA sci-fi FPS with a "high '
     'realism bar".'),
    # Eurogamer's link, Nintendo Life's footer, Guardian's "Continue reading..."
    ('<p>The sequel has been very popular on Steam.</p> <p><a href="https://eurogamer.net/x">Read more</a></p>',
     "The sequel has been very popular on Steam."),
    ("<p>It's a lot more expensive.</p><p><a href='x'>Read the full article on nintendolife.com</a></p>",
     "It's a lot more expensive."),
    ("<p>The minister resigned on Monday.</p> <a href='x'>Continue reading...</a>",
     "The minister resigned on Monday."),
    ('Apple tripled the limit. This article, " Apple Quietly Triples iCloud Mail Alias Limit " first '
     "appeared on MacRumors.com. Discuss this article in our forums", "Apple tripled the limit."),
    ("Families spoke to AP. This article originally appeared on Associated Press at "
     "https://www.yahoo.com/news/articles/x-103134796.html", "Families spoke to AP."),
    ("Trump nominated them, saying it is unfortunate what they did. Go deeper: Trump's shadow docket "
     "blitz hits a new milestone", "Trump nominated them, saying it is unfortunate what they did."),
    ("<p>Builders might get into trouble.</p><p>Tags: <a>aws</a>, <a>ai</a>, <a>coding-agents</a></p>",
     "Builders might get into trouble."),
    # Photo captions and credits (Daily Beast, AppleInsider), spaces left by inline tags (9to5Mac)
    ('<figure><img alt="Paxton speaks" src="x.jpg" /><figcaption>Sergio Flores/Getty Images</figcaption>'
     "</figure><p>Ken Paxton has been recorded making an admission.</p>",
     "Ken Paxton has been recorded making an admission."),
    ('New code reveals a new Focus Mode.<br /><br /><div><img alt="Two phones" src="x.jpg" /><br />'
     "<span>The iPhone Duo lock screen</span></div><br />Apple is expected to ship it soon.",
     "New code reveals a new Focus Mode. Apple is expected to ship it soon."),
    ("A partnership between <a>Steve Jobs</a> and <a>Jony Ive</a>.",
     "A partnership between Steve Jobs and Jony Ive."),
    ("The senator spoke on Tuesday about the bill. (Justin Ford/Getty Images)",
     "The senator spoke on Tuesday about the bill."),
    # Paragraphs are separate sentences, not "...White House says The White House has defended".
    ("<p>Pressure grows on aide, White House says</p><p>The White House has defended the hire.</p>",
     "Pressure grows on aide, White House says. The White House has defended the hire."),
])
def test_snippets_lose_publisher_boilerplate(raw, expected):
    assert clean_snippet(raw, limit=300) == expected


def test_snippet_keeps_ordinary_sentences_that_look_like_boilerplate():
    assert clean_snippet("You can read more about it in our guide.") == "You can read more about it in our guide."
    assert clean_snippet("We release an implementation at https://github.com/x/y") == (
        "We release an implementation at https://github.com/x/y")


def test_snippet_that_only_repeats_the_headline_is_dropped():
    assert clean_snippet("Tagesschau in 100 seconds tagesschau", "Tagesschau in 100 seconds") == ""
    assert clean_snippet("<p>Big news happens</p>", "Big news happens") == ""
    # A repeated headline in front of real text is cut off; the rest stays.
    assert clean_snippet("Big news happens. The company confirmed it in a statement on Monday.",
                         "Big news happens") == "The company confirmed it in a statement on Monday."


@pytest.mark.parametrize("raw,expected", [
    ("(LEAD) Fishing boat capsizes off Jeju; 9 rescued, 2 missing",
     "Fishing boat capsizes off Jeju; 9 rescued, 2 missing"),
    ("(2nd LD) N. Korea fires ballistic missile", "N. Korea fires ballistic missile"),
    ("(URGENT) S. Korea, U.S. to hold talks", "S. Korea, U.S. to hold talks"),
    ("Opinion | Letitia James and the Cornell 7", "Letitia James and the Cornell 7"),
    ("(Asiad) Indian archers end South Korea's recurve reign",
     "(Asiad) Indian archers end South Korea's recurve reign"),
])
def test_clean_title_drops_wire_and_section_tags(raw, expected):
    assert clean_title(raw) == expected


def test_title_tokens_match_rewritten_headlines():
    assert title_tokens("Brazil's runoff looms") == title_tokens("Brazil runoff looms")
    assert {"6", "coastguard", "suspend"} <= (title_tokens("US coastguard suspends search for six on board")
                                             & title_tokens("Coast Guard suspended search for 6 passengers"))
    # A numbered name is one word, so "Forza Horizon 6" doesn't share a bare "6" with every count.
    assert "horizon6" in title_tokens("Pull Up to 7-Eleven in Forza Horizon 6")
    assert not {"horizon", "6"} & title_tokens("Forza Horizon 6 delayed")
    assert {"china", "agent"} <= title_tokens("FBI arrests suspected Chinese agent") & title_tokens("China's agents")
    assert {"us", "uk", "bomber"} <= (title_tokens("U.S. bombers leave British base")
                                     & title_tokens("United States pulls bomber from UK base"))
    assert title_tokens("Spain’s Sánchez calls election") == title_tokens("Spain's Sanchez calls election")
    assert "1000km" in title_tokens("Missile flew 1,000km")
    # Dates mark recurring features, not stories.
    assert title_tokens("Headlines for October 5, 2026") == title_tokens("Headlines") == {"headlin"}


def test_podcast_episodes_are_roundups_and_one_outlets_formulas_dont_merge():
    from briefing.dedupe import is_roundup
    assert is_roundup("9to5Mac Daily: October 8, 2026 – iPad mini rumors, iCloud+")
    assert is_roundup("Engadget Podcast: The Pixel 11 is here")
    assert not is_roundup("Valve announces the Steam Deck 2")
    nine = feed("9to5mac")
    pair = [item(nine, "Apple Mail added four convenient new features in iOS 27"),
            item(nine, "Apple Home adds two powerful new features in iOS 27")]
    assert len(cluster_items(pair + filler_items())) == len(filler_items()) + 2


def test_rewritten_live_headlines_cluster_and_roundups_dont_bridge():
    clusters = cluster_items(snapshot_items())
    same = [
        ("U.S. removes all bombers from British base", "United States withdraws all bombers from British base"),
        ("FBI arrests suspected Chinese agent", "US accuses California woman of spying for China"),
        ("Coast Guard suspends search for 6 medical jet", "US coastguard suspends search for six"),
        ("Latvia's pro-Ukraine party wins", "Pro-Ukraine governing coalition wins 35% in Latvian election"),
        ("Ethiopian rebel forces withdraw from Tigray", "Opposition fighters withdraw from capital of Ethiopia"),
        ("FBI Director Kash Patel gets engaged", "Kash Patel, girlfriend announce engagement"),
    ]
    for a, b in same:
        assert cluster_of(clusters, a) is cluster_of(clusters, b), (a, b)
    # "Europe Today: Russia hits Kyiv as Merz visits; Bolsonaro wins Brazil's first round election"
    # names two stories; it used to chain the Kyiv strikes into Brazil's election.
    roundup = cluster_of(clusters, "Europe Today:")
    assert len(roundup.items) == 1
    assert cluster_of(clusters, "Russian strikes hit second Kyiv bridge") is not cluster_of(
        clusters, "Brazil election: Bolsonaro and Lula head to runoff")


def test_two_clause_headline_joins_one_story_but_never_bridges_two():
    yonhap, herald, bloomberg = feed("yonhap"), feed("koreaherald"), feed("bloomberg")
    items = filler_items() + [
        item(yonhap, "Fishing boat capsizes off Jeju; 9 rescued, 2 missing"),
        item(yonhap, "Fishing boat capsizes off Jeju; 9 rescued, 2 missing, coast guard says"),
        item(herald, "Fishing boat capsizes off Jeju island, 2 missing"),
        item(bloomberg, "Euro weakens to 17-month low; Bolsonaro takes lead over Lula in Brazil election"),
        item(herald, "Euro weakens to 17-month low against the dollar"),
        item(yonhap, "Bolsonaro takes lead over Lula in Brazil election count"),
    ]
    clusters = cluster_items(items)
    assert len(cluster_of(clusters, "Fishing boat capsizes").items) == 3
    assert len(cluster_of(clusters, "Euro weakens to 17-month low;").items) == 1
    assert cluster_of(clusters, "Euro weakens to 17-month low against") is not cluster_of(
        clusters, "Bolsonaro takes lead over Lula in Brazil election count")


def test_live_blog_url_does_not_join_different_stories():
    world, europe = feed("guardian-world"), feed("guardian-europe")
    live = "https://www.theguardian.com/world/live/2026/oct/05/europe-live-latest-news-updates"
    items = filler_items() + [
        item(world, "Spain's Sánchez calls snap election amid national housing crisis", url=live),
        item(europe, "15-year-old loses hand in clash with French police during school protest", url=live),
        item(europe, "Spain's Sánchez calls snap election amid national housing crisis", url=live + "?page=2"),
    ]
    clusters = cluster_items(items)
    assert len(cluster_of(clusters, "Spain's Sánchez").items) == 2  # same headline still joins
    assert len(cluster_of(clusters, "15-year-old loses hand").items) == 1


@pytest.mark.parametrize("title", [
    "NYT Strands Hints and Answers for Game #945 on October 4",
    "Slate Mini Crossword for Oct. 4, 2026",
    "Mech Arena Codes and Free Rewards—October 2026 Promo Codes",
    "NBA Champions Basketball Codes (October 2026)",
    "Roblox Music Codes (September 2026)",
    "All Brawlhalla Codes & Rewards—Every October 2026 Active Code",
    "Latest news bulletin | October 5th, 2026 – Midday",
    "Today in Korean history",
    "Top headlines in major S. Korean newspapers",
    "Today in Supreme Court History: October 5, 1953",
    "September sponsors-only newsletter",
])
def test_mute_patterns_drop_evergreen_filler(title):
    assert is_muted(title, load_config())


@pytest.mark.parametrize("title", [
    "Google freezes OSS vulnerability submissions after AI-generated report flood",
    "Valorant player banned over CPU's previous owner",
    "Capcom details plans for RE Engine",
    "Hackers stole 2FA codes from thousands of accounts",
    "Ohtani answers critics after Game 3 win",
    "Source code for Half-Life 2 beta leaks online",
    "Today in Washington: Senate votes on funding bill",
    "Investigators pinpoint clues in Air India crash",
    "FBI probes shooter's connections for clues to motive",
    "Police find connections, few answers in Minneapolis shooting",
])
def test_mute_patterns_keep_real_news(title):
    assert not is_muted(title, load_config())


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


# --- When items were published ------------------------------------------------------------------

def rss(*entries: str) -> bytes:
    """An RSS document; each entry is "title|pubDate" (pubDate may be empty)."""
    items = []
    for n, e in enumerate(entries):
        title, date = e.split("|")
        pub = f"<pubDate>{date}</pubDate>" if date else ""
        items.append(f"<item><title>{title}</title><link>https://x.example/{n}</link>{pub}</item>")
    return f'<?xml version="1.0"?><rss version="2.0"><channel><title>t</title>{"".join(items)}</channel></rss>'.encode()


def test_parse_feed_says_how_well_each_item_is_dated():
    exact, day, undated = parse_feed(feed("justthenews", "US"), rss(
        "Senate passes bill|Thu, 01 Oct 2026 10:00:00 GMT",
        "Bolsonaro, Lula advance to runoff|2026-09-30",       # Just the News: a bare date
        "My Personal History|"), NOW)                          # Nikkei: no date at all
    assert (exact.time_quality, exact.published) == ("exact", datetime(2026, 10, 1, 10, tzinfo=timezone.utc))
    assert (day.time_quality, day.published) == ("date", datetime(2026, 9, 30, tzinfo=timezone.utc))
    assert (undated.time_quality, undated.published) == ("none", NOW)


def test_items_all_stamped_with_the_feed_build_time_count_as_undated():
    kt = feed("koreatimes", "Korea")
    built = "Thu, 01 Oct 2026 11:52:03 GMT"  # The Korea Times: every item, 8 minutes before the fetch
    assert {it.time_quality for it in parse_feed(kt, rss(*[f"Story {i}|{built}" for i in range(3)]), NOW)} == {"none"}
    # Stamped ahead of the clock: clamped to now, the same giveaway.
    ahead = [f"Story {i}|Thu, 01 Oct 2026 1{3 + i}:00:00 GMT" for i in range(3)]
    assert {it.time_quality for it in parse_feed(kt, rss(*ahead), NOW)} == {"none"}
    # Real publishing schedules share stamps too: an old batch, part of a feed, or just two.
    old = "Mon, 28 Sep 2026 10:00:00 GMT"
    for entries in ([f"S{i}|{old}" for i in range(3)], [f"S{i}|{built}" for i in range(3)] + [f"S9|{old}"],
                    [f"S{i}|{built}" for i in range(2)]):
        assert {it.time_quality for it in parse_feed(kt, rss(*entries), NOW)} == {"exact"}


def test_times_without_an_offset_are_read_in_the_feeds_time_zone():
    nl = Feed("nltimes", "NL Times", "https://nltimes.nl/rss", "Europe", time_zone="Europe/Amsterdam")
    [it] = parse_feed(nl, rss("Dutch cabinet falls|1 October 2026 - 13:09"), NOW)
    assert (it.time_quality, it.published) == ("exact", datetime(2026, 10, 1, 11, 9, tzinfo=timezone.utc))
    [it] = parse_feed(feed("nltimes"), rss("Dutch cabinet falls|1 October 2026 - 13:09"), NOW)
    assert it.time_quality == "none"
    assert {f.key: f for f in load_opml(ROOT / "feeds.opml")}["nltimes"].time_zone == "Europe/Amsterdam"


def test_settle_times_uses_when_an_item_was_first_seen():
    f = feed("nikkei", "Japan")
    undated, unseen, day, ahead, normal = (item(f, f"Story {i}") for i in range(5))
    undated.time_quality = unseen.time_quality = "none"
    day.time_quality, day.published = "date", datetime(2026, 9, 29, tzinfo=timezone.utc)
    ahead.published = NOW  # stated in the future at first sight, so clamped to that run's now
    seen = {undated.id: state.iso(NOW - timedelta(hours=30)), day.id: state.iso(NOW - timedelta(hours=40)),
            ahead.id: state.iso(NOW - timedelta(hours=2)), normal.id: state.iso(NOW)}
    settle_times([undated, unseen, day, ahead, normal], seen, NOW)
    assert undated.published == NOW - timedelta(hours=30)
    assert unseen.published == NOW
    assert day.published == datetime(2026, 9, 29, 20, tzinfo=timezone.utc)  # first seen that evening
    assert ahead.published == NOW - timedelta(hours=2)
    assert normal.published == NOW - timedelta(minutes=30)  # a real time before first sight stands


def test_date_only_item_first_seen_long_after_stays_in_its_day():
    [day] = parse_feed(feed("justthenews", "US"), rss("Old story|2026-09-27"), NOW)
    settle_times([day], {}, NOW)
    assert day.published == datetime(2026, 9, 28, 12, tzinfo=timezone.utc)  # not "now"


def test_an_estimated_time_never_makes_an_item_the_lead():
    day = item(feed("justthenews", "US"), "Bolsonaro, Lula advance to runoff", minutes_ago=600)
    day.time_quality = "date"
    report = item(feed("ap", "US"), "Bolsonaro and Lula advance to Brazil runoff", minutes_ago=480)
    cluster = Cluster(1, [day, report])
    assert cluster.lead is report and cluster.headline_item is report
    assert Cluster(2, [day]).lead is day  # alone, it still leads its own story


def test_a_web_page_instead_of_a_feed_is_reported_as_such():
    page = b"<!DOCTYPE html>\n<html><head><meta http-equiv=\"refresh\" content=\"0;/.well-known/sgcaptcha/?r=%2Ffeed%2F&y=1\">"
    with pytest.raises(ValueError, match="not a feed"):
        parse_feed(feed("cphpost"), page, NOW)


def test_prune_keeps_ids_still_in_their_feed():
    old, new = state.iso(NOW - timedelta(days=5)), state.iso(NOW)
    assert state.prune({"a": old, "b": old, "c": new}, NOW, keep_days=3, keep={"a"}) == {"a": old, "c": new}


class Clock(datetime):
    current = NOW

    @classmethod
    def now(cls, tz=None):
        return cls.current


def test_digest_reads_a_bare_date_as_that_day_not_midnight_utc(monkeypatch, tmp_path):
    # Posted on the evening of Sep 30 ET, dated "2026-09-30": midnight UTC is outside a brief
    # window that starts at 10:00 UTC on Sep 30, though the story is new to the reader.
    jtn = feed("justthenews", "US")
    [late] = parse_feed(jtn, rss("Bolsonaro, Lula advance to runoff|2026-09-30"), NOW)
    monkeypatch.setattr(digest, "datetime", Clock)
    monkeypatch.setattr(digest, "ROOT", tmp_path)
    monkeypatch.setattr(digest, "load_opml", lambda path: [jtn])
    monkeypatch.setattr(digest, "fetch_all", lambda feeds, now: [FetchResult(jtn, [late])])
    cfg = {**CFG, "digest": {**CFG["digest"], "sections": ["US"], "window_hours": 26, "summarize": False,
                             "max_clusters_for_llm": 10}, "health": {"stale_days": 14}}
    brief = digest.run(no_llm=True, dry_run=True, cfg=cfg)
    assert [s["title"] for s in brief["top"]] == ["Bolsonaro, Lula advance to runoff"]


@pytest.mark.parametrize("last_run,expected", [
    (None, False),                      # the configured 90 minutes
    (timedelta(minutes=15), False),     # runs close together: still 90 minutes
    (timedelta(hours=3), True),         # a 3 h gap: what arrived 2 h ago still alerts
    (timedelta(hours=10), False),       # never more than 4 h back
])
def test_alert_lookback_covers_the_gap_since_the_last_run(last_run, expected):
    openai = feed("openai", official=True, alert_mode="all")
    minutes = 300 if last_run == timedelta(hours=10) else 120
    it = item(openai, "Introducing our new safety report", minutes_ago=minutes)
    last = state.iso(NOW - last_run) if last_run else None
    assert bool(alerts.find_alerts([it], {}, {}, CFG, NOW, last)) is expected
