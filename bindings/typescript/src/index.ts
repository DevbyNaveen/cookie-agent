// A TypeScript client for the Cookie Agent Harness. It runs `cookie serve` as
// a child process and speaks its protocol: one JSON object per line. The
// harness calls the model and runs the trust gates; your tools and your
// approver run here.

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, join } from "node:path";
import { createInterface } from "node:readline";

export type Effect = "read" | "write" | "outbound" | "destroy";
export const EFFECTS: readonly Effect[] = ["read", "write", "outbound", "destroy"];

export type JsonSchema = Record<string, unknown>;

export interface ToolDefinition<Args = any> {
  name: string;
  description?: string;
  /** What calling it does to the world. `outbound` and `destroy` always ask the approver. */
  effect: Effect;
  /** JSON schema of the arguments; `{"type":"object"}` if left out. */
  schema?: JsonSchema;
  /** Arguments (or JSON pointers like "/message/to") that must come from the person's words or `allow`. */
  guard?: string[];
  /** Its result goes to the model as text: strings as they are, anything else as JSON. A throw is sent as an error. */
  run: (args: Args) => unknown;
}

/** Check a tool definition and return it. */
export function tool<Args = any>(definition: ToolDefinition<Args>): ToolDefinition<Args> {
  if (!EFFECTS.includes(definition.effect)) {
    throw new TypeError(`unknown effect ${JSON.stringify(definition.effect)} (${EFFECTS.join(", ")})`);
  }
  return definition;
}

export interface ApprovalRequest {
  tool: string;
  effect: string;
  /** What will actually happen. */
  preview: string;
  reason: string;
  /** Values the person didn't write (`to = ...`), when the run asked for `confirm_data`. */
  fromData: string[];
}

/** Only a returned `true` is a yes. */
export type Approver = (request: ApprovalRequest) => boolean | Promise<boolean>;

export interface AgentOptions {
  /** `provider:model`, e.g. "anthropic:claude-sonnet-4-6". There is no default. */
  model: string;
  tools?: ToolDefinition[];
  instructions?: string;
  /** Values the person approved in advance (recipients, hosts). */
  allow?: string[];
  /** `false` turns Enkeon off. */
  enkeon?: boolean;
  /** Without one, every request is declined. */
  approver?: Approver;
  /** The `cookie` binary; else `COOKIE_BIN`, else `cookie` on PATH. */
  cookieBin?: string;
  /** A JSONL session file to resume and append to. */
  session?: string;
  /** Limits for each run; a limit left out keeps its default. */
  budget?: { max_steps?: number; max_tokens?: number; max_dollars?: number };
  /** Dollars per million tokens, needed for `max_dollars`. */
  prices?: { input: number; output: number; cache_read: number; cache_write: number };
  /** MCP servers for each run (see the protocol in the README). */
  mcp?: Record<string, unknown>[];
}

/** An image sent with one run; always untrusted content, never the person's words. */
export interface RunImage {
  media_type: "image/png" | "image/jpeg" | "image/gif" | "image/webp";
  /** Base64. */
  data: string;
  /** Where it came from: "screen" (the default), "web" or "file". */
  source?: "screen" | "web" | "file";
  /** Text sent just before the image; untrusted like the image. */
  caption?: string;
}

/** Options for one run. */
export interface RunOptions {
  images?: RunImage[];
}

/** A streamed event (`text_delta`, `tool_call_started`, `usage`, …), or the last one: `done`. */
export type AgentEvent = { type: "done"; answer: string } | { type: string; data?: unknown };

export class CookieError extends Error {
  override name = "CookieError";
}

type Line = Record<string, any>;

/** The child's stdout as a queue of lines. */
class Lines {
  #buffer: string[] = [];
  #waiter: ((line: string | null) => void) | undefined;
  #ended = false;

  constructor(stream: NodeJS.ReadableStream) {
    const lines = createInterface({ input: stream, crlfDelay: Infinity });
    lines.on("line", (line) => {
      if (!line.trim()) return;
      const waiter = this.#waiter;
      this.#waiter = undefined;
      waiter ? waiter(line) : this.#buffer.push(line);
    });
    lines.on("close", () => {
      this.#ended = true;
      this.#waiter?.(null);
      this.#waiter = undefined;
    });
  }

  next(): Promise<string | null> {
    if (this.#buffer.length) return Promise.resolve(this.#buffer.shift()!);
    if (this.#ended) return Promise.resolve(null);
    return new Promise((resolve) => (this.#waiter = resolve));
  }
}

interface Server {
  child: ChildProcessWithoutNullStreams;
  lines: Lines;
  exited: Promise<string>;
}

function findBinary(explicit?: string): string {
  const named = explicit ?? process.env.COOKIE_BIN;
  if (named) return named;
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, "cookie");
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {}
  }
  throw new CookieError("cannot find the cookie binary: set COOKIE_BIN or put `cookie` on PATH");
}

/**
 * A model, its instructions, your tools and who approves. One `cookie serve`
 * process is started on the first run and reused until `close()`. One run at
 * a time per agent.
 */
export class Agent {
  readonly options: AgentOptions;
  #tools = new Map<string, ToolDefinition>();
  #server: Server | undefined;
  #runs = 0;
  #running: string | undefined;

  constructor(options: AgentOptions) {
    this.options = options;
    for (const t of options.tools ?? []) {
      tool(t);
      if (this.#tools.has(t.name)) throw new TypeError(`tool ${JSON.stringify(t.name)} is declared twice`);
      this.#tools.set(t.name, t);
    }
  }

  /** Run to the end and return the answer. Rejects with CookieError if the run fails. */
  async run(input: string, options: RunOptions = {}): Promise<string> {
    for await (const event of this.stream(input, options)) {
      if (event.type === "done") return (event as { answer: string }).answer;
    }
    throw new CookieError("the run ended without an answer");
  }

  /**
   * The run's events, then `{type: "done", answer}`. Tool calls and approvals
   * are handled while you iterate. Leaving the loop early cancels the run.
   */
  async *stream(input: string, options: RunOptions = {}): AsyncGenerator<AgentEvent, void, undefined> {
    if (this.#running) throw new CookieError("a run is already going on this agent");
    const id = `r${++this.#runs}`;
    this.#running = id;
    let ended = false;
    try {
      const server = this.#start();
      const { model, instructions, allow, enkeon } = this.options;
      const run: Line = { type: "run", id, model, input };
      if (instructions !== undefined) run.instructions = instructions;
      if (allow !== undefined) run.allow = allow;
      if (enkeon !== undefined) run.enkeon = enkeon;
      for (const key of ["session", "budget", "prices", "mcp"] as const) {
        if (this.options[key] !== undefined) run[key] = this.options[key];
      }
      if (options.images?.length) run.images = options.images;
      run.tools = [...this.#tools.values()].map(({ name, description, effect, schema, guard }) => ({
        name,
        description: description ?? "",
        effect,
        guard: guard ?? [],
        schema: schema ?? { type: "object" },
      }));
      this.#send(run);
      while (true) {
        const line = await this.#read(server);
        if (line.run != null && line.run !== id) continue; // a late line from an earlier run
        switch (line.type) {
          case "event":
            yield line.event;
            break;
          case "tool_call":
            this.#send(await this.#call(line));
            break;
          case "approval":
            this.#send({ type: "approve", id: line.id, allow: await this.#approve(line) });
            break;
          case "done":
            ended = true;
            yield { type: "done", answer: line.answer ?? "" };
            return;
          case "error":
            if (line.run === id) {
              ended = true;
              throw new CookieError(String(line.message ?? ""));
            }
            // About a line we sent, not the run: stop the run, then report it.
            throw new CookieError(`cookie serve refused a message: ${line.message ?? ""}`);
          // Any other type is from a newer server; skip it.
        }
      }
    } finally {
      if (!ended) await this.#stop(id);
      this.#running = undefined;
      this.#idle();
    }
  }

  /** Stop the current run now. A no-op when nothing runs. */
  cancel(): void {
    if (this.#running) this.#trySend({ type: "cancel" });
  }

  /** Stop the current run after this turn's tools finish. */
  finishTurn(): void {
    if (this.#running) this.#trySend({ type: "finish_turn" });
  }

  /** End the `cookie serve` process. The agent starts a new one if run again. */
  async close(): Promise<void> {
    const server = this.#server;
    this.#server = undefined;
    if (!server) return;
    server.child.stdin.end();
    const timer = setTimeout(() => server.child.kill("SIGKILL"), 5000);
    await server.exited;
    clearTimeout(timer);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close();
  }

  async #call(line: Line): Promise<Line> {
    const reply: Line = { type: "tool_result", id: line.id };
    try {
      const t = this.#tools.get(line.name);
      if (!t) throw new Error(`no tool named ${JSON.stringify(line.name)} on this client`);
      const output = await t.run(line.args);
      reply.output = typeof output === "string" ? output : output === undefined || output === null ? "" : JSON.stringify(output);
      reply.is_error = false;
    } catch (e) {
      // The model sees the failure; the run goes on.
      reply.output = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
      reply.is_error = true;
    }
    return reply;
  }

  /** One answer, or one per item when the turn's actions came together. */
  async #approve(line: Line): Promise<boolean | boolean[]> {
    if (Array.isArray(line.items)) {
      const answers: boolean[] = [];
      for (const item of line.items as Line[]) answers.push(await this.#approveOne(item));
      return answers;
    }
    return this.#approveOne(line);
  }

  async #approveOne(line: Line): Promise<boolean> {
    const approver = this.options.approver;
    if (!approver) return false;
    const request: ApprovalRequest = {
      tool: String(line.tool ?? ""),
      effect: String(line.effect ?? ""),
      preview: String(line.preview ?? ""),
      reason: String(line.reason ?? ""),
      fromData: Array.isArray(line.from_data) ? line.from_data.map(String) : [],
    };
    try {
      return (await approver(request)) === true;
    } catch {
      return false;
    }
  }

  /** Cancel the run and read until it ends, so the process can take the next run. */
  async #stop(id: string): Promise<void> {
    const server = this.#server;
    if (!server) return;
    try {
      this.#send({ type: "cancel" });
      while (true) {
        const line = await this.#read(server);
        // Nothing else runs now: late tool calls and approvals are left unanswered.
        if (line.run === id && (line.type === "done" || line.type === "error")) return;
      }
    } catch {
      await this.close();
    }
  }

  #start(): Server {
    if (this.#server && this.#server.child.exitCode === null && this.#server.child.signalCode === null) {
      this.#ref(this.#server);
      return this.#server;
    }
    this.#server = undefined;
    const binary = findBinary(this.options.cookieBin);
    const child = spawn(binary, ["serve"], { stdio: ["pipe", "pipe", "inherit"] }) as unknown as ChildProcessWithoutNullStreams;
    child.stdin.on("error", () => {}); // a dead server shows up as the end of stdout
    const exited = new Promise<string>((resolve) => {
      child.on("error", (e) => resolve(`cannot start ${binary}: ${e.message}`));
      child.on("close", (code, signal) => resolve(`cookie serve exited (code ${code ?? signal})`));
    });
    this.#server = { child, lines: new Lines(child.stdout), exited };
    return this.#server;
  }

  /** Between runs the process must not keep Node alive. */
  #idle(): void {
    const server = this.#server;
    if (!server) return;
    server.child.unref();
    (server.child.stdout as any).unref?.();
    (server.child.stdin as any).unref?.();
  }

  #ref(server: Server): void {
    server.child.ref();
    (server.child.stdout as any).ref?.();
    (server.child.stdin as any).ref?.();
  }

  #send(message: Line): void {
    const server = this.#server;
    if (!server || !server.child.stdin.writable) throw new CookieError("cookie serve is not running");
    server.child.stdin.write(JSON.stringify(message) + "\n");
  }

  #trySend(message: Line): void {
    try {
      this.#send(message);
    } catch {}
  }

  async #read(server: Server): Promise<Line> {
    const text = await server.lines.next();
    if (text === null) {
      const why = await server.exited;
      if (this.#server === server) this.#server = undefined;
      throw new CookieError(why);
    }
    let line: unknown;
    try {
      line = JSON.parse(text);
    } catch {
      await this.close();
      throw new CookieError(`cookie serve sent a line that is not JSON: ${JSON.stringify(text.slice(0, 200))}`);
    }
    if (typeof line !== "object" || line === null || Array.isArray(line)) {
      await this.close();
      throw new CookieError(`cookie serve sent a line that is not a JSON object: ${JSON.stringify(text.slice(0, 200))}`);
    }
    return line as Line;
  }
}
