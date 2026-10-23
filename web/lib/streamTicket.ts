// Long-lived streams go straight to the gateway, never through the BFF.
//
// The BFF (`app/api/gw/[...path]`) is a Vercel function: it is billed for
// provisioned memory every second a request is in flight and is cut at 300 s.
// Relaying an SSE feed through it kept a function alive per open tab — that is
// what burned the Hobby memory allowance in a week, while doing no work.
//
// So a stream opens in two steps:
//   1. mint a one-use ticket THROUGH the BFF (the only place the httpOnly
//      session cookie is readable; a `tr_sk_` key rides as the bearer, and the
//      BFF adds the session beside it exactly as for an engine call);
//   2. connect DIRECTLY to the gateway with `?ticket=` — no credential in the
//      URL, nothing on Vercel for the life of the stream.
// The gateway side is `services/gateway/src/stream_ticket.rs`.
//
// Kept free of `@/` imports so `node --test` can load it as-is.

/** The gateway, reached directly (Cloudflare → Caddy → gateway). */
export const DIRECT_GATEWAY = process.env.NEXT_PUBLIC_GATEWAY_URL ?? "https://api.thinkingroot.com";

export class StreamTicketError extends Error {
  readonly status: number;
  /** The gateway's error body, parsed when it was JSON. */
  readonly body: unknown;
  constructor(status: number, body: unknown) {
    super(`stream ticket refused (${status})`);
    this.status = status;
    this.body = body;
  }
}

/** Mint a one-use ticket for one method + gateway path (`/v1/…/stream`,
 *  `/engine/api/v1/…/stream`). `bearer` is the `tr_sk_` key for engine paths;
 *  without it the BFF uses the signed-in session. */
export async function mintStreamTicket(
  path: string,
  opts: { bearer?: string; method?: "GET" | "POST"; signal?: AbortSignal } = {},
): Promise<string> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (opts.bearer) headers.authorization = `Bearer ${opts.bearer}`;
  const res = await fetch("/api/gw/v1/stream-tickets", {
    method: "POST",
    headers,
    body: JSON.stringify({ path, method: opts.method ?? "GET" }),
    signal: opts.signal,
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    let body: unknown = text;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      /* not JSON — keep the text */
    }
    throw new StreamTicketError(res.status, body);
  }
  const { ticket } = (await res.json()) as { ticket?: string };
  if (!ticket) throw new StreamTicketError(502, "no ticket in the reply");
  return ticket;
}

/** The direct gateway URL a ticket opens. */
export function ticketedUrl(path: string, ticket: string, base: string = DIRECT_GATEWAY): string {
  return `${base}${path}${path.includes("?") ? "&" : "?"}ticket=${encodeURIComponent(ticket)}`;
}

/** Backoff before reconnect `attempt` (0-based): exponential from 1 s to a
 *  30 s ceiling, with half of it jittered so a gateway restart is not met by
 *  every open tab in the same millisecond. */
export function reconnectDelayMs(attempt: number, random: () => number = Math.random): number {
  const ceiling = Math.min(30_000, 1_000 * 2 ** Math.max(0, attempt));
  return Math.round(ceiling / 2 + (random() * ceiling) / 2);
}

/** A refused mint that retrying cannot fix: a bad path (400), signed out
 *  after the BFF's own refresh (401), or no access (403). Anything else —
 *  a gateway restart, a 5xx, the network — is retried. */
export function mintFailureIsFinal(status: number): boolean {
  return status === 400 || status === 401 || status === 403;
}

export type LiveStream = { close(): void };

export type LiveStreamHandlers = {
  /** `tr_sk_` key for an engine stream; omit for a session-authed one. */
  bearer?: string;
  /** Connected. `reconnected` is true on every open after the first — the
   *  moment to refetch whatever the gap may have dropped. */
  onOpen?: (reconnected: boolean) => void;
  onMessage?: (ev: MessageEvent<string>) => void;
  /** Named SSE events (`event: resync` …). */
  events?: Record<string, (ev: MessageEvent<string>) => void>;
  /** Connection lost; a reconnect is scheduled unless the refusal was final. */
  onDown?: () => void;
};

/** Open a live SSE feed straight at the gateway and keep it open: every
 *  (re)connect mints a fresh ticket (a ticket opens once, so the browser's
 *  own auto-reconnect could not reuse its URL). Browser-only. */
export function openLiveStream(path: string, h: LiveStreamHandlers): LiveStream {
  let closed = false;
  let es: EventSource | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;
  let attempt = 0;
  let openedBefore = false;

  const retry = () => {
    if (closed) return;
    timer = setTimeout(connect, reconnectDelayMs(attempt++));
  };

  async function connect() {
    timer = null;
    let ticket: string;
    try {
      ticket = await mintStreamTicket(path, { bearer: h.bearer });
    } catch (e) {
      if (closed) return;
      h.onDown?.();
      if (e instanceof StreamTicketError && mintFailureIsFinal(e.status)) return;
      retry();
      return;
    }
    if (closed) return;
    const source = new EventSource(ticketedUrl(path, ticket));
    es = source;
    source.onopen = () => {
      attempt = 0;
      h.onOpen?.(openedBefore);
      openedBefore = true;
    };
    if (h.onMessage) source.onmessage = h.onMessage;
    for (const [name, fn] of Object.entries(h.events ?? {})) {
      source.addEventListener(name, fn as EventListener);
    }
    source.onerror = () => {
      source.close();
      if (es === source) es = null;
      if (closed) return;
      h.onDown?.();
      retry();
    };
  }

  void connect();
  return {
    close() {
      closed = true;
      if (timer) clearTimeout(timer);
      es?.close();
      es = null;
    },
  };
}
