"""Reliability labels for stories, so a rumor never reads like a confirmed announcement.

CONFIRMED         an official / first-party source published it
REPORTED          journalism from an outlet, not (yet) confirmed by the company
RUMOR-CREDIBLE    leak or rumor from a source with a strong track record, or several outlets
RUMOR-UNVERIFIED  leak or rumor from a single source without that track record
DEAL              a sale, discount or price drop

In AI mode the model assigns labels; these rules are the fallback and the list-mode labeler.
Opinion pieces keep their label (the enum is shared with the app and the Worker) and are flagged
separately with `is_opinion`.
"""
from __future__ import annotations

import re
from urllib.parse import urlsplit

from .models import Cluster, Item
from .topics import REGIONS

LABELS = ("CONFIRMED", "REPORTED", "RUMOR-CREDIBLE", "RUMOR-UNVERIFIED", "DEAL")

# Whole words only: "50 million sales" isn't "on sale", and "discounts fade" isn't a deal.
# "Deals:" anywhere, but a singular "Deal:" only opens a headline ("Greenland Deal: Trump drops
# threat" is diplomacy). "Keeper is $13.99 on Steam", "$45.65 at VGP", and Wario64's "#ad" posts.
DEAL_RE = re.compile(
    r"\bdeals:|^\W*(?:(?:daily|hot|today'?s|best) )?deal:|\bdeal alert\b"
    r"|\bon sale\b(?!\s+(?:of|to|by|for)\b)|\bsale:"
    r"|\d+% off\b|\bsave \$\d|\bcoupons?\b"
    r"|\bpromo codes?\b|\bfree to keep\b|\bfree this week\b|\bprime (?:big deal )?days?\b"
    r"|\bblack friday\b|\bcyber monday\b|\bdiscounted to \$|\$\d[\d,.]* (?:off|discount)\b"
    r"|\$\d[\d,]*(?:\.\d\d)?\s+(?:on|at|@|via)\s|#ad\b",
    re.IGNORECASE)
# A price level is a deal only next to a price: "AirPods Pro 3 hit all-time low $179", not "Yen
# falls to all-time low" or "Brent sinks to lowest price since 2021".
PRICE_LEVEL_RE = re.compile(r"\b(?:lowest price|all-time low|record low|price drop)\b", re.IGNORECASE)
PRICE_RE = re.compile(r"[$£€]\s?\d|\d+% off\b", re.IGNORECASE)
# A leak of unannounced products ("trailer leaks", "leak reveals", "per leaker"), not a leaked
# video of a politician, a customer-data leak or "the Dobbs leaker". "Allegedly" is ordinary
# legal wording, not a rumor.
RUMOR_RE = re.compile(
    r"\brumou?r(?:s|ed)?\b|\bdatamin\w*"
    r"|\bunannounced\b(?!\s+(?:visit|trip|inspection|raid|meeting|stop|tour|appearance|arrival)s?\b)(?!\W*$)"
    r"|\breportedly leaked\b"
    r"|\b(?:per|according to|via|from|says|claims) (?:an? |the |one |noted |prolific |reliable |known )?"
    r"leaker\b|\bleaker (?:says|claims|reveals|suggests|shares|hints)\b"
    r"|\bleak(?:s|ed)?\s*(?::|reveals?|suggests?|hints?|points?|shows?|indicates?|claims?)"
    r"|\bleak(?:s|ed)? (?:out|online|early|ahead)\b|\b(?:seems?|appears?) to (?:have )?leak(?:ed)?\b"
    r"|\b(?:trailer|footage|gameplay|screenshots?|renders?|specs|pricing|price|release date|"
    r"roadmap|box art|logo|build|benchmarks?)(?: (?:has|have|allegedly|reportedly|apparently))*"
    r" leak(?:s|ed)?\b"
    r"|(?<!data )(?<!privacy )(?<!security )\bleaks?\W*$",
    re.IGNORECASE)
# Leaks that aren't product leaks: "Chemical leak forces evacuation", "Data leak reveals passwords",
# "Pentagon leaks: what we know".
OTHER_LEAK_RE = re.compile(
    r"\b(?:data|privacy|security|chat|signal|email|e-mail|document|documents|memo|pentagon|intelligence|"
    r"customer|personal|information|gas|chemical|oil|water|fuel|ammonia|radiation|radioactive|nuclear|"
    r"pipeline|roof|methane|toxic|sewage|carbon monoxide|hydrogen|chlorine)\s+leak(?:s|ed|age)?\b",
    re.IGNORECASE)
# "James Gunn Shuts Down Casting Rumors" or "Grammy winner addresses rumor" report a response to a
# rumor, not the rumor.
DENIAL_RE = re.compile(
    r"\b(?:den(?:y|ies|ied|ying)|shuts? down|shoots? down|debunk\w*|dismiss\w*|refutes?|squash\w*|"
    r"quash\w*|tamps? down|ignor(?:e|es|ed|ing)|address(?:es|ed|ing)?|respond(?:s|ed|ing)? to)\b",
    re.IGNORECASE)
# "EXCLUSIVE: ..." or "🚨 EXCLUSIVE 🚨 ..." at the start of a headline.
SCOOP_RE = re.compile(r"^\W*exclusive\b\s*(?:[:|\-–—]|\W*$|\W+\s)", re.IGNORECASE)

_OPINION_SECTIONS = frozenset({
    "opinion", "opinions", "commentisfree", "editorial", "editorials", "editoriali", "op-ed",
    "op-eds", "oped", "columns", "comment", "viewpoint", "viewpoints",
})
_OPINION_TITLE_RE = re.compile(
    r"^\W*(?:opinion|op-?ed|editorial|commentary|column|viewpoint)\s*[|:\]】]"
    r"|^\((?:editorial|op-?ed|column)\b|\|\s*opinion\s*$",
    re.IGNORECASE)


def is_opinion(item: Item) -> bool:
    """An opinion column or editorial, judged by the section in its URL or a title tag
    ('Opinion | ...', '... | Opinion', Yonhap's '(EDITORIAL from ...)')."""
    sections = urlsplit(item.url).path.lower().split("/")
    if any(s in _OPINION_SECTIONS or s.startswith("opinion") for s in sections):
        return True
    return bool(_OPINION_TITLE_RE.search(item.raw_title or item.title))


def is_opinion_story(cluster: Cluster) -> bool:
    """Every item is opinion; one column among news reports doesn't make the story an opinion."""
    return all(is_opinion(it) for it in cluster.items)


def _is_rumor(title: str) -> bool:
    m = RUMOR_RE.search(title)
    if not m or DENIAL_RE.search(title):
        return False
    return "leak" not in m.group(0).lower() or not OTHER_LEAK_RE.search(title)


def _is_deal(item: Item) -> bool:
    """A sale of games or gadgets. The Deals section is for those; a regional news desk's "arms
    sale:", "trade deals:" or "Oil rises to $95 on Iran fears" is news."""
    if item.feed.category in REGIONS:
        return False
    t = item.label_text
    return bool(DEAL_RE.search(t) or (PRICE_LEVEL_RE.search(t) and PRICE_RE.search(t)))


def label_cluster(cluster: Cluster) -> str:
    titles = [it.label_text for it in cluster.items]
    deals = [it for it in cluster.items if _is_deal(it)]
    # One matching headline mustn't turn a many-outlet news story into a deal (DEALs get no summary,
    # no push and leave Top stories): the headline itself, or half the outlets, must read as one.
    headline = cluster.headline_item
    if deals and (any(it is headline for it in deals)
                  or 2 * len({it.outlet for it in deals}) >= len(cluster.outlets)):
        return "DEAL"
    trusted = any(it.feed.trusted for it in cluster.items)
    if any(_is_rumor(t) for t in titles):
        credible = trusted or len(cluster.outlets) >= 2
        return "RUMOR-CREDIBLE" if credible else "RUMOR-UNVERIFIED"
    # An "EXCLUSIVE:" scoop from a proven leaker (billbil-kun, VGC) is a credible leak, not
    # confirmation. "Exclusive interview" or "PS5 exclusive" aren't scoops, hence the tag shape.
    scoop = any(SCOOP_RE.search(t) for t in titles)
    if scoop and trusted and not cluster.official:
        return "RUMOR-CREDIBLE"
    if cluster.official:
        return "CONFIRMED"
    return "REPORTED"


def is_deal(cluster: Cluster) -> bool:
    return label_cluster(cluster) == "DEAL"
