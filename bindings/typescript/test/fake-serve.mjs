// A fake `cookie serve` that follows a script instead of a model.
// Script path in FAKE_SCRIPT, log path in FAKE_LOG. The script is a JSON list
// of steps, played in order:
//   {"read": "<type>"}    read the next line; it must have that type
//   {"write": {...}}      write one line; "run" is filled with the current run
//                         id unless the object already has a "run" key
//   {"write_raw": "..."}  write text as is
//   {"exit": <code>}      exit at once
// After the last step it reads until stdin closes. Every line read is
// appended to the log.
import { appendFileSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline";

const script = JSON.parse(readFileSync(process.env.FAKE_SCRIPT, "utf8"));
const log = process.env.FAKE_LOG;
appendFileSync(log, JSON.stringify({ type: "_started", pid: process.pid }) + "\n");
const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
let run = null;

async function read() {
  const { value, done } = await lines.next();
  if (done) return null;
  appendFileSync(log, value + "\n");
  return value;
}

const write = (text) => new Promise((resolve) => process.stdout.write(text, resolve));

for (const step of script) {
  if ("read" in step) {
    const line = await read();
    if (line === null) process.exit(4);
    const message = JSON.parse(line);
    if (message.type !== step.read) {
      await write(JSON.stringify({ type: "error", message: `fake: expected ${step.read}, got ${line}` }) + "\n");
      process.exit(3);
    }
    if (message.type === "run") run = message.id;
  } else if ("write" in step) {
    await write(JSON.stringify({ run, ...step.write }) + "\n");
  } else if ("write_raw" in step) {
    await write(step.write_raw);
  } else if ("exit" in step) {
    process.exit(step.exit);
  }
}
while ((await read()) !== null);
