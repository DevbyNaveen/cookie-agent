// A run as a lace: where its threads go and when, built only from what the
// run recorded — the trigger, each tool call (what, when, how long, how much
// came back, whether it worked), the answer. Times are seconds from the run's
// start; positions are world units.

import type { CookieDraft, CookieRun, CookieStep } from "@/lib/api";

export type StopKind = "context" | "search" | "web" | "save";

export type Stop = {
  id: string;
  /** Index of the step in `run.steps` — what the answer's sources name. */
  step: number;
  kind: StopKind;
  x: number;
  y: number;
  at: number;
  trip: number;
  /** Characters handed back to Cookie — the thread thickens with it. */
  read: number;
  /** Pages it read (a site read counts each page). */
  pages: number;
  ok: boolean;
  label: string;
  /** A few words under the node on the canvas. */
  short: string;
  note: string;
  host?: string;
};

export type Lace = {
  origin: { kind: "mail" | "slack" | "page"; label: string };
  stops: Stop[];
  /** When the answer was ready (null while Cookie is still working). */
  done: number | null;
  /** The last moment anything happens. */
  end: number;
  lines: string[];
  /** Per line, the ids of the stops it used (empty when the run named none). */
  sources: string[][];
  /** The questions Cookie asked before starting, one per item. */
  questions: string[] | null;
  draft: CookieDraft | null;
};

export const ORIGIN = { x: 110, y: 430 };
export const HUB = { x: 330, y: 430 };
/** The trigger reaching Cookie takes this long on the canvas, before the first call. */
export const INTRO = 1.6;
const FALLBACK_TRIP = 0.8;

const rad = (deg: number) => (deg * Math.PI) / 180;
const cut = (v: string, n: number) => (v.length > n ? `${v.slice(0, n - 1).trimEnd()}…` : v);

/** Nodes ring Cookie in the order it reached them, far enough apart that their names never touch. */
function ring(i: number, n: number) {
  const r = Math.max(230, (n * 170) / (2 * Math.PI));
  const a = n === 1 ? 0 : -90 + (360 * i) / n;
  return { x: HUB.x + Math.cos(rad(a)) * r, y: HUB.y + Math.sin(rad(a)) * r * 0.78 };
}

/** Where a step went; `null` for a step that is not a place (asking first). */
function kindOf(step: CookieStep): StopKind | null {
  switch (step.tool) {
    case "recall":
      return "context";
    case "web_search":
      return "search";
    case "remember":
      return "save";
    case "ask_first":
    // An app action is shown as its own card in the reply, not as a page read.
    case "apps":
    case "app_call":
      return null;
    default:
      return "web";
  }
}

/** `read_site` logs "host · 7 pages". */
function sitePages(what: string): number | null {
  const m = / · (\d+) pages?$/.exec(what);
  return m ? Number(m[1]) : null;
}

function stopNote(step: CookieStep, kind: StopKind): { label: string; short: string; note: string; host?: string } {
  const failed = step.ok ? "" : " — didn't work";
  const what = step.what.trim();
  if (kind === "context") return { label: "Your context", short: cut(what, 26), note: `Looked up “${what}”${failed}` };
  if (kind === "save") return { label: "Saved to your context", short: `Saved · ${cut(what, 18)}`, note: step.ok ? `“${what}”` : `Couldn't save “${what}”` };
  if (kind === "search") return { label: "Web search", short: cut(what, 26), note: `“${what}”${failed}` };
  const pages = sitePages(what);
  const host = what.replace(/ · \d+ pages?$/, "").replace(/^www\./, "");
  if (pages != null) return { label: host || "A site", short: cut(host || "A site", 26), host, note: step.ok ? `Read ${pages} pages of the site` : "Couldn't read the site" };
  return { label: host || "A page", short: cut(host || "A page", 26), host, note: step.ok ? "Read the page" : "Couldn't read the page" };
}

/** Pages a step read: one for a page, the count for a site. */
export function pagesOf(step: { tool: string; what?: string; ok: boolean }): number {
  if (!step.ok) return 0;
  if (step.tool === "read_url") return 1;
  if (step.tool === "read_site") return sitePages(step.what ?? "") ?? 1;
  return 0;
}

export function laceOf(run: CookieRun, waiting: CookieDraft[]): Lace {
  // Keep each step's index in the run: the answer's sources name steps by it.
  const steps = (run.steps ?? [])
    .map((step, index) => ({ step, index, kind: kindOf(step) }))
    .filter((x): x is { step: CookieStep; index: number; kind: StopKind } => x.kind !== null)
    .sort((a, b) => a.step.at_ms - b.step.at_ms);
  const pos = new Map<number, { x: number; y: number }>();
  steps.forEach((x, i) => pos.set(x.index, ring(i, steps.length)));

  const stops: Stop[] = steps.map(({ step: s, index, kind }) => {
    const trip = Math.max(0.35, (s.ms ?? FALLBACK_TRIP * 1000) / 1000);
    return {
      id: `s${index}`,
      step: index,
      kind,
      ...pos.get(index)!,
      at: INTRO + s.at_ms / 1000 - trip,
      trip,
      read: s.size ?? 0,
      pages: pagesOf(s),
      ok: s.ok,
      ...stopNote(s, kind),
    };
  });

  const started = Date.parse(run.started_at);
  const lastStep = stops.reduce((m, s) => Math.max(m, s.at + s.trip), INTRO);
  const done =
    run.status === "running"
      ? null
      : run.finished_at
        ? Math.max(lastStep + 0.6, INTRO + (Date.parse(run.finished_at) - started) / 1000)
        : lastStep + 0.6;
  const lines = (run.answer ?? "")
    .split(/\n{2,}/)
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(0, 12);
  // The gateway splits the answer into paragraphs the same way, so its i-th
  // source list belongs to the i-th line.
  const have = new Set(stops.filter((x) => x.ok).map((x) => x.step));
  const sources = lines.map((_, i) => (run.answer_sources?.[i] ?? []).filter((n) => have.has(n)).map((n) => `s${n}`));
  const questions =
    run.delivery === "asked" || run.delivery === "answered"
      ? (run.questions ?? "")
          .split("\n")
          .map((q) => q.replace(/^-\s*/, "").trim())
          .filter(Boolean)
      : null;
  const draft = waiting.find((d) => d.run_id === run.id) ?? null;
  const origin =
    run.trigger === "email"
      ? { kind: "mail" as const, label: "The email that asked" }
      : run.trigger === "slack"
        ? { kind: "slack" as const, label: "The Slack message that asked" }
        : run.trigger === "tool"
          ? { kind: "page" as const, label: "Asked from an AI tool" }
          : { kind: "page" as const, label: "Asked here" };
  // The replay ends once the last line has finished appearing (each line
  // starts 0.45 s after the one before and takes 0.8 s).
  const end = done == null ? lastStep + 1.2 : done + 0.8 + lines.length * 0.45 + 0.6;
  return { origin, stops, done, end, lines, sources, questions: questions?.length ? questions : null, draft };
}

/** Seconds since a running run started, on the lace's clock. */
export function liveClock(run: CookieRun): number {
  return INTRO + (Date.now() - Date.parse(run.started_at)) / 1000;
}
