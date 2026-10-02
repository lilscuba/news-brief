from __future__ import annotations

import html
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

_TRACKING_PARAMS = {
    "fbclid", "gclid", "mc_cid", "mc_eid", "ref", "ref_src", "source", "cmpid", "taid",
    "guccounter", "smid", "mod", "rss", "via", "feature", "share",
}
_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")
_WORD_RE = re.compile(r"[a-z0-9][a-z0-9'+.#-]*")
_STOPWORDS = frozenset(
    """a an the and or but of in on at to for from by with as is are was were be been it its
    this that these those you your we our they their he she his her new now just after over
    into about than more most up out says say said will can could would how why what when who
    here there all not no yes vs via""".split()
)
# " - The Verge", " | Ars Technica" style suffixes some feeds append to titles.
_SUFFIX_RE = re.compile(r"\s+[-|–—]\s+[^-|–—]{2,30}$")


def canonical_url(url: str) -> str:
    """Normalize a URL so the same article from different feeds compares equal."""
    if not url:
        return ""
    parts = urlsplit(url.strip())
    host = parts.netloc.lower()
    if host.startswith("www."):
        host = host[4:]
    if host.startswith("m."):
        host = host[2:]
    query = [
        (k, v)
        for k, v in parse_qsl(parts.query, keep_blank_values=False)
        if not k.lower().startswith("utm_") and k.lower() not in _TRACKING_PARAMS
    ]
    path = parts.path.rstrip("/") or "/"
    return urlunsplit(("https", host, path, urlencode(sorted(query)), ""))


def strip_html(text: str) -> str:
    return _WS_RE.sub(" ", html.unescape(_TAG_RE.sub(" ", text or ""))).strip()


def snippet(text: str, limit: int = 300) -> str:
    text = strip_html(text)
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut + "…"


def clean_title(title: str) -> str:
    return _SUFFIX_RE.sub("", strip_html(title))


def title_tokens(title: str) -> frozenset[str]:
    words = _WORD_RE.findall(clean_title(title).lower().replace("’", "'"))
    return frozenset(w.strip(".'") for w in words if w not in _STOPWORDS and len(w) > 1)


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def contains(text: str, term: str) -> bool:
    return term.lower() in text.lower()
