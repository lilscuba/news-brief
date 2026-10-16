"""The emailed brief: delivery is logged, the HTML survives Gmail, and it goes out once a day."""
import logging
import re
import smtplib
from datetime import datetime, timedelta, timezone

import pytest

from briefing import __main__ as cli
from briefing import deliver, digest, render
from briefing.feeds import FetchResult
from briefing.models import Feed, Item


class FakeSMTP:
    sent = []
    fail_login = False

    def __init__(self, host, port, timeout=0):
        self.host, self.port = host, port

    def starttls(self):
        pass

    def login(self, user, password):
        if self.fail_login:
            raise smtplib.SMTPAuthenticationError(534, b"5.7.9 Application-specific password required")

    def send_message(self, msg):
        FakeSMTP.sent.append(msg)
        return {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.fixture
def gmail(monkeypatch):
    for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "EMAIL_TO"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("GMAIL_ADDRESS", "me@gmail.com")
    monkeypatch.setenv("GMAIL_APP_PASSWORD", "abcd efgh ijkl mnop")
    monkeypatch.setattr(deliver.smtplib, "SMTP", FakeSMTP)
    FakeSMTP.sent, FakeSMTP.fail_login = [], False


def test_success_is_logged_and_the_message_goes_to_the_gmail_address(gmail, caplog):
    with caplog.at_level(logging.INFO, logger="briefing.deliver"):
        assert deliver.send_email("Daily brief: 2026-10-02", "<p>hi</p>", "hi") is True
    assert "email sent" in caplog.text
    msg = FakeSMTP.sent[0]
    assert msg["To"] == "me@gmail.com" and msg["Subject"] == "Daily brief: 2026-10-02"


def test_a_rejected_login_is_logged_as_a_failure(gmail, caplog):
    FakeSMTP.fail_login = True
    with caplog.at_level(logging.INFO, logger="briefing.deliver"):
        assert deliver.send_email("s", "<p>x</p>", "x") is False
    assert "email failed" in caplog.text and "email sent" not in caplog.text


# --- The emailed brief ---------------------------------------------------------------------------

SITE = "https://me.github.io/news-brief/"


def story(n=0, outlets=2):
    return {"id": f"s{n}", "title": f"Story {n}", "summary": "What happened.", "importance": 3,
            "label": "REPORTED", "category": "Gaming", "published": "2026-10-04T13:15:00Z",
            "outlet_count": outlets,
            "sources": [{"outlet": f"Outlet {k}", "title": f"Headline {k}",
                         "url": f"https://o{k}.example/{n}", "official": False} for k in range(outlets)]}


def brief(sections=None):
    return {"version": 1, "date": "2026-10-04", "headline": "A busy Sunday.",
            "generated_at": "2026-10-04T11:02:00Z", "timezone": "America/New_York",
            "window_hours": 26, "mode": "list", "model": None, "top": [story(0, outlets=6)],
            "sections": sections or [{"name": "Gaming", "stories": [story(1)]}],
            "stats": {"items": 3, "clusters": 2, "feeds_ok": 2, "feeds_failed": 0},
            "feed_health": [{"key": "d", "title": "The Decoder", "status": "error", "detail": "timeout"}]}


def test_email_html_uses_plain_colors_and_nothing_gmail_drops():
    html = render.brief_html(brief(), archive_link=SITE + "archive/", email=True, web_url=SITE)
    assert "var(" not in html and "--bg" not in html and "prefers-color-scheme" not in html
    assert "background:#f7f6f3" in html and "color:#c2410c" in html  # light theme, written out
    assert "<details" not in html and "<script" not in html and "<nav" not in html
    assert 'name="color-scheme" content="light"' in html
    assert "Sources with problems: The Decoder (not responding)." in html


def test_email_links_the_web_page_and_only_absolute_archive_links():
    html = render.brief_html(brief(), archive_link=SITE + "archive/", email=True, web_url=SITE)
    assert f'<p class="view"><a href="{SITE}">View in browser</a></p>' in html
    assert f'<a href="{SITE}archive/">Past briefs</a>' in html
    assert all(h.startswith("https://") for h in re.findall(r'href="([^"]*)"', html))
    bare = render.brief_html(brief(), archive_link=None, email=True)  # no PAGES_URL
    assert "View in browser" not in bare and "Past briefs" not in bare and 'href="archive' not in bare


def test_email_lists_outlets_without_a_chip_on_one_line():
    html = render.brief_html(brief(), email=True)
    assert ('<p class="also">Also: <a href="https://o4.example/0">Outlet 4</a>, '
            '<a href="https://o5.example/0">Outlet 5</a></p>') in html


def test_email_keeps_long_sections_short_and_links_the_rest():
    # Gmail cuts a message off after about 100 KB, so the email carries each section's best ten.
    many = [{"name": "Gaming", "stories": [story(n) for n in range(1, 14)]}]
    html = render.brief_html(brief(many), email=True, web_url=SITE)
    assert html.count('<article id="s') == 1 + 10
    assert f'<a href="{SITE}#gaming">See all 13 Gaming stories</a>' in html
    everything = render.brief_html(brief(many), email=True)  # nowhere to link: send them all
    assert everything.count('<article id="s') == 1 + 13


def test_notify_emails_the_mail_version_with_links_to_the_site(gmail, monkeypatch):
    monkeypatch.setenv("PAGES_URL", SITE.rstrip("/"))  # set without the trailing slash
    for k in ("NTFY_TOPIC", "PUSHOVER_TOKEN", "PUSHOVER_USER"):
        monkeypatch.delenv(k, raising=False)
    digest.notify(brief())
    msg = FakeSMTP.sent[0]
    html = msg.get_body(("html",)).get_content()
    text = msg.get_body(("plain",)).get_content()
    # This day's own page: by tomorrow the home page shows a different brief.
    day = f"{SITE}archive/{brief()['date']}.html"
    assert "var(" not in html and f'href="{day}">View in browser' in html
    assert f'href="{SITE}archive/">Past briefs' in html
    assert f"View in browser: {day}" in text


# --- Once a day: --skip-if-sent ------------------------------------------------------------------

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
    monkeypatch.setattr(digest.deliver, "email_configured", lambda: True)
    monkeypatch.setattr(digest.deliver, "send_email", lambda *a: log["delivered"].append("email"))
    monkeypatch.delenv("PAGES_URL", raising=False)

    def run(at, **kw):
        Clock.current = at
        return digest.run(cfg=CFG, out_dir=tmp_path / "docs", **kw)

    log["run"] = run
    return log


def test_a_brief_already_sent_today_is_not_built_or_sent_again(daily):
    seven_am = datetime(2026, 10, 4, 11, 0, tzinfo=timezone.utc)
    assert daily["run"](seven_am, skip_if_sent=True)["date"] == "2026-10-04"
    assert daily["fetched"] == 1 and daily["delivered"] == ["push", "email"]

    # GitHub's backstop run at 12:41 UTC: nothing fetched, nothing delivered, nothing rewritten.
    assert daily["run"](seven_am + timedelta(hours=1, minutes=41), skip_if_sent=True) is None
    assert daily["fetched"] == 1 and daily["delivered"] == ["push", "email"]

    # A manual run with "force" goes out anyway; the next morning is a new day.
    assert daily["run"](seven_am + timedelta(hours=3)) is not None
    assert daily["run"](seven_am + timedelta(days=1), skip_if_sent=True)["date"] == "2026-10-05"
    assert daily["fetched"] == 3 and daily["delivered"].count("email") == 3


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
