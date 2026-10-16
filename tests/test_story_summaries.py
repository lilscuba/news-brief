"""AI summaries for top stories in the shared feed: caching, gating, and failing safe."""
import json
from datetime import timedelta

import pytest

from briefing import service, state, story_summaries
from briefing.dedupe import cluster_items
from briefing.feeds import FetchResult
from briefing.models import Cluster
from briefing.rank import rank
from test_pipeline import CFG, NOW, feed, item

CFG_S = {**CFG, "alerts": {**CFG["alerts"]}}


class FakeGemini:
    def __init__(self, fail=False, empty=()):
        self.calls, self.fail, self.empty = [], fail, set(empty)

    def __call__(self, system, user, schema, cfg, timeout=0, models=None):
        self.models = models
        if self.fail:
            raise RuntimeError("Gemini HTTP 429")
        sent = json.loads(user)
        self.calls.append(sent)
        items = [{"i": s["i"], "summary": "" if s["i"] in self.empty else f"AI: {s['sources'][0]['headline']}"}
                 for s in sent]
        return json.dumps({"items": items}), {"input_tokens": 1, "output_tokens": 1}


@pytest.fixture
def gemini(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "test-key")
    fake = FakeGemini()
    monkeypatch.setattr(story_summaries, "gemini_json", fake)
    return fake


def clusters(n=5, prefix="Story"):
    out = []
    for i in range(n):
        f = feed(f"src{i}")
        out.append(cluster_items([item(f, f"{prefix} number {i} about something {'xyz'[i % 3]}{i}",
                                       url=f"https://s{i}.example/{prefix}{i}")])[0])
    return [(f"id{prefix}{i}", c) for i, c in enumerate(out)]


def test_summarizes_pending_stories_once_and_caches(gemini):
    cands, st = clusters(5), {}
    out = story_summaries.summarize_stories(cands, CFG, st, NOW)
    assert len(out) == 5 and out["idStory0"].startswith("AI: ")
    assert len(gemini.calls) == 1 and len(gemini.calls[0]) == 5
    again = story_summaries.summarize_stories(cands, CFG, st, NOW)
    assert again == out and len(gemini.calls) == 1  # cached: no second call


def test_sends_every_outlets_headline_and_snippet_but_no_urls(gemini):
    a, b = feed("verge"), feed("ars")
    ia = item(a, "Apple unveils new chip", url="https://verge.example/1")
    ib = item(b, "Apple's new chip explained", url="https://ars.example/1")
    ia.summary = "Apple announced a chip on Tuesday."
    c = Cluster(1, [ia, ib])
    story_summaries.summarize_stories([("s1", c)], {**CFG, "story_summaries": {"min_new": 1}}, {}, NOW)
    sent = gemini.calls[0][0]
    assert sent["outlets"] == 2 and {s["outlet"] for s in sent["sources"]} == {"Verge", "Ars"}
    assert "chip on Tuesday" in json.dumps(sent) and "example" not in json.dumps(sent)


def _cached(cands):
    """A state where these candidates already have a summary."""
    return {"story_summaries": {sid: {"summary": f"old {sid}", "at": state.iso(NOW - timedelta(hours=1)),
                                      "outlets": len(c.outlets), "newest": state.iso(c.newest)}
                                for sid, c in cands}}


def test_waits_until_enough_new_stories_are_ready(gemini):
    # Three new stories ranked 11th-13th: below the default min_new of 4 and not near the top.
    top, low = clusters(10, "Top"), clusters(3, "Low")
    out = story_summaries.summarize_stories(top + low, CFG, _cached(top), NOW)
    assert gemini.calls == [] and set(out) == {sid for sid, _ in top}


def test_a_new_story_near_the_top_is_summarized_right_away(gemini):
    top, new = clusters(9, "Top"), clusters(1, "Breaking")
    out = story_summaries.summarize_stories(top + new, CFG, _cached(top), NOW)  # 10th place
    assert len(gemini.calls) == 1 and [s["i"] for s in gemini.calls[0]] == [0]
    assert out["idBreaking0"].startswith("AI: ")


def grown_cluster(n_outlets, newest_minutes_ago=10):
    items = [item(feed(f"o{i}"), f"US pulls bombers out of RAF Fairford after terror plot {i}",
                  minutes_ago=newest_minutes_ago + 5 * i, url=f"https://o{i}.example/a") for i in range(n_outlets)]
    return Cluster(1, items)


def test_grown_story_is_resummarized_and_replaces_the_cache(gemini):
    st = {"story_summaries": {"s1": {"summary": "A planned security incident at the base.",
                                     "at": state.iso(NOW - timedelta(hours=3)), "outlets": 2,
                                     "newest": state.iso(NOW - timedelta(hours=3))}}}
    c = grown_cluster(8)
    out = story_summaries.summarize_stories([("s1", c)], CFG, st, NOW)
    assert len(gemini.calls) == 1 and out["s1"].startswith("AI: US pulls bombers")
    assert st["story_summaries"]["s1"]["outlets"] == 8
    assert st["story_summaries"]["s1"]["newest"] == state.iso(c.newest)
    # Written now from 8 outlets: the next run keeps it.
    story_summaries.summarize_stories([("s1", c)], CFG, st, NOW + timedelta(minutes=10))
    assert len(gemini.calls) == 1


@pytest.mark.parametrize("cached,age_hours,rank,expected", [
    (2, 3, 0, True),     # 2 -> 8 outlets, summary 3 h old
    (2, 1, 0, False),    # grown, but the summary is only 1 h old
    (6, 3, 0, False),    # 6 -> 8 is not enough growth
    (6, 7, 5, True),     # a top-15 story still getting coverage 6+ h after its summary
    (6, 7, 20, False),   # ...but not one further down
    (None, 3, 30, True),  # entries from before outlets were recorded count as 1 outlet
])
def test_when_a_cached_summary_is_outgrown(cached, age_hours, rank, expected):
    at = NOW - timedelta(hours=age_hours)
    entry = {"summary": "x", "at": state.iso(at)}
    if cached is not None:
        entry |= {"outlets": cached, "newest": state.iso(at - timedelta(minutes=5))}
    assert story_summaries._outgrown(entry, grown_cluster(8), rank, NOW) is expected


def test_nothing_new_since_the_summary_means_no_refresh():
    c = grown_cluster(8, newest_minutes_ago=8 * 60)
    entry = {"summary": "x", "at": state.iso(NOW - timedelta(hours=1)), "outlets": 2,
             "newest": state.iso(c.newest)}
    assert not story_summaries._outgrown(entry, c, 0, NOW)


def test_refreshes_are_capped_and_new_stories_go_first(gemini):
    old = clusters(7, "Old")
    st = {"story_summaries": {sid: {"summary": "x", "at": state.iso(NOW - timedelta(hours=9)), "outlets": 1,
                                    "newest": state.iso(NOW - timedelta(hours=9))} for sid, _ in old}}
    new = clusters(2, "New")
    cfg = {**CFG, "story_summaries": {"max_refresh_per_run": 5}}
    story_summaries.summarize_stories(old + new, cfg, st, NOW)  # all 7 developing (top 15, 6 h+)
    sent = [s["sources"][0]["headline"] for s in gemini.calls[0]]
    assert [h.split()[0] for h in sent] == ["New", "New"] + ["Old"] * 5
    assert sent[2].startswith("Old number 0")  # refreshes best-ranked first


def test_a_failed_refresh_keeps_the_old_summary(gemini):
    gemini.fail = True
    st = {"story_summaries": {"s1": {"summary": "Earlier summary.", "at": state.iso(NOW - timedelta(hours=3)),
                                     "outlets": 2, "newest": state.iso(NOW - timedelta(hours=3))}}}
    assert story_summaries.summarize_stories([("s1", grown_cluster(8))], CFG, st, NOW) == {"s1": "Earlier summary."}


def test_an_empty_refresh_keeps_the_old_summary_and_is_not_retried(gemini):
    gemini.empty = {0}
    st = {"story_summaries": {"s1": {"summary": "Earlier summary.", "at": state.iso(NOW - timedelta(hours=3)),
                                     "outlets": 2, "newest": state.iso(NOW - timedelta(hours=3))}}}
    c = grown_cluster(8)
    assert story_summaries.summarize_stories([("s1", c)], CFG, st, NOW) == {"s1": "Earlier summary."}
    assert st["story_summaries"]["s1"]["outlets"] == 8
    story_summaries.summarize_stories([("s1", c)], CFG, st, NOW + timedelta(minutes=10))
    assert len(gemini.calls) == 1


def test_payload_has_one_item_per_outlet_newest_first(gemini):
    verge, verge_ai, ars = feed("verge"), feed("verge-ai"), feed("ars")
    items = [item(verge, "Apple unveils new chip", minutes_ago=90, url="https://verge.example/1"),
             item(verge_ai, "Apple's chip runs bigger models", minutes_ago=20, url="https://verge.example/2"),
             item(ars, "Apple's new chip explained", minutes_ago=60, url="https://ars.example/1")]
    items += [item(feed(f"x{i}"), f"Apple chip coverage {i}", minutes_ago=100 + i, url=f"https://x{i}.example/1")
              for i in range(6)]
    story_summaries.summarize_stories([("s1", Cluster(1, items))], CFG, {}, NOW)
    sources = gemini.calls[0][0]["sources"]
    assert [s["headline"] for s in sources[:2]] == ["Apple's chip runs bigger models", "Apple's new chip explained"]
    assert len(sources) == story_summaries.MAX_SOURCES == 6  # 8 outlets, the newest 6


def test_without_a_key_nothing_is_sent(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    assert story_summaries.summarize_stories(clusters(5), CFG, {}, NOW) == {}


def test_api_failure_is_not_cached_and_not_fatal(gemini):
    gemini.fail = True
    st = {}
    assert story_summaries.summarize_stories(clusters(5), CFG, st, NOW) == {}
    assert not st.get("story_summaries")
    gemini.fail = False
    assert len(story_summaries.summarize_stories(clusters(5), CFG, st, NOW)) == 5


def test_empty_summaries_fall_back_and_are_not_asked_again(gemini):
    gemini.empty = {1}
    cands, st = clusters(5), {}
    out = story_summaries.summarize_stories(cands, CFG, st, NOW)
    assert "idStory1" not in out and len(out) == 4
    story_summaries.summarize_stories(cands, CFG, st, NOW)
    assert len(gemini.calls) == 1


def test_batches_and_call_cap(gemini):
    cfg = {**CFG, "story_summaries": {"batch_size": 2, "max_calls_per_run": 2, "min_new": 1}}
    out = story_summaries.summarize_stories(clusters(5), cfg, {}, NOW)
    assert [len(c) for c in gemini.calls] == [2, 2] and len(out) == 4


def test_cache_entries_expire_and_feature_can_be_disabled(gemini):
    st = {"story_summaries": {"old": {"summary": "x", "at": state.iso(NOW - timedelta(days=9))}}}
    story_summaries.summarize_stories(clusters(1), CFG, st, NOW)
    assert "old" not in st["story_summaries"]
    calls = len(gemini.calls)
    off = {**CFG, "story_summaries": {"enabled": False}}
    assert story_summaries.summarize_stories(clusters(5), off, {}, NOW) == {} and len(gemini.calls) == calls


def test_prompt_schema_asks_for_index_and_summary():
    from briefing.summarize import gemini_schema
    props = gemini_schema(story_summaries._Batch)["properties"]["items"]["items"]["properties"]
    assert set(props) == {"i", "summary"}


def _build(gemini_state, cfg=CFG, st=None):
    fs = [feed(f"w{i}", "Tech") for i in range(5)]
    results = [FetchResult(f, [item(f, f"Distinct headline {i} regarding topic {'abcde'[i]}{i}", minutes_ago=10 + i,
                                    url=f"https://w{i}.example/a")]) for i, f in enumerate(fs)]
    cfg = {**cfg, "digest": {**cfg["digest"], "sections": ["Tech"]}}
    return service.build_feed(results, fs, cfg, NOW, st)


def test_build_feed_replaces_snippets_with_ai_summaries_and_marks_them(gemini):
    out = _build(gemini, st={})
    assert all(s["summary"].startswith("AI: ") and s["aiSummary"] is True for s in out["stories"])


def test_build_feed_without_state_keeps_snippets(gemini):
    out = _build(gemini, st=None)
    assert gemini.calls == [] and all("aiSummary" not in s for s in out["stories"])


def test_deals_and_stories_beyond_top_n_are_not_summarized(gemini):
    cfg = {**CFG, "story_summaries": {"top_n": 2, "min_new": 1}}
    out = _build(gemini, cfg, st={})
    assert sum("aiSummary" in s for s in out["stories"]) == 2
    deal_cfg = {**CFG, "story_summaries": {"min_new": 1}}
    fs = feed("shop", "Gaming")
    results = [FetchResult(fs, [item(fs, "Deal: Big game 50% off at Steam", url="https://shop.example/d")])]
    deals = service.build_feed(results, [fs], {**deal_cfg, "digest": {**deal_cfg["digest"], "sections": ["Gaming"]}}, NOW, {})
    assert "aiSummary" not in deals["stories"][0]
