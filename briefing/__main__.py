"""Usage:
  python -m briefing digest [--no-llm] [--dry-run]   build + publish today's brief
  python -m briefing alerts [--dry-run]              check for breaking news and push
  python -m briefing ingest [--dry-run]              shared backend: feed for all app users
  python -m briefing feeds                           fetch every feed and report status
  python -m briefing test-push                       send a test notification
"""
from __future__ import annotations

import argparse
import json
import logging
import sys

from . import alerts, deliver, digest, service
from .config import ROOT
from .feeds import fetch_all, load_opml


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="briefing")
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("digest", help="build and publish the daily brief")
    d.add_argument("--no-llm", action="store_true", help="skip Claude; rank-only brief")
    d.add_argument("--dry-run", action="store_true", help="print JSON; write nothing")
    a = sub.add_parser("alerts", help="send breaking-news push alerts")
    a.add_argument("--dry-run", action="store_true", help="print alerts; send nothing")
    i = sub.add_parser("ingest", help="shared backend: build the feed for all app users and push")
    i.add_argument("--dry-run", action="store_true", help="write feed.json locally; no upload")
    sub.add_parser("feeds", help="check every feed")
    sub.add_parser("test-push", help="send a test push notification")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    if args.command == "digest":
        brief = digest.run(no_llm=args.no_llm, dry_run=args.dry_run)
        print(f"brief for {brief['date']}: {len(brief['top'])} top stories, "
              f"{sum(len(s['stories']) for s in brief['sections'])} in sections")
    elif args.command == "alerts":
        alerts.run(dry_run=args.dry_run)
    elif args.command == "ingest":
        result = service.run(dry_run=args.dry_run)
        if args.dry_run:
            out = ROOT / "server" / "dev" / "feed.json"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(result["feed"], indent=1, ensure_ascii=False), encoding="utf-8")
            print(f"{len(result['feed']['stories'])} stories, {len(result['candidates'])} alert "
                  f"candidates; feed written to {out}")
        else:
            print(result)
    elif args.command == "feeds":
        failed = 0
        for r in fetch_all(load_opml(ROOT / "feeds.opml")):
            newest = max((it.published for it in r.items), default=None)
            status = f"ERROR {r.error}" if r.error else f"{len(r.items):4} items, newest {newest:%Y-%m-%d %H:%M}Z" if newest else "0 items"
            print(f"{r.feed.key:14} {status}")
            failed += bool(r.error)
        return 1 if failed else 0
    elif args.command == "test-push":
        if not deliver.push_channels():
            print("No push channel configured. Set NTFY_TOPIC or PUSHOVER_TOKEN + PUSHOVER_USER.")
            return 1
        ok = deliver.push("Personal Feed", "Test notification: push alerts are working.",
                          priority=3, tags="white_check_mark")
        print("sent" if ok else "failed")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
