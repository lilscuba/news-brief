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

    def __call__(self, system, user, schema, cfg, timeout=0):
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


def test_waits_until_enough_new_stories_are_ready(gemini):
    out = story_summaries.summarize_stories(clusters(3), CFG, {}, NOW)  # default min_new is 4
    assert out == {} and gemini.calls == []


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
    off = {**CFG, "story_summaries": {"enabled": False}}
    assert story_summaries.summarize_stories(clusters(5), off, {}, NOW) == {} and gemini.calls == []


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
