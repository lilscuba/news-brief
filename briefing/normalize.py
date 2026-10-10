from __future__ import annotations

import html
import re
import unicodedata
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
# Wire-service jargon and section tags in front of headlines: Yonhap's "(LEAD)", "(2nd LD)",
# "(URGENT)" and the WSJ's "Opinion | " (opinion pieces are flagged separately, see labels.py).
_PREFIX_RE = re.compile(
    r"^(?:\((?:LEAD|URGENT|LD|\d+(?:st|nd|rd|th) LD)\)|(?:Opinion|OPINION|Op-[Ee]d|Editorial|"
    r"Commentary)\s*[|:])\s*"
)


def is_web_url(url: str) -> bool:
    """An http(s) link. Anything else a feed sends (javascript:, data:, a bare path) is never
    linked: it would run in the reader's browser, and the in-app browser only opens web pages."""
    try:
        return urlsplit(url.strip()).scheme.lower() in ("http", "https")
    except ValueError:
        return False


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


# --- Snippets -----------------------------------------------------------------------------------
# Feed descriptions are HTML fragments full of furniture: photos with captions and credits,
# "Continue reading..." links, WordPress footers. These go before the text is flattened.
_DROP_HTML = [
    re.compile(r"<(figure|figcaption|script|style)\b[^>]*>.*?</\1\s*>", re.I | re.S),
    # Embedded posts ("twitter-tweet"): someone else's words, not the article's.
    re.compile(r"<blockquote\b[^>]*class=\"[^\"]*(?:tweet|instagram|tiktok)[^\"]*\"[^>]*>.*?</blockquote\s*>",
               re.I | re.S),
    # A box holding just an image and its caption (AppleInsider, 9to5Mac).
    re.compile(r"<div\b[^>]*>\s*(?:<a\b[^>]*>\s*)?<img\b[^>]*>\s*(?:</a>\s*)?(?:<br\s*/?>\s*)*"
               r"(?:<(?:span|p|em|i|small)\b[^>]*>[^<]{0,400}</(?:span|p|em|i|small)>\s*)?"
               r"(?:<br\s*/?>\s*)*</div\s*>", re.I),
    re.compile(r"<a\b[^>]*class=\"more-link\"[^>]*>.*?</a\s*>", re.I | re.S),
]
# Paragraph-level tags: the text on either side belongs to different sentences.
_BLOCK_TAG_RE = re.compile(
    r"</?(?:p|div|li|ul|ol|h[1-6]|blockquote|section|article|header|footer|table|tr)\b[^>]*>"
    r"|<(?:br|hr)\b[^>]*>", re.I)
_BREAK = "\x00"
_SENTENCE_PUNCT = ".!?…:;\"'”’)]"
# Publisher boilerplate at the end of a description, removed repeatedly (they can stack).
# Link-text forms only (capitalized, after a sentence end), so "...you can read more." survives.
_AFTER_SENTENCE = r"(?:(?<=[.!?…\"”’)\]])|^)\s*"
_TRAILING_JUNK = [
    # WordPress and MacRumors footers: 'The post X appeared first on Insider Gaming.',
    # 'This article, "X" first appeared on MacRumors.com. Discuss this article in our forums'.
    re.compile(r"\s*\b(?:The|This) (?:post|article),? .{1,300}? (?:appeared first|first appeared) on\b"
               r".{0,80}$", re.S),
    re.compile(r"\s*\bThis (?:article|story) (?:originally|first) appeared (?:on|in)\b.{0,200}$", re.S),
    re.compile(_AFTER_SENTENCE + r"(?:Continue [Rr]eading|Keep [Rr]eading|Read [Mm]ore|READ MORE|"
               r"Read the (?:full|rest of the) (?:story|article|post)|Read [Ff]ull (?:[Ss]tory|[Aa]rticle))"
               r"(?:\s+(?:here|(?:at|on) [\w.'’& -]{1,60}?))?(?:\s*:\s*\S+)?"
               r"(?:\s*\|\s*Discuss on our Forums)?\W*$"),
    re.compile(_AFTER_SENTENCE + r"Tags:\s*[\w ,.+#&'’-]{1,200}$"),  # Simon Willison's blog
    re.compile(_AFTER_SENTENCE + r"https?://\S+$"),  # a bare link after the last sentence
]
# "Read more: <another headline>" and similar cross-links in the middle of a description.
_CROSS_LINK_RE = re.compile(
    r"\s*\b(?:Read more|READ MORE|Related|RELATED|Also read|See also|Go deeper)\s*:\s.*$", re.S)
# Inline tags leave spaces inside punctuation: "<a>Jony Ive</a>." -> "Jony Ive ." and "( <em>Loki</em> )".
_TAG_SPACE_RE = re.compile(r"(?<=\w) +(?=[.,;:!?](?:\s|$))|(?<=\() +| +(?=\))")
_ELLIPSIS_TAIL_RE = re.compile(r"\s*\[(?:…|\.\.\.)\]$")
_LEADING_JUNK = [
    re.compile(r"^arXiv:\S+\s+Announce Type:\s*\S+\s+Abstract:\s*"),
    # Wire datelines: "WASHINGTON (AP) — ", "BUFFALO, N.Y. — ".
    re.compile(r"^[A-Z][A-Z.'’ -]{3,40}(?:,\s*[A-Z][A-Za-z.]{1,15}){0,2}\s*"
               r"(?:\((?:AP|AFP|Reuters|Yonhap|dpa|Kyodo|UPI|CNN|Bloomberg)\))?\s*(?:—|–|--)\s+"),
]
# A photo credit closing the description: "(Justin Ford/Getty Images)".
_PHOTO_CREDIT_RE = re.compile(
    r"\s*\((?:Photo(?:graph)?(?: by)?:?\s*)?[^()]{2,80}(?:/|\bfor\s)\s*(?:Getty Images|AP|AFP|Reuters|EPA|"
    r"Bloomberg|Shutterstock|Sipa|NurPhoto|Anadolu)[^()]*\)\s*$")
# A sentence end (with its closing quote) followed by the start of another sentence.
_SENTENCE_END_RE = re.compile(r"[.!?][\"”’']?(?=\s+[\"“‘(]?[A-Z0-9])")
_ABBREVIATIONS = frozenset(
    "mr mrs ms dr st jr sr vs inc corp co ltd gen gov sen rep lt col sgt no jan feb mar apr aug "
    "sept sep oct nov dec u.s u.k e.g i.e est approx".split())
_ALNUM_RE = re.compile(r"\w+")
MIN_SNIPPET = 25  # what's left after dropping a repeated headline must say something


def _html_to_text(text: str) -> str:
    for rx in _DROP_HTML:
        text = rx.sub(" ", text)
    text = _TAG_RE.sub(" ", _BLOCK_TAG_RE.sub(_BREAK, text))
    parts = [_TAG_SPACE_RE.sub("", _WS_RE.sub(" ", html.unescape(p))).strip() for p in text.split(_BREAK)]
    out = ""
    for part in filter(None, parts):
        if out:
            # "<p>White House says</p><p>The White House has..." reads as two sentences.
            out += (" " if out[-1] in _SENTENCE_PUNCT else ". ") + part
        else:
            out = part
    return out


def _strip_title(text: str, title: str) -> str:
    """Drop a copy of the headline at the start of the text ('' when that is all there is)."""
    t_words = [w.casefold() for w in _ALNUM_RE.findall(title)]
    words = list(_ALNUM_RE.finditer(text))
    if not t_words or not words:
        return text
    head = [m.group().casefold() for m in words[: len(t_words)]]
    if head == t_words:
        after = text[words[len(t_words) - 1].end():]
        rest = after.lstrip(" .,:;|-–—…")
        # Only a headline copy that ends there: "OpenAI partners with Cerebras to add 750MW…"
        # continues the headline, and cutting it would leave "to add 750MW…".
        ends = not rest or after[: len(after) - len(rest)].strip() or rest[0].isupper() or rest[0].isdigit()
        if ends:
            return rest if len(rest) >= MIN_SNIPPET else ""
    # A snippet that is (almost) only headline words, e.g. 'Tagesschau in 100 seconds tagesschau'.
    s_words = [m.group().casefold() for m in words]
    t_set = set(t_words)
    if len(s_words) <= len(t_words) + 2 and sum(w in t_set for w in s_words) >= 0.8 * len(s_words):
        return ""
    return text


def _cut(text: str, limit: int) -> str:
    """At most `limit` characters: a whole sentence when one ends in the second half of the window,
    otherwise the last whole word plus '…'."""
    if len(text) <= limit:
        return text
    for m in reversed(list(_SENTENCE_END_RE.finditer(text, 0, limit))):
        if m.end() < limit // 2:
            break
        word = re.search(r"([\w.]+)$", text[: m.start()])
        if m.group()[0] == "." and word and (word.group(1).lower() in _ABBREVIATIONS
                                             or len(word.group(1)) == 1):
            continue  # "Mr. Smith", "U.S. troops", "John F. Kennedy"
        return text[: m.end()]
    cut = text[: limit - 1]
    if not text[limit - 1].isspace():
        cut = cut.rsplit(" ", 1)[0]  # the window ends inside a word: drop it
    return cut.rstrip(" .,;:—–-([“\"'‘") + "…"


def clean_snippet(text: str, title: str = "", limit: int = 300) -> str:
    """A feed description as readable text of at most `limit` characters: no HTML, captions or
    publisher boilerplate, no repeat of the headline, never cut in the middle of a word."""
    text = _html_to_text(text or "")
    for rx in _LEADING_JUNK:
        text = rx.sub("", text)
    while True:
        before = text
        for rx in _TRAILING_JUNK:
            text = rx.sub("", text)
        if text == before:
            break
    if (m := _CROSS_LINK_RE.search(text)) and m.start() >= 60:
        text = text[: m.start()]
    text = _PHOTO_CREDIT_RE.sub("", _ELLIPSIS_TAIL_RE.sub("…", text)).strip()
    if title:
        text = _strip_title(text, title)
    return _cut(text, limit)


def snippet(text: str, limit: int = 300) -> str:
    return _cut(strip_html(text), limit)


# --- Titles -------------------------------------------------------------------------------------

def clean_title(title: str) -> str:
    title = strip_html(title)
    # Prefix first: "Opinion | Letitia James and the Cornell 7" would otherwise lose its headline
    # to the " | Outlet" suffix rule.
    while (stripped := _PREFIX_RE.sub("", title)) != title and stripped:
        title = stripped
    return _SUFFIX_RE.sub(_suffix, title)


# A dash also joins two clauses of one headline ("…school buses — and kids are paying the
# price", "Instinct was the buzziest AI agent around — can it survive Muse?"): those stay.
_CLAUSE_OPENERS = frozenset(
    "and but or with as so can could will would is are was were here's here how why what who "
    "when while after before plus yet now than then".split())


# Section tags written in lower case ("ICE officer shoots man – video", "… – as it happened").
_SECTION_TAGS = frozenset({"video", "videos", "podcast", "photos", "pictures", "in pictures",
                           "as it happened", "live", "explainer", "analysis", "quiz", "opinion"})


def _suffix(m: re.Match) -> str:
    """'' for an outlet or section name after a dash, else the text unchanged."""
    tail = m.group().lstrip(" -|–—")
    if tail.strip().casefold() in _SECTION_TAGS:
        return ""
    first = tail.split(maxsplit=1)[0] if tail.split() else ""
    clause = (not first[:1].isupper() and not first[:1].isdigit()) or first.lower() in _CLAUSE_OPENERS
    return m.group() if clause or tail.rstrip().endswith(("?", "!", ".")) else ""


# Shorteners and bare links in social posts. The post's real link is kept separately, and the
# displayed URL text ("www.theverge.com/news/1003...") is just a truncated copy of it.
_POST_LINK_RE = re.compile(r"(?:https?://)?(?:www\.)?(?:[a-z0-9-]+\.)+[a-z]{2,}/\S*", re.I)
_POST_TAG_RE = re.compile(r"(?<!\w)#(?:ad|sponsored)\b", re.I)
# Pointers to the removed link ("Read it here ➡️ buff.ly/x").
_POST_TAIL_RE = re.compile(r"(?:[\s:→-]|🔗|🔽|👇|⬇\ufe0f?|➡\ufe0f?)+$")


def clean_post_title(text: str) -> str:
    """A social post as a headline: links and '#ad' tags removed, lines joined. A line that was
    only a store name and its link ('Best Buy buff.ly/x') is dropped with the link."""
    lines = []
    for line in (text or "").splitlines():
        had_link = bool(_POST_LINK_RE.search(line))
        line = _WS_RE.sub(" ", _POST_TAG_RE.sub(" ", _POST_LINK_RE.sub(" ", line))).strip()
        line = _POST_TAIL_RE.sub("", line)
        if not line or (had_link and lines and len(line.split()) <= 3):
            continue
        lines.append(line)
    return " ".join(lines)


# --- Tokens for clustering ----------------------------------------------------------------------
_NUMBER_WORDS = {"one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                 "seven": "7", "eight": "8", "nine": "9", "ten": "10"}
# Country adjectives and short forms -> one token, so "Chinese agent" meets "China's agent".
_DEMONYMS = {
    "american": "us", "u.s": "us", "usa": "us", "british": "uk", "britain": "uk", "u.k": "uk",
    "chinese": "china", "japanese": "japan", "korean": "korea", "russian": "russia",
    "ukrainian": "ukraine", "german": "germany", "french": "france", "italian": "italy",
    "spanish": "spain", "brazilian": "brazil", "iranian": "iran", "israeli": "israel",
    "ethiopian": "ethiopia", "taiwanese": "taiwan", "indian": "india", "mexican": "mexico",
    "canadian": "canada", "australian": "australia", "european": "europe", "turkish": "turkey",
    "dutch": "netherlands", "swedish": "sweden", "norwegian": "norway", "danish": "denmark",
    "finnish": "finland", "latvian": "latvia", "lithuanian": "lithuania", "estonian": "estonia",
    "venezuelan": "venezuela", "pakistani": "pakistan", "afghan": "afghanistan", "syrian": "syria",
    "lebanese": "lebanon", "palestinian": "palestine", "egyptian": "egypt",
}
_PHRASES = [(re.compile(r"\bcoast guard\b"), "coastguard"),
            (re.compile(r"\bunited states\b"), "us"),
            (re.compile(r"\bunited kingdom\b"), "uk"),
            (re.compile(r"\bn(?:orth|\.) ?korean?\b"), "nkorea"),
            (re.compile(r"\bs(?:outh|\.) ?korean?\b"), "korea")]
_MONTH = (r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|"
          r"sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)")
# Dates and years mark recurring features ("Headlines for October 5, 2026", "Nobel Prize 2026:
# When will the awards be announced"), not stories: two different stories share them.
_THOUSANDS_RE = re.compile(r"(?<=\d),(?=\d{3}(?!\d))")
_DATE_RE = re.compile(rf"\b{_MONTH}\.? \d{{1,2}}(?:st|nd|rd|th)?\b(?:,? \d{{4}}\b)?"
                      rf"|\b\d{{1,2}}(?:st|nd|rd|th)? {_MONTH}\b(?:,? \d{{4}}\b)?|\b{_MONTH} \d{{4}}\b"
                      r"|\b(?:19|20)\d\d\b")


def _stem(w: str) -> str:
    """Light suffix stripping for 5+ letter words: 'bombers'/'bomber', 'accused'/'accuses'."""
    if len(w) < 5 or not w.isalpha():
        return w
    if w.endswith("ies"):
        return w[:-3] + "y"
    if w.endswith("ing") and len(w) >= 7 or w.endswith("ed") and len(w) >= 6:
        w = w[:-3] if w.endswith("ing") else w[:-2]
        if w[-1] == w[-2] and w[-1] not in "aeiouylsz":
            w = w[:-1]  # "planned" -> "plan"
    elif w.endswith("es") and w[-3] in "sxz" or w.endswith(("ches", "shes")):
        return w[:-2]
    elif w.endswith("s") and not w.endswith(("ss", "us", "is")):
        w = w[:-1]
    # "release", "released" and "releases" all end up as "releas".
    return w[:-1] if w.endswith("e") and len(w) >= 5 else w


def _token(w: str) -> str | None:
    if w.endswith("'s"):
        w = w[:-2]
    w = _NUMBER_WORDS.get(w, w)
    w = _DEMONYMS.get(w, w)
    if w in _STOPWORDS or (len(w) < 2 and not w.isdigit()):
        return None
    return _stem(w)


def _fold(text: str) -> str:
    """'Sánchez' and 'Sanchez' are one word (and 'Flávio' isn't 'fl' + 'vio')."""
    text = text.replace("œ", "oe").replace("æ", "ae").replace("ß", "ss")  # no decomposition
    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))


def title_terms(title: str) -> dict[str, str]:
    """The headline's distinctive words, normalized so rewrites of one headline match
    ("U.S. bombers" / "American bomber", "six" / "6"), each with the form it was written in
    (clustering weighs a word by how rare that written form is)."""
    text = _fold(clean_title(title).lower().replace("’", "'"))
    text = _THOUSANDS_RE.sub("", _DATE_RE.sub(" ", text))  # "1,000km" is one word
    for rx, repl in _PHRASES:
        text = rx.sub(repl, text)
    terms: dict[str, str] = {}
    prev, prev_token = None, None
    for w in _WORD_RE.findall(text):
        w = w.strip(".'")
        if len(w) == 1 and w.isdigit() and prev_token and prev.isalpha():
            # A numbered name is one word: "Steam Deck 2", "Forza Horizon 6". A lone digit would
            # link any two headlines that happen to share it.
            if terms.get(prev_token) == prev:
                del terms[prev_token]
            fused = prev + w
            terms.setdefault(fused, fused)
            prev, prev_token = fused, None
            continue
        t = _token(w)
        if t:
            terms.setdefault(t, w)
        prev, prev_token = w, t
    return terms


def title_tokens(title: str) -> frozenset[str]:
    return frozenset(title_terms(title))


def jaccard(a: frozenset[str], b: frozenset[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def contains(text: str, term: str) -> bool:
    return term.lower() in text.lower()
