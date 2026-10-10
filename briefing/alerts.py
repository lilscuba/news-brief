"""Breaking-news push alerts, run every ~10 minutes alongside the ingest. Four tiers:

  1 OFFICIAL      a feed marked pfAlert="all" (OpenAI, DeepMind, Anthropic) posts anything new.
  2 TRUSTED       a new headline from a pfTrusted source (billbil-kun, Grubb, Schreier, VGC...)
                  matches a watchlist rule. One trusted source is enough.
  3 CORROBORATED  a new headline matches a watchlist rule and that rule's matches over the last
                  few hours span at least `min_sources` outlets (an official source counts double).
  4 DIGEST        everything else waits for the daily brief.

Each rule cools down after it fires so one story doesn't alert repeatedly, deals never alert,
and there's a daily cap (official alerts are sent first when the cap is tight). Every alert
carries its reliability label, so a rumor is never pushed as fact.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from . import deliver, state
from .config import ROOT, load_config
from .feeds import fetch_all, load_opml, settle_times
from .labels import label_cluster
from .models import Cluster, Item
from .rank import is_muted

log = logging.getLogger(__name__)

CORROBORATION_HOURS = 12
RULE_COOLDOWN_HOURS = 12
TIER_NAMES = {1: "official", 2: "trusted", 3: "corroborated"}
# When runs are hours apart (GitHub delays, a missed dispatch), the lookback stretches to cover
# the gap, but nothing older than this is ever pushed as breaking.
MAX_LOOKBACK = timedelta(hours=4)
LOOKBACK_SLACK = timedelta(minutes=10)


@dataclass
class Alert:
    title: str
    message: str
    url: str
    priority: int
    item_ids: list[str]
    tier: int
    label: str
    rule: str | None = None


def rule_matches(rule: dict, title: str) -> bool:
    lowered = title.lower()
    groups = rule.get("match", [])
    return bool(groups) and all(any(t.lower() in lowered for t in group) for group in groups)


def corroboration(items: list[Item]) -> int:
    outlets = {it.outlet for it in items}
    return len(outlets) + (1 if any(it.feed.official for it in items) else 0)


def alert_lookback(cfg: dict, now: datetime, last_run: str | None) -> timedelta:
    """How recent an unseen item must be to alert: `lookback_minutes`, or the time since the last
    run (plus slack) when that is longer, so a late run doesn't silently drop what arrived in the
    gap; capped at MAX_LOOKBACK."""
    lookback = timedelta(minutes=cfg["alerts"]["lookback_minutes"])
    if not last_run:
        return lookback
    gap = now - state.parse_iso(last_run) + LOOKBACK_SLACK
    return max(lookback, min(gap, MAX_LOOKBACK))


def find_alerts(items: list[Item], seen: dict, cooldowns: dict, cfg: dict,
                now: datetime, last_run: str | None = None) -> list[Alert]:
    a = cfg["alerts"]
    recent = [it for it in items
              if now - it.published <= timedelta(hours=CORROBORATION_HOURS)
              and it.feed.alert_mode != "never" and not is_muted(it.title, cfg)]
    lookback = alert_lookback(cfg, now, last_run)
    new = {it.id for it in recent if it.id not in seen and now - it.published <= lookback}

    alerts: list[Alert] = []
    claimed: set[str] = set()
    for rule in a.get("watch", []):
        last = cooldowns.get(rule["name"])
        if last and now - state.parse_iso(last) < timedelta(hours=RULE_COOLDOWN_HOURS):
            continue
        matched = [it for it in recent if rule_matches(rule, it.title)]
        fresh = [it for it in matched if it.id in new]
        if not fresh:
            continue
        label = label_cluster(Cluster(id=0, items=matched))
        if label == "DEAL":
            continue
        if corroboration(matched) >= a["min_sources"]:
            tier = 3
        elif any(it.feed.trusted for it in fresh):
            tier = 2
        else:
            continue
        lead = min(matched, key=lambda it: (not it.feed.official, not it.feed.trusted,
                                            not it.exact_time, it.published))
        outlets = sorted({it.feed.title for it in matched})
        alerts.append(Alert(
            title=f"{rule['name']} [{label}]",
            message=f"{lead.title}\nVia {', '.join(outlets[:5])}",
            url=lead.url, priority=4, item_ids=[it.id for it in matched],
            tier=tier, label=label, rule=rule["name"],
        ))
        claimed.update(it.id for it in matched)

    for it in recent:
        if it.id in new and it.id not in claimed and it.feed.alert_mode == "all":
            alerts.append(Alert(title=f"{it.feed.title} [CONFIRMED]", message=it.title, url=it.url,
                                priority=5, item_ids=[it.id], tier=1, label="CONFIRMED"))
    return sorted(alerts, key=lambda al: al.tier)


def run(dry_run: bool = False) -> list[Alert]:
    cfg = load_config()
    path = ROOT / "state" / "alerts.json"
    st = state.load(path)
    now = datetime.now(timezone.utc)
    today = now.date().isoformat()

    # English feeds only: this pipeline doesn't translate, and headlines in other languages
    # couldn't match the watchlist anyway.
    feeds = [f for f in load_opml(ROOT / "feeds.opml") if f.alert_mode != "never" and f.lang == "en"]
    items = [it for r in fetch_all(feeds, now) for it in r.items]
    seen: dict[str, str] = st.get("seen", {})
    cooldowns: dict[str, str] = st.get("cooldowns", {})
    sent: dict[str, int] = {k: v for k, v in st.get("sent", {}).items() if k == today}
    settle_times(items, seen, now)  # undated items keep the time they were first seen

    alerts = find_alerts(items, seen, cooldowns, cfg, now, st.get("last_run"))
    budget = cfg["alerts"]["max_per_day"] - sent.get(today, 0)
    for alert in alerts:
        if dry_run:
            print(f"[dry-run] tier {alert.tier} ({TIER_NAMES[alert.tier]}) {alert.title}: "
                  f"{alert.message} -> {alert.url}")
            continue
        if budget <= 0:
            log.info("daily alert cap reached; suppressed: %s", alert.message.splitlines()[0])
            continue
        if deliver.push(alert.title, alert.message, url=alert.url, priority=alert.priority,
                        tags="rotating_light"):
            budget -= 1
            sent[today] = sent.get(today, 0) + 1
            if alert.rule:
                cooldowns[alert.rule] = state.iso(now)
        else:
            log.warning("no push channel delivered: %s", alert.message.splitlines()[0])

    if not dry_run:
        for it in items:
            seen.setdefault(it.id, state.iso(now))
        st["seen"] = state.prune(seen, now, keep_days=3,
                                 keep={it.id for it in items if not it.exact_time})
        st["cooldowns"] = cooldowns
        st["sent"] = sent
        st["last_run"] = state.iso(now)
        state.save(path, st)
    log.info("%d alert(s) found, %d sent today", len(alerts), sent.get(today, 0))
    return alerts
