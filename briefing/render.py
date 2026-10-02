"""Render a brief as a self-contained mobile web page (GitHub Pages + email) or plain text."""
from __future__ import annotations

from datetime import date as Date
from html import escape

CSS = """
:root{--bg:#f7f6f3;--card:#fff;--ink:#1c1b19;--muted:#6b6862;--line:#e6e3dc;--accent:#c2410c;
--chip:#f1efe9;--top:#fff7ed}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--card:#1d1d1b;--ink:#ecebe7;--muted:#9c9890;
--line:#2e2d2a;--accent:#fb923c;--chip:#2a2926;--top:#24201b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,BlinkMacSystemFont,
"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}
main{max-width:720px;margin:0 auto;padding:24px 16px 48px}
header h1{font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:0 0 6px}
header p.lede{font-size:22px;line-height:1.3;font-weight:650;margin:0 0 8px}
.note{background:var(--top);border:1px solid var(--line);padding:8px 12px;border-radius:8px;font-size:14px}
nav{display:flex;gap:8px;flex-wrap:wrap;margin:16px 0 8px}
nav a{font-size:14px;color:var(--ink);text-decoration:none;background:var(--chip);padding:4px 10px;border-radius:999px}
h2{font-size:15px;letter-spacing:.06em;text-transform:uppercase;color:var(--accent);margin:32px 0 8px}
article{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:10px 0}
.top article{background:var(--top)}
article h3{font-size:17px;line-height:1.3;margin:0 0 6px}
article p{margin:0 0 10px;color:var(--ink)}
.meta{font-size:12px;color:var(--muted);margin-bottom:6px}
.imp{color:var(--accent);letter-spacing:1px}
.src{display:flex;flex-wrap:wrap;gap:6px}
.src a{font-size:13px;color:var(--ink);text-decoration:none;background:var(--chip);padding:3px 9px;border-radius:999px}
.src a.off{outline:1px solid var(--accent)}
details{margin-top:4px}summary{font-size:13px;color:var(--muted);cursor:pointer}
footer{margin-top:40px;font-size:13px;color:var(--muted)}footer a{color:var(--muted)}
.empty{color:var(--muted);font-style:italic}
.lbl{font-size:10px;font-weight:700;letter-spacing:.05em;padding:1px 6px;border-radius:4px;
border:1px solid currentColor;margin-right:4px}
.lbl-CONFIRMED{color:#15803d}.lbl-REPORTED{color:var(--muted)}.lbl-RUMOR-CREDIBLE{color:#b45309}
.lbl-RUMOR-UNVERIFIED{color:#b91c1c}.lbl-DEAL{color:#7c3aed}
@media (prefers-color-scheme:dark){.lbl-CONFIRMED{color:#4ade80}.lbl-RUMOR-CREDIBLE{color:#fbbf24}
.lbl-RUMOR-UNVERIFIED{color:#f87171}.lbl-DEAL{color:#c4b5fd}}
ul.arch{list-style:none;padding:0}ul.arch li{padding:10px 0;border-bottom:1px solid var(--line)}
ul.arch a{color:var(--ink);font-weight:600;text-decoration:none}
"""

MAX_CHIPS = 4


def _page(title: str, body: str) -> str:
    return (
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        "<meta name=\"color-scheme\" content=\"light dark\">"
        f"<title>{escape(title)}</title><style>{CSS}</style></head>"
        f"<body><main>{body}</main></body></html>"
    )


def _pretty_date(iso_date: str) -> str:
    d = Date.fromisoformat(iso_date)
    return f"{d:%A}, {d:%B} {d.day}, {d.year}"


def _chip(src: dict) -> str:
    cls = ' class="off"' if src.get("official") else ""
    return (f'<a{cls} href="{escape(src["url"])}" title="{escape(src["title"])}" '
            f'rel="noopener">{escape(src["outlet"])}</a>')


def _story(s: dict) -> str:
    stars = "●" * s["importance"] + "○" * (5 - s["importance"])
    covered = f"{s['outlet_count']} outlets" if s["outlet_count"] > 1 else "1 outlet"
    chips = "".join(_chip(x) for x in s["sources"][:MAX_CHIPS])
    more = ""
    if len(s["sources"]) > MAX_CHIPS:
        extra = "".join(_chip(x) for x in s["sources"][MAX_CHIPS:])
        more = (f'<details><summary>+{len(s["sources"]) - MAX_CHIPS} more sources</summary>'
                f'<div class="src">{extra}</div></details>')
    label = s.get("label")
    badge = f'<span class="lbl lbl-{escape(label)}">{escape(label)}</span>' if label else ""
    return (
        f'<article id="{escape(s["id"])}"><div class="meta">{badge}<span class="imp" '
        f'aria-label="importance {s["importance"]} of 5">{stars}</span> · {escape(s["category"])}'
        f' · {covered}</div><h3>{escape(s["title"])}</h3><p>{escape(s["summary"])}</p>'
        f'<div class="src">{chips}</div>{more}</article>'
    )


def brief_html(brief: dict, archive_link: str = "archive/") -> str:
    parts = [
        f'<header><h1>{escape(_pretty_date(brief["date"]))}</h1>'
        f'<p class="lede">{escape(brief["headline"])}</p></header>'
    ]
    if note := brief.get("note"):
        parts.append(f'<p class="note">{escape(note)}</p>')
    anchors = ['<a href="#top">Top stories</a>'] + [
        f'<a href="#{escape(sec["name"].lower())}">{escape(sec["name"])} ({len(sec["stories"])})</a>'
        for sec in brief["sections"]
    ]
    parts.append(f"<nav>{''.join(anchors)}</nav>")
    parts.append('<section class="top"><h2 id="top">Top stories</h2>'
                 + "".join(_story(s) for s in brief["top"]) + "</section>")
    for sec in brief["sections"]:
        stories = "".join(_story(s) for s in sec["stories"]) or '<p class="empty">Quiet day.</p>'
        parts.append(f'<section><h2 id="{escape(sec["name"].lower())}">{escape(sec["name"])}</h2>'
                     f"{stories}</section>")

    st = brief["stats"]
    footer = [
        f'{st["items"]} new items from {st["feeds_ok"]} feeds, grouped into {st["clusters"]} stories.',
        f'Summarized by {escape(brief["model"])}.' if brief.get("model")
        else "Headlines and snippets straight from the feeds.",
        f'<a href="{escape(archive_link)}">Past briefs</a>',
    ]
    if brief.get("feed_health"):
        bad = "; ".join(f'{escape(f["title"])}: {escape(f["detail"])}' for f in brief["feed_health"])
        footer.append(f"Feed problems: {bad}")
    parts.append("<footer>" + "<br>".join(footer) + "</footer>")
    return _page(f"Brief: {brief['date']}", "".join(parts))


def archive_html(index: list[dict]) -> str:
    rows = "".join(
        f'<li><a href="{escape(e["date"])}.html">{escape(_pretty_date(e["date"]))}</a><br>'
        f'<span class="meta">{escape(e["headline"])}</span></li>'
        for e in index
    )
    return _page("Past briefs", f'<header><h1>Past briefs</h1></header><ul class="arch">{rows}</ul>'
                                '<footer><a href="../">Latest brief</a></footer>')


def brief_text(brief: dict) -> str:
    lines = [_pretty_date(brief["date"]), brief["headline"], ""]

    def add(title: str, stories: list[dict]) -> None:
        if not stories:
            return
        lines.append(title.upper())
        for s in stories:
            label = f"[{s['label']}] " if s.get("label") else ""
            lines.append(f"- {label}{s['title']}: {s['summary']}")
            lines.append(f"  {s['sources'][0]['url']}")
        lines.append("")

    add("Top stories", brief["top"])
    for sec in brief["sections"]:
        add(sec["name"], sec["stories"])
    return "\n".join(lines)
