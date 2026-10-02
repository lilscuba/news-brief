"""Push (ntfy and/or Pushover) and email delivery. Each channel is enabled by its secrets."""
from __future__ import annotations

import logging
import smtplib
from email.message import EmailMessage

import requests

from .config import env

log = logging.getLogger(__name__)

# ntfy priorities: 1 min .. 5 max. Pushover: -2 .. 2.
_PUSHOVER_PRIORITY = {1: -1, 2: -1, 3: 0, 4: 1, 5: 1}


def push_channels() -> list[str]:
    channels = []
    if env("NTFY_TOPIC"):
        channels.append("ntfy")
    if env("PUSHOVER_TOKEN") and env("PUSHOVER_USER"):
        channels.append("pushover")
    return channels


def push(title: str, message: str, url: str | None = None, priority: int = 3,
         tags: str = "") -> bool:
    """Send to every configured push channel. Returns True if at least one succeeded."""
    ok = False
    if topic := env("NTFY_TOPIC"):
        server = env("NTFY_SERVER") or "https://ntfy.sh"
        headers = {"Title": title.encode("utf-8"), "Priority": str(priority)}
        if url:
            headers["Click"] = url
        if tags:
            headers["Tags"] = tags
        if token := env("NTFY_TOKEN"):
            headers["Authorization"] = f"Bearer {token}"
        try:
            requests.post(f"{server.rstrip('/')}/{topic}", data=message.encode("utf-8"),
                          headers=headers, timeout=15).raise_for_status()
            ok = True
        except requests.RequestException as exc:
            log.error("ntfy push failed: %s", exc)
    if (token := env("PUSHOVER_TOKEN")) and (user := env("PUSHOVER_USER")):
        data = {"token": token, "user": user, "title": title[:250], "message": message[:1024],
                "priority": _PUSHOVER_PRIORITY.get(priority, 0)}
        if url:
            data["url"] = url
        try:
            requests.post("https://api.pushover.net/1/messages.json", data=data,
                          timeout=15).raise_for_status()
            ok = True
        except requests.RequestException as exc:
            log.error("Pushover push failed: %s", exc)
    return ok


def smtp_settings() -> dict | None:
    """Gmail shortcut (GMAIL_ADDRESS + GMAIL_APP_PASSWORD, mails yourself) or generic SMTP_*."""
    if (address := env("GMAIL_ADDRESS")) and (password := env("GMAIL_APP_PASSWORD")):
        return {"host": "smtp.gmail.com", "port": 587, "user": address,
                # App passwords are shown as "abcd efgh ijkl mnop"; Gmail wants no spaces.
                "password": password.replace(" ", ""),
                "to": env("EMAIL_TO") or address, "from": address}
    if all(env(k) for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "EMAIL_TO")):
        return {"host": env("SMTP_HOST"), "port": int(env("SMTP_PORT") or 587),
                "user": env("SMTP_USER"), "password": env("SMTP_PASSWORD"),
                "to": env("EMAIL_TO"), "from": env("EMAIL_FROM") or env("SMTP_USER")}
    return None


def email_configured() -> bool:
    return smtp_settings() is not None


def send_email(subject: str, html_body: str, text_body: str) -> bool:
    s = smtp_settings()
    if not s:
        return False
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = s["from"]
    msg["To"] = s["to"]
    msg.set_content(text_body)
    msg.add_alternative(html_body, subtype="html")
    try:
        if s["port"] == 465:
            server = smtplib.SMTP_SSL(s["host"], s["port"], timeout=30)
        else:
            server = smtplib.SMTP(s["host"], s["port"], timeout=30)
            server.starttls()
        with server:
            server.login(s["user"], s["password"])
            server.send_message(msg)
        return True
    except (smtplib.SMTPException, OSError) as exc:
        log.error("email failed: %s", exc)
        return False
