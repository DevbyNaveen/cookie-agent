"use client";

// A choice from a short list, drawn like the rest of Cookie's page instead
// of the system menu: a quiet field with its chevron, and beneath it a sheet
// of the same material with the chosen one ticked. The sheet is fixed to the
// screen, so a scrolling panel never clips it; it opens upward when there is
// no room below. Arrow keys move, Enter or a click picks, Escape or a click
// elsewhere closes, scrolling closes.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import s from "./Select.module.css";

export function Select<T extends string | number>({
  value,
  options,
  onChange,
  label,
  disabled,
}: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
  label: string;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [at, setAt] = useState(0);
  const [place, setPlace] = useState<{ left: number; width: number; top?: number; bottom?: number } | null>(null);
  const field = useRef<HTMLButtonElement>(null);
  const sheet = useRef<HTMLUListElement>(null);
  const chosen = options.find((o) => o.value === value);

  useLayoutEffect(() => {
    if (!open || !field.current) return;
    const r = field.current.getBoundingClientRect();
    const room = window.innerHeight - r.bottom;
    setPlace(room < 240 && r.top > room ? { left: r.left, width: r.width, bottom: window.innerHeight - r.top + 6 } : { left: r.left, width: r.width, top: r.bottom + 6 });
    setAt(Math.max(0, options.findIndex((o) => o.value === value)));
  }, [open, options, value]);
  // The chosen one in view as it opens.
  useLayoutEffect(() => {
    if (open && place) sheet.current?.querySelector<HTMLElement>(`[data-i="${at}"]`)?.scrollIntoView({ block: "nearest" });
  }, [open, place, at]);
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => {
      const t = e.target as Node;
      if (!field.current?.contains(t) && !sheet.current?.contains(t)) setOpen(false);
    };
    const scroll = (e: Event) => !sheet.current?.contains(e.target as Node) && setOpen(false);
    window.addEventListener("pointerdown", away);
    window.addEventListener("scroll", scroll, true);
    window.addEventListener("resize", () => setOpen(false), { once: true });
    return () => {
      window.removeEventListener("pointerdown", away);
      window.removeEventListener("scroll", scroll, true);
    };
  }, [open]);

  const pick = (i: number) => {
    setOpen(false);
    field.current?.focus();
    if (options[i] && options[i].value !== value) onChange(options[i].value);
  };
  const key = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!open) return setOpen(true);
      setAt((i) => Math.min(options.length - 1, Math.max(0, i + (e.key === "ArrowDown" ? 1 : -1))));
    } else if ((e.key === "Enter" || e.key === " ") && open) {
      e.preventDefault();
      pick(at);
    } else if (e.key === "Escape" && open) {
      e.preventDefault();
      setOpen(false);
    }
  };

  return (
    <>
      <button
        ref={field}
        type="button"
        className={s.field}
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={label}
        onClick={() => setOpen((v) => !v)}
        onKeyDown={key}
      >
        <span>{chosen?.label ?? ""}</span>
        <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden>
          <path d="M2.5 4 5 6.5 7.5 4" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
      {open && place && (
        <ul ref={sheet} className={s.sheet} role="listbox" aria-label={label} style={place} onKeyDown={key}>
          {options.map((o, i) => (
            <li
              key={String(o.value)}
              data-i={i}
              role="option"
              aria-selected={o.value === value}
              data-at={i === at ? "true" : undefined}
              onPointerEnter={() => setAt(i)}
              onClick={() => pick(i)}
            >
              <span>{o.label}</span>
              {o.value === value && (
                <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden>
                  <path d="m2.5 6.2 2.3 2.3 4.7-5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
                </svg>
              )}
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
