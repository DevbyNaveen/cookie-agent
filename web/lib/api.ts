// Cookie's slice of the Console's typed client (apps/console/lib/api.ts in
// Enkeon): the error type and the Cookie types are copied verbatim; `api`
// keeps only the two calls the page makes when it opens inside a Console.

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

export interface MeUser {
  id: string;
  handle: string;
  email: string;
  display_name?: string | null;
  is_staff: boolean;
  godseye?: boolean;
}

export interface Org {
  id: string;
  slug: string;
  name: string;
  /** Org billing owner — entitlements/limits for the org resolve from this user. */
  created_by?: string;
  role?: string;
  member_count?: number;
}

export interface Project {
  id: string;
  org_id: string;
  slug: string;
  name: string;
  workspace_name: string;
  status: string;
  region?: string;
  /** Opt-in: mine quorum'd, de-identified per-user patterns into the shared
   *  brain (verify-before-merge). OFF by default. */
  promotion_enabled?: boolean;
  /** The agent surface switch (0113). OFF = root alone, no hires, the whole
   *  agent surface hidden. Set through the provisioner, service-token only. */
  agents_enabled?: boolean;
  description?: string | null;
  use_case?: string | null;
  onboarding_type?: string | null;
  integrations?: string | null;
}

async function call<T>(url: string): Promise<T> {
  const res = await fetch(url, { credentials: "include", cache: "no-store" });
  const text = await res.text();
  const parsed = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const err = (parsed as { error?: { code?: string; message?: string } } | null)?.error ?? {};
    throw new ApiError(res.status, err.code ?? "error", err.message ?? `Request failed (HTTP ${res.status})`);
  }
  return parsed as T;
}

export const api = {
  me: (_jwt: string) => call<{ user: MeUser; orgs: Org[] }>(`/api/gw/identity/me`),
  listProjects: (orgId: string, _jwt: string) =>
    call<Project[]>(`/api/gw/provisioner/api/v1/projects?org=${encodeURIComponent(orgId)}`),
};

/** One tool call in a Cookie run, as the gateway logged it (host only for pages). */
export interface CookieStep {
  /** When the call finished, ms from the run's start. */
  at_ms: number;
  /** How long the call took (absent on runs recorded before 2026-10-19). */
  ms?: number;
  /** Characters the call handed back to Cookie. */
  size?: number;
  tool: "recall" | "web_search" | "read_url" | "read_site" | "remember" | "ask_first" | string;
  what: string;
  ok: boolean;
  /** For a lookup: the connected apps its hits came from (their sync folder, e.g. `gmail`). */
  apps?: string[];
  /** A few clipped lines of what came back, for the step's card. */
  peek?: CookiePeek;
  /** A page read: the step whose result held its URL (absent: it was in the job). */
  via?: number;
  /** On the answer check: supported · unsupported · unavailable (the check could not run). */
  verification?: "supported" | "unsupported" | "unavailable" | string;
  /** Page only: read for an earlier message of the same conversation, so it is
   *  already on the board when this one starts. */
  prior?: boolean;
  /** A call a helper made: the helper (`researcher`)… */
  agent?: string;
  /** …and which of its calls (a `helper` step's id). On a `helper` step, its own id. */
  helper?: string;
  /** An action in a connected app (`app_call`): what it was and what it came to. */
  action?: CookieAction;
}

/** One action Cookie took, or asked to take, in a connected app. */
export interface CookieAction {
  app: string;
  /** The app's action name, e.g. `HUBSPOT_UPDATE_DEAL`. */
  name: string;
  /** read | write | outbound | destroy | share */
  effect: string;
  /** done | waiting (for the member's yes) | refused (the app's setting is off) | failed | unknown */
  state: "done" | "waiting" | "refused" | "failed" | "unknown" | string;
  /** The approval it waits on. */
  approval?: string;
  /** Why it ran or waits, at the member's permission level ("the job asked for this change"). */
  why?: string;
  /** Its entry in the change journal, when the journal is on (`cj_…`). */
  journal?: string;
  /** What undoing it does once it ran: write the old values back, or delete what it created. */
  undo?: "restore" | "delete";
  /** The fields it changes: what they said before (null = not known) and after. */
  diff?: { field: string; before: unknown; after: unknown }[];
}

/** How much Cookie may do in a member's apps before it asks: every change waits ·
 *  Cookie judges (sends outside and deletes still wait) · everything runs. */
export type CookiePermission = "ask" | "smart" | "full";

/** A lesson Cookie learned from a finished job, kept while it helps. */
export interface CookieLesson {
  id: string;
  text: string;
  /** The kind of job it is for. */
  cue: string;
  learned_from: "from_clean" | "from_correction" | "from_failure" | string;
  /** Learned from a job that read outside content (the web, mail from outside): never shared into the brain. */
  outside?: boolean;
  /** `lesson`, or `procedure` (proven lessons written up as one method). */
  kind?: "lesson" | "procedure" | string;
  version?: number;
  /** active · quiet (unused 14 days, not offered) · archived */
  state: "active" | "quiet" | "archived" | string;
  /** Jobs it rode in that ended clean, and that did not. */
  wins: number;
  losses: number;
  /** Jobs it matched but was held back from, to keep testing Cookie without it. */
  withheld: number;
  last_used_at: string | null;
  /** Shared with the team's brain once it proved itself. */
  shared: boolean;
  created_at: string;
}

/** One signal a notice fired on. */
export interface CookieCue {
  id: string;
  /** decision · plan · requirement · fact · … · conflict · past_due · plan_cue */
  kind: string;
  why: string;
  salience: number;
  /** Seconds since 1970. */
  at: number;
  /** From mail or a synced app, not from someone on the team. */
  outside: boolean;
  hard: boolean;
}

/** Something Cookie noticed in the team's brain. Watch-only: recorded for a label. */
export interface CookieNotice {
  id: string;
  subject: string;
  branch: string;
  title: string;
  /** A hard cue (a decision contradicted, a plan past its day) rather than a build-up. */
  hard: boolean;
  utility: number;
  level: number;
  cues: CookieCue[];
  mode: "shadow" | string;
  /** The sentence it opens with: why this, now. */
  why_now?: string;
  /** Why it went out when it did (held for a quiet moment in the team's work). */
  because?: string | null;
  released_at?: string | null;
  label: "useful" | "not_useful" | "wrong" | null;
  labelled_by: string | null;
  labelled_at: string | null;
  created_at: string;
}

/** A change waiting for (or decided by) the member: the gateway's connector approval. */
export interface CookieApproval {
  id: string;
  /** The app. */
  slug: string;
  /** The app's action name. */
  tool: string;
  class: string;
  /** pending | approved | denied | expired | failed */
  status: string;
  /** What it would send, one `key: value` per line. */
  detail: string | null;
  /** What the app answered once it ran. */
  result: string | null;
  created_at: string;
  expires_at: string;
  /** In the outbox: goes through by itself at this time unless undone. */
  run_after?: string | null;
}

/** When Cookie's notices reach a member, and whether at all. */
export interface CookiePrefs {
  notices: boolean;
  /** Offset from UTC in minutes (local = UTC + offset). */
  tz_offset_min: number;
  /** Time zone by name (`Europe/Riga`), so local hours hold across clock changes; "" when unknown. */
  tz?: string;
  quiet_from: number;
  quiet_to: number;
}

/** A member's own rule for one app action. */
export interface CookieRule {
  id: string;
  app: string;
  /** The exact action name, a prefix ending in `*`, or `*`. */
  action: string;
  rule: "deny" | "always";
}

/** A helper at work on a running job (live only; a finished one is a `helper` step). */
export interface CookieHelper {
  id: string;
  name: string;
  task: string;
  state: "working" | "done" | "failed";
  at_ms: number;
}

export interface CookiePeek {
  /** A lookup: its top notes. */
  notes?: { text: string; app?: string; day?: string }[];
  /** A search: its first results. */
  results?: { title: string; host: string }[];
  /** A page: its title and opening words. A save: what was saved (`text`). */
  title?: string;
  text?: string;
}

export interface CookieRun {
  id: string;
  trigger: "email" | "page" | "slack" | "tool" | string;
  subject: string;
  status: "running" | "done" | "failed" | string;
  /** replied | drafted | asked | answered | silent | refused | out_of_credits | failed */
  delivery: string | null;
  credits: number;
  steps: CookieStep[];
  /** What Cookie answered, without the signature; null while working or on failure. */
  answer: string | null;
  /** Per paragraph of `answer`, the indexes of the steps it used. */
  answer_sources?: number[][];
  /** The questions Cookie asked before starting (delivery `asked`). */
  questions?: string | null;
  /** This run answers the questions of that run. */
  parent_run_id?: string | null;
  /** Things Cookie saved to the team's context. */
  saves?: number;
  searches?: number;
  started_at: string;
  finished_at: string | null;
  /** Who sent an email job. */
  from?: string | null;
  /** The start of what was asked. */
  excerpt?: string | null;
  /** The page conversation this run belongs to (the run that began it); absent = its own. */
  conversation?: string | null;
  /** Who asked, and whether it was the person looking. A teammate's job comes
   *  without what Cookie read, asked or answered — that stays theirs. */
  member_id?: string | null;
  who?: string | null;
  mine?: boolean;
  /** Why the job could not go on, when it could not: needs_input ·
   *  blocked_by_permission · transient · out_of_credits. */
  block?: string | null;
  /** Still waiting for a turn: only so many jobs work at once. */
  queued?: boolean;
  /** Live only, from the run's stream: the answer as written so far… */
  live_text?: string;
  /** …and the helpers at work. */
  helpers?: CookieHelper[];
}

/** A job's public, counts-only view. */
export interface CookieShared {
  trigger: string;
  status: string;
  pages: number;
  searches: number;
  lookups: number;
  saves: number;
  seconds: number | null;
  credits: number;
  paragraphs: number;
  day: string | null;
  steps: { tool: string; at_ms: number; ms?: number; size?: number; ok: boolean }[];
}

export interface CookieDraft {
  id: string;
  run_id: string;
  member_id: string;
  to: string[];
  subject: string;
  body: string;
  /** Waits for a Slack thread rather than a mail thread. */
  slack?: boolean;
  created_at: string;
}

export interface CookieOverview {
  enabled: boolean;
  /** The org's name — Cookie signs and shows as "Cookie · <team>". */
  team: string;
  address: string | null;
  /** `used` includes `saves`: what extracting Cookie's saves cost. */
  credits: { allowance: number; used: number; saves?: number };
  runs: CookieRun[];
  waiting: CookieDraft[];
  /** Changes in the member's apps waiting for their yes (and recently decided ones). */
  approvals?: CookieApproval[];
  /** What Cookie noticed in the team's brain (watch-only: nothing ran or was sent). */
  notices?: CookieNotice[];
  /** What Cookie learned from this team's jobs, and how each lesson is doing. */
  lessons?: CookieLesson[];
  /** Who is looking: signed in (`console`) or through a job link + PIN (`pin`). */
  viewer?: {
    member_id: string;
    via: "console" | "pin";
    pin_set: boolean;
    permission?: CookiePermission | null;
    rules?: CookieRule[];
    prefs?: CookiePrefs;
    /** The team's own words about how Cookie should be (its SOUL). */
    soul?: string | null;
    /** Chat apps set up on this gateway, and whether this member linked each. */
    channels?: { channel: string; linked: boolean; bot?: string }[];
  };
  slack?: { available: boolean; workspace: string | null };
  /** The apps this team connected: `key` = their sync folder (what a step's `apps` name), `provider` = logo slug. */
  apps?: { key: string; provider: string; ok: boolean }[];
  /** How much Cookie used each place in the last 7 days. */
  paths?: CookiePaths;
  /** Jobs this member gives again and again, offered (once) or kept as routines. */
  routines?: CookieRoutine[];
  /** Follow-ups Cookie keeps on mail it sent for this member, until someone replies. */
  chases?: CookieChase[];
}

export interface CookieRoutine {
  id: string;
  job: string;
  /** `weekly` | `daily` … as the gateway computed it. */
  cadence: string;
  weekday: number;
  hour: number;
  minute: number;
  /** How many alike jobs it was seen in. */
  seen: number;
  /** offered | active | paused */
  state: string;
  next_run_at: string | null;
  last_run_at: string | null;
  created_at: string;
}

export interface CookieChase {
  id: string;
  run_id: string;
  about: string;
  /** pending | waiting | nudged | replied | stopped | done */
  state: string;
  to: string[];
  nudges: number;
  max_nudges: number;
  due_at: string | null;
  replied_at: string | null;
  created_at: string;
}

export interface CookiePaths {
  context: number;
  saves: number;
  web: number;
  email: number;
  slack: number;
  apps: Record<string, number>;
}
