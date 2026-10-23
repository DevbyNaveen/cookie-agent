// The places Cookie can reach — the team's context, its mail address, Slack,
// the web, each connected app — and how much Cookie used each in the last 7
// days. Read from the team's setup and its runs; nothing invented.

import type { CookieOverview, CookiePaths } from "@/lib/api";

export type PlaceKind = "context" | "email" | "slack" | "web" | "app";

export type Place = {
  id: string;
  kind: PlaceKind;
  label: string;
  /** Logo slug, for an app. */
  provider?: string;
  /** False for an app whose sync is failing — still connected, shown quieter. */
  ok: boolean;
  /** Not connected yet: offered, faintly, with a way to connect it. */
  ghost?: boolean;
};

const NAMES: Record<string, string> = {
  gmail: "Gmail",
  outlook: "Outlook",
  googledrive: "Google Drive",
  google_drive: "Google Drive",
  "google-drive": "Google Drive",
  googlecalendar: "Google Calendar",
  googledocs: "Google Docs",
  notion: "Notion",
  linear: "Linear",
  jira: "Jira",
  asana: "Asana",
  clickup: "ClickUp",
  github: "GitHub",
  gitlab: "GitLab",
  slack: "Slack",
  hubspot: "HubSpot",
  salesforce: "Salesforce",
  confluence: "Confluence",
  dropbox: "Dropbox",
  intercom: "Intercom",
  zendesk: "Zendesk",
  attio: "Attio",
};
export const appName = (provider: string) =>
  NAMES[provider] ?? provider.replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());

/** The places, in a fixed order: the team's own knowledge first, the outside world last. */
export function placesOf(o: CookieOverview): Place[] {
  const out: Place[] = [{ id: "context", kind: "context", label: "Your context", ok: true }];
  for (const a of [...(o.apps ?? [])].sort((x, y) => x.key.localeCompare(y.key))) {
    out.push({ id: `app:${a.key}`, kind: "app", label: a.provider === "slack" ? "Slack · synced" : appName(a.provider), provider: a.provider, ok: a.ok });
  }
  if (o.address) out.push({ id: "email", kind: "email", label: "Email", ok: true });
  if (o.slack?.workspace) out.push({ id: "slack", kind: "slack", label: "Slack", ok: true });
  out.push({ id: "web", kind: "web", label: "Web", ok: true });
  return out;
}

/** The apps most worth connecting, in order. */
const SUGGEST = ["gmail", "googledrive", "notion", "linear", "hubspot"];
const norm = (v: string) => v.toLowerCase().replace(/[^a-z0-9]/g, "");

/**
 * What Cookie could be wired to but is not: at most three, Slack first when
 * the Cookie Slack app is available and not added. Apps are offered only when
 * the team's connections are known — never "connect Gmail" to a team whose
 * Gmail is connected.
 */
export function ghostsOf(o: CookieOverview): Place[] {
  const out: Place[] = [];
  if (o.slack?.available && !o.slack.workspace) out.push({ id: "ghost:slack", kind: "slack", label: "Slack", ok: true, ghost: true });
  if (o.apps) {
    const have = new Set(o.apps.flatMap((a) => [norm(a.provider), norm(a.key)]));
    for (const p of SUGGEST) {
      if (out.length >= 3) break;
      if (!have.has(norm(p))) out.push({ id: `ghost:${p}`, kind: "app", label: appName(p), provider: p, ok: true, ghost: true });
    }
  }
  return out.slice(0, 3);
}

/** Week use per place: from the server's tally, else counted from the runs at hand. */
export function wearOf(o: CookieOverview, places: Place[]): Map<string, number> {
  const paths: CookiePaths =
    o.paths ??
    (() => {
      const since = Date.now() - 7 * 864e5;
      const p: CookiePaths = { context: 0, saves: 0, web: 0, email: 0, slack: 0, apps: {} };
      for (const r of o.runs) {
        if (Date.parse(r.started_at) < since) continue;
        if (r.trigger === "email") p.email++;
        if (r.trigger === "slack") p.slack++;
        for (const s of r.steps ?? []) {
          if (s.tool === "recall") p.context++;
          if (s.tool === "remember" && s.ok) p.saves++;
          if (s.tool === "web_search" || s.tool === "read_url" || s.tool === "read_site") p.web++;
          for (const a of s.apps ?? []) p.apps[a] = (p.apps[a] ?? 0) + 1;
        }
      }
      return p;
    })();
  const m = new Map<string, number>();
  for (const pl of places) {
    if (pl.kind === "context") m.set(pl.id, paths.context + paths.saves);
    else if (pl.kind === "app") m.set(pl.id, paths.apps[pl.id.slice(4)] ?? 0);
    else m.set(pl.id, paths[pl.kind]);
  }
  return m;
}

/** "22 lookups this week" — said for the place. */
export function wearLine(place: Place, n: number): string {
  if (n === 0) return `${place.label}: not used this week`;
  const k = (one: string, many: string) => `${place.label}: ${n} ${n === 1 ? one : many} this week`;
  switch (place.kind) {
    case "context":
      return k("lookup or save", "lookups and saves");
    case "web":
      return k("trip to the web", "trips to the web");
    case "email":
      return k("job by email", "jobs by email");
    case "slack":
      return k("job from Slack", "jobs from Slack");
    default:
      return k("lookup drew on it", "lookups drew on it");
  }
}
