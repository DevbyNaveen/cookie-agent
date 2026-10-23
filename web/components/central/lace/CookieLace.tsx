"use client";

// Cookie's page. Behind: Cookie's board — where you watch it work. One job is
// on stage: the circles around the orb are what Cookie read (a lookup in your
// context, a search, a page — one per source; hover one and it opens into the
// real notes or results), the boxes beyond are what it made (the answer, a
// draft waiting for you, a save, the questions it asked). Threads run from the
// orb to each, and from every circle the answer drew on into the answer. On the
// top left, Cookie's name opens every conversation, from email, Slack, chat
// apps, AI tools or here; pick one and the page becomes it — its board, its
// chat. A running job takes the stage live. Things
// spring into place, threads sag and swing like string, nothing overlaps, and
// the view follows the stage. In front: the floating panel.

import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CookieDraft, CookieOverview, CookiePermission, CookiePrefs, CookieRule, CookieRun } from "@/lib/api";
import { CookieOrb, type Look } from "@/components/central/CookieOrb";
import { ConnectorLogo } from "@/components/ConnectorLogo";
import { INTRO, laceOf, liveClock } from "./build";
import { CIRCLE, ORB, REACH, guessHeight, layout, outCard, readCard, stageOf, type Box, type ReadNode } from "./board";
import { BoardCard, Glyph } from "./BoardCard";
import { Conversations } from "./Conversations";
import { onBoard, thoughtOf, threadsOf } from "./threads";
import { Reader } from "./Reader";
import { appName, ghostsOf, placesOf, wearOf, wearLine } from "./world";
import { CookiePanel as Panel, type Tab } from "./CookiePanel";
import s from "./CookieLace.module.css";

// The panel only redraws when its own inputs change, never on the board's frames.
const CookiePanel = memo(Panel);

type P = { x: number; y: number };
type View = { k: number; x: number; y: number };
export type Hover = { kind: "node"; id: string } | { kind: "line"; i: number } | null;
type Body = { x: number; y: number; vx: number; vy: number };

const clamp = (v: number, a = 0, b = 1) => Math.min(b, Math.max(a, v));
/** A replay takes about this long, however long the run really took. */
const REPLAY_SECONDS = 9;
/** The floating panel's width plus its inset — the board fits beside it. */
const PANEL_SPACE = 440 + 32;
/** The conversations sheet on the left, always there. */
const SHEET_SPACE = 272 + 32;
const ORB_R = 34;
/** How far the board zooms out and in. */
const MIN_ZOOM = 0.3;
const MAX_ZOOM = 2;
/** Things: stiff enough to arrive, soft enough to land. Threads: loose, so they swing. */
const NODE_K = 170;
const NODE_C = 22;
const STRING_K = 38;
const STRING_C = 5.5;

function quad(a: P, c: P, b: P, t: number): P {
  const u = 1 - t;
  return { x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y };
}

/** Where a thread meets a thing: a circle at its rim, a box at the edge facing the other end. */
function anchor(b: Box | "orb", toward: P): P {
  if (b === "orb") {
    const d = Math.hypot(toward.x, toward.y) || 1;
    return { x: (toward.x / d) * ORB_R, y: (toward.y / d) * ORB_R };
  }
  if (b.w === CIRCLE || b.w === REACH) {
    const c = { x: b.x + b.w / 2, y: b.y + b.h / 2 };
    const d = Math.hypot(toward.x - c.x, toward.y - c.y) || 1;
    return { x: c.x + ((toward.x - c.x) / d) * (b.w / 2), y: c.y + ((toward.y - c.y) / d) * (b.w / 2) };
  }
  const left = toward.x < b.x + b.w / 2;
  return { x: left ? b.x : b.x + b.w, y: b.y + Math.min(b.h / 2, 42) };
}
const centre = (b: Box | "orb"): P => (b === "orb" ? { x: 0, y: 0 } : { x: b.x + b.w / 2, y: b.y + b.h / 2 });

export function CookieLace({
  overview,
  selectedId,
  fresh,
  onSelect,
  onNew,
  onStop,
  onUndo,
  onRoutine,
  onStopChase,
  onSoul,
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
  selectedId: string | null;
  /** A new conversation: nothing on the page until the first job is given. */
  fresh: boolean;
  onSelect: (id: string) => void;
  /** Start a new conversation: an empty board and an empty chat. */
  onNew: () => void;
  /** Stop one of the viewer's own jobs while it works. */
  onStop: (runId: string) => Promise<void>;
  onUndo: (changeId: string) => Promise<{ state: string; why?: string }>;
  onRoutine: (routineId: string, action: "accept" | "decline" | "pause" | "resume") => Promise<void>;
  onStopChase: (chaseId: string) => Promise<void>;
  onSoul: (text: string) => Promise<void>;
  onDecide: (draft: CookieDraft, action: "send" | "skip" | "take_over") => Promise<void>;
  /** The member's yes or no to a change Cookie asked to make in an app. */
  onApproval: (approvalId: string, approve: boolean, always?: boolean) => Promise<void>;
  /** A label on something Cookie noticed. */
  onNotice: (noticeId: string, label: "useful" | "not_useful" | "wrong") => Promise<void>;
  /** Archive a lesson, or bring one back. */
  onLesson: (lessonId: string, state: "active" | "archived") => Promise<void>;
  /** How much Cookie may do in the member's apps before it asks. */
  onPermission: (level: CookiePermission) => Promise<void>;
  /** Set or remove one of the member's own rules. */
  onRule: (change: { set?: Omit<CookieRule, "id">; remove?: string }) => Promise<void>;
  onPrefs: (prefs: CookiePrefs) => Promise<void>;
  /** Link (returns a one-time code) or unlink a chat app. */
  onChannel: (channel: string, link: boolean) => Promise<{ code: string; minutes: number } | null>;
  onJob: (text: string, conversation?: string) => Promise<void>;
  /** Answer the questions a run asked; the job then starts. */
  onAnswer: (runId: string, text: string) => Promise<void>;
  /** The run's public, counts-only link. */
  onShare: (runId: string) => Promise<string>;
  onUnshare: (runId: string) => Promise<void>;
  onSetPin: (pin: string) => Promise<void>;
  onSlack: (action: "add" | "remove") => Promise<void>;
  /** Only for a Cookie session (link + PIN). */
  onSignOut?: () => Promise<void>;
}) {
  const canvas = useRef<HTMLDivElement>(null);
  const [view, setView] = useState<View>({ k: 1, x: 0, y: 0 });
  const viewRef = useRef(view);
  viewRef.current = view;
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [hover, setHover] = useState<Hover>(null);
  /** A circle clicked open: its card stays until closed. */
  const [pinned, setPinned] = useState<string | null>(null);
  const moved = useRef(false);
  useEffect(() => {
    if (!pinned) return;
    const key = (e: KeyboardEvent) => e.key === "Escape" && setPinned(null);
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [pinned]);
  const [open, setOpen] = useState(true);
  const [follow, setFollow] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  /** The run whose whole answer is open on its own sheet. */
  const [reading, setReading] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>(() => {
    const r = overview.runs.find((x) => x.id === selectedId);
    return r && r.trigger !== "page" ? "inbox" : "chat";
  });

  const runs = overview.runs;
  // On stage: the job picked, else your newest — unless this is a new
  // conversation, which starts empty.
  const run: CookieRun | null = runs.find((r) => r.id === selectedId) ?? (fresh ? null : runs.find((r) => r.mine !== false) ?? null);
  const threads = useMemo(() => threadsOf(runs), [runs]);
  const thread = run ? threads.find((x) => x.runs.some((r) => r.id === run.id)) ?? null : null;
  // On the board: this message's work on top of what its conversation already read.
  const staged = useMemo(() => (run ? onBoard(run, thread?.runs ?? []) : null), [run, thread]);
  const live = run?.status === "running";
  const lace = useMemo(() => (staged ? laceOf(staged, overview.waiting) : null), [staged, overview.waiting]);
  const waitingRuns = useMemo(() => new Set(overview.waiting.map((d) => d.run_id)), [overview.waiting]);
  const draft = run ? overview.waiting.find((d) => d.run_id === run.id) : undefined;

  // What Cookie is wired to: the connected apps, its mail address, Slack.
  const placeKey = `${overview.address}|${overview.slack?.workspace}|${(overview.apps ?? []).map((a) => `${a.key}:${a.ok}`).join(",")}`;
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const places = useMemo(() => placesOf(overview), [placeKey]);
  const wear = useMemo(() => wearOf(overview, places), [overview, places]);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const ghosts = useMemo(() => ghostsOf(overview), [placeKey, overview.slack?.available, overview.apps == null]);
  const reachPlaces = useMemo(
    () => [...places.filter((p) => p.kind === "app" || p.kind === "email" || p.kind === "slack"), ...ghosts],
    [places, ghosts],
  );
  const canConnect = overview.viewer?.via === "console";
  /** Connect what a ghost offers: Slack adds Cookie's app, an app opens Integrations. */
  const connect = (p: (typeof ghosts)[number]) => {
    if (!canConnect) return;
    if (p.id === "ghost:slack") return void onSlack("add");
    window.open(`${window.location.pathname.replace(/\/cookie\/?$/, "")}?open=integrations`, "_blank", "noopener");
  };
  const reachIds = useMemo(() => reachPlaces.map((p) => p.id), [reachPlaces]);

  // The clock: a running job follows real time; a finished one rests at its
  // end. Picking another replays it.
  const [replayAt, setReplayAt] = useState<number | null>(null);
  const [t, setT] = useState(1e9);
  const stage = useMemo(() => (staged ? stageOf(staged, overview.waiting, t, reachIds) : null), [staged, overview.waiting, t, reachIds]);
  const end = useMemo(() => (staged ? stageOf(staged, overview.waiting, 1e9).end : 0), [staged, overview.waiting]);
  const shownRun = useRef<string | null | undefined>(undefined);
  const bodies = useRef(new Map<string, Body>());
  const strings = useRef(new Map<string, Body>());
  const [drags, setDrags] = useState<Record<string, P>>({});
  const clearStage = () => {
    bodies.current.clear();
    strings.current.clear();
  };
  // A different conversation starts a fresh board; the next message of the
  // same one grows the board it is on, with nothing flying back to the orb.
  const shownThread = useRef<string | null>(null);
  const threadKey = thread?.key ?? null;
  useEffect(() => {
    const id = run?.id ?? null;
    if (shownRun.current === id) return;
    const first = shownRun.current === undefined;
    const same = !first && threadKey !== null && shownThread.current === threadKey;
    shownRun.current = id;
    shownThread.current = threadKey;
    setHover(null);
    setPinned(null);
    setFollow(true);
    if (!same) {
      setDrags({});
      clearStage();
    }
    setReplayAt(!first && !same && run && run.status !== "running" ? performance.now() : null);
  }, [run, threadKey]);
  useEffect(() => {
    if (!run) return;
    if (!live && replayAt === null) {
      setT(1e9);
      return;
    }
    let raf = 0;
    const tick = (now: number) => {
      if (live) setT(liveClock(run));
      else {
        const n = ((now - replayAt!) / 1000) * Math.max(1, end / REPLAY_SECONDS);
        if (n >= end) {
          setT(1e9);
          setReplayAt(null);
          return;
        }
        setT(n);
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [run, live, replayAt, end]);

  // Measured box heights: a box that grows pushes the others along.
  const [heights, setHeights] = useState<Record<string, number>>({});
  const observer = useRef<ResizeObserver | null>(null);
  useEffect(() => {
    observer.current = new ResizeObserver((entries) => {
      setHeights((prev) => {
        let next = prev;
        for (const e of entries) {
          const id = (e.target as HTMLElement).dataset.node;
          const h = Math.round((e.target as HTMLElement).offsetHeight);
          if (id && prev[id] !== h) next = { ...next, [id]: h };
        }
        return next;
      });
    });
    return () => observer.current?.disconnect();
  }, []);
  const measured = useCallback((id: string) => (el: HTMLDivElement | null) => {
    if (!el) return;
    el.dataset.node = id;
    observer.current?.observe(el);
  }, []);

  const measure = useCallback(() => {
    const cv = canvas.current;
    if (cv) setSize({ w: cv.clientWidth, h: cv.clientHeight });
  }, []);
  useLayoutEffect(() => {
    measure();
    const ro = new ResizeObserver(measure);
    if (canvas.current) ro.observe(canvas.current);
    return () => ro.disconnect();
  }, [measure]);

  // What is on stage now, and where everything goes.
  const reads = useMemo(() => stage?.reads.filter((r) => t >= r.start) ?? [], [stage, t]);
  const outs = useMemo(() => stage?.outs.filter((o) => t >= o.start) ?? [], [stage, t]);
  const shown = useMemo(() => new Set([...reachIds, ...reads.map((r) => r.id), ...outs.map((o) => o.id)]), [reads, outs, reachIds]);
  const edges = useMemo(
    () => stage?.edges.filter((e) => shown.has(e.to) && (e.from === ORB || shown.has(e.from))) ?? [],
    [stage, shown],
  );
  const targets = useMemo(() => {
    const kindOf = new Map(outs.map((o) => [o.id, o.kind]));
    const boxes = layout(reads, outs, (id) => heights[id] ?? guessHeight(kindOf.get(id) ?? "answer"), null, reachIds);
    for (const [id, p] of Object.entries(drags)) {
      const b = boxes.get(id);
      if (b) boxes.set(id, { ...b, x: p.x, y: p.y });
    }
    return boxes;
  }, [reads, outs, heights, drags, reachIds]);

  /** The view that shows the whole stage in the space the panel leaves free. */
  const fitView = useCallback((): View | null => {
    if (!size.w) return null;
    const wide = size.w > 760;
    const left = wide ? SHEET_SPACE : 0;
    const free = (open && wide ? size.w - PANEL_SPACE : size.w) - left;
    const freeH = open && !wide ? size.h * 0.38 : size.h;
    let [x0, x1, y0, y1] = [-ORB_R, ORB_R, -ORB_R, ORB_R];
    targets.forEach((b) => {
      x0 = Math.min(x0, b.x);
      x1 = Math.max(x1, b.x + b.w);
      y0 = Math.min(y0, b.y);
      y1 = Math.max(y1, b.y + b.h);
    });
    // A stage still filling keeps room for what comes, so nothing jumps.
    x1 = Math.max(x1, 175 + 110 + 300);
    y0 = Math.min(y0, -230);
    y1 = Math.max(y1, 230);
    const pad = 60;
    const k = clamp(Math.min(free / (x1 - x0 + pad * 2), freeH / (y1 - y0 + pad * 2)), 0.35, 1.1);
    return { k, x: left + free / 2 - ((x0 + x1) / 2) * k, y: freeH / 2 - ((y0 + y1) / 2) * k };
  }, [size, open, targets]);
  const fitRef = useRef(fitView);
  fitRef.current = fitView;
  const followRef = useRef(follow);
  followRef.current = follow;
  const targetsRef = useRef(targets);
  targetsRef.current = targets;
  const edgesRef = useRef(edges);
  edgesRef.current = edges;
  const dragging = useRef<string | null>(null);

  // One loop moves everything: things spring to their places, threads swing
  // between them, and the view eases to keep the stage in sight.
  const [, setFrame] = useState(0);
  useEffect(() => {
    let raf = 0;
    let last = performance.now();
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const step = (now: number) => {
      const dt = Math.min(0.033, (now - last) / 1000);
      last = now;
      let moving = false;
      const tg = targetsRef.current;
      for (const id of [...bodies.current.keys()]) if (!tg.has(id)) bodies.current.delete(id);
      tg.forEach((b, id) => {
        let body = bodies.current.get(id);
        if (!body) {
          // Everything comes out of the orb.
          body = still ? { x: b.x, y: b.y, vx: 0, vy: 0 } : { x: -b.w / 2, y: -b.h / 2, vx: 0, vy: 0 };
          bodies.current.set(id, body);
        }
        if (dragging.current === id) return;
        if (still) return void Object.assign(body, { x: b.x, y: b.y, vx: 0, vy: 0 });
        body.vx += (NODE_K * (b.x - body.x) - NODE_C * body.vx) * dt;
        body.vy += (NODE_K * (b.y - body.y) - NODE_C * body.vy) * dt;
        body.x += body.vx * dt;
        body.y += body.vy * dt;
        if (Math.abs(body.vx) + Math.abs(body.vy) > 0.5 || Math.abs(b.x - body.x) + Math.abs(b.y - body.y) > 0.3) moving = true;
      });
      // Threads: the control point hangs below the middle and lags behind.
      const live = new Set<string>();
      for (const e of edgesRef.current) {
        const from = e.from === ORB ? ("orb" as const) : bodyBox(e.from);
        const to = bodyBox(e.to);
        if (!from || !to) continue;
        live.add(e.id);
        const a = anchor(from, centre(to));
        const z = anchor(to, centre(from));
        const len = Math.hypot(z.x - a.x, z.y - a.y);
        const rest = { x: (a.x + z.x) / 2, y: (a.y + z.y) / 2 + 8 + len * 0.08 };
        let cp = strings.current.get(e.id);
        if (!cp) {
          cp = { x: rest.x, y: rest.y, vx: 0, vy: 0 };
          strings.current.set(e.id, cp);
        }
        if (still) {
          Object.assign(cp, { x: rest.x, y: rest.y });
          continue;
        }
        cp.vx += (STRING_K * (rest.x - cp.x) - STRING_C * cp.vx) * dt;
        cp.vy += (STRING_K * (rest.y - cp.y) - STRING_C * cp.vy) * dt;
        cp.x += cp.vx * dt;
        cp.y += cp.vy * dt;
        if (Math.abs(cp.vx) + Math.abs(cp.vy) > 0.5) moving = true;
      }
      for (const id of [...strings.current.keys()]) if (!live.has(id)) strings.current.delete(id);
      if (followRef.current) {
        const f = fitRef.current();
        const v = viewRef.current;
        if (f && (Math.abs(f.k - v.k) > 0.002 || Math.abs(f.x - v.x) > 0.5 || Math.abs(f.y - v.y) > 0.5)) {
          const e = still ? 1 : Math.min(1, dt * 3.5);
          setView({ k: v.k + (f.k - v.k) * e, x: v.x + (f.x - v.x) * e, y: v.y + (f.y - v.y) * e });
          moving = true;
        }
      }
      if (moving) setFrame((n) => (n + 1) % 1e6);
      raf = requestAnimationFrame(step);
    };
    const bodyBox = (id: string): Box | null => {
      const b = targetsRef.current.get(id);
      const body = bodies.current.get(id);
      return b && body ? { ...b, x: body.x, y: body.y } : null;
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, []);
  const boxNow = (id: string): Box | null => {
    const b = targets.get(id);
    const body = bodies.current.get(id);
    return b && body ? { ...b, x: body.x, y: body.y } : null;
  };

  const drag = useRef<{ x: number; y: number; vx: number; vy: number } | null>(null);
  // Wheel and pinch belong to the board. React's wheel listener is passive and
  // cannot claim the event, so a trackpad pinch (it arrives as ctrl+wheel) used
  // to zoom the board AND pinch-zoom the whole page — header, panel and dock
  // slid off screen. The canvas listens itself, not passively, and claims it.
  useEffect(() => {
    const cv = canvas.current;
    if (!cv) return;
    const wheel = (e: WheelEvent) => {
      // A list that scrolls on its own keeps a plain scroll.
      if (!e.ctrlKey && !e.metaKey && (e.target as HTMLElement).closest("[data-own-scroll]")) return;
      e.preventDefault();
      setFollow(false);
      const r = cv.getBoundingClientRect();
      const mx = e.clientX - r.left;
      const my = e.clientY - r.top;
      // A pixel delta is a trackpad; lines or pages are a mouse wheel.
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? r.height : 1;
      const dx = e.deltaX * unit;
      const dy = e.deltaY * unit;
      if (!e.ctrlKey && !e.metaKey) {
        setView((v) => ({ ...v, x: v.x - dx, y: v.y - dy }));
        return;
      }
      setView((v) => {
        const k = clamp(v.k * Math.exp(-dy * 0.01), MIN_ZOOM, MAX_ZOOM);
        return { k, x: mx - ((mx - v.x) / v.k) * k, y: my - ((my - v.y) / v.k) * k };
      });
    };
    cv.addEventListener("wheel", wheel, { passive: false });
    return () => cv.removeEventListener("wheel", wheel);
  }, []);
  // Nowhere on Cookie's page may a pinch zoom the page itself: over the panel,
  // the dock or the header it is claimed too (scrolling there is untouched).
  // Safari pinches with its own gesture events.
  useEffect(() => {
    const pinch = (e: WheelEvent) => {
      if (e.ctrlKey) e.preventDefault();
    };
    const gesture = (e: Event) => e.preventDefault();
    window.addEventListener("wheel", pinch, { passive: false });
    for (const g of ["gesturestart", "gesturechange", "gestureend"]) document.addEventListener(g, gesture, { passive: false });
    return () => {
      window.removeEventListener("wheel", pinch);
      for (const g of ["gesturestart", "gesturechange", "gestureend"]) document.removeEventListener(g, gesture);
    };
  }, []);
  /** Pick a thing up: it follows the pointer, its threads follow it. */
  const grab = (id: string) => (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest("button")) return;
    e.stopPropagation();
    const body = bodies.current.get(id);
    if (!body) return;
    dragging.current = id;
    const start = { x: e.clientX, y: e.clientY, bx: body.x, by: body.y };
    moved.current = false;
    const move = (ev: PointerEvent) => {
      if (Math.abs(ev.clientX - start.x) + Math.abs(ev.clientY - start.y) > 4) moved.current = true;
      const k = viewRef.current.k;
      body.x = start.bx + (ev.clientX - start.x) / k;
      body.y = start.by + (ev.clientY - start.y) / k;
      body.vx = body.vy = 0;
      setFrame((n) => (n + 1) % 1e6);
    };
    const up = () => {
      dragging.current = null;
      setDrags((d) => ({ ...d, [id]: { x: body.x, y: body.y } }));
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  // Hovering: a circle lights the paragraphs it fed; a paragraph lights the circles it drew on.
  const readOf = useMemo(() => new Map((stage?.reads ?? []).map((r) => [r.id, r])), [stage]);
  const product = outs.find((o) => o.kind === "answer" || o.kind === "draft")?.id;
  const litLines = useMemo<Set<number> | null>(() => {
    if (hover?.kind !== "node" || !lace) return null;
    const r = readOf.get(hover.id);
    if (!r) return null;
    return new Set(lace.sources.flatMap((ids, i) => (ids.some((sid) => r.steps.includes(Number(sid.slice(1)))) ? [i] : [])));
  }, [hover, lace, readOf]);
  const usedBy = (r: ReadNode, i: number) => (lace?.sources[i] ?? []).some((sid) => r.steps.includes(Number(sid.slice(1))));
  const nodeState = (id: string): "lit" | "dim" | undefined => {
    if (!hover) return undefined;
    if (hover.kind === "node") return hover.id === id ? "lit" : undefined;
    if (!(lace?.sources[hover.i] ?? []).length) return undefined;
    const r = readOf.get(id);
    if (r) return usedBy(r, hover.i) ? "lit" : "dim";
    return id === product ? "lit" : undefined;
  };
  const edgeState = (from: string, to: string): "lit" | "dim" | undefined => {
    const a = nodeState(from === ORB ? to : from);
    if (hover?.kind === "node") return hover.id === to || hover.id === from ? "lit" : undefined;
    return a;
  };

  const loadingReads = reads.filter((r) => r.landed == null || t < r.landed);
  const status = (() => {
    if (!run || !live) return "Ready";
    if (run.queued) return "Waiting for a turn";
    const now = loadingReads[loadingReads.length - 1];
    if (outs.some((o) => o.kind === "writing")) return "Writing";
    const helping = (run.helpers ?? []).filter((h) => h.state === "working").length;
    if (helping) return helping === 1 ? "A helper is researching" : `${helping} helpers researching`;
    if (!now) return t < INTRO ? "Reading the request" : "Thinking";
    if (now.kind === "context") return "Looking in your context";
    if (now.kind === "search") return "Searching the web";
    return `Reading ${now.label}`;
  })();
  const thought = thoughtOf(run);
  const needsYou = overview.waiting.length + runs.filter((r) => r.mine !== false && r.delivery === "asked").length;

  // Cookie looks at what you point at, else what it is reading.
  const gaze: Look = (() => {
    const id = hover?.kind === "node" ? hover.id : loadingReads[loadingReads.length - 1]?.id;
    const b = id ? boxNow(id) : null;
    if (!b) return null;
    const c = centre(b);
    const d = Math.hypot(c.x, c.y) || 1;
    return { x: (c.x / d) * 0.9, y: (c.y / d) * 0.9 };
  })();


  const onHoverLine = useCallback((i: number | null) => setHover(i === null ? null : { kind: "line", i }), []);
  const runId = run?.id;
  const onReplay = useCallback(
    (id: string) => {
      if (id !== runId) return onSelect(id);
      clearStage();
      setFollow(true);
      setReplayAt(performance.now());
    },
    [runId, onSelect],
  );
  const decide = async (action: "send" | "skip" | "take_over") => {
    if (!draft) return;
    setBusy(action);
    try {
      await onDecide(draft, action);
    } finally {
      setBusy(null);
    }
  };

  // What this job touched of what Cookie is wired to.
  const usedReach = useMemo(() => {
    const u = new Set<string>();
    if (!run) return u;
    if (run.trigger === "email" || run.trigger === "slack") u.add(run.trigger);
    if (run.delivery === "replied") u.add(run.trigger === "slack" ? "slack" : "email");
    for (const st of run.steps ?? []) for (const a of st.apps ?? []) u.add(`app:${a}`);
    return u;
  }, [run]);
  const hoveredReach = hover?.kind === "node" ? reachPlaces.find((p) => p.id === hover.id) : undefined;
  const hoveredRead = (pinned ? readOf.get(pinned) : undefined) ?? (hover?.kind === "node" ? readOf.get(hover.id) : undefined);
  const hoveredBox = hoveredRead ? boxNow(hoveredRead.id) : null;
  return (
    <div className={s.stage}>
      <div
        ref={canvas}
        className={s.canvas}
        style={{ backgroundSize: `${24 * view.k}px ${24 * view.k}px`, backgroundPosition: `${view.x}px ${view.y}px` }}
        onPointerDown={(e) => {
          setFollow(false);
          moved.current = false;
          drag.current = { x: e.clientX, y: e.clientY, vx: view.x, vy: view.y };
          (e.target as Element).setPointerCapture?.(e.pointerId);
        }}
        onPointerMove={(e) => {
          const d = drag.current;
          if (!d) return;
          if (Math.abs(e.clientX - d.x) + Math.abs(e.clientY - d.y) > 4) moved.current = true;
          setView((v) => ({ ...v, x: d.vx + e.clientX - d.x, y: d.vy + e.clientY - d.y }));
        }}
        onPointerUp={() => {
          // A click on the empty board closes a card held open; a drag does not.
          if (drag.current && !moved.current) setPinned(null);
          drag.current = null;
        }}
      >
        <div className={s.world} style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.k})` }}>
          <svg className={s.threads} width="1" height="1">
            {edges.map((e) => {
              const from = e.from === ORB ? ("orb" as const) : boxNow(e.from);
              const to = boxNow(e.to);
              const cp = strings.current.get(e.id);
              if (!from || !to || !cp) return null;
              const a = anchor(from, centre(to));
              const z = anchor(to, centre(from));
              const node = readOf.get(e.to) ?? readOf.get(e.from);
              const outNode = outs.find((o) => o.id === e.to);
              const toCircle = e.kind === "read" || e.kind === "via" || e.kind === "helper";
              const begun = node && (toCircle || e.kind === "app") ? node.start : outNode?.start ?? 0;
              const out = e.kind === "reach" ? 1 : clamp((t - begun) / 0.45);
              const loading = toCircle && node && (node.landed == null || t < node.landed);
              const beads: { p: number; back: boolean }[] = [];
              if (toCircle && node) {
                if (loading) beads.push({ p: ((t - node.start) % 0.9) / 0.9, back: false });
                else if (node.landed != null && t < node.landed + 0.55) beads.push({ p: (t - node.landed) / 0.55, back: true });
              }
              // Mail or Slack: the job flows in at the start, the reply flows out at the end.
              if (e.kind === "reach" && run) {
                const place = e.to;
                if (place === run.trigger && t < INTRO) beads.push({ p: t / INTRO, back: true });
                const replyTo = run.trigger === "slack" ? "slack" : "email";
                if (run.delivery === "replied" && place === replyTo && stage?.done != null && t >= stage.done && t < stage.done + 0.9) beads.push({ p: (t - stage.done) / 0.9, back: false });
              }
              // An app hands its notes to the circle that found them.
              if (e.kind === "app" && node?.landed != null && t >= node.landed - 0.55 && t < node.landed) beads.push({ p: (t - node.landed + 0.55) / 0.55, back: false });
              // What the answer drew on flows into it as it lands.
              if (e.kind === "fed" && stage?.done != null && t >= stage.done - 0.2 && t < stage.done + 0.6) beads.push({ p: (t - stage.done + 0.2) / 0.8, back: false });
              return (
                <g
                  key={e.id}
                  className={s.thread}
                  data-kind={e.kind}
                  data-used={e.kind === "reach" && usedReach.has(e.to) ? "true" : undefined}
                  data-loading={loading ? "true" : undefined}
                  data-state={edgeState(e.from, e.to)}
                >
                  <path d={`M${a.x},${a.y} Q${cp.x},${cp.y} ${z.x},${z.y}`} pathLength={1} strokeDasharray="1 1" strokeDashoffset={1 - out} />
                  {beads.map((bd, i) => {
                    const c = quad(a, cp, z, clamp(bd.back ? 1 - bd.p : bd.p));
                    return (
                      <g key={i}>
                        <circle cx={c.x} cy={c.y} r={bd.back ? 7 : 5} className={s.beadGlow} />
                        <circle cx={c.x} cy={c.y} r={bd.back ? 2.6 : 2} className={s.bead} />
                      </g>
                    );
                  })}
                  {out >= 1 && !toCircle && e.kind !== "reach" && e.kind !== "app" && <circle cx={z.x} cy={z.y} r={3} className={s.pin} />}
                </g>
              );
            })}
          </svg>
          {/* What Cookie read: one circle per source. */}
          {reads.map((r) => {
            const body = bodies.current.get(r.id);
            const landed = r.landed != null && t >= r.landed;
            const step = r.kind === "helper" ? undefined : staged!.steps[r.steps[r.steps.length - 1]];
            const app = step?.apps?.[0];
            return (
              <div
                key={r.id}
                className={s.circle}
                data-kind={r.kind}
                data-loading={landed ? undefined : "true"}
                data-failed={landed && !r.ok ? "true" : undefined}
                data-state={nodeState(r.id)}
                style={{ transform: `translate(${body?.x ?? -CIRCLE / 2}px, ${body?.y ?? -CIRCLE / 2}px)` }}
                onPointerEnter={() => setHover({ kind: "node", id: r.id })}
                onPointerLeave={() => setHover(null)}
                onPointerDown={grab(r.id)}
                onClick={() => !moved.current && setPinned((p) => (p === r.id ? null : r.id))}
                data-pinned={pinned === r.id ? "true" : undefined}
              >
                <span className={s.disc}>
                  {r.kind === "helper" ? (
                    <CookieOrb size={30} thinking={!landed} />
                  ) : r.kind === "context" ? (
                    <img src="/favicon.svg" alt="" width={20} height={20} />
                  ) : r.kind === "search" ? (
                    <Glyph kind="search" size={17} />
                  ) : (
                    <span className={s.mono}>{r.label.charAt(0).toUpperCase()}</span>
                  )}
                  {app && landed && (
                    <span className={s.badge} title={`From ${appName(app)}`}>
                      <ConnectorLogo slug={app.replace(/-/g, "")} name={appName(app)} size={11} variant="full" />
                    </span>
                  )}
                  {r.kind !== "helper" && r.steps.length > 1 && <i className={s.times}>×{r.steps.length}</i>}
                </span>
                <span className={s.circleLabel}>{r.label}</span>
              </div>
            );
          })}

          {/* What Cookie made. */}
          {outs.map((o) => {
            const body = bodies.current.get(o.id);
            const landed = o.landed != null && t >= o.landed;
            return (
              <BoardCard
                key={o.id}
                ref={measured(o.id)}
                card={outCard(o)}
                run={staged!}
                draft={draft}
                landed={landed}
                state={nodeState(o.id)}
                style={{ transform: `translate(${body?.x ?? 0}px, ${body?.y ?? -60}px)` }}
                onPointerEnter={() => setHover({ kind: "node", id: o.id })}
                onPointerLeave={() => setHover(null)}
                onPointerDown={grab(o.id)}
                footer={
                  o.kind === "draft" && draft ? (
                    <>
                      <button data-primary="true" disabled={!!busy} onClick={() => decide("send")}>
                        {busy === "send" ? "Sending…" : draft.slack ? "Post in thread" : "Send"}
                      </button>
                      {!draft.slack && (
                        <button disabled={!!busy} onClick={() => decide("take_over")}>
                          Edit in mail
                        </button>
                      )}
                      <button disabled={!!busy} onClick={() => decide("skip")}>
                        Skip
                      </button>
                    </>
                  ) : o.kind === "report" || o.kind === "leads" || (o.kind === "answer" && (run!.answer ?? "").length > 600) ? (
                    <button data-primary={o.kind === "answer" ? undefined : "true"} onClick={() => setReading(run!.id)}>
                      {o.kind === "report" ? "Read the report" : o.kind === "leads" ? "See every lead" : "Read it all"}
                    </button>
                  ) : o.kind === "questions" ? (
                    <button
                      data-primary="true"
                      onClick={() => {
                        setTab(run!.trigger === "page" ? "chat" : "inbox");
                        setOpen(true);
                      }}
                    >
                      Answer
                    </button>
                  ) : undefined
                }
              />
            );
          })}

          {/* What Cookie is wired to, each on its own thread. */}
          {reachPlaces.map((p) => {
            const body = bodies.current.get(p.id);
            return (
              <div
                key={p.id}
                className={s.reach}
                data-used={usedReach.has(p.id) ? "true" : undefined}
                data-ok={p.ok ? undefined : "false"}
                data-ghost={p.ghost ? "true" : undefined}
                onClick={p.ghost ? () => connect(p) : undefined}
                data-state={hover?.kind === "node" && hover.id === p.id ? "lit" : undefined}
                style={{ transform: `translate(${body?.x ?? -REACH / 2}px, ${body?.y ?? 240}px)` }}
                onPointerEnter={() => setHover({ kind: "node", id: p.id })}
                onPointerLeave={() => setHover(null)}
                onPointerDown={grab(p.id)}
              >
                <span className={s.reachDisc}>
                  {p.ghost && <i className={s.plus}>+</i>}
                  {p.kind === "app" ? (
                    <ConnectorLogo slug={p.provider!} name={p.label} size={18} variant="full" />
                  ) : p.kind === "slack" ? (
                    <img src="/connectors/color_slack.svg" alt="" width={16} height={16} />
                  ) : (
                    <Glyph kind="mail" size={16} />
                  )}
                </span>
                <span className={s.reachLabel}>{p.label}</span>
              </div>
            );
          })}
          {hoveredReach &&
            (() => {
              const b = boxNow(hoveredReach.id);
              if (!b) return null;
              return (
                <div className={s.reachNote} style={{ transform: `translate(${b.x + REACH + 12}px, ${b.y - 6}px)` }}>
                  {hoveredReach.ghost ? (
                    <>
                      <b>Connect {hoveredReach.label}</b>
                      <span>
                        {hoveredReach.id === "ghost:slack"
                          ? "Mention @Cookie in a channel or DM it, and it answers in the thread."
                          : `Cookie reads what syncs from ${hoveredReach.label} into your context.`}
                      </span>
                      <span className={s.reachAct}>{canConnect ? "Click to connect" : "Connect it from your dashboard"}</span>
                    </>
                  ) : (
                    <>
                  <b>{hoveredReach.label}</b>
                  <span>{hoveredReach.kind === "app" ? (hoveredReach.ok ? "Connected — syncs into your context" : "Connected — its sync is failing") : hoveredReach.kind === "email" ? overview.address : `In ${overview.slack?.workspace}`}</span>
                  <span>{wearLine(hoveredReach, wear.get(hoveredReach.id) ?? 0).replace(`${hoveredReach.label}: `, "")}</span>
                    </>
                  )}
                </div>
              );
            })()}

          {/* A circle opens into what it found while you point at it. */}
          {hoveredRead && hoveredBox && (
            <BoardCard
              card={readCard(hoveredRead)}
              run={staged!}
              landed={hoveredRead.landed != null && t >= hoveredRead.landed}
              floating
              pinned={pinned === hoveredRead.id}
              onClose={() => setPinned(null)}
              style={{ transform: `translate(${hoveredBox.x + CIRCLE + 14}px, ${hoveredBox.y - 24}px)` }}
            />
          )}

          <div className={s.orb}>
            <CookieOrb size={68} thinking={live} look={gaze} follow />
          </div>
          {thought && (
            <div className={s.thought} key={thought} aria-live="polite">
              <span>{thought}</span>
              <i />
              <i />
            </div>
          )}
          {!run && <p className={s.idle}>Give Cookie a job — by email, in Slack or here. You watch it work on this board.</p>}
          {run && run.mine === false && (
            <p className={s.idle}>
              {run.who ?? "A teammate"} asked this. What Cookie found and answered stays theirs.
            </p>
          )}
        </div>
      </div>

      {reading && run?.id === reading && run.answer && <Reader run={run} onClose={() => setReading(null)} />}

      <Conversations
        threads={threads}
        notices={(overview.notices ?? []).filter((n) => !n.label)}
        selectedKey={thread?.key ?? null}
        waiting={waitingRuns}
        status={status}
        live={live}
        needsYou={needsYou}
        onPick={onSelect}
        onNotices={() => {
          setTab("inbox");
          setOpen(true);
        }}
        onNeeds={() => {
          setTab("inbox");
          setOpen(true);
        }}
      />

      {/* Only once you have moved the board away: back to the whole job. */}
      {!follow && (
        <button className={s.fit} onClick={() => setFollow(true)} aria-label="Fit the board" title="Fit the board">
          <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
            <path d="M2 5V2h3M9 2h3v3M12 9v3H9M5 12H2V9" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      )}

      <CookiePanel
        overview={overview}
        run={run}
        thread={thread?.runs ?? []}
        onNew={onNew}
        onStop={onStop}
        onUndo={onUndo}
        onRoutine={onRoutine}
        onStopChase={onStopChase}
        onSoul={onSoul}
        tab={tab}
        onTab={setTab}
        open={open}
        onOpen={setOpen}
        onSelect={onSelect}
        litLines={litLines}
        onHoverLine={onHoverLine}
        onReplay={onReplay}
        onDecide={onDecide}
        onApproval={onApproval}
        onNotice={onNotice}
        onLesson={onLesson}
        onPermission={onPermission}
        onRule={onRule}
        onPrefs={onPrefs}
        onChannel={onChannel}
        onJob={onJob}
        onAnswer={onAnswer}
        onShare={onShare}
        onUnshare={onUnshare}
        onSetPin={onSetPin}
        onSlack={onSlack}
        onSignOut={onSignOut}
      />
    </div>
  );
}
