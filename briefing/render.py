"""Render a brief as a self-contained mobile web page (GitHub Pages), an email, or plain text."""
from __future__ import annotations

import re
from datetime import date as Date, datetime, timezone, tzinfo
from html import escape
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .normalize import is_web_url

# Colors are tokens: the page swaps them for dark mode, and the email gets the light values written
# into every rule, because Gmail drops CSS variables (and with them every color and background).
LIGHT = {"bg": "#f7f6f3", "card": "#fff", "ink": "#1c1b19", "muted": "#6b6862", "line": "#e6e3dc",
         "accent": "#c2410c", "chip": "#f1efe9", "top": "#fff7ed", "confirmed": "#15803d",
         "credible": "#b45309", "unverified": "#b91c1c", "deal": "#7c3aed"}
DARK = {"bg": "#141413", "card": "#1d1d1b", "ink": "#ecebe7", "muted": "#9c9890", "line": "#2e2d2a",
        "accent": "#fb923c", "chip": "#2a2926", "top": "#24201b", "confirmed": "#4ade80",
        "credible": "#fbbf24", "unverified": "#f87171", "deal": "#c4b5fd"}

CSS = """
*{box-sizing:border-box}[hidden]{display:none!important}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,
"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}
main{max-width:720px;margin:0 auto;padding:24px 16px 48px}
a{color:var(--ink)}
header h1{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 6px}
header p.lede{font-size:22px;line-height:1.3;font-weight:650;margin:0 0 8px}
.updated{font-size:13px;color:var(--muted);margin:0}.view{font-size:13px;margin:0 0 12px}
time{white-space:nowrap}
.note{background:var(--top);border:1px solid var(--line);padding:8px 12px;border-radius:8px;
font-size:14px;margin:12px 0}
.days{display:flex;flex-wrap:wrap;gap:4px 16px;font-size:14px;margin:12px 0 0}
.sections{position:sticky;top:0;z-index:2;display:flex;gap:8px;overflow-x:auto;margin:16px -16px 8px;
padding:8px 16px;background:var(--bg);border-bottom:1px solid var(--line);scrollbar-width:thin;
-webkit-overflow-scrolling:touch}
.sections a{flex:none;white-space:nowrap;font-size:14px;text-decoration:none;background:var(--chip);
padding:4px 10px;border-radius:999px}
h2{font-size:15px;letter-spacing:.06em;text-transform:uppercase;color:var(--accent);margin:32px 0 8px}
h2,article{scroll-margin-top:64px}
article{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;
margin:10px 0}
.top article{background:var(--top)}
article h3{font-size:17px;line-height:1.3;margin:0 0 6px}
article h3 a{color:inherit;text-decoration:none}article h3 a:hover{text-decoration:underline}
article h3 a:visited{color:var(--muted)}
article p{margin:0 0 10px}
.meta{font-size:12px;color:var(--muted);margin-bottom:6px}
.imp{color:var(--accent);letter-spacing:1px}
.src{display:flex;flex-wrap:wrap;gap:6px}
.src a{font-size:13px;text-decoration:none;background:var(--chip);padding:3px 9px;border-radius:999px}
.src a.off{outline:1px solid var(--accent)}
details{margin-top:6px}summary{font-size:13px;color:var(--muted);cursor:pointer}
details.rest>summary{font-size:14px;color:var(--ink);background:var(--chip);padding:8px 12px;
border-radius:8px}details.rest[open]>summary{margin-bottom:10px}
ul.more{margin:6px 0 0;padding-left:18px;font-size:14px}ul.more li{margin:4px 0}
.also{font-size:13px;color:var(--muted);margin:6px 0 0}
footer{margin-top:40px;font-size:13px;color:var(--muted)}footer a{color:var(--muted)}
footer p{margin:0 0 6px}
.empty{color:var(--muted);font-style:italic}
.lbl{font-size:10px;font-weight:700;letter-spacing:.05em;text-transform:uppercase;padding:1px 6px;
border-radius:4px;border:1px solid currentColor;margin-right:4px}
.lbl-CONFIRMED{color:var(--confirmed)}.lbl-RUMOR-CREDIBLE{color:var(--credible)}
.lbl-RUMOR-UNVERIFIED{color:var(--unverified)}.lbl-DEAL{color:var(--deal)}
.lbl-opinion{color:var(--muted)}
ul.arch{list-style:none;padding:0}ul.arch li{padding:10px 0;border-bottom:1px solid var(--line)}
ul.arch a{font-weight:600;text-decoration:none}
"""
# Gmail's support for flex gaps is patchy; plain inline chips wrap the same way.
EMAIL_CSS = ".src{display:block}.src a{display:inline-block;margin:0 4px 6px 0}"

# After this long the brief on the home page is yesterday's: say so, and keep absolute times.
STALE_HOURS = 26
# Web page only, never the email. Times read "3h ago" while the brief is current; an old brief on
# the home page shows its banner. It updates every minute and when a home-screen app comes back
# (timers pause in the background). Without JavaScript the absolute times stay.
SCRIPT = """(function(){
var u=document.getElementById("updated"),gen=u&&Date.parse(u.getAttribute("datetime"));
if(!gen)return;
var banner=document.getElementById("stale"),times=document.querySelectorAll("time[datetime]");
function ago(ms){var m=Math.floor(ms/6e4);
return m<1?"just now":m<60?m+" min ago":m<1440?Math.floor(m/60)+"h ago":Math.floor(m/1440)+"d ago"}
function tick(){var now=Date.now(),old=now-gen>STALE_MS;
if(banner)banner.hidden=!old;
times.forEach(function(t){if(!t.dataset.abs){t.dataset.abs=t.textContent;t.title=t.textContent}
var at=Date.parse(t.getAttribute("datetime"));
t.textContent=old||isNaN(at)?t.dataset.abs:ago(now-at)})}
tick();setInterval(tick,6e4);document.addEventListener("visibilitychange",tick)})();""".replace("STALE_MS", str(STALE_HOURS * 3_600_000))

MAX_CHIPS = 4
# Plain-list briefs run to 150 stories in a section. The page shows each section's best (they're
# ranked) and keeps the rest one tap away; the email stops there and links the page, because
# Gmail cuts messages off after about 100 KB.
SECTION_PREVIEW = 10
# REPORTED is nearly every story, so it gets no badge; these are the ones worth a glance.
LABEL_NAMES = {"CONFIRMED": "Confirmed", "RUMOR-CREDIBLE": "Credible rumor",
               "RUMOR-UNVERIFIED": "Unverified rumor", "DEAL": "Deal"}
DEALS_SECTION = "Deals"


def _css(email: bool) -> str:
    if email:
        return re.sub(r"var\(--([\w-]+)\)", lambda m: LIGHT[m[1]], CSS) + EMAIL_CSS
    tokens = lambda t: ";".join(f"--{k}:{v}" for k, v in t.items())  # noqa: E731
    return (f":root{{{tokens(LIGHT)}}}@media (prefers-color-scheme:dark){{:root{{{tokens(DARK)}}}}}"
            + CSS)


def _page(title: str, body: str, *, email: bool = False, script: bool = False) -> str:
    js = f'<script id="relative-times">{SCRIPT}</script>' if script else ""
    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        f"<meta name=\"color-scheme\" content=\"{'light' if email else 'light dark'}\">"
        f"<title>{escape(title)}</title><style>{_css(email)}</style></head>"
        f"<body><main>{body}</main>{js}</body></html>"
    )


def _pretty_date(iso_date: str, year: bool = True) -> str:
    d = Date.fromisoformat(iso_date)
    return f"{d:%A}, {d:%B} {d.day}" + (f", {d.year}" if year else "")


def _short_date(iso_date: str) -> str:
    d = Date.fromisoformat(iso_date)
    return f"{d:%a}, {d:%b} {d.day}"


def _zone(brief: dict) -> tzinfo:
    try:
        return ZoneInfo(brief.get("timezone") or "UTC")
    except (ZoneInfoNotFoundError, ValueError):
        return timezone.utc


def _parse(iso: str) -> datetime | None:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _clock(dt: datetime) -> str:
    return f"{dt:%I:%M %p}".lstrip("0")


class _Times:
    """Absolute times in the brief's time zone ("9:15 AM", or "Oct 3, 11:40 PM" on another day),
    in <time> elements the page's script can turn into "3h ago"."""

    def __init__(self, brief: dict):
        self.tz = _zone(brief)
        self.day = Date.fromisoformat(brief["date"])

    def time(self, iso: str | None, *, zone: bool = False, id: str | None = None) -> str:
        dt = _parse(iso) if iso else None
        if dt is None:
            return ""
        dt = dt.astimezone(self.tz)
        text = _clock(dt) if dt.date() == self.day else f"{dt:%b} {dt.day}, {_clock(dt)}"
        if zone:
            text += f" {dt:%Z}"
        attr = f' id="{id}"' if id else ""
        return f'<time{attr} datetime="{escape(iso)}">{text}</time>'


def _slug(name: str, taken: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "section"
    slug, n = base, 1
    while slug in taken:
        n += 1
        slug = f"{base}-{n}"
    taken.add(slug)
    return slug


def _outlet(src: dict) -> str:
    name = escape(src["outlet"])
    return f"{name} (translated)" if src.get("translated_from") else name


def _href(url: str) -> str:
    """An escaped link target. Feeds supply these; only web links are ever made clickable."""
    return escape(url) if is_web_url(url) else "#"


def _chip(src: dict, email: bool) -> str:
    cls = ' class="off"' if src.get("official") else ""
    title = src["title"]
    if src.get("translated_from"):
        title = f'{title} (translated from {src["translated_from"]}: {src.get("original_title", "")})'
    # A tooltip with the outlet's headline; mail has no hover, and every byte counts there.
    tip = "" if email else f' title="{escape(title)}"'
    return f'<a{cls} href="{_href(src["url"])}"{tip}>{_outlet(src)}</a>'


def _more_rows(sources: list[dict]) -> list[tuple[dict, dict]]:
    """(outlet, article) for every article without a chip: the other articles of the outlets
    that have one, then every article of the outlets past MAX_CHIPS."""
    rows = []
    for i, src in enumerate(sources):
        articles = src.get("also", []) if i < MAX_CHIPS else [src, *src.get("also", [])]
        rows += [(src, a) for a in articles]
    return rows


def _coverage(sources: list[dict], email: bool) -> str:
    chips = "".join(_chip(x, email) for x in sources[:MAX_CHIPS])
    html = f'<div class="src">{chips}</div>' if chips else ""
    if email:
        # No <details> in mail clients: link the outlets that didn't get a chip in one line.
        hidden = sources[MAX_CHIPS:]
        if hidden:
            links = ", ".join(f'<a href="{_href(x["url"])}">{_outlet(x)}</a>' for x in hidden)
            html += f'<p class="also">Also: {links}</p>'
        return html
    if rows := _more_rows(sources):
        items = "".join(
            f'<li><a href="{_href(a["url"])}">{escape(a["title"])}</a> · '
            f'{escape(src["outlet"])}{" (translated)" if a.get("translated_from") else ""}</li>'
            for src, a in rows)
        html += (f'<details><summary>More coverage ({len(rows)})</summary>'
                 f'<ul class="more">{items}</ul></details>')
    return html


def _story(s: dict, times: _Times, *, section: str | None, email: bool) -> str:
    """One story card. `section` is None for Top stories, which name their topic."""
    imp = s["importance"]
    tags = []
    label = s.get("label")
    # Inside the Deals section every story is a deal; the badge would only repeat the heading.
    if label in LABEL_NAMES and not (label == "DEAL" and section == DEALS_SECTION):
        tags.append(f'<span class="lbl lbl-{label}">{LABEL_NAMES[label]}</span>')
    if s.get("opinion"):
        tags.append('<span class="lbl lbl-opinion">Opinion</span>')
    meta = [f'<span class="imp" role="img" aria-label="Importance {imp} of 5">'
            f'{"●" * imp}{"○" * (5 - imp)}</span>']
    if section is None and s.get("category"):
        meta.append(escape(s["category"]))
    meta.append(f"{s['outlet_count']} outlets" if s["outlet_count"] > 1 else "1 outlet")
    if when := times.time(s.get("published")):
        meta.append(when)

    sources = s.get("sources") or []
    title = escape(s["title"])
    if sources and is_web_url(sources[0]["url"]):
        # The headline is the big tap target; it opens the story's primary article.
        title = f'<a href="{_href(sources[0]["url"])}">{title}</a>'
    summary = f'<p>{escape(s["summary"])}</p>' if s.get("summary") else ""
    return (
        f'<article id="{escape(s["id"])}"><div class="meta">{"".join(tags)}{" · ".join(meta)}</div>'
        f'<h3>{title}</h3>{summary}{_coverage(sources, email)}</article>'
    )


def _problems(feed_health: list[dict], email: bool) -> str:
    """Feeds that are failing or quiet, by name; the raw error stays in a tooltip."""
    def why(f: dict) -> str:
        return "not responding" if f.get("status") == "error" else f.get("detail") or "no new items"

    if email:
        names = ", ".join(f'{escape(f["title"])} ({escape(why(f))})' for f in feed_health)
        return f"<p>Sources with problems: {names}.</p>"
    rows = "".join(f'<li title="{escape((f.get("detail") or "")[:300])}">{escape(f["title"])}: '
                   f'{escape(why(f))}</li>' for f in feed_health)
    n = len(feed_health)
    return (f'<details><summary>{n} source{"s" if n != 1 else ""} had problems</summary>'
            f'<ul class="more">{rows}</ul></details>')


def brief_html(brief: dict, archive_link: str | None = "archive/", *, prev_date: str | None = None,
               next_date: str | None = None, latest_link: str | None = None, latest: bool = False,
               email: bool = False, web_url: str | None = None) -> str:
    """The brief as a page.

    archive_link: where the archive lives from this page ("archive/" on the home page, "./" on a
      day page); day pages are `archive_link + date + ".html"`. None leaves out every archive link.
    prev_date / next_date / latest_link: the neighbouring days and the home page, for day pages.
    latest: this is the home page, which warns when it's still showing an old brief.
    email: the version for mail clients: light colors written out, no script, no section links,
      no <details>, and a "View in browser" link to `web_url` when there is one.
    """
    times = _Times(brief)
    parts = []
    if email and web_url:
        parts.append(f'<p class="view"><a href="{escape(web_url)}">View in browser</a></p>')
    updated = []
    if stamp := times.time(brief.get("generated_at"), zone=True, id=None if email else "updated"):
        updated.append(f"Updated {stamp}")
    if hours := brief.get("window_hours"):
        updated.append(f"covers the last {hours} hours")
    parts.append(
        f'<header><h1>{escape(_pretty_date(brief["date"]))}</h1>'
        f'<p class="lede">{escape(brief["headline"])}</p>'
        + (f'<p class="updated">{" · ".join(updated)}</p>' if updated else "") + "</header>"
    )
    if latest and not email:
        day = escape(_pretty_date(brief["date"], year=False))
        parts.append(f'<p class="note" id="stale" hidden>This brief is from {day}. '
                     "Today's isn't out yet.</p>")

    days = []
    if archive_link is not None and not email:
        if prev_date:
            days.append(f'<a href="{escape(archive_link)}{escape(prev_date)}.html" rel="prev">'
                        f'← {escape(_short_date(prev_date))}</a>')
        if latest_link:
            days.append(f'<a href="{escape(latest_link)}">Latest</a>')
        if next_date:
            days.append(f'<a href="{escape(archive_link)}{escape(next_date)}.html" rel="next">'
                        f'{escape(_short_date(next_date))} →</a>')
    if days and not latest:
        parts.append(f'<nav class="days" aria-label="Other days">{"".join(days)}</nav>')
    if note := brief.get("note"):
        parts.append(f'<p class="note">{escape(note)}</p>')

    taken = {"top", "updated", "stale"}
    sections = [(sec, _slug(sec["name"], taken)) for sec in brief["sections"]]
    if not email:
        anchors = (['<a href="#top">Top stories</a>'] if brief["top"] else []) + [
            f'<a href="#{slug}">{escape(sec["name"])} ({len(sec["stories"])})</a>'
            for sec, slug in sections]
        parts.append(f'<nav class="sections" aria-label="Sections">{"".join(anchors)}</nav>')
    if brief["top"]:
        parts.append('<section class="top"><h2 id="top">Top stories</h2>'
                     + "".join(_story(s, times, section=None, email=email) for s in brief["top"])
                     + "</section>")
    for sec, slug in sections:
        name = escape(sec["name"])
        cards = [_story(s, times, section=sec["name"], email=email) for s in sec["stories"]]
        body = "".join(cards[:SECTION_PREVIEW]) or '<p class="empty">Quiet day.</p>'
        if len(cards) > SECTION_PREVIEW:
            if not email:
                body += (f'<details class="rest"><summary>Show {len(cards) - SECTION_PREVIEW} more '
                         f'in {name}</summary>{"".join(cards[SECTION_PREVIEW:])}</details>')
            elif web_url:
                body += (f'<p class="also"><a href="{escape(web_url)}#{slug}">See all {len(cards)} '
                         f'{name} stories</a></p>')
            else:  # nowhere to link to: the email carries them all
                body += "".join(cards[SECTION_PREVIEW:])
        parts.append(f'<section><h2 id="{slug}">{name}</h2>{body}</section>')

    st = brief["stats"]
    footer = [
        f'{st["items"]} new items from {st["feeds_ok"]} feeds, grouped into {st["clusters"]} stories.',
        f'Summarized by {escape(brief["model"])}.' if brief.get("model")
        else "Headlines and snippets straight from the feeds.",
    ]
    links = list(days)
    if archive_link is not None:
        links.append(f'<a href="{escape(archive_link)}">Past briefs</a>')
    if links:
        footer.append(" · ".join(links))
    html = "".join(f"<p>{line}</p>" for line in footer)
    if brief.get("feed_health"):
        html += _problems(brief["feed_health"], email)
    parts.append(f"<footer>{html}</footer>")
    return _page(f"Brief · {_short_date(brief['date'])}", "".join(parts), email=email,
                 script=not email)


def archive_html(index: list[dict]) -> str:
    def row(e: dict) -> str:
        n = e.get("story_count")
        meta = escape(e["headline"]) + (f" · {n} stor{'y' if n == 1 else 'ies'}" if n else "")
        return (f'<li><a href="{escape(e["date"])}.html">{escape(_pretty_date(e["date"]))}</a><br>'
                f'<span class="meta">{meta}</span></li>')

    return _page("Past briefs", f'<header><h1>Past briefs</h1></header>'
                                f'<ul class="arch">{"".join(row(e) for e in index)}</ul>'
                                '<footer><a href="../">Latest brief</a></footer>')


def brief_text(brief: dict, web_url: str | None = None) -> str:
    """The plain-text part of the email."""
    lines = [_pretty_date(brief["date"]), brief["headline"]]
    if web_url:
        lines.append(f"View in browser: {web_url}")
    lines.append("")

    def add(title: str, stories: list[dict]) -> None:
        if not stories:
            return
        lines.append(title.upper())
        for s in stories:
            tags = [LABEL_NAMES[s["label"]]] if s.get("label") in LABEL_NAMES else []
            if s.get("opinion"):
                tags.append("Opinion")
            prefix = "".join(f"[{t}] " for t in tags)
            summary = f": {s['summary']}" if s.get("summary") else ""
            lines.append(f"- {prefix}{s['title']}{summary}")
            if s.get("sources"):
                lines.append(f"  {s['sources'][0]['url']}")
        lines.append("")

    add("Top stories", brief["top"])
    for sec in brief["sections"]:
        add(sec["name"], sec["stories"])
    return "\n".join(lines)
