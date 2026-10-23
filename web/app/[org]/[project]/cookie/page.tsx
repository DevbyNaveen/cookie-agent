"use client";

/**
 * `/{org}/{project}/cookie` — Cookie's own page, outside the Console shell.
 *
 * Two doors (decided 2026-10-19):
 * - Signed in (from the dashboard): the Console session opens it, nothing is asked.
 * - A job link from Cookie's mail or Slack (`?job=<run>&t=<token>`) without a
 *   session asks for the member's six-digit PIN. Link + PIN open a Cookie
 *   session for this project's page only, for 30 days.
 * Neither door is a way into the rest of the Console. Which door this browser
 * has is asked first (`/api/cookie/who`), so nothing here can trip the
 * app-wide 401 → /login redirect for someone holding only a Cookie session.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams, usePathname, useRouter, useSearchParams } from "next/navigation";
import useSWR from "swr";
import { api, ApiError, type CookieDraft, type CookieOverview } from "@/lib/api";
import { cookieApi, cookieLogout, cookieUnlock, cookieWho } from "@/lib/cookieClient";
import { registerProjectSlug } from "@/lib/projectNav";
import { CookieLace } from "@/components/central/lace/CookieLace";
import { useLiveRuns, withLive } from "@/components/central/lace/useLiveRuns";
import { CookieOrb } from "@/components/central/CookieOrb";
import s from "./cookiePage.module.css";

function one(v: string | string[] | undefined): string {
  return (Array.isArray(v) ? v[0] : v) ?? "";
}

const SLACK_NOTICE: Record<string, string> = {
  added: "Cookie is in your Slack. Mention @Cookie in a channel, or send it a DM.",
  taken: "That Slack workspace already has Cookie for another team.",
  cancelled: "Slack wasn't connected.",
  failed: "Slack couldn't be connected. Try again.",
  expired: "That took too long. Try adding Cookie to Slack again.",
};

export default function CookiePage() {
  const params = useParams();
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const orgSlug = one(params.org).toLowerCase();
  const projectSlug = one(params.project).toLowerCase();
  const selected = search.get("job");
  // A new conversation: the page starts empty until its first job.
  const fresh = !selected && search.get("new") === "1";
  const linkToken = search.get("t");
  const slackOutcome = search.get("slack");

  const { data: who, mutate: reWho } = useSWR("cookie-who", cookieWho, { revalidateOnFocus: false });
  const pinSession =
    who && !who.signed_in && who.session && who.session.org.toLowerCase() === orgSlug && who.session.project.toLowerCase() === projectSlug
      ? who.session
      : null;
  const mode: "loading" | "console" | "pin" | "unlock" | "login" = !who
    ? "loading"
    : who.signed_in
      ? "console"
      : pinSession
        ? "pin"
        : linkToken
          ? "unlock"
          : "login";

  useEffect(() => {
    if (mode === "login") router.replace(`/login?next=${encodeURIComponent(`${pathname}${search.size ? `?${search}` : ""}`)}`);
  }, [mode, router, pathname, search]);

  // Signed in: resolve the slugs the way the Console does.
  const { data: me } = useSWR(mode === "console" ? ["me-for-slug"] : null, () => api.me(""), { revalidateOnFocus: false });
  const org = useMemo(() => me?.orgs.find((o) => o.slug.toLowerCase() === orgSlug) ?? null, [me, orgSlug]);
  const { data: projects } = useSWR(org ? ["projects", org.id] : null, () => api.listProjects(org!.id, ""), {
    revalidateOnFocus: false,
  });
  const consoleProject = useMemo(
    () => projects?.find((p) => p.slug.toLowerCase() === projectSlug) ?? null,
    [projects, projectSlug],
  );
  useEffect(() => {
    if (consoleProject) registerProjectSlug(consoleProject.id, orgSlug, projectSlug);
  }, [consoleProject, orgSlug, projectSlug]);
  const projectId = mode === "pin" ? pinSession!.project_id : mode === "console" ? consoleProject?.id ?? null : null;

  // Fast while Cookie works, slow while it rests — short requests through the
  // BFF, never a held-open stream.
  const { data: overview, error, mutate } = useSWR(projectId ? ["cookie-page", projectId] : null, () => cookieApi.overview(projectId!), {
    refreshInterval: (d) => (d?.runs.some((r) => r.status === "running") ? 1500 : 15000),
    revalidateOnFocus: true,
  });
  // A link to a job older than the recent list still opens that job.
  const missing = Boolean(selected && overview && !overview.runs.some((r) => r.id === selected));
  const { data: extra } = useSWR(missing && projectId ? ["cookie-run", projectId, selected] : null, () => cookieApi.run(projectId!, selected!), {
    refreshInterval: (r) => (r?.status === "running" ? 1500 : 0),
  });
  const listed: CookieOverview | undefined = useMemo(
    () => (overview && extra && missing ? { ...overview, runs: [...overview.runs, extra] } : overview),
    [overview, extra, missing],
  );
  // Working jobs, live: the words as written, steps as they land, helpers.
  const live = useLiveRuns(projectId, listed?.runs, () => void mutate());
  const shown: CookieOverview | undefined = useMemo(
    () => (listed ? { ...listed, runs: listed.runs.map((r) => withLive(r, live[r.id])) } : listed),
    [listed, live],
  );

  const [notice, setNotice] = useState<string | null>(null);
  useEffect(() => {
    if (!slackOutcome) return;
    setNotice(SLACK_NOTICE[slackOutcome] ?? null);
    const next = new URLSearchParams(search);
    next.delete("slack");
    router.replace(`${pathname}${next.size ? `?${next}` : ""}`, { scroll: false });
    const id = setTimeout(() => setNotice(null), 7000);
    return () => clearTimeout(id);
  }, [slackOutcome, search, router, pathname]);

  const select = useCallback(
    (id: string) => router.replace(`${pathname}?job=${encodeURIComponent(id)}`, { scroll: false }),
    [router, pathname],
  );
  const startNew = useCallback(() => router.replace(`${pathname}?new=1`, { scroll: false }), [router, pathname]);
  const decide = useCallback(
    async (draft: CookieDraft, action: "send" | "skip" | "take_over") => {
      if (!projectId) return;
      if (action === "take_over") {
        window.location.href = `mailto:${draft.to.map(encodeURIComponent).join(",")}?subject=${encodeURIComponent(draft.subject)}&body=${encodeURIComponent(draft.body)}`;
      }
      await cookieApi.draft(projectId, draft.id, action);
      await mutate();
    },
    [projectId, mutate],
  );
  const decideApproval = useCallback(
    async (approvalId: string, approve: boolean, always?: boolean) => {
      if (!projectId) return;
      await cookieApi.approval(projectId, approvalId, approve, always);
      await mutate();
    },
    [projectId, mutate],
  );
  const setLesson = useCallback(
    async (lessonId: string, state: "active" | "archived") => {
      if (!projectId) return;
      await cookieApi.lesson(projectId, lessonId, state);
      await mutate();
    },
    [projectId, mutate],
  );
  const labelNotice = useCallback(
    async (noticeId: string, label: "useful" | "not_useful" | "wrong") => {
      if (!projectId) return;
      await cookieApi.notice(projectId, noticeId, label);
      await mutate();
    },
    [projectId, mutate],
  );
  const giveJob = useCallback(
    async (text: string, conversation?: string) => {
      if (!projectId) return;
      const { run_id } = await cookieApi.job(projectId, text, { conversation });
      await mutate();
      select(run_id);
    },
    [projectId, mutate, select],
  );
  const answer = useCallback(
    async (runId: string, text: string) => {
      if (!projectId) return;
      const { run_id } = await cookieApi.job(projectId, text, { answers: runId });
      await mutate();
      select(run_id);
    },
    [projectId, mutate, select],
  );

  const shell = (body: React.ReactNode) => <main className={s.shell}>{body}</main>;
  const opening = shell(
    <div className={s.opening} role="status">
      <CookieOrb size={72} thinking style={{ ["--lift" as string]: 14 }} />
      <span className={s.flow}>Opening Cookie…</span>
    </div>,
  );
  if (mode === "loading" || mode === "login") return opening;
  if (mode === "unlock")
    return (
      <PinDoor
        token={linkToken!}
        loginHref={`/login?next=${encodeURIComponent(`${pathname}${selected ? `?job=${selected}` : ""}`)}`}
        onOpen={async () => {
          await reWho();
          router.replace(`${pathname}${selected ? `?job=${encodeURIComponent(selected)}` : ""}`, { scroll: false });
        }}
      />
    );
  if (mode === "console" && (!me || (org && !projects))) return opening;
  if (!projectId) return shell("You don't have access to this team's Cookie.");
  if (!shown && !error) return opening;
  if (error || !shown) {
    if (error instanceof ApiError && error.status === 401) {
      return shell(linkToken ? "Your Cookie session ended. Open the link again." : "Your Cookie session ended. Open a job link from Cookie again.");
    }
    return shell("Cookie didn't answer. Try again in a moment.");
  }
  if (!shown.enabled) return shell("Cookie isn't on for this team yet.");

  return (
    <main className={s.page}>
      <CookieLace
        overview={shown}
        selectedId={selected}
        fresh={fresh}
        onSelect={select}
        onNew={startNew}
        onStop={async (runId) => {
          await cookieApi.stop(projectId, runId);
          await mutate();
        }}
        onUndo={async (changeId) => {
          const r = await cookieApi.undoChange(projectId, changeId);
          await mutate();
          return r;
        }}
        onRoutine={async (routineId, action) => {
          await cookieApi.routine(projectId, routineId, action);
          await mutate();
        }}
        onSoul={async (text) => {
          await cookieApi.soul(projectId, text);
          await mutate();
        }}
        onStopChase={async (chaseId) => {
          await cookieApi.stopChase(projectId, chaseId);
          await mutate();
        }}
        onDecide={decide}
        onApproval={decideApproval}
        onNotice={labelNotice}
        onLesson={setLesson}
        onPermission={async (level) => {
          await cookieApi.permission(projectId, level);
          await mutate();
        }}
        onChannel={async (channel, link) => {
          if (!link) {
            await cookieApi.channelUnlink(projectId, channel);
            await mutate();
            return null;
          }
          return cookieApi.channelCode(projectId, channel);
        }}
        onPrefs={async (prefs) => {
          await cookieApi.prefs(projectId, prefs);
          await mutate();
        }}
        onRule={async (change) => {
          if (change.remove) await cookieApi.deleteRule(projectId, change.remove);
          else if (change.set) await cookieApi.rule(projectId, change.set);
          await mutate();
        }}
        onJob={giveJob}
        onAnswer={answer}
        onShare={async (runId) => (await cookieApi.share(projectId, runId)).url}
        onUnshare={async (runId) => {
          await cookieApi.unshare(projectId, runId);
        }}
        onSetPin={async (pin) => {
          await cookieApi.setPin(pin);
          await mutate();
        }}
        onSlack={async (action) => {
          if (action === "add") {
            window.location.href = (await cookieApi.slackInstall(projectId)).url;
          } else {
            await cookieApi.slackRemove(projectId);
            await mutate();
          }
        }}
        onSignOut={
          mode === "pin"
            ? async () => {
                await cookieLogout();
                await reWho();
              }
            : undefined
        }
      />
      {notice && (
        <p className={s.notice} role="status">
          {notice}
        </p>
      )}
    </main>
  );
}

/** A job link without a session: the member's six digits open it. */
function PinDoor({ token, loginHref, onOpen }: { token: string; loginHref: string; onOpen: () => Promise<void> }) {
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<{ code: string; text: string } | null>(null);
  const ended = err?.code === "link_ended" || err?.code === "cookie_not_member";
  const submit = async (value: string) => {
    if (value.length !== 6 || busy) return;
    setBusy(true);
    setErr(null);
    try {
      await cookieUnlock(token, value);
      await onOpen();
    } catch (e) {
      setPin("");
      setErr(e instanceof ApiError ? { code: e.code, text: e.message } : { code: "error", text: "That didn't work. Try again." });
    } finally {
      setBusy(false);
    }
  };
  return (
    <main className={s.shell}>
      <form
        className={s.door}
        onSubmit={(e) => {
          e.preventDefault();
          void submit(pin);
        }}
      >
        <CookieOrb size={64} follow style={{ ["--lift" as string]: 12 }} />
        <h1 className={s.doorTitle}>Enter your Cookie PIN</h1>
        <p className={s.doorLead}>The six digits you set for Cookie. They open this job and your team&apos;s Cookie page on this browser.</p>
        {!ended && (
          <input
            className={s.digits}
            value={pin}
            onChange={(e) => {
              const v = e.target.value.replace(/\D/g, "").slice(0, 6);
              setPin(v);
              if (v.length === 6) void submit(v);
            }}
            inputMode="numeric"
            autoComplete="one-time-code"
            autoFocus
            disabled={busy}
            aria-label="Six-digit PIN"
            placeholder="••••••"
          />
        )}
        <p className={err ? s.doorErr : s.doorHint} role={err ? "alert" : undefined}>
          {busy ? "Opening…" : err ? err.text : " "}
        </p>
        <a className={s.doorLink} href={loginHref}>
          {err?.code === "pin_not_set" ? "Sign in to set your PIN" : ended ? "Sign in instead" : "Forgot it? Sign in and set a new one"}
        </a>
      </form>
    </main>
  );
}
