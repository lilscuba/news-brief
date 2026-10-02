// Per-user settings: the same JSON shape the iOS app edits (UserSettings.swift).
// Everything is validated and clamped here, so the database only ever holds sane values.

// US, World, Europe, Japan and Korea are opt-in: new accounts start with DEFAULT_SETTINGS.categories.
export const CATEGORIES = ["AI", "Tech", "Gaming", "US", "World", "Europe", "Japan", "Korea", "Deals"];

export const DEFAULT_SETTINGS = Object.freeze({
  version: 1,
  categories: ["AI", "Tech", "Gaming", "Deals"],
  disabledSources: [],
  mutedWords: [],
  boosts: [],
  alerts: {
    official: true,      // tier 1: first-party lab feeds (OpenAI, DeepMind, Anthropic)
    trusted: true,       // tier 2: a proven scoop source matches your watchlist
    corroborated: true,  // tier 3: 2+ outlets match your watchlist
    defaultWatchlist: true,
    keywords: [],
    maxPerDay: 5,
  },
  brief: { notify: true, hour: 7, timezone: "America/New_York" },
});

export class SettingsError extends Error {}

const MAX_LIST = 100;
const MAX_TERM = 60;

function stringList(value, field, { allowed } = {}) {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) throw new SettingsError(`${field} must be a list`);
  const out = [];
  for (const v of value) {
    if (typeof v !== "string") throw new SettingsError(`${field} must contain strings`);
    const s = v.trim();
    if (!s) continue;
    if (s.length > MAX_TERM) throw new SettingsError(`${field} entries are limited to ${MAX_TERM} characters`);
    if (allowed && !allowed.includes(s)) throw new SettingsError(`${field}: unknown value ${s}`);
    if (!out.includes(s)) out.push(s);
  }
  if (out.length > MAX_LIST) throw new SettingsError(`${field} is limited to ${MAX_LIST} entries`);
  return out;
}

function bool(value, field) {
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") throw new SettingsError(`${field} must be true or false`);
  return value;
}

function int(value, field, min, max) {
  if (value === undefined) return undefined;
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new SettingsError(`${field} must be a whole number from ${min} to ${max}`);
  }
  return value;
}

export function isValidTimeZone(tz) {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

const defined = (obj) => Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined));

/** Merge a (partial) settings object from the app over `base`, validating every field. */
export function mergeSettings(base, input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new SettingsError("settings must be an object");
  }
  const a = input.alerts ?? {};
  const b = input.brief ?? {};
  if (b.timezone !== undefined && (typeof b.timezone !== "string" || !isValidTimeZone(b.timezone))) {
    throw new SettingsError("brief.timezone must be an IANA time zone like America/New_York");
  }
  return {
    ...base,
    ...defined({
      categories: stringList(input.categories, "categories", { allowed: CATEGORIES }),
      disabledSources: stringList(input.disabledSources, "disabledSources"),
      mutedWords: stringList(input.mutedWords, "mutedWords"),
      boosts: stringList(input.boosts, "boosts"),
    }),
    version: 1,
    alerts: {
      ...base.alerts,
      ...defined({
        official: bool(a.official, "alerts.official"),
        trusted: bool(a.trusted, "alerts.trusted"),
        corroborated: bool(a.corroborated, "alerts.corroborated"),
        defaultWatchlist: bool(a.defaultWatchlist, "alerts.defaultWatchlist"),
        keywords: stringList(a.keywords, "alerts.keywords"),
        maxPerDay: int(a.maxPerDay, "alerts.maxPerDay", 0, 20),
      }),
    },
    brief: {
      ...base.brief,
      ...defined({
        notify: bool(b.notify, "brief.notify"),
        hour: int(b.hour, "brief.hour", 0, 23),
        timezone: b.timezone,
      }),
    },
  };
}

export function parseStoredSettings(json) {
  try {
    return mergeSettings(structuredClone(DEFAULT_SETTINGS), JSON.parse(json));
  } catch {
    return structuredClone(DEFAULT_SETTINGS);
  }
}
