"use client";

// The whole of what Cookie wrote, on its own sheet over the board: a report
// paragraph by paragraph, or a list of leads as a table, each line with the
// sources it was drawn from (the steps the gateway recorded for it — a site,
// a search, a lookup in your context). Nothing here is written by the page:
// every word is Cookie's answer, every source a step the run took.

import { useEffect, useRef } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { CookieRun, CookieStep } from "@/lib/api";
import { pagesOf } from "./build";
import { paragraphs, parseLeads } from "./leads";
import { Glyph } from "./BoardCard";
import s from "./Reader.module.css";

const cut = (v: string, n: number) => (v.length > n ? `${v.slice(0, n - 1).trimEnd()}…` : v);

/** A source as a chip: the site of a page, a search's words, a lookup's words. */
function Source({ step }: { step: CookieStep }) {
  if (step.tool === "read_url" || step.tool === "read_site") {
    const host = step.what.replace(/ · \d+ pages?$/, "").replace(/^www\./, "");
    return (
      <span className={s.chip} title={host}>
        <Glyph kind="globe" size={10} />
        {host}
      </span>
    );
  }
  if (step.tool === "web_search")
    return (
      <span className={s.chip} title={`Searched “${step.what}”`}>
        <Glyph kind="search" size={10} />
        {cut(step.what, 28)}
      </span>
    );
  return (
    <span className={s.chip} title={`Looked up “${step.what}” in your context`}>
      <img src="/favicon.svg" alt="" width={10} height={10} />
      {cut(step.what, 28)}
    </span>
  );
}

function Sources({ run, para }: { run: CookieRun; para: number }) {
  const steps = (run.answer_sources?.[para] ?? []).map((n) => run.steps[n]).filter((st): st is CookieStep => Boolean(st?.ok));
  if (!steps.length) return null;
  return (
    <span className={s.sources}>
      {steps.map((st, i) => (
        <Source key={i} step={st} />
      ))}
    </span>
  );
}

export function Reader({ run, onClose }: { run: CookieRun; onClose: () => void }) {
  const sheet = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const key = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", key);
    sheet.current?.focus();
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);

  const answer = run.answer ?? "";
  const { leads, rest } = parseLeads(answer);
  const paras = paragraphs(answer);
  const pages = run.steps.reduce((n, st) => n + pagesOf(st), 0);
  const lookups = run.steps.filter((st) => st.tool === "recall").length;
  const searches = run.steps.filter((st) => st.tool === "web_search").length;
  const helpers = run.steps.filter((st) => st.tool === "helper").length;
  const day = new Date(run.started_at).toLocaleDateString([], { day: "numeric", month: "long", year: "numeric" });
  const facts = [
    day,
    lookups ? `${lookups} ${lookups === 1 ? "lookup" : "lookups"} in your context` : "",
    searches ? `${searches} ${searches === 1 ? "search" : "searches"}` : "",
    pages ? `${pages} ${pages === 1 ? "page" : "pages"} read` : "",
    helpers ? `${helpers} ${helpers === 1 ? "helper" : "helpers"}` : "",
  ].filter(Boolean);
  const restIndex = (p: string) => paras.indexOf(p);

  return (
    <div className={s.backdrop} onPointerDown={(e) => e.target === e.currentTarget && onClose()}>
      <div ref={sheet} className={s.sheet} role="dialog" aria-modal="true" aria-label={run.subject || "What Cookie wrote"} tabIndex={-1}>
        <header className={s.head}>
          <span className={s.kind}>{leads.length ? `${leads.length} leads` : "Report"}</span>
          <button className={s.close} onClick={onClose} aria-label="Close">
            <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
              <path d="m2.5 2.5 7 7m0-7-7 7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            </svg>
          </button>
        </header>
        <h1 className={s.title}>{run.subject || "What Cookie found"}</h1>
        <p className={s.facts}>{facts.join(" · ")}</p>

        <div className={s.content} data-own-scroll="">
        {leads.length > 0 ? (
          <>
            {rest
              .filter((p) => restIndex(p) < leads[0].para)
              .map((p) => (
                <p key={p} className={s.intro}>
                  {p}
                </p>
              ))}
            <div className={s.tableWrap}>
              <table className={s.table}>
                <thead>
                  <tr>
                    <th>Company</th>
                    <th>Why now</th>
                    <th>Fits because</th>
                    <th>Approach</th>
                  </tr>
                </thead>
                <tbody>
                  {leads.map((l) => (
                    <tr key={l.para}>
                      <td>
                        <b>{l.company}</b>
                        <span className={s.site}>{l.site}</span>
                        {l.what && <span className={s.what}>{l.what}</span>}
                      </td>
                      <td>
                        {l.signal || "—"}
                        <Sources run={run} para={l.para} />
                      </td>
                      <td>{l.fits || "—"}</td>
                      <td>{l.approach || "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {rest
              .filter((p) => restIndex(p) > leads[0].para)
              .map((p) => (
                <p key={p} className={s.after}>
                  {p}
                </p>
              ))}
          </>
        ) : (
          <div className={s.body}>
            {paras.map((p, i) => (
              <div key={i} className={s.para}>
                <ReactMarkdown remarkPlugins={[remarkGfm]}>{p}</ReactMarkdown>
                <Sources run={run} para={i} />
              </div>
            ))}
          </div>
        )}
        </div>
      </div>
    </div>
  );
}
