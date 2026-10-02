"""Translating non-English feeds: caching, batching, and failing safe."""
import json
from datetime import timedelta

import pytest

from briefing import service, state, translate
from briefing.dedupe import cluster_items
from briefing.digest import _sources
from briefing.models import Feed
from briefing.rank import rank
from test_pipeline import CFG, NOW, feed, item

DE = Feed("tagesschau", "Tagesschau (Germany)", "https://t.example/feed", "Europe", lang="de")


class FakeGemini:
    """Stands in for summarize.gemini_json: "translates" by prefixing, and records each call."""

    def __init__(self, fail=False, drop=()):
        self.calls, self.fail, self.drop = [], fail, set(drop)

    def __call__(self, system, user, schema, cfg, timeout=0):
        if self.fail:
            raise RuntimeError("Gemini HTTP 429")
        sent = json.loads(user)
        self.calls.append(sent)
        items = [{"i": p["i"], "title": f"EN {p['title']}", "summary": f"EN {p['summary']}"}
                 for p in sent if p["i"] not in self.drop]
        return json.dumps({"items": items}), {"input_tokens": 1, "output_tokens": 1}


@pytest.fixture
def gemini(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "test-key")
    fake = FakeGemini()
    monkeypatch.setattr(translate, "gemini_json", fake)
    return fake


def de_items(n=1, minutes_ago=30):
    return [item(DE, f"Schlagzeile {i}", minutes_ago=minutes_ago + i, url=f"https://t.example/{i}") for i in range(n)]


def test_translates_foreign_items_and_keeps_the_original(gemini):
    [it] = de_items()
    assert not translate.is_readable(it)
    st = {}
    assert translate.translate_items([it], CFG, st, NOW) == 1
    assert it.title == "EN Schlagzeile 0" and it.original_title == "Schlagzeile 0"
    assert translate.is_readable(it)
    assert gemini.calls[0][0]["lang"] == "de"
    assert st["translations"][it.id]["title"] == "EN Schlagzeile 0"


def test_cache_means_each_item_is_translated_once(gemini):
    st = {}
    translate.translate_items(de_items(2), CFG, st, NOW)
    assert len(gemini.calls) == 1
    again = de_items(2)  # a later run fetches the same entries as fresh objects with the same ids
    again[0].id, again[1].id = list(st["translations"])
    assert translate.translate_items(again, CFG, st, NOW) == 2
    assert len(gemini.calls) == 1 and all(it.title.startswith("EN ") for it in again)


def test_english_items_are_never_sent(gemini):
    en = item(feed("verge"), "Apple announces a thing")
    assert translate.translate_items([en], CFG, {}, NOW) == 0
    assert gemini.calls == [] and en.original_title is None and translate.is_readable(en)


def test_without_a_key_items_stay_untranslated_and_unreadable(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    [it] = de_items()
    assert translate.translate_items([it], CFG, {}, NOW) == 0
    assert it.title == "Schlagzeile 0" and not translate.is_readable(it)


def test_api_failure_is_not_cached_and_not_fatal(gemini):
    gemini.fail = True
    [it] = de_items()
    st = {}
    assert translate.translate_items([it], CFG, st, NOW) == 0
    assert not translate.is_readable(it) and not st.get("translations")
    gemini.fail = False  # next run succeeds
    assert translate.translate_items([it], CFG, st, NOW) == 1


def test_batches_are_capped_and_newest_goes_first(gemini):
    cfg = {**CFG, "translate": {"batch_size": 2, "max_calls_per_run": 2}}
    items = de_items(5)  # item 0 is the newest
    assert translate.translate_items(items, cfg, {}, NOW) == 4
    assert [len(c) for c in gemini.calls] == [2, 2]
    assert not translate.is_readable(items[4]) and translate.is_readable(items[0])


def test_items_the_model_skipped_are_retried_later(gemini):
    gemini.drop = {1}
    items = de_items(3)
    st = {}
    assert translate.translate_items(items, CFG, st, NOW) == 2
    assert len(st["translations"]) == 2 and sum(translate.is_readable(i) for i in items) == 2


def test_cache_entries_expire(gemini):
    st = {"translations": {"old": {"title": "x", "summary": "", "at": state.iso(NOW - timedelta(days=9))},
                           "new": {"title": "y", "summary": "", "at": state.iso(NOW - timedelta(days=1))}}}
    translate.translate_items(de_items(), CFG, st, NOW)
    assert "old" not in st["translations"] and "new" in st["translations"]


def test_disabled_in_config(gemini):
    cfg = {**CFG, "translate": {"enabled": False}}
    assert translate.translate_items(de_items(), cfg, {}, NOW) == 0 and gemini.calls == []


def test_gemini_is_asked_for_title_and_summary():
    from briefing.summarize import gemini_schema
    item_schema = gemini_schema(translate._Batch)["properties"]["items"]["items"]
    assert set(item_schema["properties"]) == {"i", "title", "summary"}


def test_translated_story_carries_original_headline_to_the_app_and_the_brief(gemini):
    [it] = de_items()
    translate.translate_items([it], CFG, {}, NOW)
    [cluster] = rank(cluster_items([it]), CFG, NOW)
    src = service._story(cluster)["sources"][0]
    assert src["title"] == "EN Schlagzeile 0"
    assert src["translatedFrom"] == "de" and src["originalTitle"] == "Schlagzeile 0"
    brief_src = _sources([cluster])[0]
    assert brief_src["translated_from"] == "de" and brief_src["original_title"] == "Schlagzeile 0"
    english = rank(cluster_items([item(feed("verge"), "Apple news", url="https://v.example/1")]), CFG, NOW)
    assert "translatedFrom" not in service._story(english[0])["sources"][0]


def test_build_feed_leaves_out_untranslated_foreign_items(gemini):
    gemini.fail = True
    foreign, english = de_items()[0], item(feed("verge"), "Apple news", url="https://v.example/2")
    from briefing.feeds import FetchResult
    cfg = {**CFG, "digest": {**CFG["digest"], "sections": ["Tech"]}}
    out = service.build_feed([FetchResult(DE, [foreign]), FetchResult(english.feed, [english])],
                             [DE, english.feed], cfg, NOW)
    assert [s["title"] for s in out["stories"]] == ["Apple news"]


def test_opml_foreign_feeds_declare_a_language():
    from briefing.config import ROOT
    from briefing.feeds import load_opml
    foreign = [f for f in load_opml(ROOT / "feeds.opml") if f.lang != "en"]
    assert len(foreign) >= 10 and {f.lang for f in foreign} >= {"de", "fr", "ja", "ko"}
    assert all(len(f.lang) == 2 for f in foreign)
