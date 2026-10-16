"""The web brief: when it was updated, links that open articles, one chip per outlet, labels that
mean something, section navigation and day-to-day links in the archive."""
import json
import re
from datetime import datetime, timedelta, timezone

import pytest

from briefing import digest, render
from briefing.dedupe import cluster_items
from briefing.digest import _sources, assemble
from briefing.models import Cluster, Feed, Item
from briefing.normalize import canonical_url
from briefing.rank import rank
from briefing.summarize import LLMBrief, LLMStory, list_brief

NOW = datetime(2026, 10, 4, 15, 42, 35, tzinfo=timezone.utc)  # 11:42 AM in New York
CFG = {
    "digest": {"sections": ["Tech", "Gaming", "Deals"], "mute": []},
    "ranking": {"per_source": 3.0, "official_boost": 2.5, "techmeme_boost": 3.0,
                "hn_points_weight": 1.5, "age_penalty_per_hour": 0.08, "boosts": {}},
}


def feed(key, title=None, category="Tech", official=False, url=None):
    return Feed(key=key, title=title or key.title(), url=url or f"https://{key}.example/feed",
                category=category, official=official)


def item(f, title, minutes_ago=30, url=None, source_name=None, n=[0]):
    n[0] += 1
    url = url or f"https://{f.key}.example/{n[0]}"
    return Item(id=f"{f.key}-{n[0]}", feed=f, title=title, url=url, canonical_url=canonical_url(url),
                summary="", published=NOW - timedelta(minutes=minutes_ago), source_name=source_name)


def story(title="Valve ships the Steam Deck 2", **over):
    s = {"id": "a1b2c3d4e5f6", "title": title, "summary": "It is out today.", "importance": 3,
         "label": "REPORTED", "category": "Tech", "published": "2026-10-04T13:15:00Z",
         "outlet_count": 2, "sources": [
             {"outlet": "The Verge", "title": "Valve's Steam Deck 2 is here",
              "url": "https://verge.example/deck", "official": False},
             {"outlet": "Ars Technica", "title": "Steam Deck 2 review",
              "url": "https://ars.example/deck", "official": False}]}
    return {**s, **over}


def brief(top=None, sections=None, **over):
    b = {"version": 1, "date": "2026-10-04", "headline": "A busy Sunday.",
         "generated_at": "2026-10-04T15:42:35Z", "timezone": "America/New_York", "window_hours": 26,
         "mode": "list", "model": None, "top": [story()] if top is None else top,
         "sections": [{"name": "Tech", "stories": []}] if sections is None else sections,
         "stats": {"items": 3, "clusters": 2, "feeds_ok": 2, "feeds_failed": 0}, "feed_health": []}
    return {**b, **over}


def visible(html):
    """The page without tooltips, styles and scripts: what a reader can actually see."""
    html = re.sub(r"<(style|script)[^>]*>.*?</\1>", "", html, flags=re.S)
    return re.sub(r' title="[^"]*"', "", html)


def test_header_says_when_the_brief_was_updated_in_the_readers_time_zone():
    html = render.brief_html(brief())
    assert ('Updated <time id="updated" datetime="2026-10-04T15:42:35Z">11:42 AM EDT</time>'
            ' · covers the last 26 hours') in html


def test_each_story_shows_when_it_was_published():
    late = story(id="late", published="2026-10-04T03:40:00Z")  # the evening before, in New York
    html = render.brief_html(brief(top=[story(), late]))
    assert '<time datetime="2026-10-04T13:15:00Z">9:15 AM</time>' in html
    assert '<time datetime="2026-10-04T03:40:00Z">Oct 3, 11:40 PM</time>' in html


def test_relative_times_and_the_old_brief_banner_are_web_only():
    home = render.brief_html(brief(), latest=True)
    assert '<script id="relative-times">' in home
    assert '<p class="note" id="stale" hidden>This brief is from Sunday, October 4.' in home
    day_page = render.brief_html(brief(), archive_link="./", latest_link="../")
    assert 'id="stale"' not in day_page  # an archived day is old on purpose
    assert "<script" not in render.brief_html(brief(), email=True)


def test_headline_opens_the_primary_article():
    html = render.brief_html(brief())
    assert '<h3><a href="https://verge.example/deck">Valve ships the Steam Deck 2</a></h3>' in html


def test_only_notable_labels_get_a_badge_and_opinion_gets_a_tag():
    top = [story(id="r"), story(id="u", label="RUMOR-UNVERIFIED"), story(id="o", opinion=True),
           story(id="d", label="DEAL")]
    deals = [story(id="d2", title="Hades is $9.99", label="DEAL")]
    html = visible(render.brief_html(brief(top=top, sections=[{"name": "Deals", "stories": deals}])))
    assert "REPORTED" not in html and "lbl-REPORTED" not in html
    assert '<span class="lbl lbl-RUMOR-UNVERIFIED">Unverified rumor</span>' in html
    assert '<span class="lbl lbl-opinion">Opinion</span>' in html
    # A deal among the top stories says so; inside Deals the heading already does.
    assert html.count('<span class="lbl lbl-DEAL">Deal</span>') == 1
    assert "[Opinion]" in render.brief_text(brief(top=top))
    assert "[REPORTED]" not in render.brief_text(brief(top=top))


def test_section_nav_is_a_labelled_sticky_strip():
    sections = [{"name": "Tech", "stories": [story(id="t")]},
                {"name": "Science & Space", "stories": []}]
    html = render.brief_html(brief(sections=sections))
    assert ('<nav class="sections" aria-label="Sections"><a href="#top">Top stories</a>'
            '<a href="#tech">Tech (1)</a><a href="#science-space">Science &amp; Space (0)</a></nav>'
            ) in html
    assert '<h2 id="science-space">Science &amp; Space</h2>' in html
    assert ".sections{position:sticky;top:0" in html and "scroll-margin-top:64px" in html


def test_importance_dots_are_announced_as_an_image():
    html = render.brief_html(brief())
    assert '<span class="imp" role="img" aria-label="Importance 3 of 5">●●●○○</span>' in html


def test_top_stories_name_their_topic_and_sections_dont_repeat_it():
    html = render.brief_html(brief(sections=[{"name": "Gaming", "stories": [
        story(id="g", category="Gaming")]}]))
    top, gaming = html.split('<h2 id="gaming">')
    assert "· Tech · 2 outlets" in top and "· Gaming ·" not in gaming


def test_feed_problems_are_folded_away_and_name_sources_not_errors():
    health = [{"key": "decoder", "title": "The Decoder", "status": "error",
               "detail": "ConnectTimeout: HTTPSConnectionPool(host='the-decoder.com', port=443)"},
              {"key": "metaai", "title": "Meta AI (mirror)", "status": "stale",
               "detail": "no new items since 2026-07-27"}]
    html = render.brief_html(brief(feed_health=health))
    assert "<details><summary>2 sources had problems</summary>" in html
    assert "The Decoder: not responding" in html
    assert "Meta AI (mirror): no new items since 2026-07-27" in html
    assert "HTTPSConnectionPool" in html and "HTTPSConnectionPool" not in visible(html)


def test_long_sections_show_their_best_ten_and_fold_the_rest():
    many = [story(id=f"g{n}", title=f"Patch {n}") for n in range(13)]
    html = render.brief_html(brief(sections=[{"name": "Gaming", "stories": many}]))
    shown, folded = html.split('<details class="rest"><summary>Show 3 more in Gaming</summary>')
    assert shown.count('<article id="g') == 10 and folded.count('<article id="g') == 3
    assert '<a href="#gaming">Gaming (13)</a>' in html  # the nav counts every story


def test_one_chip_per_outlet_and_its_other_headlines_under_more_coverage():
    euro, verge = feed("eurogamer", "Eurogamer"), feed("verge", "The Verge")
    older = item(euro, "Silksong DLC announced", minutes_ago=300)
    newer = item(euro, "Silksong DLC hands-on", minutes_ago=60)
    first = item(verge, "Team Cherry reveals Silksong DLC", minutes_ago=400)
    sources = _sources([Cluster(1, [older, newer, first])], primary=first)
    assert [s["outlet"] for s in sources] == ["The Verge", "Eurogamer"]
    assert sources[1]["url"] == newer.url  # an outlet's chip opens its newest article
    assert [a["url"] for a in sources[1]["also"]] == [older.url]

    html = render.brief_html(brief(top=[story(sources=sources)]))
    assert html.count(">Eurogamer</a>") == 1
    assert (f'<details><summary>More coverage (1)</summary><ul class="more"><li><a href="{older.url}">'
            "Silksong DLC announced</a> · Eurogamer</li></ul></details>") in html


def test_outlets_past_the_fourth_chip_are_listed_under_more_coverage():
    outlets = [{"outlet": f"Outlet {n}", "title": f"Headline {n}", "url": f"https://o{n}.example/",
                "official": False} for n in range(6)]
    html = render.brief_html(brief(top=[story(sources=outlets)]))
    assert html.count('<div class="src">') == 1 and "More coverage (2)" in html
    assert '<li><a href="https://o5.example/">Headline 5</a> · Outlet 5</li>' in html


def test_feeds_of_one_outlet_share_a_chip_named_for_the_outlet():
    world, europe = feed("guardian-world", "The Guardian: World"), feed("guardian-eu", "The Guardian: Europe")
    cna, techmeme = feed("cna", "CNA: World (Singapore)"), feed("techmeme", "Techmeme")
    items = [item(world, "Spain calls a snap election", minutes_ago=50),
             item(europe, "Sánchez gambles on a snap election", minutes_ago=40),
             item(cna, "Spain to hold early election"),
             item(techmeme, "Spain's election and the AI act", source_name="Bloomberg via Techmeme"),
             item(techmeme, "What a snap vote means", source_name="WSJ via Techmeme")]
    sources = _sources([Cluster(1, items)])
    assert sorted(s["outlet"] for s in sources) == [
        "Bloomberg via Techmeme", "CNA (Singapore)", "The Guardian", "WSJ via Techmeme"]


def test_a_list_headline_opens_its_own_article_and_an_ai_headline_the_headline_item():
    verge, ars = feed("verge", "The Verge"), feed("ars", "Ars Technica")
    first = item(verge, "Valve announces the Steam Deck 2", minutes_ago=300)
    later = item(ars, "Valve's Steam Deck 2 arrives", minutes_ago=30)
    clusters = rank(cluster_items([first, later]), CFG, NOW)
    [c] = clusters
    listed = assemble(list_brief(clusters, CFG), clusters, CFG, {"date": "2026-10-04"})
    [s] = listed["top"]
    assert s["title"] == first.title and s["sources"][0]["url"] == first.url

    written = LLMBrief(headline="Day", top=[LLMStory(title="Valve's new handheld is out", summary="",
                                                     importance=3, label="REPORTED", cluster_ids=[c.id])],
                       sections=[])
    [s] = assemble(written, clusters, CFG, {"date": "2026-10-04"})["top"]
    assert s["sources"][0]["url"] == c.headline_item.url == later.url


def test_an_official_post_is_the_primary_source_for_an_ai_headline():
    verge, google = feed("verge", "The Verge"), feed("google", "Google Blog", official=True)
    report = item(verge, "Google launches Gemini 5 for everyone", minutes_ago=20)
    post = item(google, "Introducing Gemini 5", minutes_ago=90)
    s = digest._story(LLMStory(title="Gemini 5 is here", summary="", importance=4, label="CONFIRMED",
                               cluster_ids=[1]), {1: Cluster(1, [report, post])}, None)
    assert [x["outlet"] for x in s["sources"]] == ["Google Blog", "The Verge"]


def test_a_social_post_headline_still_opens_a_reported_article():
    warren = feed("tomwarren", "Tom Warren", url="https://bsky.app/profile/tomwarren.co.uk/rss")
    verge = feed("verge", "The Verge")
    post = item(warren, "Microsoft is bringing Xbox Cloud Gaming to cars", minutes_ago=120)
    article = item(verge, "Xbox Cloud Gaming is coming to cars", minutes_ago=60)
    s = digest._story(LLMStory(title=post.title, summary="", importance=2, label="REPORTED",
                               cluster_ids=[1]), {1: Cluster(1, [post, article])}, "Gaming")
    assert s["sources"][0]["url"] == article.url


def test_opinion_story_is_flagged_only_when_every_article_is_opinion():
    wsj, nyt = feed("wsj", "The Wall Street Journal"), feed("nyt", "New York Times")
    column = item(wsj, "The Fed should cut rates now", url="https://wsj.example/opinion/fed-cut")
    report = item(nyt, "Fed weighs another rate cut")
    llm = lambda ids: LLMStory(title="Fed", summary="", importance=2, label="REPORTED", cluster_ids=ids)  # noqa: E731
    by_id = {1: Cluster(1, [column]), 2: Cluster(2, [column, report])}
    assert digest._story(llm([1]), by_id, "US")["opinion"] is True
    assert "opinion" not in digest._story(llm([2]), by_id, "US")


def day_brief(date, generated_at):
    return brief(date=date, generated_at=generated_at, headline=f"Brief for {date}")


def test_archive_day_pages_link_the_days_around_them(tmp_path):
    old = day_brief("2026-10-03", "2026-10-03T11:02:00Z")
    for key in ("timezone", "window_hours"):  # a brief saved before these existed
        del old[key]
    digest.publish(old, tmp_path)
    digest.publish(day_brief("2026-10-04", "2026-10-04T11:02:00Z"), tmp_path)
    archive = tmp_path / "archive"

    today = (archive / "2026-10-04.html").read_text()
    assert '<nav class="days" aria-label="Other days"><a href="./2026-10-03.html" rel="prev">← Sat, Oct 3</a>' \
           '<a href="../">Latest</a></nav>' in today
    assert 'rel="next"' not in today
    # Yesterday's page was rendered again so it can link forward, in the reader's time zone.
    yesterday = (archive / "2026-10-03.html").read_text()
    assert '<a href="./2026-10-04.html" rel="next">Sun, Oct 4 →</a>' in yesterday
    assert ">7:02 AM EDT</time>" in yesterday
    home = (tmp_path / "index.html").read_text()
    assert '<a href="archive/2026-10-03.html" rel="prev">← Sat, Oct 3</a> · <a href="archive/">Past briefs</a>' in home
    assert 'id="stale"' in home and 'class="days"' not in home

    digest.publish(day_brief("2026-10-05", "2026-10-05T11:02:00Z"), tmp_path)
    middle = (archive / "2026-10-04.html").read_text()
    assert 'href="./2026-10-03.html" rel="prev"' in middle and 'href="./2026-10-05.html" rel="next"' in middle
    assert (archive / "2026-10-03.html").read_text() == yesterday  # its neighbours didn't change
    index = json.loads((archive / "index.json").read_text())["briefs"]
    assert [e["date"] for e in index] == ["2026-10-05", "2026-10-04", "2026-10-03"]
    assert "Brief for 2026-10-04 · 1 story" in (archive / "index.html").read_text()


def test_pruning_the_archive_drops_the_oldest_pages_link_to_a_deleted_day(tmp_path, monkeypatch):
    monkeypatch.setattr(digest, "ARCHIVE_DAYS", 2)
    for day in ("2026-10-03", "2026-10-04", "2026-10-05"):
        digest.publish(day_brief(day, f"{day}T11:02:00Z"), tmp_path)
    archive = tmp_path / "archive"
    assert not (archive / "2026-10-03.html").exists()
    oldest = (archive / "2026-10-04.html").read_text()
    assert "2026-10-03" not in oldest and 'href="./2026-10-05.html" rel="next"' in oldest


def test_a_broken_previous_day_does_not_stop_publishing(tmp_path, caplog):
    digest.publish(day_brief("2026-10-03", "2026-10-03T11:02:00Z"), tmp_path)
    (tmp_path / "archive" / "2026-10-03.json").write_text('{"date": "2026-10-03"}')
    digest.publish(day_brief("2026-10-04", "2026-10-04T11:02:00Z"), tmp_path)
    assert (tmp_path / "index.html").exists() and "re-render" in caplog.text


@pytest.mark.parametrize("field", ["title", "outlet", "url"])
def test_everything_from_the_feeds_is_escaped(field):
    src = {"outlet": "Verge", "title": "Deck", "url": "https://verge.example/", "official": False,
           field: '"><script>alert(1)</script>'}
    html = render.brief_html(brief(top=[story(sources=[src, {**src, "outlet": "Ars"}])]))
    assert "<script>alert" not in html


@pytest.mark.parametrize("url", ["javascript:alert(document.cookie)", " JavaScript:alert(1)",
                                 "data:text/html,<b>x</b>", "/relative/path"])
def test_only_web_links_are_clickable(url):
    src = {"outlet": "Verge", "title": "Deck", "url": url, "official": False}
    for html in (render.brief_html(brief(top=[story(sources=[src])])),
                 render.brief_html(brief(top=[story(sources=[src])]), email=True)):
        assert "javascript:" not in html.lower() and "data:text" not in html
        assert 'href="/relative' not in html
