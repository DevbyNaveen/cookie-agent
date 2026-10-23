/**
 * Connector logo cache — same three layers as teamShellCache.
 *
 *   1. Memory Map     — decoded blob URLs + resolved stage (instant remount)
 *   2. sessionStorage — stage map survives reload in the same tab
 *   3. Cache API      — bytes survive reload; HTTP SWR is the network layer
 *
 * Never stores secrets. Logos are public brand marks under /connectors/.
 */

import { connectorMarkExt } from "./connectorLogos";

export type LogoStage = "mask" | "cdn" | "png" | "svg" | "fallback";

const STAGE_KEY = "tr.connector.logo.stage.v6";
const CACHE_NAME = "tr.connectors.v1";
const VALID_STAGES = new Set<LogoStage>(["mask", "cdn", "png", "svg", "fallback"]);

const stageMem = new Map<string, LogoStage>();
/** `${slug}.${ext}` → object URL from Cache API / decoded bytes. */
const blobMem = new Map<string, string>();
const inflight = new Map<string, Promise<string | null>>();

function canUseStorage(): boolean {
  return typeof window !== "undefined" && typeof sessionStorage !== "undefined";
}

function loadStageDisk(): Record<string, LogoStage> {
  if (!canUseStorage()) return {};
  try {
    const raw = sessionStorage.getItem(STAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (!parsed || typeof parsed !== "object") return {};
    const out: Record<string, LogoStage> = {};
    for (const [slug, stage] of Object.entries(parsed)) {
      if (typeof stage === "string" && VALID_STAGES.has(stage as LogoStage)) {
        out[slug] = stage as LogoStage;
      }
    }
    return out;
  } catch {
    return {};
  }
}

let diskStages: Record<string, LogoStage> | null = null;

function stages(): Record<string, LogoStage> {
  if (!diskStages) diskStages = loadStageDisk();
  return diskStages;
}

function persistStages() {
  if (!canUseStorage()) return;
  try {
    sessionStorage.setItem(STAGE_KEY, JSON.stringify(stages()));
  } catch {
    /* quota / private mode */
  }
}

export function getCachedLogoStage(slug: string): LogoStage | null {
  const hot = stageMem.get(slug);
  if (hot) return hot;
  const disk = stages()[slug];
  if (disk) {
    stageMem.set(slug, disk);
    return disk;
  }
  return null;
}

export function setCachedLogoStage(slug: string, stage: LogoStage): void {
  if (stageMem.get(slug) === stage && stages()[slug] === stage) return;
  stageMem.set(slug, stage);
  stages()[slug] = stage;
  persistStages();
}

function localPath(slug: string, ext: "svg" | "png"): string {
  return `/connectors/${slug}.${ext}`;
}

export function connectorMarkSrc(slug: string, ext: "svg" | "png"): string {
  return blobMem.get(`${slug}.${ext}`) ?? localPath(slug, ext);
}

async function fillFromCacheApi(
  slug: string,
  ext: "svg" | "png",
): Promise<string | null> {
  const key = `${slug}.${ext}`;
  const hit = blobMem.get(key);
  if (hit) return hit;
  const pending = inflight.get(key);
  if (pending) return pending;

  const work = (async () => {
    if (typeof window === "undefined" || !("caches" in window)) return null;
    const url = localPath(slug, ext);
    try {
      const cache = await caches.open(CACHE_NAME);
      let res = await cache.match(url);
      if (!res || !res.ok) {
        res = await fetch(url, { cache: "force-cache" });
        if (!res.ok) return null;
        await cache.put(url, res.clone());
      }
      const blob = await res.blob();
      if (blob.size < 32) return null;
      const obj = URL.createObjectURL(blob);
      const prev = blobMem.get(key);
      blobMem.set(key, obj);
      if (prev && prev !== obj) URL.revokeObjectURL(prev);
      return obj;
    } catch {
      return null;
    } finally {
      inflight.delete(key);
    }
  })();

  inflight.set(key, work);
  return work;
}

/** Warm Cache API + blob URLs in idle time so the grid never re-downloads.
 *
 *  Asks for the extension each mark actually ships as. It used to warm every
 *  slug as `.svg`, which meant the 27 PNG marks 404'd on every page load and
 *  were never warmed at all — the prefetch was, for those, pure cost. */
export function prefetchConnectorLogos(slugs: readonly string[]): void {
  if (typeof window === "undefined") return;
  const unique = [...new Set(slugs)];
  let i = 0;
  const batch = () => {
    const end = Math.min(i + 16, unique.length);
    for (; i < end; i++) {
      const slug = unique[i]!;
      // No local mark → nothing to warm. Fetching one anyway is the 404 this
      // prefetcher used to fire for every PNG-only and asset-less slug on
      // every page load.
      const ext = connectorMarkExt(slug);
      if (ext) void fillFromCacheApi(slug, ext);
    }
    if (i < unique.length) {
      if ("requestIdleCallback" in window) {
        requestIdleCallback(batch, { timeout: 400 });
      } else {
        setTimeout(batch, 32);
      }
    }
  };
  if ("requestIdleCallback" in window) {
    requestIdleCallback(batch, { timeout: 800 });
  } else {
    setTimeout(batch, 0);
  }
}
