"""The daily brief goes out once a day, on the reader's local day."""
from datetime import datetime, timedelta, timezone

import pytest

from briefing import __main__ as cli
from briefing import digest
from briefing.feeds import FetchResult
from briefing.models import Feed, Item


class Clock(datetime):
    current = datetime(2026, 10, 4, 11, 0, tzinfo=timezone.utc)  # 7:00 AM in New York

    @classmethod
    def now(cls, tz=None):
        return cls.current


CFG = {
    "digest": {"sections": ["Tech"], "mute": [], "window_hours": 26, "summarize": False,
               "max_clusters_for_llm": 10, "timezone": "America/New_York"},
    "ranking": {"per_source": 3.0, "official_boost": 2.5, "techmeme_boost": 3.0,
                "hn_points_weight": 1.5, "age_penalty_per_hour": 0.08, "boosts": {}},
    "health": {"stale_days": 14},
}


@pytest.fixture
def daily(monkeypatch, tmp_path):
    """digest.run against a fake clock, feed and delivery; records fetches and deliveries."""
    verge = Feed("verge", "The Verge", "https://verge.example/feed", "Tech")
    log = {"fetched": 0, "delivered": []}

    def fetch_all(feeds, now):
        log["fetched"] += 1
        n = log["fetched"]
        it = Item(id=f"v{n}", feed=verge, title=f"Valve news number {n}",
                  url=f"https://verge.example/{n}", canonical_url=f"verge.example/{n}", summary="",
                  published=now - timedelta(minutes=30))
        return [FetchResult(verge, [it])]

    monkeypatch.setattr(digest, "datetime", Clock)
    monkeypatch.setattr(digest, "ROOT", tmp_path)
    monkeypatch.setattr(digest, "load_opml", lambda path: [verge])
    monkeypatch.setattr(digest, "fetch_all", fetch_all)
    monkeypatch.setattr(digest.deliver, "push_channels", lambda: ["ntfy"])
    monkeypatch.setattr(digest.deliver, "push", lambda *a, **k: log["delivered"].append("push"))
    monkeypatch.delenv("PAGES_URL", raising=False)

    def run(at, **kw):
        Clock.current = at
        return digest.run(cfg=CFG, out_dir=tmp_path / "docs", **kw)

    log["run"] = run
    return log


def test_a_brief_already_sent_today_is_not_built_or_sent_again(daily):
    seven_am = datetime(2026, 10, 4, 11, 0, tzinfo=timezone.utc)
    assert daily["run"](seven_am, skip_if_sent=True)["date"] == "2026-10-04"
    assert daily["fetched"] == 1 and daily["delivered"] == ["push"]

    # GitHub's backstop run at 12:41 UTC: nothing fetched, nothing delivered, nothing rewritten.
    assert daily["run"](seven_am + timedelta(hours=1, minutes=41), skip_if_sent=True) is None
    assert daily["fetched"] == 1 and daily["delivered"] == ["push"]

    # A manual run with "force" goes out anyway; the next morning is a new day.
    assert daily["run"](seven_am + timedelta(hours=3)) is not None
    assert daily["run"](seven_am + timedelta(days=1), skip_if_sent=True)["date"] == "2026-10-05"
    assert daily["fetched"] == 3 and daily["delivered"].count("push") == 3


def test_the_day_is_the_readers_local_day_not_utc(daily):
    # 10 PM in New York is already the next day in UTC; the 7 AM brief is still due.
    late = datetime(2026, 10, 5, 2, 0, tzinfo=timezone.utc)
    daily["run"](late, skip_if_sent=True)
    assert daily["run"](datetime(2026, 10, 5, 11, 0, tzinfo=timezone.utc), skip_if_sent=True) is not None
    assert daily["fetched"] == 2


@pytest.mark.parametrize("st,expected", [
    ({}, False),
    ({"last_run": None}, False),
    ({"last_run": {"at": "garbage"}}, False),
    ({"last_run": {"at": "2026-10-04T04:30:00Z"}}, True),    # 12:30 AM in New York
    ({"last_run": {"at": "2026-10-04T03:59:00Z"}}, False),   # 11:59 PM the day before
])
def test_sent_today(st, expected):
    tz = digest.ZoneInfo("America/New_York")
    assert digest.sent_today(st, datetime(2026, 10, 4, 15, 0, tzinfo=timezone.utc), tz) is expected


def test_cli_passes_skip_if_sent_and_reports_the_skip(monkeypatch, capsys):
    calls = []
    monkeypatch.setattr(cli.digest, "run", lambda **kw: calls.append(kw))
    assert cli.main(["digest", "--skip-if-sent"]) == 0
    assert calls == [{"no_llm": False, "dry_run": False, "skip_if_sent": True}]
    assert "already went out" in capsys.readouterr().out
    cli.main(["digest", "--no-llm"])
    assert calls[-1]["skip_if_sent"] is False
