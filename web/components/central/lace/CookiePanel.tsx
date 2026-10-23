"use client";

// The floating panel on Cookie's page: Chat (the conversation on the page —
// what you asked here and what Cookie answered), Inbox (what came by email, Slack
// or an AI tool, and what waits for you), Settings (credits, email, PIN,
// Slack). A borderless sheet over the canvas, with its own dock beneath it.

import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { CookieChase, CookieDraft, CookieLesson, CookieNotice, CookieOverview, CookiePermission, CookiePrefs, CookieRoutine, CookieRule, CookieRun } from "@/lib/api";
import { actionLabel, changeOutcome, changesOf } from "./changes";
import { CookieOrb } from "@/components/central/CookieOrb";
import { laceOf, pagesOf } from "./build";
import { appName } from "./world";
import { Select } from "./Select";
import s from "./CookiePanel.module.css";

export type Tab = "chat" | "inbox" | "settings";

const timeOf = (iso: string) => new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const dayOf = (iso: string) => {
  const d = new Date(iso);
  const today = new Date();
  const y = new Date(today);
  y.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return "Today";
  if (d.toDateString() === y.toDateString()) return "Yesterday";
  return d.toLocaleDateString([], { weekday: "long", day: "numeric", month: "long" });
};
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** Why a job could not go on, in words. */
const BLOCK: Record<string, string> = {
  needs_input: "Cookie needs something from you to go on.",
  blocked_by_permission: "Cookie stopped at a change your settings don't allow.",
  transient: "Cookie hit a temporary problem and tried again.",
  out_of_credits: "Cookie is out of credits for this month.",
};

/** Where a follow-up stands, in one line. */
function chaseLine(c: CookieChase): string {
  const who = c.to[0] ?? "them";
  switch (c.state) {
    case "replied":
      return `${who} replied — follow-up done`;
    case "stopped":
      return "You stopped following up";
    case "done":
      return `Followed up ${plural(c.nudges, "time")} — no reply`;
    case "nudged":
      return `Waiting for ${who} · nudge ${c.nudges} of ${c.max_nudges} drafted`;
    default:
      return `Waiting for ${who}'s reply${c.due_at ? ` · Cookie checks again ${new Date(c.due_at).toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })}` : ""}`;
  }
}

const SOURCE: Record<string, { icon?: string; label: string }> = {
  email: { icon: "/connectors/gmail.svg", label: "Email" },
  slack: { icon: "/connectors/color_slack.svg", label: "Slack" },
  tool: { label: "AI tool" },
  telegram: { icon: "/connectors/telegram.svg", label: "Telegram" },
  discord: { icon: "/connectors/discord.svg", label: "Discord" },
  whatsapp: { icon: "/connectors/whatsapp.svg", label: "WhatsApp" },
  teams: { icon: "/connectors/microsoft_teams.svg", label: "Microsoft Teams" },
};

/** How a run ended, said for where it was asked. Null when there is nothing to add. */
const CHAT_APPS: Record<string, string> = { telegram: "Telegram", discord: "Discord", whatsapp: "WhatsApp", teams: "Microsoft Teams" };

function outcomeOf(run: CookieRun): string | null {
  const here = run.trigger === "page";
  switch (run.delivery) {
    case "replied":
      if (CHAT_APPS[run.trigger]) return `Replied in ${CHAT_APPS[run.trigger]}`;
      return run.trigger === "slack" ? "Replied in the Slack thread" : here || run.trigger === "tool" ? "Also emailed to you" : "Replied by email";
    case "planned":
      return "Split into parts — one answer when they're done";
    case "part":
      return "One part of a bigger job";
    case "drafted":
      return "Draft waiting for you";
    case "asked":
      return "Asked you first";
    case "answered":
      return "You answered — the job ran next";
    case "silent":
      return "Read it and stayed quiet";
    case "stopped":
      return "You stopped it";
    case "refused":
      return "Didn't act — not from the team";
    case "out_of_credits":
      return "Stopped — out of Cookie credits";
    case "failed":
      if (run.answer) return here ? "Answered here. The email copy didn't send." : "Answered, but the reply didn't send.";
      return "Cookie couldn't finish this one.";
    default:
      return null;
  }
}

/** One line for what a run read: "Read 5 notes · searched twice · 3 pages · 6 s". */
function readOf(run: CookieRun): string {
  const looked = run.steps.filter((x) => x.tool === "recall").length;
  const searched = run.steps.filter((x) => x.tool === "web_search").length;
  const pages = run.steps.reduce((n, x) => n + pagesOf(x), 0);
  const saved = run.steps.filter((x) => x.tool === "remember" && x.ok).length;
  const secs = run.finished_at ? Math.max(1, Math.round((Date.parse(run.finished_at) - Date.parse(run.started_at)) / 1000)) : null;
  const parts = [
    looked ? `Read ${plural(looked, "note")}` : null,
    searched ? `searched ${searched === 1 ? "once" : `${searched} times`}` : null,
    pages ? plural(pages, "page") : null,
    saved ? `saved ${saved}` : null,
  ].filter(Boolean) as string[];
  const head = parts.length ? parts.join(" · ").replace(/^./, (c) => c.toUpperCase()) : "Answered from what it knew";
  return secs ? `${head} · ${secs} s` : head;
}

const TAB_NAME: Record<Tab, string> = { chat: "Chat", inbox: "Inbox", settings: "Settings" };
const DOCK_ICON: Record<Tab, ReactNode> = {
  chat: (
    <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden>
      <path d="M10 3.5c4.1 0 7 2.6 7 5.9s-2.9 5.9-7 5.9c-.8 0-1.6-.1-2.3-.3L4.2 16.5l.9-3C3.8 12.4 3 11 3 9.4 3 6.1 5.9 3.5 10 3.5Z" fill="currentColor" />
    </svg>
  ),
  inbox: (
    <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden>
      <path d="M3.5 11.5 5.4 5a1.5 1.5 0 0 1 1.4-1h6.4a1.5 1.5 0 0 1 1.4 1l1.9 6.5v3A1.5 1.5 0 0 1 15 16H5a1.5 1.5 0 0 1-1.5-1.5v-3Z" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
      <path d="M3.5 11.5h3.6l1 1.8h3.8l1-1.8h3.6" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round" />
    </svg>
  ),
  settings: (
    <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden>
      <path d="M4 6h7M15 6h1M4 14h1M9 14h7" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
      <circle cx="13" cy="6" r="2" fill="none" stroke="currentColor" strokeWidth="1.7" />
      <circle cx="7" cy="14" r="2" fill="none" stroke="currentColor" strokeWidth="1.7" />
    </svg>
  ),
};

const STEP_LABEL: Record<string, string> = {
  recall: "Your context",
  web_search: "Web search",
  read_url: "Page",
  read_site: "Site",
  remember: "Saved",
  ask_first: "Asked first",
  apps: "Apps",
  app_call: "In an app",
};

const Markdown = memo(function Markdown({ text }: { text: string }) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        a: ({ href, children }) => (
          <a href={href} target="_blank" rel="noopener noreferrer">
            {children}
          </a>
        ),
      }}
    >
      {text}
    </ReactMarkdown>
  );
});

export function CookiePanel({
  overview,
  run,
  thread,
  onNew,
  onStop,
  onUndo,
  onRoutine,
  onStopChase,
  onSoul,
  tab,
  onTab,
  open,
  onOpen,
  onSelect,
  litLines,
  onHoverLine,
  onReplay,
  onDecide,
  onApproval,
  onNotice,
  onLesson,
  onPermission,
  onRule,
  onPrefs,
  onChannel,
  onJob,
  onAnswer,
  onShare,
  onUnshare,
  onSetPin,
  onSlack,
  onSignOut,
}: {
  overview: CookieOverview;
  /** The run the canvas is showing. */
  run: CookieRun | null;
  /** The conversation it belongs to, oldest first; empty on a new one. */
  thread: CookieRun[];
  onNew: () => void;
  /** Stop one of the viewer's own jobs while it works. */
  onStop: (runId: string) => Promise<void>;
  onUndo: (changeId: string) => Promise<{ state: string; why?: string }>;
  onRoutine: (routineId: string, action: "accept" | "decline" | "pause" | "resume") => Promise<void>;
  onStopChase: (chaseId: string) => Promise<void>;
  onSoul: (text: string) => Promise<void>;
  tab: Tab;
  onTab: (t: Tab) => void;
  open: boolean;
  onOpen: (v: boolean) => void;
  onSelect: (id: string) => void;
  /** Paragraphs of the shown run that a hovered node fed. */
  litLines: Set<number> | null;
  onHoverLine: (i: number | null) => void;
  onReplay: (id: string) => void;
  onDecide: (draft: CookieDraft, action: "send" | "skip" | "take_over") => Promise<void>;
  /** The member's yes or no to a change Cookie asked to make in an app. */
  onApproval: (approvalId: string, approve: boolean, always?: boolean) => Promise<void>;
  /** A label on something Cookie noticed. */
  onNotice: (noticeId: string, label: "useful" | "not_useful" | "wrong") => Promise<void>;
  /** Archive a lesson, or bring one back. */
  onLesson: (lessonId: string, state: "active" | "archived") => Promise<void>;
  onPermission: (level: CookiePermission) => Promise<void>;
  onRule: (change: { set?: Omit<CookieRule, "id">; remove?: string }) => Promise<void>;
  onPrefs: (prefs: CookiePrefs) => Promise<void>;
  onChannel: (channel: string, link: boolean) => Promise<{ code: string; minutes: number } | null>;
  onJob: (text: string, conversation?: string) => Promise<void>;
  onAnswer: (runId: string, text: string) => Promise<void>;
  onShare: (runId: string) => Promise<string>;
  onUnshare: (runId: string) => Promise<void>;
  onSetPin: (pin: string) => Promise<void>;
  onSlack: (action: "add" | "remove") => Promise<void>;
  onSignOut?: () => Promise<void>;
}) {
  const runs = overview.runs;
  // The chat is the conversation on the page, when it is one you had here.
  const chat = useMemo(() => thread.filter((r) => r.trigger === "page" && r.mine !== false), [thread]);
  const inbox = useMemo(() => {
    const waiting = new Set(overview.waiting.map((d) => d.run_id));
    const needs = (r: CookieRun) =>
      waiting.has(r.id) || r.delivery === "asked" || changesOf(r, overview.approvals).some((c) => c.approval?.status === "pending");
    return runs
      .filter((r) => r.trigger !== "page" && r.mine !== false)
      .sort((a, b) => Number(needs(b)) - Number(needs(a)) || b.started_at.localeCompare(a.started_at))
      .map((r) => ({ run: r, needs: needs(r) }));
  }, [runs, overview.waiting, overview.approvals]);
  const unlabelled = (overview.notices ?? []).filter((n) => !n.label).length + (overview.routines ?? []).filter((r) => r.state === "offered").length;
  const needsYou = inbox.filter((x) => x.needs).length + unlabelled;
  const left = Math.max(0, overview.credits.allowance - overview.credits.used);

  const resets = (() => {
    const n = new Date();
    return new Date(n.getFullYear(), n.getMonth() + 1, 1).toLocaleDateString([], { day: "numeric", month: "long" });
  })();
  // The dock stays under the panel, open or folded: tap a view to open it there,
  // tap the open one again to fold the panel away.
  const dock = (
    <nav className={s.dock} aria-label="Cookie views">
      {(["chat", "inbox", "settings"] as const).map((k) => (
        <button
          key={k}
          aria-label={TAB_NAME[k]}
          aria-pressed={open && tab === k}
          title={TAB_NAME[k]}
          onClick={() => {
            if (open && tab === k) onOpen(false);
            else {
              onTab(k);
              onOpen(true);
            }
          }}
        >
          {DOCK_ICON[k]}
          {k === "inbox" && needsYou > 0 && <i className={s.dockBadge}>{needsYou}</i>}
        </button>
      ))}
    </nav>
  );

  if (!open) return dock;

  return (
    <>
    <aside className={s.panel} aria-label="Cookie">
      <header className={s.top}>
        <h2 className={s.heading}>{TAB_NAME[tab]}</h2>
        <div className={s.credits}>
          <button className={s.ringBtn} onClick={() => onTab("settings")} aria-describedby="cookie-credits">
            <CreditRing used={overview.credits.used} allowance={overview.credits.allowance} />
          </button>
          <div id="cookie-credits" role="tooltip" className={s.pop}>
            <b>
              {left.toLocaleString()} <span>of {overview.credits.allowance.toLocaleString()} credits left</span>
            </b>
            <span>This month · resets {resets}</span>
          </div>
        </div>
        <button className={s.icon} onClick={() => onOpen(false)} aria-label="Fold the panel">
          <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
            <path d="M3.5 5.25 7 8.75l3.5-3.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      </header>

      {tab === "chat" && (
        <Chat
          runs={chat}
          overview={overview}
          shown={run}
          litLines={litLines}
          onSelect={onSelect}
          onHoverLine={onHoverLine}
          onReplay={onReplay}
          onDecide={onDecide}
          onApproval={onApproval}
          onJob={onJob}
          onAnswer={onAnswer}
          onShare={onShare}
          onUnshare={onUnshare}
          onNew={onNew}
          onStop={onStop}
          onUndo={onUndo}
          onStopChase={onStopChase}
          blocked={left <= 0}
        />
      )}
      {tab === "inbox" && (
        <div className={s.scroll}>
          {(overview.routines ?? []).some((r) => r.state === "offered") && (
            <Offers routines={overview.routines!.filter((r) => r.state === "offered")} onRoutine={onRoutine} />
          )}
          {(overview.notices ?? []).length > 0 && <Noticed notices={overview.notices!} onNotice={onNotice} />}
          {inbox.length === 0 && (overview.notices ?? []).length > 0 ? null : inbox.length === 0 ? (
            <div className={s.empty}>
              <p className={s.emptyTitle}>Nothing has come in yet</p>
              <p className={s.emptyLead}>
                {overview.address ? (
                  <>
                    Email <b>{overview.address}</b>
                    {overview.slack?.workspace ? ", or mention @Cookie in Slack" : ""}. What Cookie did with it shows here.
                  </>
                ) : (
                  "Mail and Slack messages to Cookie show here."
                )}
              </p>
            </div>
          ) : (
            <ul className={s.inbox}>
              {inbox.map(({ run: r, needs }) => {
                const src = SOURCE[r.trigger] ?? { label: r.trigger };
                const openRow = r.id === run?.id;
                return (
                  <li key={r.id} className={s.card} data-open={openRow ? "true" : undefined}>
                    <button className={s.cardHead} onClick={() => onSelect(r.id)}>
                      <span className={s.src}>
                        {src.icon ? <img src={src.icon} alt="" width={14} height={14} /> : <CookieOrb size={16} />}
                      </span>
                      <span className={s.cardText}>
                        <b>{r.subject || "(no subject)"}</b>
                        <span>
                          {src.label} · {dayOf(r.started_at)}, {timeOf(r.started_at)}
                          {r.status === "running" ? " · working…" : outcomeOf(r) ? ` · ${outcomeOf(r)}` : ""}
                        </span>
                      </span>
                      {needs && <i className={s.dot} aria-label="Needs you" />}
                    </button>
                    {openRow && (
                      <div className={s.cardBody}>
                        <Reply
                          run={r}
                          overview={overview}
                          shown
                          litLines={litLines}
                          onHoverLine={onHoverLine}
                          onReplay={onReplay}
                          onDecide={onDecide}
                          onApproval={onApproval}
                          onAnswer={onAnswer}
                          onShare={onShare}
                          onUnshare={onUnshare}
                          onStop={onStop}
                          onUndo={onUndo}
                          onStopChase={onStopChase}
                        />
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}
      {tab === "settings" && (
        <Settings
          overview={overview}
          onSetPin={onSetPin}
          onSlack={onSlack}
          onSignOut={onSignOut}
          onLesson={onLesson}
          onPermission={onPermission}
          onRule={onRule}
          onPrefs={onPrefs}
          onChannel={onChannel}
          onRoutine={onRoutine}
          onSoul={onSoul}
        />
      )}
    </aside>
    {dock}
    </>
  );
}

/** This month's credits as a ring that empties; amber from 80% used, red when out. */
function CreditRing({ used, allowance }: { used: number; allowance: number }) {
  const share = allowance > 0 ? Math.min(1, used / allowance) : 1;
  const left = Math.max(0, allowance - used);
  const r = 7;
  const len = 2 * Math.PI * r;
  const tone = share >= 1 ? "#f87171" : share >= 0.8 ? "var(--cookie)" : "color-mix(in srgb, var(--text) 80%, transparent)";
  return (
    <span className={s.ring}>
      <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden>
        <circle cx="9" cy="9" r={r} fill="none" stroke="color-mix(in srgb, var(--text) 14%, transparent)" strokeWidth="2" />
        <circle
          cx="9" cy="9" r={r} fill="none" stroke={tone} strokeWidth="2" strokeLinecap="round"
          strokeDasharray={`${len * (1 - share)} ${len}`} transform="rotate(-90 9 9)"
        />
      </svg>
      <span style={{ color: share >= 0.8 ? tone : undefined }}>{left.toLocaleString()}</span>
    </span>
  );
}

function Chat({
  runs,
  overview,
  shown,
  litLines,
  onSelect,
  onHoverLine,
  onReplay,
  onDecide,
  onApproval,
  onJob,
  onAnswer,
  onShare,
  onUnshare,
  onNew,
  onStop,
  onUndo,
  onStopChase,
  blocked,
}: {
  runs: CookieRun[];
  overview: CookieOverview;
  shown: CookieRun | null;
  litLines: Set<number> | null;
  onSelect: (id: string) => void;
  onHoverLine: (i: number | null) => void;
  onReplay: (id: string) => void;
  onDecide: (draft: CookieDraft, action: "send" | "skip" | "take_over") => Promise<void>;
  /** The member's yes or no to a change Cookie asked to make in an app. */
  onApproval: (approvalId: string, approve: boolean, always?: boolean) => Promise<void>;
  onJob: (text: string, conversation?: string) => Promise<void>;
  onAnswer: (runId: string, text: string) => Promise<void>;
  onShare: (runId: string) => Promise<string>;
  onUnshare: (runId: string) => Promise<void>;
  onNew: () => void;
  onStop: (runId: string) => Promise<void>;
  onUndo: (changeId: string) => Promise<{ state: string; why?: string }>;
  onStopChase: (chaseId: string) => Promise<void>;
  blocked: boolean;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const last = runs[runs.length - 1];
  const working = runs.some((r) => r.status === "running");
  // The conversation keeps going until you start a new one: Cookie reads its
  // last exchanges before each job (`conversation` on the job).
  // Added messages (steered into a running job) belong to that job's conversation.
  const anchor = [...runs].reverse().find((r) => r.delivery !== "steered" && r.delivery !== "paused") ?? last;
  const continuing = anchor ? anchor.conversation ?? anchor.id : undefined;
  const send = (text: string) => onJob(text, continuing);
  // Stay at the newest message as the conversation grows or Cookie answers.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [runs.length, last?.status, last?.answer, last?.live_text]);

  return (
    <>
      <div ref={scroller} className={s.scroll}>
        {runs.length === 0 ? (
          <div className={s.empty}>
            <CookieOrb size={56} follow />
            <p className={s.emptyTitle}>Ask Cookie anything</p>
            <p className={s.emptyLead}>It reads your team&apos;s context, and the web when it needs to, then answers here.</p>
          </div>
        ) : (
          <ol className={s.thread}>
            {runs.map((r, i) => {
              const day = dayOf(r.started_at);
              const newDay = i === 0 || dayOf(runs[i - 1].started_at) !== day;
              return (
                <li key={r.id}>
                  {newDay && <p className={s.day}>{day}</p>}
                  <div className={s.me}>
                    <p className={s.bubble}>{r.subject || "(no subject)"}</p>
                    <span className={s.when}>
                      {r.delivery === "steered" ? "Added to the job Cookie was working on · " : r.delivery === "paused" ? "Cookie is pausing here for a few minutes · " : ""}
                      {timeOf(r.started_at)}
                    </span>
                  </div>
                  {r.delivery === "steered" || r.delivery === "paused" ? null : (
                  <div
                    className={s.cookie}
                    data-shown={r.id === shown?.id ? "true" : undefined}
                    onClick={() => r.id !== shown?.id && onSelect(r.id)}
                  >
                    <Reply
                      run={r}
                      overview={overview}
                      shown={r.id === shown?.id}
                      litLines={r.id === shown?.id ? litLines : null}
                      onHoverLine={onHoverLine}
                      onReplay={onReplay}
                      onDecide={onDecide}
                      onApproval={onApproval}
                      onAnswer={onAnswer}
                      onShare={onShare}
                      onUnshare={onUnshare}
                      onStop={onStop}
                      onUndo={onUndo}
                      onStopChase={onStopChase}
                    />
                  </div>
                  )}
                </li>
              );
            })}
          </ol>
        )}
      </div>
      {last && (
        <div className={s.talkBar}>
          <span>Cookie reads this conversation before each answer.</span>
          <button onClick={onNew}>New conversation</button>
        </div>
      )}
      <Composer
        onJob={send}
        working={working}
        blocked={blocked}
        followUp={Boolean(continuing)}
        onStop={(() => {
          const busy = [...runs].reverse().find((r) => r.status === "running");
          return busy ? () => onStop(busy.id) : undefined;
        })()}
      />
    </>
  );
}

function Composer({
  onJob,
  working,
  blocked,
  followUp,
  onStop,
}: {
  onJob: (text: string) => Promise<void>;
  working: boolean;
  blocked: boolean;
  followUp: boolean;
  /** While this conversation's job works and nothing is typed, send becomes Stop. */
  onStop?: () => Promise<void>;
}) {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const box = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    el.style.height = "0px";
    el.style.height = `${Math.min(160, el.scrollHeight)}px`;
  }, [text]);
  const submit = async () => {
    const v = text.trim();
    if (!v || busy || blocked) return;
    setBusy(true);
    setErr(null);
    try {
      await onJob(v);
      setText("");
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Cookie didn't take that.");
    } finally {
      setBusy(false);
    }
  };
  return (
    <form
      className={s.composer}
      onSubmit={(e) => {
        e.preventDefault();
        void submit();
      }}
    >
      {(err || blocked) && <p className={s.composerNote}>{blocked ? "Cookie is out of credits for this month." : err}</p>}
      <div className={s.field} onClick={() => box.current?.focus()}>
        <textarea
          ref={box}
          rows={1}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              void submit();
            }
          }}
          placeholder={working ? "Cookie is working — ask the next thing…" : followUp ? "Ask a follow-up…" : "Ask Cookie anything…"}
          disabled={busy || blocked}
          aria-label="Ask Cookie"
        />
        <div className={s.fieldBar}>
          <span className={s.reads}>
            <img src="/favicon.svg" alt="" width={13} height={13} />
            Reads your team&apos;s context
          </span>
          <span className={s.hint}>{text.trim() ? "↵ send · ⇧↵ new line" : ""}</span>
          {onStop && !text.trim() ? (
            <StopButton onStop={onStop} round />
          ) : (
          <button type="submit" className={s.send} disabled={busy || blocked || !text.trim()} aria-label="Send">
            {busy ? (
              <i className={s.spin} />
            ) : (
              <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
                <path d="M7 11.5V2.5M3 6.5l4-4 4 4" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            )}
          </button>
          )}
        </div>
      </div>
    </form>
  );
}

/** Stop a job while it works: a pill beside what it is doing, or the
 *  composer's round button. Once pressed it says so until the job ends. */
function StopButton({ onStop, round }: { onStop: () => Promise<void>; round?: boolean }) {
  const [stopping, setStopping] = useState(false);
  const press = async () => {
    if (stopping) return;
    setStopping(true);
    try {
      await onStop();
    } catch {
      setStopping(false);
    }
  };
  const square = (
    <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
      <rect x="1" y="1" width="8" height="8" rx="1.8" fill="currentColor" />
    </svg>
  );
  return round ? (
    <button type="button" className={s.send} onClick={press} disabled={stopping} aria-label="Stop Cookie" title="Stop">
      {stopping ? <i className={s.spin} /> : square}
    </button>
  ) : (
    <button type="button" className={s.stop} onClick={press} disabled={stopping}>
      {square}
      {stopping ? "Stopping…" : "Stop"}
    </button>
  );
}

/** Cookie's side of one exchange: what it read, what it wrote, and what waits for you. */
function Reply({
  run,
  overview,
  shown,
  litLines,
  onHoverLine,
  onReplay,
  onDecide,
  onApproval,
  onAnswer,
  onShare,
  onUnshare,
  onStop,
  onUndo,
  onStopChase,
}: {
  run: CookieRun;
  overview: CookieOverview;
  shown: boolean;
  litLines: Set<number> | null;
  onHoverLine: (i: number | null) => void;
  onReplay: (id: string) => void;
  onDecide: (draft: CookieDraft, action: "send" | "skip" | "take_over") => Promise<void>;
  /** The member's yes or no to a change Cookie asked to make in an app. */
  onApproval: (approvalId: string, approve: boolean, always?: boolean) => Promise<void>;
  onAnswer: (runId: string, text: string) => Promise<void>;
  onShare: (runId: string) => Promise<string>;
  onUnshare: (runId: string) => Promise<void>;
  /** Stop this job while it works (only the person who asked sees it). */
  onStop: (runId: string) => Promise<void>;
  /** Put back (or delete) what one change did, if the record still matches. */
  onUndo: (changeId: string) => Promise<{ state: string; why?: string }>;
  onStopChase: (chaseId: string) => Promise<void>;
}) {
  const lace = useMemo(() => laceOf(run, overview.waiting), [run, overview.waiting]);
  const changes = useMemo(() => changesOf(run, overview.approvals), [run, overview.approvals]);
  // Waiting for a yes (a held one goes out by itself, so "Yes to all" leaves it).
  const pending = changes.flatMap(({ approval }) => (approval?.status === "pending" && !approval.run_after ? [approval] : []));
  const signedIn = overview.viewer?.via === "console";
  const [details, setDetails] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  /** What an Undo came to, by journal id. */
  const [undone, setUndone] = useState<Record<string, string>>({});
  const chase = (overview.chases ?? []).find((c) => c.run_id === run.id);
  const [reply, setReply] = useState("");
  const [replyErr, setReplyErr] = useState<string | null>(null);
  const [share, setShare] = useState<{ url: string; copied: boolean } | null>(null);
  const live = run.status === "running";
  const outcome = outcomeOf(run);
  const perLine = shown && lace.sources.some((l) => l.length > 0);

  // A running reply counts its calls as they land.
  const [, tick] = useState(0);
  useEffect(() => {
    if (!live) return;
    const id = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(id);
  }, [live]);

  const decide = async (draft: CookieDraft, action: "send" | "skip" | "take_over") => {
    setBusy(action);
    try {
      await onDecide(draft, action);
    } finally {
      setBusy(null);
    }
  };
  const copy = (url: string) =>
    navigator.clipboard?.writeText(url).then(() => {
      setShare({ url, copied: true });
      setTimeout(() => setShare((v) => (v ? { ...v, copied: false } : v)), 1600);
    });

  return (
    <div className={s.reply}>
      {live ? (
        <>
          <div className={s.reading}>
            <CookieOrb size={30} thinking={!run.queued} />
            <span className={s.flow} data-still={run.queued ? "true" : undefined}>
              {run.queued
                ? "Waiting for a turn — other jobs are working"
                : run.live_text
                  ? "Writing…"
                  : (run.helpers ?? []).some((h) => h.state === "working")
                    ? `${plural((run.helpers ?? []).filter((h) => h.state === "working").length, "helper")} researching`
                    : run.steps.length
                      ? `Reading your context · ${plural(run.steps.length, "note")} so far`
                      : "Reading your context…"}
            </span>
            {run.mine !== false && <StopButton onStop={() => onStop(run.id)} />}
          </div>
          {(run.helpers ?? []).length > 0 && (
            <ul className={s.helpers}>
              {run.helpers!.map((h) => (
                <li key={h.id} data-state={h.state}>
                  <i />
                  <span>{h.task || "Researching"}</span>
                </li>
              ))}
            </ul>
          )}
          {run.live_text && (
            <div className={s.answer} data-live="true">
              {run.live_text.split(/\n{2,}/).map((line, i, all) => (
                <div key={i} className={s.para} data-caret={i === all.length - 1 ? "true" : undefined}>
                  <Markdown text={line} />
                </div>
              ))}
            </div>
          )}
        </>
      ) : (
        run.steps.length > 0 && (
          <button
            className={s.disclosure}
            aria-expanded={details}
            onClick={(e) => {
              e.stopPropagation();
              setDetails((v) => !v);
            }}
          >
            <svg width="8" height="8" viewBox="0 0 8 8" aria-hidden>
              <path d="M2.5 1.5 5.5 4l-3 2.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            {readOf(run)}
          </button>
        )
      )}

      {details && !live && (
        <div className={s.details} onClick={(e) => e.stopPropagation()}>
          <ol className={s.steps}>
            {run.steps.map((x, i) => (
              <li key={i} data-ok={x.ok ? undefined : "false"}>
                <span className={s.stepKind}>{STEP_LABEL[x.tool] ?? x.tool}</span>
                <span className={s.stepWhat}>
                  {x.what}
                  {x.apps?.length ? <em className={s.stepFrom}> · from {x.apps.map(appName).join(", ")}</em> : null}
                </span>
                {x.ms != null && <span className={s.stepMs}>{x.ms < 1000 ? `${x.ms} ms` : `${(x.ms / 1000).toFixed(1)} s`}</span>}
              </li>
            ))}
          </ol>
          <div className={s.detailFoot}>
            <span>{plural(run.credits, "credit")}</span>
            <button onClick={() => onReplay(run.id)}>Replay on canvas</button>
            {run.delivery !== "asked" &&
              (share ? (
                <>
                  <button onClick={() => copy(share.url)}>{share.copied ? "Link copied" : "Copy link"}</button>
                  <button
                    onClick={async () => {
                      await onUnshare(run.id);
                      setShare(null);
                    }}
                  >
                    Stop sharing
                  </button>
                </>
              ) : (
                <button
                  disabled={busy === "share"}
                  onClick={async () => {
                    setBusy("share");
                    try {
                      await copy(await onShare(run.id));
                    } finally {
                      setBusy(null);
                    }
                  }}
                >
                  Share
                </button>
              ))}
          </div>
          {share && <p className={s.fine}>The link shows counts only — never what was asked or answered.</p>}
        </div>
      )}

      {lace.lines.length > 0 && (
        <div className={s.answer} onPointerLeave={() => shown && onHoverLine(null)}>
          {lace.lines.map((line, i) => (
            <div
              key={i}
              className={s.para}
              data-lit={litLines ? (litLines.has(i) ? "true" : "false") : undefined}
              data-sourced={perLine && lace.sources[i]?.length ? "true" : undefined}
              onPointerEnter={perLine ? () => onHoverLine(i) : undefined}
            >
              <Markdown text={line} />
            </div>
          ))}
        </div>
      )}

      {lace.questions && (
        <section className={s.ask} onClick={(e) => e.stopPropagation()}>
          <p className={s.askHead}>{run.delivery === "asked" ? "Before starting, Cookie asks" : "Cookie asked first"}</p>
          <ul>
            {lace.questions.map((q, i) => (
              <li key={i}>{q}</li>
            ))}
          </ul>
          {run.delivery === "asked" && (
            <form
              onSubmit={async (e) => {
                e.preventDefault();
                const text = reply.trim();
                if (!text) return;
                setBusy("answer");
                setReplyErr(null);
                try {
                  await onAnswer(run.id, text);
                  setReply("");
                } catch (err) {
                  setReplyErr(err instanceof Error ? err.message : "Cookie didn't get that.");
                } finally {
                  setBusy(null);
                }
              }}
            >
              <textarea value={reply} onChange={(e) => setReply(e.target.value)} placeholder="Your answers…" rows={3} disabled={busy === "answer"} aria-label="Answer Cookie" />
              <div className={s.actions}>
                <button className={s.primary} type="submit" disabled={!!busy || !reply.trim()}>
                  {busy === "answer" ? "Starting…" : "Answer and start"}
                </button>
                {replyErr && <span className={s.err}>{replyErr}</span>}
              </div>
            </form>
          )}
        </section>
      )}

      {lace.draft && (
        <section className={s.ask} onClick={(e) => e.stopPropagation()}>
          <p className={s.askHead}>{lace.draft.slack ? "Reply for the Slack thread" : `Reply to ${lace.draft.to.join(", ")}`} · waiting for you</p>
          <div className={s.draft}>
            <Markdown text={lace.draft.body} />
          </div>
          <div className={s.actions}>
            <button className={s.primary} disabled={!!busy} onClick={() => decide(lace.draft!, "send")}>
              {busy === "send" ? "Sending…" : lace.draft.slack ? "Post in thread" : "Send"}
            </button>
            {!lace.draft.slack && (
              <button disabled={!!busy} onClick={() => decide(lace.draft!, "take_over")}>
                Edit in mail
              </button>
            )}
            <button disabled={!!busy} onClick={() => decide(lace.draft!, "skip")}>
              Skip
            </button>
          </div>
        </section>
      )}

      {pending.length > 1 && (
        <div className={s.actions} onClick={(e) => e.stopPropagation()}>
          <button
            className={s.primary}
            disabled={!!busy}
            onClick={async () => {
              setBusy("yes:all");
              try {
                for (const a of pending) await onApproval(a.id, true);
              } finally {
                setBusy(null);
              }
            }}
          >
            {busy === "yes:all" ? "Doing them…" : `Yes to all ${pending.length}`}
          </button>
        </div>
      )}

      {changes.map(({ action, approval }, i) => {
        const done = changeOutcome(action, approval, appName);
        const pendingNow = approval?.status === "pending";
        const held = pendingNow && approval?.run_after ? approval.run_after : null;
        const waiting = pendingNow && !held;
        return (
          <section key={approval?.id ?? i} className={s.ask} data-quiet={pendingNow ? undefined : "true"} onClick={(e) => e.stopPropagation()}>
            <p className={s.askHead}>
              {appName(action.app)} · {actionLabel(action.app, action.name)}
              {waiting ? " · waiting for your yes" : ""}
              {held ? ` · goes out at ${new Date(held).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : ""}
            </p>
            {pendingNow && action.why && <p className={s.changeWhy}>{held ? "Not sent yet — you can undo it until then." : `Waiting because ${action.why}.`}</p>}
            {(action.diff ?? []).length > 0 ? (
              <dl className={s.diff}>
                {action.diff!.map((d) => (
                  <div key={d.field}>
                    <dt>{d.field}</dt>
                    <dd>
                      <del>{d.before == null ? "—" : String(d.before)}</del>
                      <span aria-hidden>→</span>
                      <ins>{String(d.after ?? "")}</ins>
                    </dd>
                  </div>
                ))}
              </dl>
            ) : (
              pendingNow && approval?.detail && <pre className={s.change}>{approval.detail}</pre>
            )}
            {held && approval ? (
              <div className={s.actions}>
                <button
                  className={s.primary}
                  disabled={!!busy}
                  onClick={async () => {
                    setBusy(`undo:${approval.id}`);
                    try {
                      await onApproval(approval.id, false);
                    } finally {
                      setBusy(null);
                    }
                  }}
                >
                  {busy === `undo:${approval.id}` ? "Undoing…" : "Undo"}
                </button>
                <button
                  disabled={!!busy}
                  onClick={async () => {
                    setBusy(`now:${approval.id}`);
                    try {
                      await onApproval(approval.id, true);
                    } finally {
                      setBusy(null);
                    }
                  }}
                >
                  Send now
                </button>
              </div>
            ) : waiting && approval ? (
              <div className={s.actions}>
                <button
                  className={s.primary}
                  disabled={!!busy}
                  onClick={async () => {
                    setBusy(`yes:${approval.id}`);
                    try {
                      await onApproval(approval.id, true);
                    } finally {
                      setBusy(null);
                    }
                  }}
                >
                  {busy === `yes:${approval.id}` ? "Doing it…" : "Yes, do it"}
                </button>
                <button
                  disabled={!!busy}
                  onClick={async () => {
                    setBusy(`no:${approval.id}`);
                    try {
                      await onApproval(approval.id, false);
                    } finally {
                      setBusy(null);
                    }
                  }}
                >
                  No
                </button>
                {signedIn && (
                  <button
                    disabled={!!busy}
                    title={`From now on, Cookie does ${actionLabel(action.app, action.name).toLowerCase()} in ${appName(action.app)} without asking you. Remove it any time in Settings.`}
                    onClick={async () => {
                      setBusy(`always:${approval.id}`);
                      try {
                        await onApproval(approval.id, true, true);
                      } finally {
                        setBusy(null);
                      }
                    }}
                  >
                    {busy === `always:${approval.id}` ? "Doing it…" : "Yes, always"}
                  </button>
                )}
              </div>
            ) : (
              done && (
                <div className={s.changeEnd}>
                  <p className={s.changeDone}>{undone[action.journal ?? ""] ?? done}</p>
                  {action.journal && action.undo && (action.state === "done" || approval?.status === "approved") && !undone[action.journal] && (
                    <button
                      disabled={!!busy}
                      onClick={async () => {
                        const id = action.journal!;
                        setBusy(`revert:${id}`);
                        try {
                          const r = await onUndo(id);
                          setUndone((u) => ({ ...u, [id]: r.state === "kept" ? `Left as it is — ${r.why ?? "it changed since"}` : r.state === "undone" ? "Deleted again — undone" : "Put back as it was" }));
                        } catch (e) {
                          setUndone((u) => ({ ...u, [id]: e instanceof Error ? e.message : "Couldn't undo it" }));
                        } finally {
                          setBusy(null);
                        }
                      }}
                    >
                      {busy === `revert:${action.journal}` ? "Undoing…" : action.undo === "delete" ? "Undo — delete it" : "Undo — put it back"}
                    </button>
                  )}
                </div>
              )
            )}
          </section>
        );
      })}

      {chase && (
        <div className={s.chase} onClick={(e) => e.stopPropagation()}>
          <span>{chaseLine(chase)}</span>
          {["pending", "waiting", "nudged"].includes(chase.state) && (
            <button
              disabled={busy === `chase:${chase.id}`}
              onClick={async () => {
                setBusy(`chase:${chase.id}`);
                try {
                  await onStopChase(chase.id);
                } finally {
                  setBusy(null);
                }
              }}
            >
              {busy === `chase:${chase.id}` ? "Stopping…" : "Stop following up"}
            </button>
          )}
        </div>
      )}

      {!live && run.block && BLOCK[run.block] && <p className={s.outcome} data-warn="true">{BLOCK[run.block]}</p>}
      {!live && run.answer && run.steps.some((x) => x.tool === "check" && x.verification === "unavailable") && (
        <p className={s.outcome}>Not checked against its sources this time — the check couldn&apos;t run.</p>
      )}

      {!live && outcome && !(lace.draft && run.delivery === "drafted") && !(lace.questions && run.delivery === "asked") && (
        <p className={s.outcome} data-warn={run.delivery === "out_of_credits" || (run.delivery === "failed" && !run.answer) ? "true" : undefined}>
          {outcome}
        </p>
      )}
    </div>
  );
}

function Settings({
  overview,
  onSetPin,
  onSlack,
  onSignOut,
  onLesson,
  onPermission,
  onRule,
  onPrefs,
  onChannel,
  onRoutine,
  onSoul,
}: {
  overview: CookieOverview;
  onRoutine: (routineId: string, action: "accept" | "decline" | "pause" | "resume") => Promise<void>;
  onSoul: (text: string) => Promise<void>;
  onSetPin: (pin: string) => Promise<void>;
  onSlack: (action: "add" | "remove") => Promise<void>;
  onSignOut?: () => Promise<void>;
  onLesson: (lessonId: string, state: "active" | "archived") => Promise<void>;
  onPermission: (level: CookiePermission) => Promise<void>;
  onRule: (change: { set?: Omit<CookieRule, "id">; remove?: string }) => Promise<void>;
  onPrefs: (prefs: CookiePrefs) => Promise<void>;
  onChannel: (channel: string, link: boolean) => Promise<{ code: string; minutes: number } | null>;
}) {
  const [pin, setPin] = useState("");
  const [pinNote, setPinNote] = useState<{ ok: boolean; text: string } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const { allowance, used, saves = 0 } = overview.credits;
  const left = Math.max(0, allowance - used);
  const share = allowance > 0 ? Math.min(1, used / allowance) : 1;
  // How much Cookie went to each place in the last 7 days, in words; only what it did.
  const week = (() => {
    const p = overview.paths;
    if (!p) return "";
    const n = (v: number, one: string, many: string) => `${v.toLocaleString()} ${v === 1 ? one : many}`;
    return [
      p.context > 0 && n(p.context, "lookup in your context", "lookups in your context"),
      p.web > 0 && n(p.web, "web search or page read", "web searches and pages read"),
      p.email > 0 && n(p.email, "job by email", "jobs by email"),
      p.slack > 0 && n(p.slack, "job from Slack", "jobs from Slack"),
      p.saves > 0 && n(p.saves, "save to your context", "saves to your context"),
    ]
      .filter(Boolean)
      .join(" · ");
  })();
  const now = new Date();
  const resets = new Date(now.getFullYear(), now.getMonth() + 1, 1).toLocaleDateString([], { day: "numeric", month: "long" });
  const console_ = overview.viewer?.via === "console";

  return (
    <div className={s.scroll}>
      <div className={s.settings}>
        <Soul text={overview.viewer?.soul ?? ""} signedIn={console_} onSoul={onSoul} />
        {overview.viewer?.permission && <Permission level={overview.viewer.permission} signedIn={console_} onPermission={onPermission} />}
        {overview.viewer?.permission && <Rules rules={overview.viewer.rules ?? []} onRule={onRule} />}
        {overview.viewer?.prefs && <NoticePrefs prefs={overview.viewer.prefs} onPrefs={onPrefs} />}
        {(overview.viewer?.channels ?? []).length > 0 && <ChatApps channels={overview.viewer!.channels!} signedIn={console_} onChannel={onChannel} />}

        <p className={s.groupLabel}>Credits</p>
        <div className={s.group}>
          <div className={s.row}>
            <div className={s.rowText}>
              <b>
                {left.toLocaleString()} <span>of {allowance.toLocaleString()} left</span>
              </b>
              <div className={s.bar} data-tone={share >= 1 ? "out" : share >= 0.8 ? "low" : undefined}>
                <span style={{ width: `${(1 - share) * 100}%` }} />
              </div>
              <em>
                Resets {resets}. {saves > 0 ? `${saves.toLocaleString()} of the ${used.toLocaleString()} used went to saving to your context.` : ""}
              </em>
            </div>
          </div>
          {week && (
            <div className={s.row}>
              <div className={s.rowText}>
                <b>This week</b>
                <em>{week}</em>
              </div>
            </div>
          )}
        </div>

        {(overview.routines ?? []).some((r) => r.state === "active" || r.state === "paused") && (
          <Routines routines={overview.routines!.filter((r) => r.state === "active" || r.state === "paused")} onRoutine={onRoutine} />
        )}
        {(overview.lessons ?? []).length > 0 && <Learned lessons={overview.lessons!} onLesson={onLesson} />}

        <p className={s.groupLabel}>Email</p>
        <div className={s.group}>
          <div className={s.row}>
            <div className={s.rowText}>
              <b>{overview.address ?? "No address yet"}</b>
              <em>Email Cookie a job from the address you use for this team. It answers in the same thread.</em>
            </div>
            {overview.address && (
              <button
                onClick={() =>
                  navigator.clipboard?.writeText(overview.address!).then(() => {
                    setCopied(true);
                    setTimeout(() => setCopied(false), 1400);
                  })
                }
              >
                {copied ? "Copied" : "Copy"}
              </button>
            )}
          </div>
        </div>

        <p className={s.groupLabel}>Sign-in</p>
        <div className={s.group}>
          {console_ ? (
            <form
              className={s.row}
              onSubmit={async (e) => {
                e.preventDefault();
                setBusy("pin");
                setPinNote(null);
                try {
                  await onSetPin(pin);
                  setPin("");
                  setPinNote({ ok: true, text: "Saved. Links from Cookie open with it." });
                } catch (err) {
                  setPinNote({ ok: false, text: err instanceof Error ? err.message : "That PIN wasn't saved." });
                } finally {
                  setBusy(null);
                }
              }}
            >
              <div className={s.rowText}>
                <b>Your PIN</b>
                <em>{overview.viewer?.pin_set ? "Set. Links from Cookie's mail and Slack ask for it." : "Not set. Links from Cookie need one."}</em>
                {pinNote && <em className={pinNote.ok ? undefined : s.err}>{pinNote.text}</em>}
              </div>
              <input
                className={s.pin}
                value={pin}
                onChange={(e) => setPin(e.target.value.replace(/\D/g, "").slice(0, 6))}
                inputMode="numeric"
                autoComplete="new-password"
                placeholder="••••••"
                aria-label="Six-digit PIN"
              />
              <button type="submit" disabled={busy === "pin" || pin.length !== 6}>
                {overview.viewer?.pin_set ? "Change" : "Set"}
              </button>
            </form>
          ) : (
            <div className={s.row}>
              <div className={s.rowText}>
                <b>Opened with your PIN</b>
                <em>This browser can open this team&apos;s Cookie for 30 days.</em>
              </div>
              {onSignOut && <button onClick={() => void onSignOut()}>Sign out</button>}
            </div>
          )}
        </div>

        {overview.slack?.available && (
          <>
            <p className={s.groupLabel}>Slack</p>
            <div className={s.group}>
              <div className={s.row}>
                <span className={s.src}>
                  <img src="/connectors/color_slack.svg" alt="" width={16} height={16} />
                </span>
                <div className={s.rowText}>
                  <b>{overview.slack.workspace ?? "Not added"}</b>
                  <em>
                    {overview.slack.workspace
                      ? "Mention @Cookie in a channel or DM it. It answers in the thread."
                      : "Add Cookie and mention @Cookie in any channel."}
                  </em>
                </div>
                {console_ ? (
                  <button
                    disabled={busy === "slack"}
                    onClick={async () => {
                      setBusy("slack");
                      try {
                        await onSlack(overview.slack!.workspace ? "remove" : "add");
                      } finally {
                        setBusy(null);
                      }
                    }}
                  >
                    {overview.slack.workspace ? "Remove" : "Add to Slack"}
                  </button>
                ) : null}
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

const CUE_KIND: Record<string, string> = {
  conflict: "Contradicts a decision",
  past_due: "Past its day",
  due_soon: "Coming due",
  plan_cue: "Someone is owed something",
};
const cueKind = (k: string) => CUE_KIND[k] ?? k.charAt(0).toUpperCase() + k.slice(1).replace(/_/g, " ");

const LABEL_SAID: Record<string, string> = { useful: "Useful", not_useful: "Not useful", wrong: "Wrong" };

/** What Cookie noticed in the team's brain, watch-only: each waits for a label. */
const LEVELS: { level: CookiePermission; title: string; text: string }[] = [
  { level: "ask", title: "Ask me first", text: "Every change waits for your yes." },
  {
    level: "smart",
    title: "Let Cookie judge",
    text: "Cookie makes the changes you clearly asked for and asks about the rest. Anything sent outside your team, and anything deleted, still waits for you.",
  },
  {
    level: "full",
    title: "Full permission",
    text: "Cookie does everything without asking, sending and deleting included. You see each change in the job after it happens.",
  },
];

/** How much Cookie may do in the member's apps before it asks them. */
function Permission({
  level,
  signedIn,
  onPermission,
}: {
  level: CookiePermission;
  signedIn: boolean;
  onPermission: (level: CookiePermission) => Promise<void>;
}) {
  const [busy, setBusy] = useState<CookiePermission | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const rank = (l: CookiePermission) => LEVELS.findIndex((x) => x.level === l);
  return (
    <>
      <p className={s.groupLabel}>In your apps</p>
      <div className={s.group} role="radiogroup" aria-label="What Cookie may do in your apps">
        {LEVELS.map((l) => {
          const on = l.level === level;
          // A PIN session can take room away, never give more.
          const locked = !signedIn && rank(l.level) > rank(level);
          return (
            <button
              key={l.level}
              role="radio"
              aria-checked={on}
              className={s.choice}
              data-on={on ? "true" : undefined}
              disabled={!!busy || locked}
              onClick={async () => {
                if (on) return;
                setBusy(l.level);
                setErr(null);
                try {
                  await onPermission(l.level);
                } catch (e) {
                  setErr(e instanceof Error ? e.message : "That wasn't saved.");
                } finally {
                  setBusy(null);
                }
              }}
            >
              <span className={s.rowText}>
                <b>{l.title}</b>
                <em>{locked ? "Sign in to Enkeon to choose this." : l.text}</em>
              </span>
              <span className={s.tick} aria-hidden>
                {busy === l.level ? "…" : on ? "✓" : ""}
              </span>
            </button>
          );
        })}
      </div>
      {err && <p className={`${s.choiceErr} ${s.err}`}>{err}</p>}
    </>
  );
}

/** Chat apps the member can give Cookie jobs from: link with a one-time code, or unlink. */
function ChatApps({
  channels,
  signedIn,
  onChannel,
}: {
  channels: { channel: string; linked: boolean; bot?: string }[];
  signedIn: boolean;
  onChannel: (channel: string, link: boolean) => Promise<{ code: string; minutes: number } | null>;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [code, setCode] = useState<{ channel: string; code: string; minutes: number } | null>(null);
  const how = (c: string, bot?: string) =>
    c === "telegram"
      ? `Send /start ${code?.code} to ${bot ? `@${bot.replace(/^@/, "")}` : "Cookie's Telegram bot"}.`
      : c === "discord"
        ? `In Discord, type /cookie-link and the code ${code?.code}.`
        : `Send ${code?.code} to Cookie in ${CHAT_APPS[c] ?? c}.`;
  return (
    <>
      <p className={s.groupLabel}>Chat apps</p>
      <div className={s.group}>
        {channels.map((c) => (
          <div key={c.channel} className={s.row}>
            <div className={s.rowText}>
              <b>{CHAT_APPS[c.channel] ?? c.channel}</b>
              <em>
                {c.linked
                  ? "Linked. Give Cookie jobs there; answers come back only to you."
                  : code?.channel === c.channel
                    ? `${how(c.channel, c.bot)} The code works for ${code.minutes} minutes.`
                    : signedIn
                      ? "Not linked."
                      : "Sign in to Enkeon to link it."}
              </em>
            </div>
            <button
              disabled={!!busy || (!c.linked && !signedIn)}
              onClick={async () => {
                setBusy(c.channel);
                try {
                  const got = await onChannel(c.channel, !c.linked);
                  setCode(got ? { channel: c.channel, ...got } : null);
                } finally {
                  setBusy(null);
                }
              }}
            >
              {busy === c.channel ? "…" : c.linked ? "Unlink" : "Link"}
            </button>
          </div>
        ))}
      </div>
    </>
  );
}

const HOURS = Array.from({ length: 24 }, (_, h) => h);
const hourLabel = (h: number) => `${String(h).padStart(2, "0")}:00`;

/** When Cookie's notices reach the member — by Slack or mail — and whether at all. */
function NoticePrefs({ prefs, onPrefs }: { prefs: CookiePrefs; onPrefs: (prefs: CookiePrefs) => Promise<void> }) {
  const [busy, setBusy] = useState(false);
  const save = async (change: Partial<CookiePrefs>) => {
    setBusy(true);
    try {
      // The browser's own offset, so quiet hours are in the member's time.
      await onPrefs({ ...prefs, ...change, tz_offset_min: -new Date().getTimezoneOffset() });
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <p className={s.groupLabel}>Notices</p>
      <div className={s.group}>
        <div className={s.row}>
          <div className={s.rowText}>
            <b>{prefs.notices ? "Cookie tells you" : "Off"}</b>
            <em>When Cookie notices something in your team&apos;s context, it tells you in Slack or by mail, three times a day at most. Reply and it looks into it.</em>
          </div>
          <button disabled={busy} onClick={() => save({ notices: !prefs.notices })}>
            {prefs.notices ? "Turn off" : "Turn on"}
          </button>
        </div>
        {prefs.notices && (
          <div className={s.row}>
            <div className={s.rowText}>
              <b>Quiet hours</b>
              <em>Nothing is sent between these hours, your time.</em>
              <span className={s.ruleInputs}>
                <Select
                  label="Quiet from"
                  value={prefs.quiet_from}
                  disabled={busy}
                  options={HOURS.map((h) => ({ value: h, label: `From ${hourLabel(h)}` }))}
                  onChange={(h) => save({ quiet_from: h })}
                />
                <Select
                  label="Quiet until"
                  value={prefs.quiet_to}
                  disabled={busy}
                  options={HOURS.map((h) => ({ value: h, label: `Until ${hourLabel(h)}` }))}
                  onChange={(h) => save({ quiet_to: h })}
                />
              </span>
            </div>
          </div>
        )}
      </div>
    </>
  );
}

/** The member's own rules: what Cookie never does, and what it always does without asking. */
function Rules({ rules, onRule }: { rules: CookieRule[]; onRule: (change: { set?: Omit<CookieRule, "id">; remove?: string }) => Promise<void> }) {
  const [app, setApp] = useState("");
  const [action, setAction] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const run = async (key: string, change: { set?: Omit<CookieRule, "id">; remove?: string }) => {
    setBusy(key);
    setErr(null);
    try {
      await onRule(change);
      if (change.set) {
        setApp("");
        setAction("");
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : "That wasn't saved.");
    } finally {
      setBusy(null);
    }
  };
  return (
    <>
      <p className={s.groupLabel}>Your rules</p>
      <div className={s.group}>
        {rules.map((r) => (
          <div key={r.id} className={s.row}>
            <div className={s.rowText}>
              <b>
                {r.rule === "deny" ? "Never" : "Always, without asking"} <span>· {appName(r.app)}</span>
              </b>
              <em>{r.action === "*" ? "Every action" : r.action.endsWith("*") ? `Every action starting ${r.action.slice(0, -1)}` : actionLabel(r.app, r.action)}</em>
            </div>
            <button disabled={!!busy} onClick={() => run(r.id, { remove: r.id })}>
              {busy === r.id ? "…" : "Remove"}
            </button>
          </div>
        ))}
        <form
          className={s.row}
          onSubmit={(e) => {
            e.preventDefault();
            if (app.trim() && action.trim()) run("new", { set: { app: app.trim().toLowerCase(), action: action.trim().toUpperCase(), rule: "deny" } });
          }}
        >
          <div className={s.rowText}>
            <b>Never let Cookie…</b>
            <em>An app and an action name, or a start of one ending in *. Holds at every level, Full included.</em>
            <span className={s.ruleInputs}>
              <input className={s.ruleInput} placeholder="App, e.g. hubspot" value={app} onChange={(e) => setApp(e.target.value)} aria-label="App" />
              <input className={s.ruleInput} placeholder="Action, e.g. HUBSPOT_DELETE_*" value={action} onChange={(e) => setAction(e.target.value)} aria-label="Action" />
              <button type="submit" className={s.ruleAdd} disabled={!!busy || !app.trim() || !action.trim()}>
                {busy === "new" ? "…" : "Add"}
              </button>
            </span>
          </div>
        </form>
      </div>
      {err && <p className={`${s.choiceErr} ${s.err}`}>{err}</p>}
    </>
  );
}

/** The team's own words about how Cookie should be — its voice and what to care about. */
function Soul({ text, signedIn, onSoul }: { text: string; signedIn: boolean; onSoul: (text: string) => Promise<void> }) {
  const [draft, setDraft] = useState(text);
  const [state, setState] = useState<"idle" | "saving" | "saved" | string>("idle");
  useEffect(() => setDraft(text), [text]);
  const changed = draft.trim() !== text.trim();
  const left = 2000 - draft.length;
  return (
    <>
      <p className={s.groupLabel}>How Cookie should be</p>
      <div className={s.group}>
        <div className={s.row}>
          <div className={s.rowText}>
            <em>In your team&apos;s own words: how Cookie should sound, what it should care about, what it should never do. Every job reads it. Your permission settings still decide what it may change.</em>
            <textarea
              className={s.soul}
              value={draft}
              maxLength={2000}
              disabled={!signedIn || state === "saving"}
              placeholder={"e.g. Be blunt and warm. We sell to CTOs of Baltic product companies. When I'm stuck, give me the next concrete thing — drafts, not advice."}
              onChange={(e) => {
                setDraft(e.target.value);
                setState("idle");
              }}
              aria-label="How Cookie should be"
            />
            <span className={s.soulBar}>
              <i>{!signedIn ? "Sign in to Enkeon to change it." : state === "saved" ? "Saved — the next job reads it." : state !== "idle" && state !== "saving" ? state : left < 200 ? `${left} characters left` : ""}</i>
              <button
                className={s.ruleAdd}
                disabled={!signedIn || !changed || state === "saving"}
                onClick={async () => {
                  setState("saving");
                  try {
                    await onSoul(draft);
                    setState("saved");
                  } catch (e) {
                    setState(e instanceof Error ? e.message : "Couldn't save it.");
                  }
                }}
              >
                {state === "saving" ? "Saving…" : "Save"}
              </button>
            </span>
          </div>
        </div>
      </div>
    </>
  );
}

const WEEKDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
/** "every Monday at 9:00" / "every day at 9:00", in the person's own time. */
function whenOf(r: CookieRoutine): string {
  const at = `${r.hour}:${String(r.minute).padStart(2, "0")}`;
  return r.cadence === "daily" ? `every day at ${at}` : `every ${WEEKDAY[((r.weekday % 7) + 7) % 7]} at ${at}`;
}

/** A job given again and again, offered once as a routine. */
function Offers({ routines, onRoutine }: { routines: CookieRoutine[]; onRoutine: (id: string, action: "accept" | "decline") => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null);
  const answer = async (id: string, action: "accept" | "decline") => {
    setBusy(`${action}:${id}`);
    try {
      await onRoutine(id, action);
    } finally {
      setBusy(null);
    }
  };
  return (
    <section className={s.noticed} aria-label="Routines Cookie can take on">
      <p className={s.noticedHead}>A routine?</p>
      <ul className={s.noticedList}>
        {routines.map((r) => (
          <li key={r.id} className={s.notice}>
            <div className={s.noticeTop}>
              <b>Want me to do this {whenOf(r)}?</b>
              <span>You asked for it {plural(r.seen, "time")} around then.</span>
            </div>
            <p className={s.noticeWhy}>“{r.job}”</p>
            <div className={s.actions}>
              <button className={s.primary} disabled={!!busy} onClick={() => answer(r.id, "accept")}>
                {busy === `accept:${r.id}` ? "Setting it up…" : "Yes, every time"}
              </button>
              <button disabled={!!busy} onClick={() => answer(r.id, "decline")}>
                No thanks
              </button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** The routines a member keeps, to pause or resume. */
function Routines({ routines, onRoutine }: { routines: CookieRoutine[]; onRoutine: (id: string, action: "pause" | "resume") => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null);
  return (
    <>
      <p className={s.groupLabel}>Routines</p>
      <div className={s.group}>
        {routines.map((r) => (
          <div key={r.id} className={s.row} data-dim={r.state === "paused" ? "true" : undefined}>
            <div className={s.rowText}>
              <b className={s.lessonText}>{r.job}</b>
              <em>
                {r.state === "paused" ? "Paused" : `${whenOf(r)[0].toUpperCase()}${whenOf(r).slice(1)}`}
                {r.state === "active" && r.next_run_at ? ` · next ${new Date(r.next_run_at).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" })}` : ""}
              </em>
            </div>
            <button
              disabled={busy === r.id}
              onClick={async () => {
                setBusy(r.id);
                try {
                  await onRoutine(r.id, r.state === "paused" ? "resume" : "pause");
                } finally {
                  setBusy(null);
                }
              }}
            >
              {busy === r.id ? "…" : r.state === "paused" ? "Resume" : "Pause"}
            </button>
          </div>
        ))}
      </div>
    </>
  );
}

function Noticed({ notices, onNotice }: { notices: CookieNotice[]; onNotice: (id: string, label: "useful" | "not_useful" | "wrong") => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null);
  const label = async (id: string, l: "useful" | "not_useful" | "wrong") => {
    setBusy(id);
    try {
      await onNotice(id, l);
    } finally {
      setBusy(null);
    }
  };
  return (
    <section className={s.noticed} aria-label="Cookie noticed">
      <p className={s.noticedHead}>Cookie noticed</p>
      <p className={s.noticedLead}>Cookie brings these up at a quiet moment and never acts on them by itself. Tell it whether each was worth your attention.</p>
      <ul className={s.noticedList}>
        {notices.map((n) => (
          <li key={n.id} className={s.notice} data-labelled={n.label ? "true" : undefined}>
            <div className={s.noticeTop}>
              <b>{n.title}</b>
              <span>
                {n.hard ? "Needs a look" : "Built up"} · {dayOf(n.released_at ?? n.created_at)}, {timeOf(n.released_at ?? n.created_at)}
              </span>
            </div>
            {n.why_now && <p className={s.noticeWhy}>{n.why_now}</p>}
            <ul className={s.cues}>
              {n.cues.slice(-3).map((c) => (
                <li key={c.id}>
                  <em>{cueKind(c.kind)}</em> {c.why}
                  {c.outside ? <span className={s.cueFrom}> · from a synced app</span> : null}
                </li>
              ))}
              {n.cues.length > 3 && <li className={s.cueMore}>and {plural(n.cues.length - 3, "more signal")}</li>}
            </ul>
            {n.label ? (
              <p className={s.noticeSaid}>You said: {LABEL_SAID[n.label] ?? n.label}</p>
            ) : (
              <div className={s.actions}>
                <button className={s.primary} disabled={busy === n.id} onClick={() => label(n.id, "useful")}>
                  Useful
                </button>
                <button disabled={busy === n.id} onClick={() => label(n.id, "not_useful")}>
                  Not useful
                </button>
                <button disabled={busy === n.id} onClick={() => label(n.id, "wrong")}>
                  Wrong
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

/** What Cookie learned: each lesson with its record, archive / restore. */
function Learned({ lessons, onLesson }: { lessons: CookieLesson[]; onLesson: (id: string, state: "active" | "archived") => Promise<void> }) {
  const [busy, setBusy] = useState<string | null>(null);
  const set = async (id: string, state: "active" | "archived") => {
    setBusy(id);
    try {
      await onLesson(id, state);
    } finally {
      setBusy(null);
    }
  };
  return (
    <>
      <p className={s.groupLabel}>What Cookie learned</p>
      <div className={s.group}>
        {lessons.map((l) => {
          const record = l.wins + l.losses === 0 ? "Not used yet" : `${plural(l.wins, "clean job")} · ${plural(l.losses, "miss", "misses")}`;
          const state = l.state === "archived" ? "Archived" : l.state === "quiet" ? "Resting — unused for two weeks" : l.shared ? "Shared with your context" : null;
          return (
            <div key={l.id} className={s.row} data-dim={l.state === "archived" ? "true" : undefined}>
              <div className={s.rowText}>
                <b className={s.lessonText}>{l.text}</b>
                <em>
                  For {l.cue}. {record}.
                  {l.kind === "procedure" ? ` A procedure written from proven lessons${l.version && l.version > 1 ? `, version ${l.version}` : ""}.` : ""}
                  {l.learned_from === "from_correction"
                    ? " Learned from your correction."
                    : l.learned_from === "from_failure"
                      ? " Learned from a job that went wrong, compared with one that went well."
                      : ""}
                  {l.outside ? " Learned while reading outside your team, so it stays out of your context." : ""}
                  {state ? ` ${state}.` : ""}
                </em>
              </div>
              <button disabled={busy === l.id} onClick={() => set(l.id, l.state === "archived" ? "active" : "archived")}>
                {l.state === "archived" ? "Restore" : "Archive"}
              </button>
            </div>
          );
        })}
      </div>
      <p className={s.fine}>Cookie keeps a lesson only while the jobs it helps end clean, and sometimes works without it to check.</p>
    </>
  );
}
