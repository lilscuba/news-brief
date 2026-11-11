"""Push delivery (ntfy and/or Pushover). Each channel is enabled by its secrets."""
from __future__ import annotations

import logging

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

