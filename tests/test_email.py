"""send_email logs success (it used to be silent) and reports failure."""
import logging
import smtplib

import pytest

from briefing import deliver


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
