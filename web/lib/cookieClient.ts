// Cookie's page talks to the gateway through the same BFF as the Console, but
// with plain fetches: the page can be open on a Cookie session (a job link +
// PIN) that has no Console sign-in, and the app-wide 401 → /login redirect in
// `api.ts` must not fire for it. The BFF still injects whichever credential
// this browser holds (and refreshes a Console session on 401 by itself).

import { ApiError, type CookieApproval, type CookieOverview, type CookiePermission, type CookiePrefs, type CookieRule, type CookieRun, type CookieShared } from "./api";

async function gw<T>(path: string, init: { method?: string; body?: unknown } = {}): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`/api/gw/${path}`, {
      method: init.method ?? "GET",
      headers: init.body === undefined ? undefined : { "content-type": "application/json" },
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
      credentials: "include",
      cache: "no-store",
    });
  } catch {
    throw new ApiError(0, "unreachable", "Cookie can't be reached right now.");
  }
  const text = await res.text();
  let parsed: unknown = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  if (!res.ok) {
    const err = (parsed && typeof parsed === "object" ? (parsed as { error?: { code?: string; message?: string } }).error : undefined) ?? {};
    const code = err.code ?? "error";
    // The gateway says "<code>: <message>" for its own coded answers.
    const raw = err.message ?? `Request failed (HTTP ${res.status})`;
    const message = raw.startsWith(`${code}: `) ? raw.slice(code.length + 2) : raw.replace(/^[a-z ]+: /, "");
    throw new ApiError(res.status, code, message);
  }
  return parsed as T;
}

const p = (projectId: string) => `v1/projects/${encodeURIComponent(projectId)}/cookie`;

export const cookieApi = {
  overview: (projectId: string) => gw<CookieOverview>(p(projectId)),
  run: (projectId: string, runId: string) => gw<CookieRun>(`${p(projectId)}/runs/${encodeURIComponent(runId)}`),
  /** A new job, or — with `answers` — the answer to the questions that run asked.
   *  `conversation` continues the page conversation that run belongs to. */
  job: (projectId: string, text: string, opts: { answers?: string; conversation?: string } = {}) =>
    gw<{ run_id: string; steered?: boolean }>(`${p(projectId)}/jobs`, { method: "POST", body: { text, ...opts } }),
  draft: (projectId: string, draftId: string, action: "send" | "skip" | "take_over") =>
    gw<{ state: string }>(`${p(projectId)}/drafts/${encodeURIComponent(draftId)}`, { method: "POST", body: { action } }),
  /** The member's yes (runs the change exactly as composed) or no. */
  approval: (projectId: string, approvalId: string, approve: boolean, always = false) =>
    gw<CookieApproval>(`${p(projectId)}/approvals/${encodeURIComponent(approvalId)}`, { method: "POST", body: { approve, always } }),
  /** A one-time code to link a chat app (Telegram, Discord, WhatsApp, Teams); needs a Console sign-in. */
  channelCode: (projectId: string, channel: string) =>
    gw<{ code: string; minutes: number }>(`${p(projectId)}/channels/${encodeURIComponent(channel)}`, { method: "POST" }),
  channelUnlink: (projectId: string, channel: string) =>
    gw<{ unlinked: boolean }>(`${p(projectId)}/channels/${encodeURIComponent(channel)}`, { method: "DELETE" }),
  /** When Cookie's notices reach this member. */
  prefs: (projectId: string, prefs: CookiePrefs) => gw<{ saved: boolean }>(`${p(projectId)}/prefs`, { method: "PUT", body: prefs }),
  /** A member's own rule: never, or always without asking (always needs a Console sign-in). */
  rule: (projectId: string, rule: Omit<CookieRule, "id">) => gw<CookieRule>(`${p(projectId)}/rules`, { method: "PUT", body: rule }),
  deleteRule: (projectId: string, ruleId: string) =>
    gw<{ deleted: boolean }>(`${p(projectId)}/rules/${encodeURIComponent(ruleId)}`, { method: "DELETE" }),
  /** How much Cookie may do in this member's apps before it asks. Raising it needs a Console sign-in. */
  permission: (projectId: string, level: CookiePermission) =>
    gw<{ permission: CookiePermission }>(`${p(projectId)}/permission`, { method: "PUT", body: { level } }),
  /** Archive a lesson Cookie learned, or bring one back. */
  lesson: (projectId: string, lessonId: string, state: "active" | "archived") =>
    gw<{ state: string }>(`${p(projectId)}/lessons/${encodeURIComponent(lessonId)}`, { method: "POST", body: { state } }),
  /** A label on something Cookie noticed. */
  notice: (projectId: string, noticeId: string, label: "useful" | "not_useful" | "wrong") =>
    gw<{ label: string }>(`${p(projectId)}/notices/${encodeURIComponent(noticeId)}`, { method: "POST", body: { label } }),
  /** Put back what Cookie changed (old values) or delete what it created, if it still matches. */
  undoChange: (projectId: string, changeId: string) =>
    gw<{ state: "restored" | "undone" | "kept"; why?: string }>(`${p(projectId)}/changes/${encodeURIComponent(changeId)}/undo`, { method: "POST" }),
  /** Answer a routine offer, or pause / resume one. */
  routine: (projectId: string, routineId: string, action: "accept" | "decline" | "pause" | "resume") =>
    gw<{ state: string; next_run_at: string | null }>(`${p(projectId)}/routines/${encodeURIComponent(routineId)}`, { method: "POST", body: { action } }),
  /** The team's own words about how Cookie should be; empty clears it. */
  soul: (projectId: string, text: string) => gw<{ saved: boolean }>(`${p(projectId)}/soul`, { method: "PUT", body: { text } }),
  /** Stop following up on a mail. */
  stopChase: (projectId: string, chaseId: string) =>
    gw<{ stopped: boolean }>(`${p(projectId)}/chases/${encodeURIComponent(chaseId)}/stop`, { method: "POST" }),
  /** Stop one of your own jobs while it works or waits for a turn. */
  stop: (projectId: string, runId: string) =>
    gw<{ stopping: boolean }>(`${p(projectId)}/runs/${encodeURIComponent(runId)}/stop`, { method: "POST" }),
  share: (projectId: string, runId: string) => gw<{ url: string }>(`${p(projectId)}/runs/${encodeURIComponent(runId)}/share`, { method: "POST" }),
  unshare: (projectId: string, runId: string) =>
    gw<{ shared: boolean }>(`${p(projectId)}/runs/${encodeURIComponent(runId)}/share`, { method: "DELETE" }),
  slackInstall: (projectId: string) => gw<{ url: string }>(`${p(projectId)}/slack/install`),
  slackRemove: (projectId: string) => gw<{ removed: boolean }>(`${p(projectId)}/slack`, { method: "DELETE" }),
  /** Signed-in only: a PIN never changes a PIN. */
  setPin: (pin: string) => gw<{ set: boolean }>("v1/cookie/pin", { method: "PUT", body: { pin } }),
  /** A public job link's counts. No sign-in. */
  shared: (token: string) => gw<CookieShared>(`v1/cookie/shared/${encodeURIComponent(token)}`),
};

/** Which door this browser can open the Cookie page with (`/api/cookie/who`). */
export type CookieWho = {
  signed_in: boolean;
  session: { project_id: string; member_id: string; org: string; project: string } | null;
  unreachable?: boolean;
};

export async function cookieWho(): Promise<CookieWho> {
  const r = await fetch("/api/cookie/who", { credentials: "include", cache: "no-store" });
  if (!r.ok) throw new ApiError(r.status, "error", "Cookie can't be reached right now.");
  return r.json();
}

/** A job link's token + PIN → a Cookie session (set as an httpOnly cookie). */
export async function cookieUnlock(token: string, pin: string): Promise<{ project_id: string; job: string }> {
  const r = await fetch("/api/cookie/unlock", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token, pin }),
    credentials: "include",
    cache: "no-store",
  });
  const data = await r.json().catch(() => null);
  if (!r.ok) throw new ApiError(r.status, data?.error?.code ?? "error", data?.error?.message ?? "That didn't work. Try again.");
  return data;
}

export async function cookieLogout(): Promise<void> {
  await fetch("/api/cookie/logout", { method: "POST", credentials: "include", cache: "no-store" }).catch(() => undefined);
}
