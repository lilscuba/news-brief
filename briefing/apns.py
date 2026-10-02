"""Apple Push Notification service sender (token-based auth, HTTP/2).

Secrets (GitHub Actions):
  APNS_KEY      contents of the .p8 key file from developer.apple.com → Keys
  APNS_KEY_ID   that key's 10-character id
  APNS_TEAM_ID  your Apple Developer team id
  APNS_TOPIC    the app's bundle id, e.g. com.yourname.newsfeed
"""
from __future__ import annotations

import logging
import time

from .config import env

log = logging.getLogger(__name__)

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}


def _jwt() -> str:
    import jwt  # PyJWT[crypto]

    key = (env("APNS_KEY") or "").replace("\\n", "\n")
    return jwt.encode({"iss": env("APNS_TEAM_ID"), "iat": int(time.time())}, key,
                      algorithm="ES256", headers={"kid": env("APNS_KEY_ID")})


def payload(push: dict) -> dict:
    body = {"aps": {"alert": {"title": push["title"], "body": push["body"]}, "sound": "default"}}
    if push.get("threadId"):
        body["aps"]["thread-id"] = push["threadId"]
    for key in ("url", "storyId", "kind"):
        if push.get(key):
            body[key] = push[key]
    return body


def send_all(pushes: list[dict]) -> list[str]:
    """Send every push; return device tokens APNs says are dead (410 / BadDeviceToken)."""
    if not all(env(k) for k in ("APNS_KEY", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC")):
        log.warning("APNS_* secrets not set; skipping %d push(es)", len(pushes))
        return []
    import httpx

    token = _jwt()
    invalid: list[str] = []
    with httpx.Client(http2=True, timeout=15) as client:
        for p in pushes:
            host = HOSTS.get(p.get("environment", "production"), HOSTS["production"])
            headers = {
                "authorization": f"bearer {token}",
                "apns-topic": env("APNS_TOPIC"),
                "apns-push-type": "alert",
                "apns-priority": "10" if p.get("kind") == "alert" else "5",
            }
            try:
                r = client.post(f"{host}/3/device/{p['token']}", json=payload(p), headers=headers)
            except httpx.HTTPError as exc:
                log.error("APNs request failed: %s", exc)
                continue
            if r.status_code == 200:
                continue
            reason = r.json().get("reason", "") if r.content else ""
            # Only reasons that mean "this token is dead". Config errors (e.g.
            # DeviceTokenNotForTopic) are logged instead, so a typo can't wipe every device.
            if r.status_code == 410 or reason in ("BadDeviceToken", "Unregistered"):
                invalid.append(p["token"])
            else:
                log.error("APNs %s: %s", r.status_code, reason)
    return invalid
