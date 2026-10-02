"""Shared-backend mode: feed payload, alert candidates and the APNs sender."""
from datetime import timedelta

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from briefing import apns, service
from briefing.feeds import FetchResult
from briefing.models import Cluster
from test_pipeline import CFG, FILLER, NOW, feed, item

FULL_CFG = {**CFG, "digest": {**CFG["digest"], "sections": ["AI", "Tech", "Gaming", "Deals"],
                             "mute": ["wordle"]}}


def test_story_id_is_stable_as_coverage_grows():
    a, b = feed("verge"), feed("ars")
    first = item(a, "Gemini 4 Argon launches today", minutes_ago=60)
    c1 = Cluster(1, [first])
    c2 = Cluster(2, [first, item(b, "Google's Gemini 4 Argon launches", minutes_ago=10)])
    assert service.story_id(c1) == service.story_id(c2) == first.id


def test_build_feed_shape_and_ignores_personal_boosts():
    deepmind, verge, misc = feed("deepmind", "AI", official=True), feed("verge"), feed("misc")
    items = [item(misc, t, url=f"https://misc.example/{i}") for i, t in enumerate(FILLER)]
    items += [item(deepmind, "Gemini 4 Argon: our next era of frontier intelligence"),
              item(verge, "Gemini 4 Argon is Google's next era of frontier intelligence"),
              item(verge, "Wordle hint for today"),                      # muted
              item(verge, "Ancient story", minutes_ago=60 * 72)]         # outside 48 h
    results = [FetchResult(f, [it for it in items if it.feed is f]) for f in (deepmind, verge, misc)]
    out = service.build_feed(results, [deepmind, verge, misc], FULL_CFG, NOW)
    assert out["version"] == 1 and out["sections"] == ["AI", "Tech", "Gaming", "Deals"]
    assert [s["key"] for s in out["sources"]] == ["deepmind", "verge", "misc"]
    titles = [s["title"] for s in out["stories"]]
    assert "Wordle hint for today" not in titles and "Ancient story" not in titles
    top = out["stories"][0]
    assert top["outletCount"] == 2 and top["label"] == "CONFIRMED" and top["official"]
    assert top["sources"][0]["official"] and top["sources"][0]["url"].startswith("https://deepmind")
    assert out["watchlist"][0]["name"] == "Gemini launch"


def test_alert_candidates_only_include_clusters_with_new_items():
    vgc, ign, openai = feed("vgc", trusted=True), feed("ign"), feed("openai", official=True, alert_mode="all")
    old = item(vgc, "Nintendo Direct announced for tomorrow", minutes_ago=200)
    new = item(ign, "Nintendo Direct announced for tomorrow morning", minutes_ago=10)
    lab = item(openai, "Introducing a new model", minutes_ago=5)
    seen = {old.id: "x"}
    cands = service.alert_candidates([old, new, lab], seen, FULL_CFG, NOW)
    by_title = {c["title"]: c for c in cands}
    nd = by_title["Nintendo Direct announced for tomorrow"]
    assert nd["corroboration"] == 2 and not nd["trustedNew"] and nd["outlet"] == "Vgc"
    assert sorted(nd["sourceKeys"]) == ["ign", "vgc"]
    assert by_title["Introducing a new model"]["alertAllNew"]
    # nothing new -> no candidates
    assert service.alert_candidates([old], seen, FULL_CFG, NOW) == []


def test_apns_payload_and_jwt(monkeypatch):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    monkeypatch.setenv("APNS_KEY", pem.replace("\n", "\\n"))  # as pasted into a one-line secret
    monkeypatch.setenv("APNS_KEY_ID", "ABC123DEFG")
    monkeypatch.setenv("APNS_TEAM_ID", "TEAM123456")
    token = apns._jwt()
    assert jwt.get_unverified_header(token) == {"alg": "ES256", "kid": "ABC123DEFG", "typ": "JWT"}
    claims = jwt.decode(token, key.public_key(), algorithms=["ES256"])
    assert claims["iss"] == "TEAM123456"

    body = apns.payload({"title": "T", "body": "B", "url": "https://x", "storyId": "s1",
                         "kind": "alert", "threadId": "Gaming", "token": "abc", "tier": 2})
    assert body == {"aps": {"alert": {"title": "T", "body": "B"}, "sound": "default",
                            "thread-id": "Gaming"}, "url": "https://x", "storyId": "s1", "kind": "alert"}


def test_apns_send_skips_without_secrets(monkeypatch):
    for k in ("APNS_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"):
        monkeypatch.delenv(k, raising=False)
    assert apns.send_all([{"token": "abc", "title": "t", "body": "b"}]) == []
