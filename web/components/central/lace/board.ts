// Cookie's board: one job on stage. Circles are what Cookie read (each lookup,
// search, page — one circle per source, however often it went back) and the
// helpers it handed parts of the job to; boxes are what it produced (the
// answer — a report or a list of leads when that is what it wrote — or the
// draft waiting for you, each save, the questions it asked, or why it
// stopped). A page hangs from the search or lookup whose result held its
// address, and what a helper read hangs from the helper, so the threads draw
// how the work actually went. Every circle the answer drew on threads into
// the answer. Everything appears on the job's clock, read only from what the
// run recorded. The past lives in one scrolling history box beside it.
//
// Layout never lets two things touch: circles sit in gently bowed columns
// beside the orb, boxes stack in columns beyond them, the history box hangs
// on the other side.

import type { CookieDraft, CookieRun, CookieStep } from "@/lib/api";
import { INTRO, pagesOf } from "./build";
import { paragraphs, parseLeads } from "./leads";

export type ReadKind = "context" | "search" | "page" | "helper";
export type OutKind = "answer" | "report" | "leads" | "draft" | "questions" | "save" | "writing" | "stopped";

export type ReadNode = {
  id: string;
  kind: ReadKind;
  /** Every step that went to this source (the last one is shown). For a
   *  helper: its own step, once it finished. */
  steps: number[];
  label: string;
  start: number;
  landed: number | null;
  ok: boolean;
  /** What it hangs from: the orb, the circle whose result led here, or the helper that read it. */
  parent: string;
  /** A helper's task, whole. */
  task?: string;
};
export type OutNode = { id: string; kind: OutKind; step?: number; start: number; landed: number | null };
export type Edge = { id: string; from: string; to: string; kind: "read" | "via" | "helper" | "out" | "fed" | "reach" | "app" | "ghost" };
export type Box = { x: number; y: number; w: number; h: number };

export const ORB = "orb";
export const CIRCLE = 46;
export const OUT_W = 300;
/** A report or a list of leads needs a wider sheet. */
export const WIDE_W = 380;
export const widthOf = (kind: OutKind) => (kind === "leads" || kind === "report" ? WIDE_W : OUT_W);
export const HIST_W = 300;
/** A reach node: a connected app, the mail address, Slack — what Cookie is wired to. */
export const REACH = 38;
const REACH_STEP = 76;
const GAP = 18;
/** Circle columns: the first one's distance from the orb, the step between them, a row's height. */
const FIRST_COLUMN = 175;
const COLUMN = 150;
const ROW = 84;
const CIRCLES_PER_COLUMN = 6;
const OUT_COLUMN = 600;

const cut = (v: string, n: number) => (v.length > n ? `${v.slice(0, n - 1).trimEnd()}…` : v);
const hostOf = (what: string) => what.replace(/ · \d+ pages?$/, "").replace(/^www\./, "");

function readKind(step: CookieStep): ReadKind | null {
  switch (step.tool) {
    case "recall":
    case "past_jobs":
      return "context";
    case "web_search":
      return "search";
    case "read_url":
    case "read_site":
      return "page";
    default:
      return null;
  }
}

/** The kind of product box the finished answer is: a list of leads when it
 *  is written as one, a report when it is research (pages read, or helpers)
 *  of three paragraphs or more, else an answer. */
export function productKind(run: CookieRun): "answer" | "report" | "leads" {
  const answer = run.answer ?? "";
  if (parseLeads(answer).leads.length) return "leads";
  const pages = (run.steps ?? []).reduce((n, st) => n + pagesOf(st), 0);
  const helped = (run.steps ?? []).some((st) => st.tool === "helper");
  return (pages >= 2 || helped) && paragraphs(answer).length >= 3 ? "report" : "answer";
}

/** The job on stage: its reading, its output, the threads between them. */
export function stageOf(run: CookieRun, waiting: CookieDraft[], t: number, reach: string[] = []) {
  const reads = new Map<string, ReadNode>();
  const outs: OutNode[] = [];
  const nodeOfStep = new Map<number, string>();
  const steps = run.steps ?? [];
  const at = (ms: number) => INTRO + ms / 1000;
  let last = INTRO;
  // Helpers first, so what they read can hang from them: each finished one is
  // a `helper` step; one still working is only on the live run.
  steps.forEach((s, i) => {
    if (s.tool !== "helper" || !s.helper) return;
    const id = `helper:${s.helper}`;
    // An earlier message's work is already there when this one starts.
    const start = s.prior ? 0 : at(Math.max(0, s.at_ms - (s.ms ?? 0)));
    const landed = s.prior ? 0 : at(s.at_ms);
    reads.set(id, { id, kind: "helper", steps: [i], label: cut(s.what || "Researching", 22), task: s.what, start, landed, ok: s.ok, parent: ORB });
    nodeOfStep.set(i, id);
    last = Math.max(last, landed);
  });
  for (const h of run.helpers ?? []) {
    const id = `helper:${h.id}`;
    if (reads.has(id)) continue;
    reads.set(id, { id, kind: "helper", steps: [], label: cut(h.task || "Researching", 22), task: h.task, start: at(h.at_ms), landed: h.state === "working" ? null : at(h.at_ms), ok: h.state !== "failed", parent: ORB });
  }
  steps.forEach((s, i) => {
    if (s.tool === "helper") return;
    const ms = s.ms ?? 800;
    const start = s.prior ? 0 : INTRO + Math.max(0, s.at_ms - ms) / 1000;
    const landed = s.prior ? 0 : Math.max(start + 0.7, at(s.at_ms));
    last = Math.max(last, landed);
    if (s.tool === "remember") {
      if (s.prior) return;
      outs.push({ id: `save:${i}`, kind: "save", step: i, start, landed });
      return;
    }
    const kind = readKind(s);
    if (!kind) return;
    // One circle per source: the same lookup, search or site again is the same circle.
    const sourceKey = kind === "page" ? hostOf(s.what).toLowerCase() : s.what.trim().toLowerCase();
    const id = `${kind}:${sourceKey}`;
    const prev = reads.get(id);
    if (prev) {
      prev.steps.push(i);
      prev.landed = Math.max(prev.landed ?? 0, landed);
      prev.ok = prev.ok || s.ok;
    } else {
      // It hangs from the circle whose result held its address, else from the
      // helper that read it, else from the orb. Both came earlier, so no loop.
      const via = s.via != null ? nodeOfStep.get(s.via) : undefined;
      const helper = s.helper && reads.has(`helper:${s.helper}`) ? `helper:${s.helper}` : undefined;
      reads.set(id, { id, kind, steps: [i], label: cut(kind === "page" ? hostOf(s.what) : s.what.trim(), 22), start, landed, ok: s.ok, parent: via ?? helper ?? ORB });
    }
    nodeOfStep.set(i, id);
  });

  const running = run.status === "running";
  const started = Date.parse(run.started_at);
  const done = running ? null : Math.max(last + 0.5, run.finished_at ? INTRO + (Date.parse(run.finished_at) - started) / 1000 : last + 0.5);
  const draft = waiting.find((d) => d.run_id === run.id);
  if (done != null) {
    const at = { start: done, landed: done + 0.35 };
    if (run.delivery === "asked") outs.push({ id: "questions", kind: "questions", ...at });
    else if (draft) outs.push({ id: "draft", kind: "draft", ...at });
    else if (run.answer) outs.push({ id: "answer", kind: productKind(run), ...at });
    else outs.push({ id: "stopped", kind: "stopped", ...at });
  } else if (run.live_text) {
    // The words as Cookie writes them.
    outs.push({ id: "writing", kind: "writing", start: Math.min(t, last + 0.3), landed: null });
  } else if (reads.size > 0 && t > last + 0.8) {
    const out = [...reads.values()].some((r) => r.landed == null || (t >= r.start && t < r.landed));
    if (!out) outs.push({ id: "writing", kind: "writing", start: last + 0.8, landed: null });
  }

  // Threads: from what each circle hangs from, the orb to each box, and the
  // circles the answer drew on to the answer.
  const edges: Edge[] = [];
  for (const r of reads.values()) {
    const kind = r.kind === "helper" ? "helper" : r.parent === ORB ? "read" : "via";
    edges.push({ id: `${r.parent}>${r.id}`, from: r.parent, to: r.id, kind });
  }
  for (const o of outs) edges.push({ id: `${ORB}>${o.id}`, from: ORB, to: o.id, kind: "out" });
  const product = outs.find((o) => o.kind === "answer" || o.kind === "report" || o.kind === "leads" || o.kind === "draft");
  if (product) {
    const cited = new Set((run.answer_sources ?? []).flat());
    for (const r of reads.values()) if (r.steps.some((n) => cited.has(n))) edges.push({ id: `${r.id}>${product.id}`, from: r.id, to: product.id, kind: "fed" });
  }
  // What Cookie is wired to hangs from it; an app whose notes a lookup found
  // feeds that circle (the notes synced from it into the team's context).
  const wired = new Set(reach);
  for (const id of reach) edges.push({ id: `${ORB}>${id}`, from: ORB, to: id, kind: id.startsWith("ghost:") ? "ghost" : "reach" });
  for (const r of reads.values()) {
    const apps = new Set(r.steps.flatMap((n) => steps[n]?.apps ?? []));
    for (const a of apps) if (wired.has(`app:${a}`)) edges.push({ id: `app:${a}>${r.id}`, from: `app:${a}`, to: r.id, kind: "app" });
  }
  // Circles in the order the work went: each one followed by what hangs from
  // it, so a helper's reading and a search's pages sit together.
  const kids = new Map<string, ReadNode[]>();
  for (const r of reads.values()) kids.set(r.parent, [...(kids.get(r.parent) ?? []), r]);
  const ordered: ReadNode[] = [];
  const walk = (id: string) => {
    for (const r of (kids.get(id) ?? []).sort((a, b) => a.start - b.start)) {
      ordered.push(r);
      walk(r.id);
    }
  };
  walk(ORB);
  return { reads: ordered, outs, edges, done, end: done == null ? last + 1 : done + 1 };
}

/** Where everything goes (top-left corners, world units; the orb is at 0,0). */
export function layout(
  reads: ReadNode[],
  outs: OutNode[],
  heightOf: (id: string) => number,
  history: { h: number } | null,
  reach: string[] = [],
): Map<string, Box> {
  const out = new Map<string, Box>();
  if (history) out.set("history", { x: -110 - HIST_W, y: -history.h / 2, w: HIST_W, h: history.h });
  // Circles in columns to the right of the orb, bowed gently around it. A
  // column is wider than any label and a row taller than a circle and its
  // label, so no two ever touch however many there are.
  const cols = Math.max(1, Math.ceil(reads.length / CIRCLES_PER_COLUMN));
  const perCol = Math.ceil(reads.length / cols);
  reads.forEach((n, i) => {
    const ci = Math.floor(i / perCol);
    const inCol = Math.min(perCol, reads.length - ci * perCol);
    const ri = i - ci * perCol;
    const y = (ri - (inCol - 1) / 2) * ROW;
    const x = FIRST_COLUMN + ci * COLUMN - (y * y) / 1400;
    out.set(n.id, { x: x - CIRCLE / 2, y: y - CIRCLE / 2, w: CIRCLE, h: CIRCLE });
  });
  // What Cookie is wired to: one row under the orb, below every circle and
  // the history box, so nothing it can reach ever sits on something it read.
  if (reach.length) {
    let below = 230;
    out.forEach((b) => (below = Math.max(below, b.y + b.h + (b.w === CIRCLE ? 26 : 0))));
    const y = below + 74;
    reach.forEach((id, i) => {
      const x = (i - (reach.length - 1) / 2) * REACH_STEP;
      out.set(id, { x: x - REACH / 2, y: y - REACH / 2, w: REACH, h: REACH });
    });
  }
  // Boxes in columns beyond the circles, each column centred on the orb.
  const x0 = (reads.length ? FIRST_COLUMN + (cols - 1) * COLUMN + CIRCLE / 2 : 60) + 110;
  const columns: OutNode[][] = [[]];
  let used = 0;
  for (const o of outs) {
    const h = heightOf(o.id);
    const col = columns[columns.length - 1];
    if (col.length && used + GAP + h > OUT_COLUMN) {
      columns.push([o]);
      used = h;
    } else {
      used += (col.length ? GAP : 0) + h;
      col.push(o);
    }
  }
  let x = x0;
  for (const col of columns) {
    const total = col.reduce((n, o, i) => n + heightOf(o.id) + (i ? GAP : 0), 0);
    let y = -total / 2;
    for (const o of col) {
      const h = heightOf(o.id);
      out.set(o.id, { x, y, w: widthOf(o.kind), h });
      y += h + GAP;
    }
    x += Math.max(OUT_W, ...col.map((o) => widthOf(o.kind))) + GAP * 2;
  }
  return out;
}

export function guessHeight(kind: OutKind): number {
  return kind === "leads" || kind === "report" ? 260 : kind === "answer" || kind === "draft" || kind === "writing" ? 190 : kind === "questions" ? 150 : 110;
}

/** Strip markdown for a preview. */
export function plain(md: string): string {
  return md
    .replace(/\[s\d+\]/g, "")
    .replace(/[*_`#>]+/g, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
}

/** The card a node is (for BoardCard): its kind and the step it shows. */
export type Card = {
  id: string;
  kind: ReadKind | OutKind;
  step?: number;
  /** Every step behind a circle (a site read page by page lists each). */
  steps?: number[];
  /** A helper's task. */
  task?: string;
  start: number;
  landed: number | null;
  ok: boolean;
};
export const readCard = (r: ReadNode): Card => ({
  id: r.id,
  kind: r.kind,
  step: r.steps[r.steps.length - 1],
  steps: r.steps,
  task: r.task,
  start: r.start,
  landed: r.landed,
  ok: r.ok,
});
export const outCard = (o: OutNode): Card => ({ id: o.id, kind: o.kind, step: o.step, start: o.start, landed: o.landed, ok: true });
