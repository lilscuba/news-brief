"""Bluesky source, reliability labels, deals routing, alert tiers, Gemini schema, Gmail config."""
import json

import pytest

from briefing import alerts, bluesky, deliver
from briefing.dedupe import cluster_items
from briefing.digest import assemble
from briefing.labels import is_opinion, is_opinion_story, label_cluster
from briefing.models import Cluster, Feed
from briefing.rank import rank
from briefing.summarize import LLMBrief, gemini_schema, list_brief
from test_pipeline import CFG, NOW, feed, item

BSKY = Feed("schreier", "Jason Schreier", "https://bsky.app/profile/jasonschreier.bsky.social/rss",
            "Gaming", trusted=True)


def post(text, created="2026-10-01T11:00:00.000Z", link=None, facet_link=None, **extra):
    p = {"uri": f"at://did:plc:x/app.bsky.feed.post/{abs(hash(text))}",
         "author": {"handle": "jasonschreier.bsky.social"},
         "record": {"text": text, "createdAt": created}}
    if link:
        p["embed"] = {"$type": "app.bsky.embed.external#view",
                      "external": {"uri": link, "title": "Card title"}}
    if facet_link:
        p["record"]["facets"] = [{"features": [{"$type": "app.bsky.richtext.facet#link",
                                                "uri": facet_link}]}]
    return {"post": p, **extra}


def test_handle_for():
    assert bluesky.handle_for("https://bsky.app/profile/grubb.wtf/rss") == "grubb.wtf"
    assert bluesky.handle_for("https://www.theverge.com/rss/index.xml") is None


def test_bluesky_keeps_news_and_drops_chatter():
    data = {"feed": [
        post("NEW: Studio X lays off 200 people", link="https://www.bloomberg.com/x?utm_source=bsky"),
        post("Big Walk is $15.99 on Steam", facet_link="https://buff.ly/abc"),
        post("EXCLUSIVE: Sony is planning a handheld"),          # text-only, but news
        post("Oh Phillies noooooo"),                            # chatter
        post("vote in my poll", link="https://forms.gle/abc"),  # non-news link
        post("reposted thing", reason={"$type": "app.bsky.feed.defs#reasonRepost"}),
    ]}
    items = bluesky.parse_author_feed(BSKY, data, NOW)
    titles = [it.title for it in items]
    assert titles == ["NEW: Studio X lays off 200 people", "Big Walk is $15.99 on Steam",
                      "EXCLUSIVE: Sony is planning a handheld"]
    assert items[0].canonical_url == "https://bloomberg.com/x"   # clusters with the article
    assert items[0].summary == "Card title"
    assert items[1].url == "https://buff.ly/abc"
    assert items[2].url.startswith("https://bsky.app/profile/jasonschreier.bsky.social/post/")
    assert items[0].published.isoformat() == "2026-10-01T11:00:00+00:00"


def test_bluesky_titles_drop_shortlinks_and_ad_tags_but_stay_deals():
    wario = Feed("wario64", "Wario64", "https://bsky.app/profile/wario64.bsky.social/rss", "Gaming")
    data = {"feed": [
        post("Apple AirPods 4 is $79 at Walmart buff.ly/8HWWe6b #ad", facet_link="https://buff.ly/8HWWe6b"),
        post("Walmart Deals Days week buff.ly/QyhA9lq\nTech buff.ly/7XEuuLS\nVideo Games/Media "
             "buff.ly/uYPyoSV\nToys buff.ly/B01tzTC #ad", facet_link="https://buff.ly/QyhA9lq"),
        post("Invincible VS (PS5) is $24.99 on Amazon amzn.to/4vTD7Al\nBest Buy buff.ly/mTafYBR #ad",
             facet_link="https://amzn.to/4vTD7Al"),
    ]}
    items = bluesky.parse_author_feed(wario, data, NOW)
    assert [it.title for it in items] == ["Apple AirPods 4 is $79 at Walmart", "Walmart Deals Days week",
                                          "Invincible VS (PS5) is $24.99 on Amazon"]
    assert items[0].raw_title == "Apple AirPods 4 is $79 at Walmart buff.ly/8HWWe6b #ad"
    # Labels read the post as written, so "#ad" still marks a deal without a price in the title.
    assert all(label_cluster(Cluster(1, [it])) == "DEAL" for it in items)


@pytest.mark.parametrize("titles,official,trusted,expected", [
    (["Keeper is $13.99 on Steam"], False, False, "DEAL"),
    (["CrossCode 75% off this week"], False, False, "DEAL"),
    (["Rumor: new Zelda remake in development"], False, False, "RUMOR-UNVERIFIED"),
    (["Rumor: new Zelda remake in development"], False, True, "RUMOR-CREDIBLE"),
    (["EXCLUSIVE: PS Plus October lineup revealed"], False, True, "RUMOR-CREDIBLE"),
    (["Exclusive: Studio closes after layoffs"], False, False, "REPORTED"),
    (["🚨 EXCLUSIVE 🚨 The official GTA VI album is coming"], False, True, "RUMOR-CREDIBLE"),
    (["The Boba Teashop Refill—Exclusive Interview"], False, True, "REPORTED"),
    (["Stellar Blade 2 is a PS5 exclusive"], False, True, "REPORTED"),
    (["Nintendo announces Switch 2 Lite"], True, False, "CONFIRMED"),
    (["Microsoft buys studio for $2 billion"], False, False, "REPORTED"),
    # Live headlines the substring rules got wrong: words, not fragments ("milli-on sale-s").
    (["Metro Redux's Next-Gen Update passes 50 million sales"], False, False, "REPORTED"),
    (["Sales of EVs slow as discounts fade"], False, False, "REPORTED"),
    (["Greenland Deal: Trump Drops Threat to Annex Denmark Territory"], False, False, "REPORTED"),
    (["Amazon slashes 50% off Beats Studio Pro headphones"], False, False, "DEAL"),
    (["Daily Deal: The Complete Raspberry Pi And Alexa A-Z Bundle"], False, False, "DEAL"),
    (["Amazon's $199 Apple Watch deal is back for Prime Big Deal Days"], False, False, "DEAL"),
    # A leaked video, a data leak, legal "allegedly" and a denial aren't rumors.
    (["Samoa prime minister apologises for Nazi gesture in leaked video"], False, False, "REPORTED"),
    (["Daiwa Securities says info on 110,000 clients may have been leaked"], False, False, "REPORTED"),
    (["FBI in Los Angeles arrests realtor who allegedly worked as Chinese agent"], False, False, "REPORTED"),
    (["Police Allegedly Destroyed $37,000 of Legal Hemp"], False, False, "REPORTED"),
    (["James Gunn Shuts Down Jensen Ackles Batman Casting Rumors"], False, False, "REPORTED"),
    (["Alito Hints That The Dobbs Leaker Knew A Member of the Majority"], False, False, "REPORTED"),
    (["Rumour: Sony 'Accepting Game Pitches' on Fan Fave Franchises"], False, False, "RUMOR-UNVERIFIED"),
    (["Google's Fitbit Edge leaks out with a screen and Pixel 11 colors"], False, False, "RUMOR-UNVERIFIED"),
    (["Marvel's 'Project COMET' First Gameplay Trailer Allegedly Leaks"], False, False, "RUMOR-UNVERIFIED"),
    (["'HomePad' could launch in these four colors, per leaker"], False, False, "RUMOR-UNVERIFIED"),
    # Market and policy wording isn't a sale; a price level needs a price next to it.
    (["Yen falls to all-time low against the dollar"], False, False, "REPORTED"),
    (["Brent crude sinks to lowest price since 2021"], False, False, "REPORTED"),
    (["U.S. lifts sanctions on sale of Russian diesel in global markets"], False, False, "REPORTED"),
    (["\"After an all-time low, we've started to return to growth\" - Xbox's turnaround"], False, False, "REPORTED"),
    (["AirPods Pro 3 hit all-time low $179 at Amazon"], False, False, "DEAL"),
    # Visits, physical leaks and data leaks aren't rumors.
    (["Zelensky makes unannounced visit to Washington"], False, False, "REPORTED"),
    (["Part of Laval Town Centre Evacuated in Mayenne After Chemical Leak"], False, False, "REPORTED"),
    (["Data leak reveals 10 million customers' passwords"], False, False, "REPORTED"),
    (["Pentagon leaks: what we know"], False, False, "REPORTED"),
    (["Sony's unannounced handheld leaks in new photos"], False, False, "RUMOR-UNVERIFIED"),
])

def test_labels(titles, official, trusted, expected):
    f = feed("src", official=official, trusted=trusted)
    assert label_cluster(Cluster(1, [item(f, t) for t in titles])) == expected


def test_regional_news_desks_never_file_deals_and_one_title_cant_turn_a_story_into_one():
    us = feed("ap", "US")
    assert label_cluster(Cluster(1, [item(us, "Oil rises to $95 on Iran supply fears")])) == "REPORTED"
    assert label_cluster(Cluster(1, [item(us, "Taiwan arms sale: US approves $2bn package")])) == "REPORTED"
    news = [item(feed(f"n{i}"), "Trump says Russia to supply diesel to US and global market") for i in range(5)]
    odd = item(feed("deals"), "Russian diesel on sale: 20% off at the pump")
    assert label_cluster(Cluster(1, news + [odd])) == "REPORTED"


def test_opinion_pieces_are_flagged_by_section_or_tag():
    wsj, nikkei, yonhap = feed("wsj"), feed("nikkei"), feed("yonhap")
    assert is_opinion(item(wsj, "Letitia James and the Cornell 7",
                           url="https://www.wsj.com/opinion/letitia-james-cornell-7-abc"))
    assert is_opinion(item(nikkei, "Strategic ambiguity remains Washington's best bet",
                           url="https://asia.nikkei.com/opinion/strategic-ambiguity"))
    assert is_opinion(item(feed("guardian"), "It's time to abolish ICE",
                           url="https://www.theguardian.com/commentisfree/2026/oct/05/abolish-ice"))
    assert is_opinion(item(yonhap, "(EDITORIAL from Korea JoongAng Daily on Oct. 5) A costly delay"))
    tagged = item(wsj, "Letitia James and the Cornell 7")
    tagged.raw_title = "Opinion | Letitia James and the Cornell 7"  # as parse_feed keeps it
    assert is_opinion(tagged)
    news = item(wsj, "Fed holds rates steady", url="https://www.wsj.com/economy/fed-holds-rates")
    assert not is_opinion(news)
    # One column among news reports doesn't make the story an opinion piece; the label is untouched.
    assert is_opinion_story(Cluster(1, [tagged])) and not is_opinion_story(Cluster(2, [tagged, news]))
    assert label_cluster(Cluster(1, [tagged])) == "REPORTED"


def test_deals_get_their_own_section_and_never_top():
    cfg = {**CFG, "digest": {**CFG["digest"], "sections": ["AI", "Tech", "Gaming", "Deals"]}}
    g, a, b = feed("ign", "Gaming"), feed("wario64", "Gaming"), feed("vgc", "Gaming")
    items = [item(a, "Elden Ring is $29.99 on Amazon"), item(a, "Hades II is $19.99 at Best Buy"),
             item(g, "Nintendo Direct dated"), item(b, "Nintendo Direct dated for Thursday")]
    clusters = rank(cluster_items(items), cfg, NOW)
    brief = assemble(list_brief(clusters, cfg), clusters, cfg, {"date": "2026-10-01"})
    assert all(s["label"] != "DEAL" for s in brief["top"])
    deals = next(s for s in brief["sections"] if s["name"] == "Deals")["stories"]
    assert {s["label"] for s in deals} == {"DEAL"} and len(deals) == 2


def test_trusted_single_source_alerts_as_tier_2():
    grubb = feed("grubb", trusted=True)
    [alert] = alerts.find_alerts([item(grubb, "Nintendo Direct coming next week")], {}, {}, CFG, NOW)
    assert alert.tier == 2 and alert.label == "REPORTED" and "[REPORTED]" in alert.title


def test_untrusted_single_source_waits_for_digest():
    rando = feed("blog")
    assert alerts.find_alerts([item(rando, "Nintendo Direct coming next week")], {}, {}, CFG, NOW) == []


def test_deals_never_alert_and_official_goes_first():
    store, openai = feed("store", trusted=True), feed("openai", official=True, alert_mode="all")
    found = alerts.find_alerts([item(store, "Gemini launch sale: 50% off Pixel"),
                                item(openai, "Introducing a new model")], {}, {}, CFG, NOW)
    assert [a.tier for a in found] == [1]


def test_gemini_schema_is_inlined_and_valid():
    schema = gemini_schema(LLMBrief)
    text = json.dumps(schema)
    assert "$ref" not in text and "$defs" not in text and "additionalProperties" not in text
    story = schema["properties"]["top"]["items"]
    assert story["properties"]["label"]["enum"] == [
        "CONFIRMED", "REPORTED", "RUMOR-CREDIBLE", "RUMOR-UNVERIFIED", "DEAL"]
    assert "cluster_ids" in story["required"]
    # Every required field must be declared, including the one named "title".
    assert set(story["required"]) <= set(story["properties"]) and "title" in story["properties"]


def test_gmail_settings(monkeypatch):
    for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "EMAIL_TO"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("GMAIL_ADDRESS", "me@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcd efgh ijkl mnop")
    s = deliver.smtp_settings()
    assert s["host"] == "smtp.gmail.com" and s["password"] == "abcdefghijklmnop"
    assert s["to"] == "me@gmail.com"
    monkeypatch.delenv("GMAIL_APP_PASSWORD")
    assert deliver.smtp_settings() is None
