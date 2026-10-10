// Decides, per user, which breaking stories to push and when their morning brief is due.
// Pure functions (no I/O) so they're easy to test; index.js does the database work.
//
// Alert tiers (same as the personal pipeline in briefing/alerts.py):
//   1 official      a first-party lab feed (pfAlert="all") posted something new
//   2 trusted       a proven scoop source posted a headline matching the user's watchlist
//   3 corroborated  a headline matching the watchlist is covered by 2+ outlets
// Deals never alert, each story alerts a user at most once, and there's a per-user daily cap.

const KEEP_ALERT_KEYS = 200;
const BRIEF_GRACE_HOURS = 3;

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Compiled once per term: each ingest checks every story against every user's muted words.
const wordRes = new Map();

function wordRegex(t, plural) {
  const key = `${plural ? "p" : "w"}:${t}`;
  let re = wordRes.get(key);
  if (!re) {
    if (wordRes.size >= 5000) wordRes.clear();
    const body = t.split(/\s+/).filter(Boolean).map(escapeRe).join("\\s+"); // "call  of duty" too
    const suffix = plural ? "(?:s|es)?" : "";
    re = new RegExp(`(^|[^\\p{L}\\p{N}])${body}${suffix}($|[^\\p{L}\\p{N}])`, "u");
    wordRes.set(key, re);
  }
  return re;
}

/** `plural` also accepts a trailing "s"/"es", so muting "game" hides "games" (as on the phone). */
function termMatches(lowered, term, wholeWord, plural = false) {
  const t = term.toLowerCase();
  if (!wholeWord) return lowered.includes(t);
  return wordRegex(t, plural).test(lowered);
}

/** Default rules use substrings on purpose ("introduc" = introduces/introducing); personal
 *  keywords match whole words, so "AI" doesn't fire on "said". */
export function ruleMatches(rule, text) {
  const lowered = text.toLowerCase();
  const groups = rule.match ?? [];
  return groups.length > 0 &&
    groups.every((g) => g.some((t) => termMatches(lowered, t, rule.wholeWord === true)));
}

/** The user's watchlist: the shared default rules (if enabled) plus their own keywords. */
export function userRules(settings, defaultWatchlist) {
  const rules = settings.alerts.defaultWatchlist ? [...defaultWatchlist] : [];
  for (const kw of settings.alerts.keywords) rules.push({ name: kw, match: [[kw]], wholeWord: true });
  return rules;
}

/** Local calendar date and hour for a time zone. */
export function localParts(now, timeZone) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23",
    }).formatToParts(now).map((p) => [p.type, p.value]),
  );
  return { date: `${parts.year}-${parts.month}-${parts.day}`, hour: Number(parts.hour) };
}

function wanted(settings, item) {
  if (!settings.categories.includes(item.category)) return false;
  const keys = item.sourceKeys ?? item.sources?.map((s) => s.key) ?? [];
  if (keys.length && keys.every((k) => settings.disabledSources.includes(k))) return false;
  const text = (item.titles ?? [item.title]).join(" ").toLowerCase();
  // Whole words, like the phone: muting "ICE" mustn't drop alerts about police or prices.
  return !settings.mutedWords.some((w) => termMatches(text, w, true, true));
}

/** Which candidates to push to this user, and their updated alert state. */
export function alertsForUser(settings, userState, candidates, defaultWatchlist, now) {
  const { date } = localParts(now, settings.brief.timezone);
  let count = userState.alertDay === date ? userState.alertCount : 0;
  const sentKeys = [...userState.alertKeys];
  const rules = userRules(settings, defaultWatchlist);
  const out = [];

  const ranked = [];
  for (const c of candidates) {
    if (c.label === "DEAL" || sentKeys.includes(c.id) || !wanted(settings, c)) continue;
    const text = c.titles.join(" ");
    const rule = rules.find((r) => ruleMatches(r, text));
    let tier = 0;
    if (c.alertAllNew && settings.alerts.official) tier = 1;
    else if (rule && c.corroboration >= 2 && settings.alerts.corroborated) tier = 3;
    else if (rule && c.trustedNew && settings.alerts.trusted) tier = 2;
    if (tier) ranked.push({ c, tier, rule });
  }
  ranked.sort((x, y) => x.tier - y.tier || y.c.corroboration - x.c.corroboration);

  for (const { c, tier, rule } of ranked) {
    if (count >= settings.alerts.maxPerDay) break;
    out.push({
      kind: "alert",
      tier,
      storyId: c.id,
      title: tier === 1 ? `${c.outlet ?? c.category} [${c.label}]` : `${rule.name} [${c.label}]`,
      body: c.title,
      url: c.url,
      threadId: c.category,
    });
    count += 1;
    sentKeys.push(c.id);
  }
  return {
    pushes: out,
    state: { alertDay: date, alertCount: count, alertKeys: sentKeys.slice(-KEEP_ALERT_KEYS) },
  };
}

/** Stories from the last 24 h this user would see, best first. */
export function personalStories(settings, feed, now) {
  const since = now.getTime() - 24 * 3600 * 1000;
  return feed.stories
    .filter((s) => Date.parse(s.published) >= since && s.label !== "DEAL" && wanted(settings, s))
    .sort((a, b) => b.score - a.score);
}

/** The "your brief is ready" push: sent by the first ingest in the BRIEF_GRACE_HOURS from the user's
 *  brief hour, once per local day. A window rather than the exact hour, so one late or failed
 *  ingest run doesn't skip the day's push. */
export function briefPush(settings, userState, feed, now) {
  if (!settings.brief.notify || !feed) return null;
  const { date, hour } = localParts(now, settings.brief.timezone);
  const late = hour - settings.brief.hour;
  if (late < 0 || late >= BRIEF_GRACE_HOURS || userState.briefDay === date) return null;
  const stories = personalStories(settings, feed, now);
  if (!stories.length) return null;
  return {
    push: {
      kind: "brief",
      title: "Your brief is ready",
      body: `${stories.length} ${stories.length === 1 ? "story" : "stories"} today. Top: ${stories[0].title}`,
      threadId: "brief",
    },
    briefDay: date,
  };
}
