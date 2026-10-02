"""gemini_json rides out Gemini's transient 'high demand' errors."""
import json

import pytest
import requests

from briefing import summarize
from test_pipeline import CFG

CFG_G = {**CFG, "gemini": {"model": "m"}}
OK = {"candidates": [{"content": {"parts": [{"text": "{}"}]}, "finishReason": "STOP"}]}


class Resp:
    def __init__(self, status, body=None):
        self.status_code, self._body = status, body or {}
        self.text = json.dumps(self._body)

    def json(self):
        return self._body


@pytest.fixture(autouse=True)
def _reset_overloaded():
    summarize._OVERLOADED.clear()
    yield
    summarize._OVERLOADED.clear()


@pytest.fixture
def post(monkeypatch):
    monkeypatch.setenv("GEMINI_API_KEY", "k")
    sleeps = []
    monkeypatch.setattr(summarize.time, "sleep", sleeps.append)

    def install(*responses):
        queue, calls = list(responses), []

        def fake(url, **kw):
            calls.append(url)
            r = queue.pop(0)
            if isinstance(r, Exception):
                raise r
            return r

        monkeypatch.setattr(summarize.requests, "post", fake)
        return calls, sleeps
    return install


def test_retries_a_503_then_succeeds(post):
    calls, sleeps = post(Resp(503), Resp(503), Resp(200, OK))
    text, _ = summarize.gemini_json("s", "u", {}, CFG_G)
    assert text == "{}" and len(calls) == 3 and sleeps == [3, 8]


def test_gives_up_after_the_last_retry(post):
    calls, _ = post(Resp(503), Resp(503), Resp(503))
    with pytest.raises(RuntimeError, match="Gemini HTTP 503"):
        summarize.gemini_json("s", "u", {}, CFG_G)
    assert len(calls) == 3


def test_a_client_error_is_not_retried(post):
    calls, sleeps = post(Resp(400))
    with pytest.raises(RuntimeError, match="Gemini HTTP 400"):
        summarize.gemini_json("s", "u", {}, CFG_G)
    assert len(calls) == 1 and sleeps == []


def test_network_errors_are_retried(post):
    calls, _ = post(requests.Timeout("slow"), Resp(200, OK))
    assert summarize.gemini_json("s", "u", {}, CFG_G)[0] == "{}" and len(calls) == 2


def test_falls_back_to_the_next_model_when_the_primary_stays_overloaded(post):
    cfg = {**CFG, "gemini": {"model": "primary", "fallback_models": ["backup1", "backup2"]}}
    calls, sleeps = post(Resp(503), Resp(503), Resp(503), Resp(503), Resp(200, OK))
    text, usage = summarize.gemini_json("s", "u", {}, cfg)
    assert text == "{}" and usage["model"] == "backup2"
    assert [c.split("models/")[1].split(":")[0] for c in calls] == ["primary"] * 3 + ["backup1", "backup2"]
    assert sleeps == [3, 8]  # fallbacks get a single try, no waiting


def test_client_errors_do_not_fall_back(post):
    cfg = {**CFG, "gemini": {"model": "primary", "fallback_models": ["backup"]}}
    calls, _ = post(Resp(400))
    with pytest.raises(RuntimeError, match="HTTP 400"):
        summarize.gemini_json("s", "u", {}, cfg)
    assert len(calls) == 1


def test_all_models_overloaded_raises_the_last_error(post):
    cfg = {**CFG, "gemini": {"model": "primary", "fallback_models": ["backup"]}}
    calls, _ = post(Resp(503), Resp(503), Resp(503), Resp(503))
    with pytest.raises(RuntimeError, match="HTTP 503"):
        summarize.gemini_json("s", "u", {}, cfg)
    assert len(calls) == 4


def test_a_model_that_failed_every_retry_is_skipped_for_the_rest_of_the_run(post):
    cfg = {**CFG, "gemini": {"model": "primary", "fallback_models": ["backup"]}}
    calls, sleeps = post(Resp(503), Resp(503), Resp(503), Resp(200, OK), Resp(200, OK))
    summarize.gemini_json("s", "u", {}, cfg)
    summarize.gemini_json("s", "u", {}, cfg)  # second call: straight to the backup, no waiting
    names = [c.split("models/")[1].split(":")[0] for c in calls]
    assert names == ["primary"] * 3 + ["backup", "backup"] and sleeps == [3, 8]
