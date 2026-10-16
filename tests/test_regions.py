"""World / Europe / Japan / Korea sources: the OPML stays consistent, big categories are damped and
stories land in the topic they're about."""
import pytest

from briefing.config import ROOT, load_config
from briefing.feeds import load_opml
from briefing.models import Cluster
from briefing.rank import rank
from test_pipeline import CFG, NOW, feed, item

REGIONS = ("US", "World", "Europe", "Japan", "Korea")


def test_opml_loads_with_region_folders_in_the_configured_sections():
    feeds = load_opml(ROOT / "feeds.opml")  # raises on duplicate pfKey
    sections = set(load_config()["digest"]["sections"])
    assert {f.category for f in feeds} <= sections
    for region in REGIONS:
        in_region = [f for f in feeds if f.category == region]
        assert in_region, region
        assert all(f.url.startswith("https://") for f in in_region)
    # Same outlet under several feeds (BBC World/Europe/UK) must share a key prefix to count once.
    assert {f.outlet for f in feeds if f.key.startswith("bbc-")} == {"bbc"}


def _cluster(cid, category, outlets):
    return Cluster(cid, [item(feed(f"{category.lower()}{n}", category), f"{category} story {cid}", minutes_ago=30)
                         for n in range(outlets)])


def test_category_weight_keeps_wide_coverage_categories_from_taking_every_top_slot():
    world, tech = _cluster(1, "World", 4), _cluster(2, "Tech", 3)
    plain = rank([world, tech], CFG, NOW)
    assert plain[0] is world  # 4 outlets beat 3 when nothing is damped

    damped_cfg = {**CFG, "ranking": {**CFG["ranking"], "category_weight": {"World": 0.5}}}
    world, tech = _cluster(1, "World", 4), _cluster(2, "Tech", 3)
    assert rank([world, tech], damped_cfg, NOW)[0] is tech
    assert world.score < tech.score


def test_list_brief_keeps_only_the_top_stories_of_limited_sections():
    from briefing.summarize import list_brief
    cfg = {**CFG, "digest": {**CFG["digest"], "sections": ["Tech", "Europe"],
                             "section_limits": {"Europe": 3}}}
    europe = [_cluster(n, "Europe", 1) for n in range(1, 13)]
    tech = [_cluster(n, "Tech", 1) for n in range(20, 26)]
    ranked = rank(europe + tech, cfg, NOW)
    for n, c in enumerate(ranked, start=1):
        c.id = n
    brief = list_brief(ranked, cfg)
    sizes = {s.name: len(s.stories) for s in brief.sections}
    assert sizes["Europe"] == 3 and sizes["Tech"] > 3  # only the limited section is cut



def _story(*sources):
    """A cluster from (folder, outlet key, headline) triples."""
    return Cluster(1, [item(feed(key, category), title) for category, key, title in sources])


def test_split_regional_vote_goes_to_the_place_the_headlines_name():
    # Brazil's runoff (live): ten European outlets, five World, four US.
    brazil = "Lula and Bolsonaro head to Brazil's presidential runoff"
    sources = ([("Europe", f"eu{n}", brazil) for n in range(10)]
               + [("World", f"w{n}", brazil) for n in range(5)]
               + [("US", f"us{n}", brazil) for n in range(4)])
    assert _story(*sources).category == "World"
    # FBI / Taiwan spy story: one US, one World and one Japan outlet, places in two regions named.
    spy = "FBI arrests suspected Chinese agent accused of surveilling Taiwan president's son"
    assert _story(("US", "nbc", spy), ("World", "aljazeera", spy), ("Japan", "asahi", spy)).category == "World"
    # "US marine" is who, Okinawa is where.
    assert _story(("Japan", "japanforward", "US Marine Arrested in Okinawa Hotel Robbery-Murder"),
                  ("World", "bbc", "Arrest of US marine for murder reignites protests in Japan's Okinawa")
                  ).category == "Japan"


def test_regional_vote_stands_when_clear_or_nothing_is_named():
    kyiv = "Russian strikes hit second Kyiv bridge in two days"
    sources = [("Europe", f"eu{n}", kyiv) for n in range(5)] + [("World", "w0", kyiv)]
    assert _story(*sources).category == "Europe"
    assert _story(("US", "thehill", "White House defends new press aide")).category == "US"
    # A split vote naming laureates from two regions: the region with the most outlets.
    sources = ([("World", f"w{n}", "German and US scientists win Nobel Prize in medicine") for n in range(5)]
               + [("Europe", f"eu{n}", "Nobel medicine prize for optogenetics") for n in range(4)]
               + [("US", f"us{n}", "Three scientists win medicine Nobel") for n in range(3)])
    assert _story(*sources).category == "World"
    # A tie between regions with nothing named is World, whatever order the items arrived in.
    a = ("US", "npr", "Mortgage rates hit 6% for first time in three years")
    b = ("Europe", "bbc", "Mortgage rates hit 6%")
    assert _story(a, b).category == _story(b, a).category == "World"
    # One outlet's US desk and world feed carrying the same story: a US story, not World.
    us = ("US", "guardian-us", "Prosecutors oppose Luigi Mangione's push for dismissal of state charges")
    world = ("World", "guardian-world", us[2])
    assert _story(us, world).category == _story(world, us).category == "US"


@pytest.mark.parametrize("folder,title,expected", [
    ("Tech", 'OpenAI\'s Altman: Ascribing religion to models a "safety issue"', "AI"),
    ("US", "Trump names national intelligence chief Jay Clayton as new AI czar", "AI"),
    ("Tech", "The AI boom is making the world's cheapest smartphones disappear", "AI"),
    ("Gaming", "OpenAI's GPT-6 Astra gets frustrated losing at StarCraft", "AI"),
    # Broad AI wording is enough in Tech, not in Gaming or news folders.
    ("Gaming", "Jagex responds to use of generative AI in RuneScape trailer", "Gaming"),
    ("World", "FlyDubai copilot planned to crash plane into Tel Aviv airport", "World"),
    ("Europe", "Claude Monet exhibition opens in Paris", "Europe"),
])
def test_ai_news_filed_elsewhere_moves_to_ai(folder, title, expected):
    assert _story((folder, "src", title)).category == expected


def test_live_snapshot_topics():
    from briefing.dedupe import cluster_items
    from test_pipeline import cluster_of, snapshot_items
    clusters = cluster_items(snapshot_items())
    assert cluster_of(clusters, "Brazil election: Bolsonaro and Lula head to runoff").category == "World"
    assert cluster_of(clusters, "Russian strikes hit second Kyiv bridge").category == "Europe"
    assert cluster_of(clusters, "FBI arrests suspected Chinese agent").category == "World"
    assert cluster_of(clusters, "OpenAI's Altman: Ascribing religion").category == "AI"
