"use client";

// The jobs that are working, live: the answer as Cookie writes it, each step
// as it lands, the helpers at work, and whether a job still waits for its
// turn. One stream per working job, opened with a stream ticket straight at
// the gateway (`openLiveStream`, never through the BFF). The page's polling
// stays as it was, so a lost stream costs smoothness, never truth: what the
// stream adds is merged over what the run row says, and the row wins once the
// job is recorded.

import { useEffect, useRef, useState } from "react";
import type { CookieHelper, CookieRun, CookieStep } from "@/lib/api";
import { openLiveStream, type LiveStream } from "@/lib/streamTicket";

export type LiveRun = { text: string; steps: CookieStep[]; helpers: CookieHelper[]; queued: boolean; done: boolean };

/** Streams open at once; more working jobs than this show by polling. */
const MAX_STREAMS = 3;

type Frame = { text: string; helpers: CookieHelper[]; queued: boolean; done: boolean; steps_from: number; steps: CookieStep[] };

/** Fold one frame in. The first frame of every (re)connect carries all the
 *  steps (`steps_from` 0); later ones carry only the new. */
function fold(prev: LiveRun | undefined, f: Frame): LiveRun {
  const have = prev?.steps ?? [];
  const steps = f.steps_from === 0 ? f.steps : f.steps_from === have.length ? have.concat(f.steps) : have;
  return { text: f.text, steps, helpers: f.helpers, queued: f.queued, done: f.done };
}

export function useLiveRuns(projectId: string | null, runs: CookieRun[] | undefined, onDone: () => void): Record<string, LiveRun> {
  const [live, setLive] = useState<Record<string, LiveRun>>({});
  const streams = useRef(new Map<string, LiveStream>());
  const done = useRef(onDone);
  done.current = onDone;
  const working = (runs ?? [])
    // A teammate's job streams to them alone.
    .filter((r) => r.status === "running" && r.mine !== false)
    .slice(0, MAX_STREAMS)
    .map((r) => r.id)
    .join(",");

  useEffect(() => {
    if (!projectId) return;
    const want = new Set(working ? working.split(",") : []);
    for (const [id, s] of streams.current) {
      if (!want.has(id)) {
        s.close();
        streams.current.delete(id);
      }
    }
    for (const id of want) {
      if (streams.current.has(id)) continue;
      const path = `/v1/projects/${encodeURIComponent(projectId)}/cookie/runs/${encodeURIComponent(id)}/stream`;
      const stream = openLiveStream(path, {
        events: {
          live: (ev) => {
            let f: Frame;
            try {
              f = JSON.parse(ev.data) as Frame;
            } catch {
              return;
            }
            setLive((m) => ({ ...m, [id]: fold(m[id], f) }));
            if (f.done) {
              streams.current.get(id)?.close();
              streams.current.delete(id);
              done.current();
            }
          },
        },
      });
      streams.current.set(id, stream);
    }
  }, [projectId, working]);

  useEffect(
    () => () => {
      for (const s of streams.current.values()) s.close();
      streams.current.clear();
    },
    [],
  );

  // Forget what the run rows now say for themselves.
  useEffect(() => {
    const still = new Set((runs ?? []).filter((r) => r.status === "running").map((r) => r.id));
    setLive((m) => {
      const keep = Object.entries(m).filter(([id]) => still.has(id));
      return keep.length === Object.keys(m).length ? m : Object.fromEntries(keep);
    });
  }, [runs]);

  return live;
}

/** A working run with its live state laid over: the longer step list, the
 *  words so far, the helpers, the queue. A recorded run is returned as is. */
export function withLive(run: CookieRun, live: LiveRun | undefined): CookieRun {
  if (!live || run.status !== "running") return run;
  return {
    ...run,
    steps: live.steps.length > run.steps.length ? live.steps : run.steps,
    live_text: live.text || undefined,
    helpers: live.helpers,
    queued: live.queued,
  };
}
