"""Shared-backend mode: feed payload, alert candidates and the APNs sender."""
import dataclasses
import json
from datetime import timedelta

import jwt
import pytest
import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from briefing import apns, service, state, summarize
from briefing.feeds import FetchResult, settle_times
from briefing.models import Cluster, Feed
from test_pipeline import CFG, FILLER, NOW, Clock, feed, item

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


def test_headline_is_a_current_representative_report_but_id_stays_the_earliest():
    # The Spain story (live): the first item is an old explainer, later reports converge on one
    # wording; an aggregator and an opinion column never give the headline.
    old = item(feed("helsinkitimes"), "Housing protests spread across Spain after parliament rejects "
               "tenant measures", minutes_ago=46 * 60)
    reports = [
        item(feed("cbc"), "Spanish PM Sánchez calls snap election after mounting housing crisis", minutes_ago=120),
        item(feed("bbc"), "Spanish PM Sánchez calls early election after housing protests", minutes_ago=200),
        item(feed("rte"), "Spanish PM calls early election amid housing protests", minutes_ago=180),
    ]
    hn = item(feed("hn"), "Spanish PM Sánchez calls early election after housing protests", minutes_ago=5)
    column = item(feed("wsj"), "Spanish PM Sánchez calls early election after housing protests",
                  url="https://www.wsj.com/opinion/sanchez-gamble", minutes_ago=1)
    cluster = Cluster(1, [old, *reports, hn, column])
    assert cluster.lead is old and cluster.headline_item is reports[1]
    story = service._story(cluster)
    assert story["id"] == old.id
    assert story["title"] == reports[1].title and story["sources"][0]["url"] == reports[1].url
    # An official source is always the headline; with nothing but aggregators, the earliest item.
    official = item(feed("lamoncloa", official=True), "Sánchez announces general election for 29 November",
                    minutes_ago=300)
    assert Cluster(2, [*reports, official]).headline_item is official
    assert Cluster(3, [hn]).headline_item is hn
    # Two outlets give no consensus to measure: the newer report is the more current headline.
    assert Cluster(4, [old, reports[0]]).headline_item is reports[0]


def test_story_summary_is_clean_cut_and_falls_back_to_another_outlet():
    a, b = feed("dailycaller"), feed("abc")
    head = item(a, "John Kennedy Does Not Say Yes When Asked If Paxton Has Character", minutes_ago=10)
    head.summary = "John Kennedy Does Not Say Yes When Asked If Paxton Has Character"  # just the headline
    other = item(b, "Kennedy won't say whether Paxton has the character to serve", minutes_ago=60)
    other.summary = ("Sen. John Kennedy declined on Sunday to say whether Ken Paxton has the character to serve "
                     "in the Senate, as Republicans worry about the Texas race and what it means for control "
                     "of the chamber next year, according to people familiar with the discussions in Washington.")
    story = service._story(Cluster(1, [head, other]))
    assert story["title"] == head.title
    assert story["summary"].startswith("Sen. John Kennedy declined") and story["summary"].endswith("…")
    assert len(story["summary"]) <= service.SUMMARY_CHARS
    assert "opinion" not in story
    assert service._story(Cluster(2, [head]))["summary"] == ""
    assert service._story(Cluster(3, [head]), summary="AI text")["summary"] == "AI text"


def test_story_flags_opinion_and_lists_techmeme_by_outlet():
    wsj = feed("wsj")
    column = item(wsj, "Hurray for Higher Mortgage Rates", url="https://www.wsj.com/opinion/hurray-d31ff582")
    assert service._story(Cluster(1, [column]))["opinion"] is True

    verge, tm = feed("verge"), Feed("techmeme", "Techmeme", "https://www.techmeme.com/feed.xml", "Tech")
    article = item(verge, "Apple ships iOS 27.1", url="https://www.theverge.com/apple-ios-27-1", minutes_ago=60)
    post = item(tm, "Apple ships iOS 27.1 with bug fixes", url="https://www.theverge.com/apple-ios-27-1")
    post.source_name, post.alt_urls = "The Verge via Techmeme", ["https://techmeme.com/261005/p9"]
    story = service._story(Cluster(2, [article, post]))
    # The article is listed once, as the Verge's; Techmeme keeps its own page as a second source.
    assert [(s["outlet"], s["url"]) for s in story["sources"]] == [
        ("Verge", "https://www.theverge.com/apple-ios-27-1"), ("Techmeme", "https://techmeme.com/261005/p9")]
    alone = service._story(Cluster(3, [post]))
    assert alone["sources"][0]["outlet"] == "The Verge via Techmeme"


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


def test_source_catalog_flags_feeds_that_stopped_posting():
    live, frozen, broken, empty = feed("bbc"), feed("corriere"), feed("newsweek"), feed("quiet")
    results = [FetchResult(live, [item(live, "Fresh news")]),
               FetchResult(frozen, [item(frozen, "Old news", minutes_ago=20 * 24 * 60)]),
               FetchResult(broken, [], error="HTTPError: 404"), FetchResult(empty, [])]
    cfg = {**CFG, "health": {"stale_days": 14}}
    catalog = {s["key"]: s for s in service._source_catalog([live, frozen, broken, empty], results, cfg, NOW)}
    assert {k: (s["status"], s["stale"]) for k, s in catalog.items()} == {
        "bbc": ("ok", False), "corriere": ("ok", True), "newsweek": ("error", False), "quiet": ("ok", False)}
    assert catalog["corriere"]["latest"] == state.iso(NOW - timedelta(days=20))
    out = service.build_feed(results, [live, frozen, broken, empty], FULL_CFG, NOW)
    assert all(isinstance(s["stale"], bool) for s in out["sources"])  # always present for the app


def test_undated_items_age_from_when_they_were_first_seen():
    nikkei = feed("nikkei", "Japan")
    a, b, c = (item(nikkei, t) for t in ("Toyota to build EV battery plant in Kyushu",
                                          "Japan's exports rise for third month",
                                          "Bank of Japan holds rates steady"))
    for it in (a, b, c):
        it.time_quality, it.published = "none", NOW  # what parse_feed gives an undated entry
    seen = {a.id: state.iso(NOW - timedelta(hours=30)), b.id: state.iso(NOW - timedelta(hours=50))}
    settle_times([a, b, c], seen, NOW)
    cfg = {**FULL_CFG, "digest": {**FULL_CFG["digest"], "sections": ["Japan"]}}
    out = service.build_feed([FetchResult(nikkei, [a, b, c])], [nikkei], cfg, NOW)
    published = {s["title"]: s["published"] for s in out["stories"]}
    assert published == {a.title: state.iso(NOW - timedelta(hours=30)), c.title: state.iso(NOW)}  # b: > 48 h


def test_a_date_only_item_never_heads_a_story_over_a_timed_report():
    jtn, ap = feed("justthenews", "US"), feed("ap", "US")
    day = item(jtn, "Bolsonaro, Lula advance to runoff", minutes_ago=12 * 60)
    day.time_quality = "date"
    report = item(ap, "Bolsonaro and Lula advance to runoff in Brazil", minutes_ago=10 * 60)
    story = service._story(Cluster(1, [day, report]))
    assert story["title"] == report.title and story["sources"][0]["url"] == report.url
    assert story["id"] == day.id  # the id stays the earliest item's


def test_alert_candidates_cover_the_gap_since_the_last_run():
    ign = feed("ign", "Gaming")
    it = item(ign, "Nintendo Direct announced for tomorrow", minutes_ago=120)
    assert service.alert_candidates([it], {}, FULL_CFG, NOW, state.iso(NOW - timedelta(minutes=15))) == []
    [cand] = service.alert_candidates([it], {}, FULL_CFG, NOW, state.iso(NOW - timedelta(hours=3)))
    assert cand["title"] == it.title


# --- service.run ----------------------------------------------------------------------------------

class Worker:
    """Stands in for requests.post to the Worker: answers from a queue, records each feed."""

    def __init__(self, *answers):
        self.answers, self.feeds = list(answers), []

    def __call__(self, url, json=None, headers=None, timeout=None):
        self.feeds.append(json["feed"])
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        resp = requests.Response()
        resp.status_code, resp._content = answer, b'{"pushes": []}'
        return resp


@pytest.fixture
def ingest(monkeypatch, tmp_path):
    """service.run against fake feeds, a fake Worker and a state file in tmp_path."""
    nikkei, verge = feed("nikkei", "Japan"), feed("verge")
    monkeypatch.setattr(service, "ROOT", tmp_path)
    monkeypatch.setattr(service, "load_config", lambda: FULL_CFG)
    monkeypatch.setattr(service, "load_opml", lambda path: [nikkei, verge])
    monkeypatch.setattr(service, "datetime", Clock)
    monkeypatch.setattr(service.time, "sleep", lambda s: None)
    monkeypatch.setenv("WORKER_URL", "https://worker.example")
    monkeypatch.setenv("INGEST_SECRET", "s")
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    def fetch(feeds, now):  # fresh objects each run, as a real fetch gives
        undated = item(nikkei, "Toyota to build EV battery plant in Kyushu", url="https://nikkei.example/1")
        undated.id, undated.time_quality, undated.published = "nk1", "none", now
        timed = item(verge, "Apple ships iOS 27.1", url="https://verge.example/1")
        timed.id, timed.published = "v1", NOW - timedelta(minutes=30)
        return [FetchResult(nikkei, [undated]), FetchResult(verge, [timed])]

    monkeypatch.setattr(service, "fetch_all", fetch)
    Clock.current = NOW
    yield tmp_path / "state" / "ingest.json"
    Clock.current = NOW


def test_run_keeps_an_undated_items_first_seen_time_across_runs(ingest, monkeypatch):
    worker = Worker(200, 200)
    monkeypatch.setattr(service.requests, "post", worker)
    service.run()
    Clock.current = NOW + timedelta(hours=3)
    service.run()
    story = next(s for s in worker.feeds[1]["stories"] if s["title"].startswith("Toyota"))
    assert story["published"] == state.iso(NOW)  # not the second run's time
    saved = json.loads(ingest.read_text())
    assert saved["seen"]["nk1"] == state.iso(NOW) and saved["last_run"] == state.iso(NOW + timedelta(hours=3))


def test_a_headline_waiting_for_translation_stays_new_until_it_reads_in_english(ingest, monkeypatch):
    """Batching translations mustn't cost alerts: an untranslated foreign item isn't marked seen,
    so it still counts as new in the run that translates it."""
    asahi = dataclasses.replace(feed("asahi", "Japan"), lang="ja")
    waiting = item(asahi, "任天堂ダイレクト 10月15日に配信", url="https://asahi.example/1")
    waiting.id = "as1"
    monkeypatch.setattr(service, "load_opml", lambda path: [asahi])
    monkeypatch.setattr(service, "fetch_all", lambda feeds, now: [FetchResult(asahi, [waiting])])
    monkeypatch.setattr(service.translate, "translate_items", lambda *a, **k: None)  # batch not due
    monkeypatch.setattr(service.requests, "post", Worker(200))
    state.save(ingest, {"seen": {"old": state.iso(NOW - timedelta(hours=1))}})
    service.run()
    assert "as1" not in json.loads(ingest.read_text())["seen"]


def test_run_saves_paid_for_caches_when_the_worker_upload_fails(ingest, monkeypatch):
    state.save(ingest, {"seen": {"old": state.iso(NOW - timedelta(hours=1))},
                        "last_run": state.iso(NOW - timedelta(minutes=10))})

    def translated(items, cfg, st, now):
        st.setdefault("translations", {})["de1"] = {"title": "EN", "summary": "", "at": state.iso(now)}

    monkeypatch.setattr(service.translate, "translate_items", translated)
    summarize._FAILED["gemini-x"] = True  # a model that failed during this run
    worker = Worker(requests.ConnectionError("reset"), requests.Timeout("slow"))
    monkeypatch.setattr(service.requests, "post", worker)
    try:
        with pytest.raises(requests.Timeout):
            service.run()
    finally:
        summarize._FAILED.clear()
        summarize._OVERLOADED.clear()
    assert len(worker.feeds) == 2  # one retry
    saved = json.loads(ingest.read_text())
    assert saved["translations"]["de1"]["title"] == "EN" and "gemini-x" in saved["gemini_cooldown"]
    # Nothing was delivered, so the next run offers the same items as new again.
    assert saved["seen"] == {"old": state.iso(NOW - timedelta(hours=1))}
    assert saved["last_run"] == state.iso(NOW - timedelta(minutes=10))


def test_run_retries_a_worker_5xx_once(ingest, monkeypatch):
    worker = Worker(503, 200)
    monkeypatch.setattr(service.requests, "post", worker)
    assert service.run()["stories"] == 2 and len(worker.feeds) == 2
    assert set(json.loads(ingest.read_text())["seen"]) == {"nk1", "v1"}
    monkeypatch.setattr(service.requests, "post", Worker(502, 502))
    with pytest.raises(requests.HTTPError):
        service.run()
