"""Bluesky source, reliability labels, deals routing, alert tiers, Gemini schema, Gmail config."""
import json

import pytest

from briefing import alerts, bluesky, deliver
from briefing.dedupe import cluster_items
from briefing.digest import assemble
from briefing.labels import label_cluster
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
])
def test_labels(titles, official, trusted, expected):
    f = feed("src", official=official, trusted=trusted)
    assert label_cluster(Cluster(1, [item(f, t) for t in titles])) == expected


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
