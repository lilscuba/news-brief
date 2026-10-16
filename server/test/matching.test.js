import assert from "node:assert/strict";
import { test } from "node:test";

import { alertsForUser, briefPush, localParts, personalStories, ruleMatches } from "../src/matching.js";
import { DEFAULT_SETTINGS, mergeSettings } from "../src/settings.js";

const NOW = new Date("2026-10-01T11:30:00Z"); // 07:30 in New York
const WATCH = [{ name: "Nintendo Direct", match: [["nintendo direct"]] },
  { name: "Gemini launch", match: [["gemini"], ["launch", "release"]] }];
const fresh = () => ({ alertDay: null, alertCount: 0, alertKeys: [], briefDay: null });
const settings = (patch = {}) => mergeSettings(structuredClone(DEFAULT_SETTINGS), patch);

function cand(over = {}) {
  return {
    id: over.id ?? "s1", title: "Nintendo Direct announced", url: "https://x/1", category: "Gaming",
    label: "REPORTED", corroboration: 1, official: false, trustedNew: false, alertAllNew: false,
    sourceKeys: ["vgc"], titles: [over.title ?? "Nintendo Direct announced"], ...over,
  };
}

test("rule matching needs every group", () => {
  assert.equal(ruleMatches(WATCH[1], "Google launches Gemini 5"), true);
  assert.equal(ruleMatches(WATCH[1], "Gemini tips"), false);
});

test("personal keywords match whole words only", () => {
  const ai = { name: "AI", match: [["AI"]], wholeWord: true };
  assert.equal(ruleMatches(ai, "Google's AI model launches"), true);
  assert.equal(ruleMatches(ai, "AI: what's next"), true);
  assert.equal(ruleMatches(ai, "Studio said it will try again"), false);
  const multi = { name: "Nintendo Direct", match: [["nintendo direct"]], wholeWord: true };
  assert.equal(ruleMatches(multi, "New Nintendo Direct dated"), true);
});

test("local time follows the user's zone", () => {
  assert.deepEqual(localParts(NOW, "America/New_York"), { date: "2026-10-01", hour: 7 });
  assert.deepEqual(localParts(NOW, "Asia/Tokyo"), { date: "2026-10-01", hour: 20 });
});

test("tiers: single untrusted source waits, trusted or corroborated alerts, official always", () => {
  const s = settings();
  assert.equal(alertsForUser(s, fresh(), [cand()], WATCH, NOW).pushes.length, 0);
  assert.equal(alertsForUser(s, fresh(), [cand({ trustedNew: true })], WATCH, NOW).pushes[0].tier, 2);
  assert.equal(alertsForUser(s, fresh(), [cand({ corroboration: 2 })], WATCH, NOW).pushes[0].tier, 3);
  const official = cand({ title: "Introducing a model", category: "AI", alertAllNew: true, outlet: "OpenAI News", label: "CONFIRMED" });
  const [p] = alertsForUser(s, fresh(), [official], WATCH, NOW).pushes;
  assert.equal(p.tier, 1);
  assert.equal(p.title, "OpenAI News [CONFIRMED]");
});

test("user preferences filter alerts", () => {
  const c = cand({ trustedNew: true });
  assert.equal(alertsForUser(settings({ categories: ["AI"] }), fresh(), [c], WATCH, NOW).pushes.length, 0);
  assert.equal(alertsForUser(settings({ disabledSources: ["vgc"] }), fresh(), [c], WATCH, NOW).pushes.length, 0);
  assert.equal(alertsForUser(settings({ mutedWords: ["nintendo"] }), fresh(), [c], WATCH, NOW).pushes.length, 0);
  assert.equal(alertsForUser(settings({ alerts: { trusted: false } }), fresh(), [c], WATCH, NOW).pushes.length, 0);
  assert.equal(alertsForUser(settings({ alerts: { defaultWatchlist: false } }), fresh(), [c], WATCH, NOW).pushes.length, 0);
  // ...but a personal keyword brings it back
  const kw = settings({ alerts: { defaultWatchlist: false, keywords: ["Direct"] } });
  assert.equal(alertsForUser(kw, fresh(), [c], WATCH, NOW).pushes[0].title, "Direct [REPORTED]");
  assert.equal(alertsForUser(settings(), fresh(), [cand({ trustedNew: true, label: "DEAL" })], WATCH, NOW).pushes.length, 0);
});

test("muted words match whole words (and plurals), like the phone", () => {
  const pushed = (muted, title) =>
    alertsForUser(settings({ mutedWords: muted }), fresh(), [cand({ trustedNew: true, title })], WATCH, NOW).pushes.length;
  // Substring matching used to drop these: "ice" in police/price, "ai" in said, "war" in software.
  assert.equal(pushed(["ice"], "Nintendo Direct: police say price of service rose"), 1);
  assert.equal(pushed(["AI"], "Nintendo Direct date, insider said again"), 1);
  assert.equal(pushed(["war"], "Nintendo Direct software update"), 1);
  // ...while real mentions are still muted, whatever the case, plural or possessive.
  assert.equal(pushed(["ice"], "Nintendo Direct: ICE raids"), 0);
  assert.equal(pushed(["game"], "Nintendo Direct shows 12 games"), 0);
  assert.equal(pushed(["match"], "Nintendo Direct matches"), 0);
  assert.equal(pushed(["nintendo"], "Nintendo's Direct is tomorrow, Nintendo Direct"), 0);
  assert.equal(pushed(["call of duty"], "Nintendo Direct: Call of Duty coming to Switch 2"), 0);
  assert.equal(pushed(["call of duty"], "Nintendo Direct: Call of  Duty, twice spaced"), 0);
  assert.equal(pushed(["call of duty"], "Nintendo Direct: a call of dutyfree shopping"), 1);
  assert.equal(pushed(["c++"], "Nintendo Direct, written in C++"), 0);
  assert.equal(pushed(["c++"], "Nintendo Direct, c and more"), 1);
  // Other headlines in the cluster count too.
  const c = cand({ trustedNew: true, titles: ["Nintendo Direct announced", "Ice Age remaster revealed"] });
  assert.equal(alertsForUser(settings({ mutedWords: ["ice age"] }), fresh(), [c], WATCH, NOW).pushes.length, 0);
  // The brief push's story count uses the same rule.
  const feed = { stories: [{ title: "Police seize record haul", category: "Gaming", label: "REPORTED", score: 1,
    published: "2026-10-01T09:00:00Z", sources: [{ key: "vgc" }] }] };
  assert.equal(personalStories(settings({ mutedWords: ["ice"] }), feed, NOW).length, 1);
  assert.equal(personalStories(settings({ mutedWords: ["police"] }), feed, NOW).length, 0);
});

test("daily cap and one push per story", () => {
  const s = settings({ alerts: { maxPerDay: 2 } });
  const many = [1, 2, 3].map((i) => cand({ id: `s${i}`, corroboration: 3 }));
  const r = alertsForUser(s, fresh(), many, WATCH, NOW);
  assert.equal(r.pushes.length, 2);
  assert.equal(alertsForUser(s, r.state, many, WATCH, NOW).pushes.length, 0); // cap reached today
  const tomorrow = new Date(NOW.getTime() + 24 * 3600e3);
  const next = alertsForUser(s, r.state, many, WATCH, tomorrow);
  assert.deepEqual(next.pushes.map((p) => p.storyId), ["s3"]); // new day, but s1/s2 already sent
});

test("brief push goes out once, at the user's hour", () => {
  const feed = { stories: [
    { title: "Big gaming news", category: "Gaming", label: "REPORTED", score: 9, published: "2026-10-01T09:00:00Z", sources: [{ key: "vgc" }] },
    { title: "Old news", category: "Gaming", label: "REPORTED", score: 20, published: "2026-09-29T09:00:00Z", sources: [{ key: "vgc" }] },
  ] };
  const s = settings({ brief: { hour: 7, timezone: "America/New_York" } });
  const b = briefPush(s, fresh(), feed, NOW);
  assert.equal(b.push.body, "1 story today. Top: Big gaming news");
  assert.equal(briefPush(s, { ...fresh(), briefDay: b.briefDay }, feed, NOW), null);
  assert.equal(briefPush(settings({ brief: { hour: 8 } }), fresh(), feed, NOW), null);
  assert.equal(briefPush(settings({ brief: { notify: false } }), fresh(), feed, NOW), null);
});

test("a late ingest still sends the brief push, within 3 hours of the brief hour", () => {
  const feed = { stories: [
    { title: "Big gaming news", category: "Gaming", label: "REPORTED", score: 9, published: "2026-10-01T09:00:00Z", sources: [{ key: "vgc" }] },
  ] };
  const s = settings({ brief: { hour: 7, timezone: "America/New_York" } }); // EDT = UTC-4
  const local = (hhmm) => new Date(`2026-10-01T${hhmm}:00-04:00`);
  const late = briefPush(s, fresh(), feed, local("08:40"));
  assert.equal(late.briefDay, "2026-10-01");
  assert.equal(briefPush(s, { ...fresh(), briefDay: late.briefDay }, feed, local("09:10")), null); // once a day
  assert.ok(briefPush(s, fresh(), feed, local("09:55")));
  assert.equal(briefPush(s, fresh(), feed, local("10:05")), null); // more than 3 h late: skip the day
  assert.equal(briefPush(s, fresh(), feed, local("11:05")), null);
  assert.equal(briefPush(s, fresh(), feed, local("06:50")), null); // too early
  // A brief hour late in the evening doesn't spill into the next day.
  const night = settings({ brief: { hour: 23, timezone: "America/New_York" } });
  assert.ok(briefPush(night, fresh(), feed, local("23:30")));
  assert.equal(briefPush(night, fresh(), feed, new Date("2026-10-02T00:30:00-04:00")), null);
});
