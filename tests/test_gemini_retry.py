"""gemini_json rides out Gemini's transient 'high demand' errors."""
import json
from datetime import timedelta

import pytest
import requests

from briefing import state, summarize
from test_pipeline import CFG, NOW

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
    summarize._FAILED.clear()
    yield
    summarize._OVERLOADED.clear()
    summarize._FAILED.clear()


@pytest.fixture
def clock(monkeypatch):
    """time.monotonic under the test's control."""
    now = [1000.0]
    monkeypatch.setattr(summarize.time, "monotonic", lambda: now[0])
    return now


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


def names(calls):
    return [c.split("models/")[1].split(":")[0] for c in calls]


TWO = {**CFG, "gemini": {"model": "primary", "fallback_models": ["backup"]}}


def test_a_model_that_failed_every_retry_is_skipped_by_the_next_calls(post, clock):
    calls, sleeps = post(Resp(503), Resp(503), Resp(503), Resp(200, OK), Resp(200, OK))
    summarize.gemini_json("s", "u", {}, TWO)
    clock[0] += 60
    summarize.gemini_json("s", "u", {}, TWO)  # a minute later: straight to the backup, no waiting
    assert names(calls) == ["primary"] * 3 + ["backup", "backup"] and sleeps == [3, 8]


def test_overloaded_mark_expires(post, clock):
    # One 503 spike early in the run mustn't send everything after it to the last fallback.
    calls, _ = post(Resp(503), Resp(503), Resp(503), Resp(200, OK), Resp(200, OK))
    summarize.gemini_json("s", "u", {}, TWO)
    clock[0] += summarize.OVERLOAD_SECONDS + 1
    _, usage = summarize.gemini_json("s", "u", {}, TWO)
    assert names(calls) == ["primary"] * 3 + ["backup", "primary"] and usage["model"] == "primary"


def test_429_skips_retries_and_falls_back(post):
    calls, sleeps = post(Resp(429), Resp(200, OK))
    _, usage = summarize.gemini_json("s", "u", {}, TWO)
    assert names(calls) == ["primary", "backup"] and sleeps == [] and usage["model"] == "backup"


def test_429_on_the_last_model_is_not_retried(post):
    calls, sleeps = post(Resp(429))
    with pytest.raises(RuntimeError, match="HTTP 429"):
        summarize.gemini_json("s", "u", {}, CFG_G)
    assert len(calls) == 1 and sleeps == []


def test_critical_call_retries_primary_even_if_marked_overloaded(post):
    calls, sleeps = post(Resp(503), Resp(503), Resp(503), Resp(200, OK), Resp(503), Resp(200, OK))
    summarize.gemini_json("s", "u", {}, TWO)  # primary marked overloaded
    _, usage = summarize.gemini_json("s", "u", {}, TWO, critical=True)
    assert names(calls) == ["primary"] * 3 + ["backup"] + ["primary"] * 2
    assert usage["model"] == "primary" and sleeps == [3, 8, summarize.GEMINI_CRITICAL_DELAYS[0]]


def test_critical_call_stays_inside_its_time_budget(post, clock, monkeypatch):
    """A hanging primary can't eat the daily-brief job: retries stop once the next one couldn't
    finish in the budget, requests are cut to what's left, and fallbacks share the same clock."""
    timeouts = []
    calls, sleeps = post()

    def slow(url, **kw):
        calls.append(url)
        timeouts.append(kw["timeout"])
        clock[0] += kw["timeout"]  # every request hangs until its timeout
        raise requests.Timeout()

    monkeypatch.setattr(summarize.requests, "post", slow)
    monkeypatch.setattr(summarize.time, "sleep", lambda s: (sleeps.append(s), clock.__setitem__(0, clock[0] + s)))
    start = clock[0]
    with pytest.raises((requests.Timeout, RuntimeError)):
        summarize.gemini_json("s", "u", {}, TWO, critical=True)
    assert clock[0] - start <= summarize.GEMINI_CRITICAL_BUDGET
    assert names(calls)[0] == "primary" and timeouts[0] == 300


def test_models_override_replaces_the_configured_list(post):
    calls, _ = post(Resp(200, OK))
    summarize.gemini_json("s", "u", {}, TWO, models=["lite", "flash"])
    assert names(calls) == ["lite"]


def test_failed_model_is_skipped_by_later_runs_for_the_cooldown(post, clock):
    calls, _ = post(Resp(503), Resp(503), Resp(503), Resp(200, OK), Resp(200, OK), Resp(200, OK))
    st = {}
    summarize.gemini_json("s", "u", {}, TWO)
    summarize.store_cooldowns(st, NOW)
    assert st["gemini_cooldown"] == {"primary": state.iso(NOW + summarize.COOLDOWN)}

    def new_process():
        summarize._OVERLOADED.clear()
        summarize._FAILED.clear()

    # The next run (a new process) ten minutes later skips the primary without trying it...
    new_process()
    summarize.restore_cooldowns(st, NOW + timedelta(minutes=10))
    summarize.gemini_json("s", "u", {}, TWO)
    assert names(calls)[-1] == "backup"
    summarize.store_cooldowns(st, NOW + timedelta(minutes=10))
    assert st["gemini_cooldown"] == {"primary": state.iso(NOW + summarize.COOLDOWN)}  # not extended

    # ...and once the cooldown is over, tries it again; answering clears it.
    new_process()
    summarize.restore_cooldowns(st, NOW + timedelta(minutes=31))
    summarize.gemini_json("s", "u", {}, TWO)
    summarize.store_cooldowns(st, NOW + timedelta(minutes=31))
    assert names(calls)[-1] == "primary" and "gemini_cooldown" not in st
