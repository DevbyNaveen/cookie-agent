// Cookie's work as conversations, not jobs. A follow-up on the page, an
// answer to the questions Cookie asked and the job that began them are one
// conversation: one row in the list, one thread in the chat. Each run names
// the run its page conversation began with (`conversation`) or the run whose
// questions it answers (`parent_run_id`); everything else stands alone.

import type { CookieRun, CookieStep } from "@/lib/api";

export type Thread = {
  /** The run it began with. */
  key: string;
  /** Oldest first. */
  runs: CookieRun[];
  /** The newest run — what the row says and what opens. */
  last: CookieRun;
  mine: boolean;
  who: string | null;
};

/** The conversation a run belongs to. */
export function threadKeyOf(r: CookieRun, byId: Map<string, CookieRun>): string {
  let cur = r;
  // A conversation can be continued from an answer to questions, whose own
  // conversation began further back: follow every link to the start.
  for (let hops = 0; hops < 50; hops++) {
    const up = cur.conversation ?? cur.parent_run_id;
    if (!up || up === cur.id) return cur.id;
    const next = byId.get(up);
    if (!next) return up;
    cur = next;
  }
  return cur.id;
}

/** Every conversation, the one most recently active first. */
export function threadsOf(runs: CookieRun[]): Thread[] {
  const byId = new Map(runs.map((r) => [r.id, r]));
  const groups = new Map<string, CookieRun[]>();
  for (const r of runs) {
    const k = threadKeyOf(r, byId);
    const g = groups.get(k);
    if (g) g.push(r);
    else groups.set(k, [r]);
  }
  return [...groups.entries()]
    .map(([key, g]) => {
      const sorted = [...g].sort((a, b) => a.started_at.localeCompare(b.started_at));
      const last = sorted[sorted.length - 1];
      return { key, runs: sorted, last, mine: last.mine !== false, who: last.who ?? null };
    })
    .sort((a, b) => b.last.started_at.localeCompare(a.last.started_at));
}

/** The words a conversation goes by: what it was started with. */
export const titleOf = (t: Thread) => t.runs[0].subject || "(no subject)";

/** What a working job is doing now, from its last step. */
export function doingOf(r: CookieRun): string {
  if (r.queued) return "Waiting for a turn";
  if ((r.helpers ?? []).some((h) => h.state === "working")) return "A helper is researching";
  const last = r.steps?.[r.steps.length - 1];
  if (!last) return "Reading the request";
  if (last.tool === "recall") return "Looking in your context";
  if (last.tool === "web_search") return "Searching the web";
  if (last.tool === "read_url" || last.tool === "read_site") {
    try {
      return `Reading ${new URL(last.what).hostname.replace(/^www\./, "")}`;
    } catch {
      return "Reading a page";
    }
  }
  return "Working";
}

/**
 * The board for one message of a conversation: what Cookie read for the
 * earlier messages comes first, already in place (`prior`), then this
 * message's own work, so the board keeps growing instead of starting over.
 * Step numbers move with the steps: the answer's sources, a page's `via`
 * and a helper's id stay pointed at the right step.
 */
export function onBoard(run: CookieRun, thread: CookieRun[]): CookieRun {
  const before = thread.filter((r) => r.id !== run.id && r.started_at <= run.started_at);
  if (!before.length) return run;
  const steps: CookieStep[] = [];
  const add = (r: CookieRun, prior: boolean) => {
    const base = steps.length;
    for (const st of r.steps ?? []) {
      steps.push({
        ...st,
        ...(prior ? { prior: true } : {}),
        ...(st.via != null ? { via: st.via + base } : {}),
        ...(st.helper ? { helper: prior ? `${r.id}:${st.helper}` : st.helper } : {}),
      });
    }
    return base;
  };
  for (const r of before) add(r, true);
  const base = add(run, false);
  return { ...run, steps, answer_sources: run.answer_sources?.map((p) => p.map((n) => n + base)) };
}

/**
 * What Cookie is thinking, as one line above its face while it works: the
 * words it is looking for, the page it is reading, that it is writing.
 * Read only from what the run did; nothing while it rests.
 */
export function thoughtOf(r: CookieRun | null): string | null {
  if (!r || r.status !== "running") return null;
  if (r.queued) return "Waiting for my turn…";
  if (r.live_text) return "Writing it up…";
  if ((r.helpers ?? []).some((h) => h.state === "working")) return "Asking a helper to dig deeper…";
  const last = r.steps?.[r.steps.length - 1];
  const words = (w: string) => (w.length > 48 ? `${w.slice(0, 47).trimEnd()}…` : w);
  if (!last) return "Reading what you asked…";
  if (last.tool === "recall" || last.tool === "past_jobs") return `Remembering “${words(last.what)}”…`;
  if (last.tool === "web_search") return `Searching “${words(last.what)}”…`;
  if (last.tool === "read_url" || last.tool === "read_site") return `${doingOf(r)}…`;
  if (last.tool === "app_call") return "Checking your apps…";
  return "Thinking…";
}
