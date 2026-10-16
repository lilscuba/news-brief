"""Which topic (section) a story belongs to.

The starting point is a vote of the OPML folders of the outlets covering it. Folders describe an
outlet, not a story, so two rules correct the vote:

- AI news that arrives through Tech, Gaming or news feeds (Techmeme, The Verge, politics desks) is
  filed under AI when the headline, or at least half of the headlines, is about AI labs, models
  or AI policy. Readers who follow AI would otherwise miss a third of it. Tech stories also move
  for broader AI vocabulary ("the AI boom"); a game studio's "generative AI in a trailer" stays in
  Gaming.
- Regional folders say where an outlet is based. When the regional vote is split (no region has
  half the outlets, three regions take part, or a tie), the place most headlines name decides:
  Brazil's election covered by ten European outlets is World news. When no single place stands
  out, the region with the most outlets wins. A tie between World (the catch-all) and one region
  goes to that region; a tie between regions is World.

Ties never depend on the order of the items.
"""
from __future__ import annotations

import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .models import Cluster

REGIONS = ("Japan", "Korea", "Europe", "US", "World")
# Equal votes for non-regional topics go to the more specific one.
_PRECEDENCE = ("AI", "Gaming", "Tech", *REGIONS)

# AI labs, their models and leaders, and AI policy: AI news in whichever folder it arrives.
AI_RE = re.compile(
    r"\b(?:openai|anthropic|chatgpt|gpt-?\d\w*|deepmind|gemini (?:\d|app|model|ai|ultra|pro|flash|"
    r"nano|live)|google(?:'s|’s)? gemini|llms?|large language models?|qwen|deepseek|mistral|grok|"
    r"xai|(?:microsoft|github|windows) copilot|perplexity ai|hugging ?face|llama \d|meta ai|"
    r"superintelligence|agi|altman|amodei|"
    r"hassabis|frontier (?:ai|models?)|ai (?:models?|agents?|labs?|safety|czar|policy|act|regulation|"
    r"bills?|chatbots?))\b"
    # "Claude" the model, not Jean-Claude Juncker or Claude Monet.
    r"|(?<![\w-])claude\b(?! (?:monet|debussy|van damme|lelouch|makelele)\b)",
    re.IGNORECASE)
# Broader AI vocabulary, enough to move a Tech story ("The AI boom is making cheap phones disappear";
# a "copilot" in a Tech headline isn't flying a plane).
AI_TECH_RE = re.compile(
    r"\b(?:artificial intelligence|generative ai|gen ?ai|apple intelligence|gemini|copilot|ai (?:chips?|"
    r"startups?|data cent(?:er|re)s?|training|companies|company|boom|bubble|race|assistants?|"
    r"infrastructure|investments?|spending|compute))\b",
    re.IGNORECASE)

# Places that put a story in a region. "U.S." is matched case-sensitively below ("us" is a pronoun).
_PLACES = {
    "Japan": r"japan\w*|tokyo|osaka|kyoto|okinawa|hokkaido|fukushima|hiroshima|nagasaki|yokohama|"
             r"takaichi|ishiba|kishida|nikkei",
    "Korea": r"korea\w*|seoul|busan|incheon|jeju|pyongyang|dmz|kim jong[ -]un|lee jae[ -]myung",
    "Europe": r"europe\w*|eu|brussels|britain|british|uk|england|english|scotland|scottish|wales|"
              r"welsh|ireland|irish|london|france|french|paris|macron|germany|german|berlin|merz|"
              r"italy|italian|rome|meloni|spain|spanish|madrid|portugal|lisbon|netherlands|dutch|"
              r"amsterdam|belgium|poland|warsaw|ukrain\w*|kyiv|kiev|zelensky\w*|russia\w*|moscow|"
              r"kremlin|putin|siberia\w*|sweden|swedish|norway|norwegian|denmark|danish|finland|"
              r"finnish|greece|greek|athens|austria|vienna|switzerland|swiss|hungary|hungarian|"
              r"orban|czech|prague|romania\w*|bucharest|bulgaria\w*|serbia\w*|kosovo|croatia\w*|"
              r"bosnia\w*|moldova\w*|latvia\w*|lithuania\w*|estonia\w*|baltic|nato|starmer",
    "US": r"america|american|americans|united states|washington|white house|congress|senate|"
          r"pentagon|fbi|cia|scotus|trump|vance|democrats?|republicans?|gop|california|texas|florida|"
          r"new york|chicago|los angeles|alaska|hawaii",
    "World": r"china|chinese|beijing|shanghai|xi jinping|taiwan\w*|hong kong|india|indian|modi|"
             r"pakistan\w*|bangladesh\w*|afghan\w*|iran\w*|tehran|iraq\w*|syria\w*|israel\w*|"
             r"gaza|hamas|palestin\w*|lebanon|lebanese|hezbollah|saudi|yemen\w*|houthis?|egypt\w*|"
             r"turkey|turkish|erdogan|africa\w*|nigeria\w*|kenya\w*|ethiopia\w*|tigray|sudan\w*|"
             r"somalia\w*|congo\w*|brazil\w*|lula|bolsonaro|argentin\w*|mexic\w*|venezuela\w*|"
             r"colombia\w*|chile\w*|peru|peruvian|cuba\w*|canad\w*|australia\w*|new zealand|"
             r"indonesia\w*|philippin\w*|vietnam\w*|thailand|thai|myanmar|samoa\w*",
}
_PLACE_RES = {region: re.compile(rf"\b(?:{pattern})\b", re.IGNORECASE) for region, pattern in _PLACES.items()}
_US_RE = re.compile(r"\bU\.?S\.?A?\b")


def is_ai(title: str, tech: bool = False) -> bool:
    """About AI; `tech` also accepts the broader vocabulary used for stories filed under Tech."""
    return bool(AI_RE.search(title) or (tech and AI_TECH_RE.search(title)))


def _places(title: str) -> set[str]:
    """Regions a headline names. "U.S." alone names an actor when another place is named too:
    "Arrest of US marine reignites protests in Japan's Okinawa" is a Japan story."""
    found = {r for r, rx in _PLACE_RES.items() if rx.search(title)}
    if not found and _US_RE.search(title):
        found.add("US")
    return found


def _votes(cluster: Cluster) -> dict[str, int]:
    """Outlets per folder; an outlet with several feeds (BBC World/Europe) votes once per folder."""
    pairs = {(it.outlet, it.feed.category) for it in cluster.items}
    votes: dict[str, int] = {}
    for _, cat in pairs:
        votes[cat] = votes.get(cat, 0) + 1
    return votes


def _rank(cat: str) -> int:
    return _PRECEDENCE.index(cat) if cat in _PRECEDENCE else len(_PRECEDENCE)


def _regional(votes: dict[str, int], titles: list[str]) -> str:
    """A split regional vote. The region at least half the headlines name wins when no other region
    is named half as often ("Brazil" in every headline, however many European outlets cover it);
    otherwise the most outlets, and a tie is World ("German and US scientists win Nobel")."""
    places = [_places(t) for t in titles]
    named = {r: sum(r in p for p in places) / len(titles) for r in REGIONS}
    ranked = sorted(named.values(), reverse=True)
    if ranked[0] >= 0.5 and ranked[1] < ranked[0] / 2:
        return max(named, key=named.get)
    top = max(votes.values())
    leaders = [r for r in REGIONS if votes.get(r) == top]
    # World is the catch-all: an outlet's US desk and its world feed carrying one story is a US
    # story. Only a tie between specific regions is World.
    specific = [r for r in leaders if r != "World"]
    return specific[0] if len(specific) == 1 else "World"


def category(cluster: Cluster) -> str:
    votes = _votes(cluster)
    top = max(votes.values())
    # Most votes; equal votes go to the more specific topic, never to whichever item came first.
    winner = min((c for c, n in votes.items() if n == top), key=lambda c: (_rank(c), c))
    titles = [it.title for it in cluster.items]
    if winner != "AI":
        tech = winner == "Tech"
        if (is_ai(cluster.headline_item.title, tech)
                or sum(is_ai(t, tech) for t in titles) * 2 >= len(titles)):
            return "AI"
    if set(votes) <= set(REGIONS) and (top * 2 < sum(votes.values()) or len(votes) >= 3
                                       or list(votes.values()).count(top) > 1):
        return _regional(votes, titles)
    return winner
