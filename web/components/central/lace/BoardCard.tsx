"use client";

// A card on Cookie's board: the real thing behind a node. For a circle (what
// Cookie read) it opens on hover — the notes a lookup found, a search's
// results, the page. For a box (what Cookie made) it is the box itself — the
// answer, the draft waiting for you, a save, the questions it asked, why it
// stopped. Bones while the call is out.

import { forwardRef } from "react";
import type { CookieDraft, CookieRun } from "@/lib/api";
import { CookieOrb } from "@/components/central/CookieOrb";
import { ConnectorLogo } from "@/components/ConnectorLogo";
import { plain, type Card } from "./board";
import { pagesOf } from "./build";
import { paragraphs, parseLeads } from "./leads";
import { appName } from "./world";
import s from "./BoardCard.module.css";

const cut = (v: string, n: number) => (v.length > n ? `${v.slice(0, n - 1).trimEnd()}…` : v);
const ms = (n?: number) => (n == null ? "" : n < 1000 ? `${n} ms` : `${(n / 1000).toFixed(1)} s`);
const dayOf = (d: string) => new Date(`${d}T12:00:00Z`).toLocaleDateString([], { day: "numeric", month: "short" });

export function Glyph({ kind, size = 13 }: { kind: "globe" | "mail" | "you" | "search"; size?: number }) {
  if (kind === "globe")
    return (
      <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden>
        <circle cx="10" cy="10" r="7.2" fill="none" stroke="currentColor" strokeWidth="1.7" />
        <path d="M2.8 10h14.4M10 2.8c2.2 2 3.2 4.4 3.2 7.2s-1 5.2-3.2 7.2c-2.2-2-3.2-4.4-3.2-7.2s1-5.2 3.2-7.2Z" fill="none" stroke="currentColor" strokeWidth="1.5" />
      </svg>
    );
  if (kind === "search")
    return (
      <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden>
        <circle cx="8.6" cy="8.6" r="5.6" fill="none" stroke="currentColor" strokeWidth="1.8" />
        <path d="m13 13 4.2 4.2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    );
  if (kind === "mail")
    return (
      <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden>
        <rect x="2.5" y="4.5" width="15" height="11" rx="2.5" fill="none" stroke="currentColor" strokeWidth="1.7" />
        <path d="m3.5 6 6.5 5 6.5-5" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden>
      <circle cx="10" cy="7" r="3.3" fill="none" stroke="currentColor" strokeWidth="1.7" />
      <path d="M3.8 17c.8-3.2 3.3-5 6.2-5s5.4 1.8 6.2 5" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
    </svg>
  );
}

function Skeleton({ lines = 3 }: { lines?: number }) {
  return (
    <div className={s.skeleton} aria-hidden>
      {Array.from({ length: lines }, (_, i) => (
        <i key={i} style={{ width: `${[92, 78, 64, 84][i % 4]}%` }} />
      ))}
    </div>
  );
}

/** Where the answer went, for the product box's corner. */
function delivered(run: CookieRun): string {
  if (run.delivery === "replied") return run.trigger === "slack" ? "Posted in the thread" : "Emailed";
  return run.delivery === "failed" ? "Here · email didn't send" : "Here";
}

/** The answer's sources: the pages' sites, and how many lookups in your context. */
function sourcesOf(run: CookieRun): { hosts: string[]; lookups: number } {
  const cited = new Set((run.answer_sources ?? []).flat());
  const hosts: string[] = [];
  let lookups = 0;
  for (const n of cited) {
    const st = run.steps[n];
    if (!st?.ok) continue;
    if (st.tool === "recall") lookups += 1;
    else if (st.tool === "read_url" || st.tool === "read_site") {
      const h = st.what.replace(/ · \d+ pages?$/, "").replace(/^www\./, "");
      if (h && !hosts.includes(h)) hosts.push(h);
    }
  }
  return { hosts, lookups };
}

const STOPPED: Record<string, string> = {
  out_of_credits: "Out of Cookie credits for this month.",
  refused: "Didn't act — the sender isn't on the team.",
  silent: "Read it and stayed quiet — nothing needed a reply.",
};

export const BoardCard = forwardRef<
  HTMLDivElement,
  {
    card: Card;
    run: CookieRun;
    /** Its content has come back (on the run's clock). */
    landed: boolean;
    state?: "lit" | "dim";
    /** A circle's card opened over the board, not a box on it. */
    floating?: boolean;
    /** Clicked open: it stays, scrolls, and closes with ✕, Escape or a click on the board. */
    pinned?: boolean;
    onClose?: () => void;
    draft?: CookieDraft;
    /** Buttons under the content (a draft's Send / Skip, Answer). */
    footer?: React.ReactNode;
    style?: React.CSSProperties;
    onPointerEnter?: () => void;
    onPointerLeave?: () => void;
    onPointerDown?: (e: React.PointerEvent) => void;
  }
>(function BoardCard({ card, run, landed, state, floating, pinned, onClose, draft, footer, style, onPointerEnter, onPointerLeave, onPointerDown }, ref) {
  const step = card.step != null ? run.steps[card.step] : undefined;
  const peek = step?.peek;
  const loading = !landed;

  let icon: React.ReactNode;
  let label: string;
  let meta = "";
  let body: React.ReactNode;

  switch (card.kind) {
    case "context":
      icon = <img src="/favicon.svg" alt="" width={14} height={14} />;
      label = "Your context";
      meta = landed ? ms(step?.ms) : "Looking";
      body = (
        <>
          <p className={s.query}>{cut(step?.what ?? "", 90)}</p>
          {loading ? (
            <Skeleton />
          ) : peek?.notes?.length ? (
            <ul className={s.notes}>
              {peek.notes.map((n, i) => (
                <li key={i}>
                  <span className={s.note}>{n.text}</span>
                  {(n.app || n.day) && (
                    <span className={s.noteMeta}>
                      {n.app && (
                        <span className={s.app}>
                          <ConnectorLogo slug={n.app.replace(/-/g, "")} name={appName(n.app)} size={11} variant="full" />
                          {appName(n.app)}
                        </span>
                      )}
                      {n.day && <span>{dayOf(n.day)}</span>}
                    </span>
                  )}
                </li>
              ))}
            </ul>
          ) : (
            <p className={s.quiet}>{step?.ok ? `${Math.round((step.size ?? 0) / 100) / 10}k characters came back` : "Didn't work"}</p>
          )}
        </>
      );
      break;
    case "search":
      icon = <Glyph kind="search" />;
      label = "Web search";
      meta = landed ? ms(step?.ms) : "Searching";
      body = (
        <>
          <p className={s.query}>{cut(step?.what ?? "", 90)}</p>
          {loading ? (
            <Skeleton />
          ) : peek?.results?.length ? (
            <ul className={s.results}>
              {peek.results.map((r, i) => (
                <li key={i}>
                  <span className={s.resultTitle}>{r.title}</span>
                  <span className={s.host}>{r.host.replace(/^www\./, "")}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className={s.quiet}>{step?.ok ? "Results came back" : "Didn't work"}</p>
          )}
        </>
      );
      break;
    case "page": {
      const host = (step?.what ?? "").replace(/ · \d+ pages?$/, "").replace(/^www\./, "");
      const pages = /· (\d+) pages?$/.exec(step?.what ?? "")?.[1];
      icon = <Glyph kind="globe" />;
      label = host || "A page";
      meta = landed ? (pages ? `${pages} pages` : ms(step?.ms)) : pages ? "Reading the site" : "Reading";
      body = loading ? (
        <>
          <Skeleton lines={3} />
          <div className={s.progress}>
            <i />
          </div>
        </>
      ) : (card.steps?.length ?? 0) > 1 ? (
        // One site, read page by page: each page it opened.
        <ul className={s.results}>
          {card.steps!.map((n) => {
            const st = run.steps[n];
            return (
              <li key={n}>
                <span className={s.resultTitle}>{st?.peek?.title ?? (st?.ok ? "A page" : "Couldn't read it")}</span>
                {st?.peek?.text && <span className={s.host}>{cut(st.peek.text, 90)}</span>}
              </li>
            );
          })}
        </ul>
      ) : peek?.title ? (
        <>
          <p className={s.lead}>{peek.title}</p>
          {peek.text && <p className={s.text}>{peek.text}</p>}
        </>
      ) : (
        <p className={s.quiet}>{step?.ok ? "Read the page" : "Couldn't read it"}</p>
      );
      break;
    }
    case "save":
      icon = <img src="/favicon.svg" alt="" width={14} height={14} />;
      label = "Saved to your context";
      meta = landed ? "" : "Saving";
      body = loading ? <Skeleton lines={2} /> : <p className={s.text}>{peek?.text ?? step?.what}</p>;
      break;
    case "answer": {
      const paras = (run.answer ?? "").split(/\n{2,}/).map(plain).filter(Boolean);
      icon = <CookieOrb size={16} />;
      label = "Answer";
      meta = delivered(run);
      body = <p className={`${s.text} ${s.long}`}>{cut(paras.join(" "), 600)}</p>;
      break;
    }
    case "report": {
      const paras = paragraphs(run.answer ?? "").map(plain);
      const { hosts, lookups } = sourcesOf(run);
      icon = <CookieOrb size={16} />;
      label = "Report";
      meta = delivered(run);
      body = (
        <>
          <p className={s.lead}>{run.subject || "Research"}</p>
          <p className={`${s.text} ${s.long}`}>{cut(paras.slice(0, 2).join(" "), 420)}</p>
          <p className={s.sources}>
            {hosts.slice(0, 4).map((h) => (
              <span key={h} className={s.chip}>
                <Glyph kind="globe" size={10} />
                {h}
              </span>
            ))}
            {hosts.length > 4 && <span className={s.chip}>+{hosts.length - 4}</span>}
            {lookups > 0 && (
              <span className={s.chip}>
                <img src="/favicon.svg" alt="" width={10} height={10} />
                {lookups === 1 ? "your context" : `your context ×${lookups}`}
              </span>
            )}
            <span className={s.count}>{paras.length} paragraphs</span>
          </p>
        </>
      );
      break;
    }
    case "leads": {
      const { leads } = parseLeads(run.answer ?? "");
      icon = <CookieOrb size={16} />;
      label = `${leads.length} leads`;
      meta = delivered(run);
      body = (
        <ol className={s.leads}>
          {leads.slice(0, 6).map((l) => (
            <li key={l.para}>
              <span className={s.leadHead}>
                <b>{l.company}</b>
                <em>{l.site}</em>
              </span>
              <span className={s.leadWhy}>{l.signal || l.what}</span>
              {l.approach && <span className={s.leadTo}>Approach: {l.approach}</span>}
            </li>
          ))}
          {leads.length > 6 && <li className={s.more}>+{leads.length - 6} more</li>}
        </ol>
      );
      break;
    }
    case "helper": {
      const own = run.steps.filter((st) => st.helper && `helper:${st.helper}` === card.id && st.tool !== "helper");
      const looked = own.filter((st) => st.tool === "recall" || st.tool === "web_search").length;
      const pages = own.reduce((n, st) => n + pagesOf(st), 0);
      icon = <CookieOrb size={16} thinking={loading} />;
      label = "Helper";
      meta = loading ? "Researching" : card.ok ? ms(step?.ms) : "Didn't finish";
      body = (
        <>
          <p className={s.lead}>{card.task || "Research"}</p>
          <p className={s.quiet}>
            {looked || pages ? [looked ? `${looked} ${looked === 1 ? "lookup" : "lookups"}` : "", pages ? `${pages} ${pages === 1 ? "page" : "pages"} read` : ""].filter(Boolean).join(" · ") : loading ? "Starting" : "Read nothing"}
          </p>
        </>
      );
      break;
    }
    case "draft":
      icon = <CookieOrb size={16} />;
      label = draft?.slack ? "Reply for the Slack thread" : `Reply to ${draft?.to.join(", ") ?? ""}`;
      meta = "Waiting for you";
      body = <p className={`${s.text} ${s.long} ${s.letter}`}>{cut((draft?.body ?? "").replace(/[*_`#>]+/g, "").trim(), 600)}</p>;
      break;
    case "questions":
      icon = <CookieOrb size={16} />;
      label = "Cookie asks first";
      meta = "Waiting for you";
      body = (
        <ul className={s.asks}>
          {(run.questions ?? "")
            .split("\n")
            .map((q) => q.replace(/^-\s*/, "").trim())
            .filter(Boolean)
            .map((q, i) => (
              <li key={i}>{q}</li>
            ))}
        </ul>
      );
      break;
    case "stopped":
      icon = <CookieOrb size={16} />;
      label = "Stopped";
      meta = "";
      body = <p className={s.quiet}>{STOPPED[run.delivery ?? ""] ?? "Cookie couldn't finish this one."}</p>;
      break;
    case "writing": {
      // The words as they are written: the latest of them, with a caret.
      const live = plain(run.live_text ?? "");
      const words = live ? live.split(" ").length : 0;
      icon = <CookieOrb size={16} thinking />;
      label = "Writing";
      meta = words ? `${words} words` : "";
      body = live ? (
        <p className={`${s.text} ${s.long} ${s.live}`}>{live.length > 600 ? `…${live.slice(-560).replace(/^\S*\s/, "")}` : live}</p>
      ) : (
        <Skeleton lines={4} />
      );
      break;
    }
  }

  return (
    <div
      ref={ref}
      className={s.card}
      data-kind={card.kind}
      data-loading={loading ? "true" : undefined}
      data-failed={landed && !card.ok ? "true" : undefined}
      data-state={state}
      data-floating={floating ? "true" : undefined}
      data-pinned={pinned ? "true" : undefined}
      data-own-scroll={pinned ? "" : undefined}
      style={style}
      onPointerEnter={onPointerEnter}
      onPointerLeave={onPointerLeave}
      onPointerDown={pinned ? (e) => e.stopPropagation() : onPointerDown}
    >
      <header className={s.head}>
        <span className={s.icon}>{icon}</span>
        <span className={s.label}>{label}</span>
        {meta && <span className={s.meta}>{meta}</span>}
        {pinned && onClose && (
          <button className={s.close} onClick={onClose} aria-label="Close">
            <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
              <path d="m2.5 2.5 5 5m0-5-5 5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          </button>
        )}
      </header>
      <div className={s.body}>{body}</div>
      {footer && <div className={s.footer}>{footer}</div>}
    </div>
  );
});
