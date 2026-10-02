"""World / Europe / Japan / Korea sources: the OPML stays consistent and big categories are damped."""
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
