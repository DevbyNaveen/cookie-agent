"use client";

// Cookie's work, as conversations: a sheet on the left, always there, the
// same material as the panel on the right. At its top, Cookie and what it is
// doing; then every conversation, from email, Slack, a chat app, an AI tool
// or this page, the most recent first, with what is still open on top. Yours
// by default; Team adds your teammates' — who asked, where, and how it ended,
// never what Cookie found for them. Pick one and the page becomes it: its
// board, its chat. A new conversation starts from the chat.

import { useMemo, useState } from "react";
import type { CookieNotice, CookieRun } from "@/lib/api";
import { CookieOrb } from "@/components/central/CookieOrb";
import { doingOf, titleOf, type Thread } from "./threads";
import s from "./Conversations.module.css";

const ago = (iso: string) => {
  const m = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60000));
  if (m < 1) return "now";
  if (m < 60) return `${m}m`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h}h`;
  const d = new Date(iso);
  return h < 48 ? "yesterday" : d.toLocaleDateString([], { day: "numeric", month: "short" });
};

type Icon = "working" | "queued" | "sent" | "answered" | "thread" | "draft" | "asked" | "quiet" | "failed";

/** Still open: working, waiting for its turn, or waiting for you. */
export const isOpen = (r: CookieRun, waiting: Set<string>) => r.status === "running" || r.delivery === "asked" || waiting.has(r.id);

/** How a job ended, in a few words, and the small live icon that says it. */
function endOf(r: CookieRun, waiting: boolean): { text: string; tone?: "wait" | "bad"; icon: Icon } {
  if (r.status === "running" && r.queued) return { text: "Waiting for a turn", tone: "wait", icon: "queued" };
  if (r.status === "running") return { text: "Working", icon: "working" };
  if (r.delivery === "asked") return { text: "Asked you first", tone: "wait", icon: "asked" };
  if (waiting) return { text: "Draft waiting", tone: "wait", icon: "draft" };
  switch (r.delivery) {
    case "replied":
      return r.trigger === "slack"
        ? { text: "In the thread", icon: "thread" }
        : r.trigger === "email"
          ? { text: "Replied", icon: "sent" }
          : { text: "Answered", icon: "answered" };
    case "answered":
      return { text: "You answered", icon: "answered" };
    case "silent":
      return { text: "Stayed quiet", icon: "quiet" };
    case "stopped":
      return { text: "You stopped it", icon: "quiet" };
    case "steered":
      return { text: "Added to the job", icon: "answered" };
    case "paused":
      return { text: "Paused here", tone: "wait", icon: "quiet" };
    case "refused":
      return { text: "Not from the team", tone: "bad", icon: "failed" };
    case "out_of_credits":
      return { text: "Out of credits", tone: "bad", icon: "failed" };
    default:
      return r.answer ? { text: "Answered", icon: "answered" } : { text: "Couldn't finish", tone: "bad", icon: "failed" };
  }
}

/**
 * A live status icon. What waits for you keeps moving (a pen writing, a
 * question bobbing); what is done moves once when it appears and again when
 * you point at its row (a check drawing, a plane lifting off).
 */
function Live({ icon }: { icon: Icon }) {
  if (icon === "working") return <CookieOrb size={14} thinking />;
  const common = { width: 16, height: 16, viewBox: "0 0 20 20", fill: "none", stroke: "currentColor", strokeWidth: 1.7, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  return (
    <span className={s.live} data-icon={icon} aria-hidden>
      {icon === "queued" && (
        <svg {...common} strokeWidth={1.5}>
          <path d="M6 3.5h8M6 16.5h8" />
          <path d="M7 3.5c0 3 3 4.2 3 6.5s-3 3.5-3 6.5M13 3.5c0 3-3 4.2-3 6.5s3 3.5 3 6.5" />
          <path d="M8.2 15.6h3.6" className={s.sand} />
          <circle cx="10" cy="11.5" r=".7" fill="currentColor" stroke="none" className={s.grain} />
        </svg>
      )}
      {icon === "answered" && (
        <svg {...common}>
          <circle cx="10" cy="10" r="7.2" className={s.ring} pathLength={1} />
          <path d="m6.8 10.2 2.2 2.2 4.3-4.6" className={s.draw} pathLength={1} />
        </svg>
      )}
      {icon === "sent" && (
        <svg {...common}>
          <g className={s.plane}>
            <path d="M3.5 9.6 16.5 4l-4.6 12.2-2.6-4.9-5.8-1.7Z" />
            <path d="m9.3 11.3 7.2-7.3" />
          </g>
          <path d="M2.8 15.5h3.4" className={s.trail} pathLength={1} />
        </svg>
      )}
      {icon === "thread" && (
        <svg {...common}>
          <path d="M4 4.8h12a1.6 1.6 0 0 1 1.6 1.6v6.2a1.6 1.6 0 0 1-1.6 1.6H9l-3.6 2.6v-2.6H4a1.6 1.6 0 0 1-1.6-1.6V6.4A1.6 1.6 0 0 1 4 4.8Z" />
          <circle cx="7" cy="9.5" r=".9" className={s.dot1} fill="currentColor" stroke="none" />
          <circle cx="10" cy="9.5" r=".9" className={s.dot2} fill="currentColor" stroke="none" />
          <circle cx="13" cy="9.5" r=".9" className={s.dot3} fill="currentColor" stroke="none" />
        </svg>
      )}
      {icon === "draft" && (
        <svg {...common}>
          <path d="M3 16.5h8.5" className={s.line} pathLength={1} />
          <g className={s.pen}>
            <path d="m12.6 4.2 3.2 3.2-7.4 7.4-3.7.6.6-3.7 7.3-7.5Z" />
          </g>
        </svg>
      )}
      {icon === "asked" && (
        <svg {...common}>
          <g className={s.bob}>
            <path d="M7.3 7.4a2.8 2.8 0 1 1 3.9 2.6c-.8.4-1.2.9-1.2 1.8v.5" />
            <circle cx="10" cy="15.3" r=".95" fill="currentColor" stroke="none" />
          </g>
        </svg>
      )}
      {icon === "quiet" && (
        <svg {...common} strokeWidth={1.5}>
          <path d="M5 12.5h4l-4 4h4" className={s.z1} />
          <path d="M11 4.5h3.5l-3.5 3.5h3.5" className={s.z2} />
        </svg>
      )}
      {icon === "failed" && (
        <svg {...common}>
          <circle cx="10" cy="10" r="7.2" className={s.ring} pathLength={1} />
          <path d="m7.6 7.6 4.8 4.8M12.4 7.6l-4.8 4.8" className={s.draw} pathLength={1} />
        </svg>
      )}
    </span>
  );
}

const SOURCE_NAME: Record<string, string> = {
  page: "this page", email: "email", slack: "Slack", tool: "an AI tool",
  telegram: "Telegram", discord: "Discord", whatsapp: "WhatsApp", teams: "Teams",
};

/** Where a job came from, as a small app-style tile: chat, email, Slack, an AI tool. */
function SourceTile({ trigger }: { trigger: string }) {
  const src = trigger === "email" || trigger === "slack" || trigger === "tool" ? trigger : "chat";
  const label = SOURCE_NAME[trigger] ?? "this page";
  return (
    <span className={s.src} data-src={src} aria-label={`From ${label}`}>
      {src === "slack" ? (
        <img src="/connectors/color_slack.svg" alt="" width={13} height={13} />
      ) : src === "email" ? (
        <svg width="15" height="15" viewBox="0 0 20 20" aria-hidden>
          <rect x="2.4" y="4.6" width="15.2" height="10.8" rx="2.6" fill="currentColor" />
          <path d="m3.6 6.4 6.4 4.7 6.4-4.7" fill="none" stroke="rgb(0 0 0 / .28)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : src === "tool" ? (
        <svg width="15" height="15" viewBox="0 0 20 20" aria-hidden>
          <path d="M10 2.6c.5 3.6 1.8 4.9 5.4 5.4-3.6.5-4.9 1.8-5.4 5.4-.5-3.6-1.8-4.9-5.4-5.4 3.6-.5 4.9-1.8 5.4-5.4Z" fill="currentColor" />
          <path d="M15.2 12.6c.2 1.5.8 2.1 2.3 2.3-1.5.2-2.1.8-2.3 2.3-.2-1.5-.8-2.1-2.3-2.3 1.5-.2 2.1-.8 2.3-2.3Z" fill="currentColor" opacity=".75" />
        </svg>
      ) : (
        <svg width="15" height="15" viewBox="0 0 20 20" aria-hidden>
          <path d="M10 3.5c4.1 0 7 2.6 7 5.9s-2.9 5.9-7 5.9c-.8 0-1.6-.1-2.3-.3L4.2 16.5l.9-3C3.8 12.4 3 11 3 9.4 3 6.1 5.9 3.5 10 3.5Z" fill="currentColor" />
        </svg>
      )}
    </span>
  );
}

/** A teammate: their initials where your rows show where the job came from. */
function Person({ who }: { who: string | null }) {
  const initials = (who ?? "?").split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join("") || "?";
  return (
    <span className={s.person} aria-hidden>
      {initials}
    </span>
  );
}

const isOpenThread = (t: Thread, waiting: Set<string>) => t.runs.some((r) => isOpen(r, waiting));

export function Conversations({
  threads,
  notices,
  selectedKey,
  waiting,
  status,
  live,
  needsYou,
  onPick,
  onNotices,
  onNeeds,
}: {
  threads: Thread[];
  /** What Cookie noticed on its own and nobody has looked at yet. */
  notices: CookieNotice[];
  /** The conversation on the page; null on a new, empty one. */
  selectedKey: string | null;
  waiting: Set<string>;
  /** What the conversation on the page is doing now. */
  status: string;
  live: boolean;
  needsYou: number;
  onPick: (runId: string) => void;
  onNotices: () => void;
  onNeeds: () => void;
}) {
  const [scope, setScope] = useState<"mine" | "team">("mine");
  const teammates = threads.some((t) => !t.mine);
  const shown = useMemo(() => (scope === "team" ? threads : threads.filter((t) => t.mine)), [threads, scope]);
  const openOnes = shown.filter((t) => isOpenThread(t, waiting));
  const rest = shown.filter((t) => !isOpenThread(t, waiting));
  const working = threads.filter((t) => t.last.status === "running").length;
  const line = live ? (working > 1 ? `${status} · ${working} working` : status) : working ? `${working} working` : status;
  const pick = onPick;

  const row = (t: Thread) => {
    const end = endOf(t.last, waiting.has(t.last.id));
    const running = t.last.status === "running";
    const said = running && t.mine ? doingOf(t.last) : end.text;
    const where = SOURCE_NAME[t.last.trigger] ?? "this page";
    return (
      <li key={t.key}>
        <button className={s.row} aria-current={t.key === selectedKey ? "true" : undefined} onClick={() => pick(t.last.id)}>
          {t.mine ? <SourceTile trigger={t.runs[0].trigger} /> : <Person who={t.who} />}
          <span className={s.text}>
            <b>{titleOf(t)}</b>
            <span>
              {!t.mine && `${t.who ?? "A teammate"} · ${where} · `}
              {ago(t.last.started_at)} · <i data-tone={end.tone}>{said}</i>
              {t.runs.length > 1 && ` · ${t.runs.length} messages`}
            </span>
          </span>
          <span className={s.status} data-tone={end.tone}>
            <Live icon={end.icon} />
          </span>
        </button>
      </li>
    );
  };

  const notice = (n: CookieNotice) => (
    <li key={n.id}>
      <button className={s.row} onClick={onNotices}>
        <span className={s.self}>
          <CookieOrb size={18} />
        </span>
        <span className={s.text}>
          <b>{n.title}</b>
          <span>
            <i data-tone="wait">{n.why_now ?? "Cookie noticed something"}</i>
          </span>
        </span>
        <span className={s.status} data-tone="wait">
          <Live icon="asked" />
        </span>
      </button>
    </li>
  );

  return (
    <aside className={s.sheet} aria-label="Conversations">
      <header className={s.top}>
        <CookieOrb size={18} thinking={live || working > 0} />
        <span className={s.name}>Cookie</span>
        <span className={s.now} data-live={live || working > 0 ? "true" : undefined}>
          <i />
          {line}
        </span>
        {needsYou > 0 && (
          <button className={s.needs} onClick={onNeeds}>
            Needs you · {needsYou}
          </button>
        )}
      </header>
      {teammates && (
        <div className={s.scope} role="tablist" aria-label="Whose conversations">
          {(["mine", "team"] as const).map((k) => (
            <button key={k} role="tab" aria-selected={scope === k} onClick={() => setScope(k)}>
              {k === "mine" ? "Mine" : "Team"}
            </button>
          ))}
        </div>
      )}
      {shown.length === 0 && notices.length === 0 ? (
        <p className={s.empty}>
          {scope === "team" ? "Nobody on your team has given Cookie a job yet." : "Nothing yet. Give Cookie a job by email, in Slack or here, and it shows up."}
        </p>
      ) : (
        <ul className={s.list} data-own-scroll="">
          {(openOnes.length > 0 || (scope === "mine" && notices.length > 0)) && <li className={s.group}>Open</li>}
          {scope === "mine" && notices.map(notice)}
          {openOnes.map(row)}
          {rest.length > 0 && <li className={s.group}>Earlier</li>}
          {rest.map(row)}
        </ul>
      )}
    </aside>
  );
}
