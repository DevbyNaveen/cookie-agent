"""A fake `cookie serve` that follows a script instead of a model.

Usage: fake_serve.py serve   (script path in FAKE_SCRIPT, log path in FAKE_LOG)

The script is a JSON list of steps, played in order:
  {"read": "<type>"}   read the next line; it must have that type
  {"write": {...}}     write one line; "run" is filled with the current run id
                       unless the object already has a "run" key
  {"write_raw": "..."} write text as is (for lines that are not JSON)
  {"exit": <code>}     exit at once
After the last step it reads until stdin closes. Every line read is appended
to the log, so a test can check what the client sent.
"""

import json
import os
import sys


def main():
    script = json.load(open(os.environ["FAKE_SCRIPT"]))
    log = open(os.environ["FAKE_LOG"], "a")
    log.write(json.dumps({"type": "_started", "pid": os.getpid()}) + "\n")
    log.flush()
    run = None

    def read():
        line = sys.stdin.readline()
        if line:
            log.write(line if line.endswith("\n") else line + "\n")
            log.flush()
        return line

    for step in script:
        if "read" in step:
            line = read()
            if not line:
                sys.exit(4)
            message = json.loads(line)
            if message.get("type") != step["read"]:
                sys.stdout.write(json.dumps({"type": "error", "message": "fake: expected %s, got %s" % (step["read"], line.strip())}) + "\n")
                sys.stdout.flush()
                sys.exit(3)
            if message["type"] == "run":
                run = message["id"]
        elif "write" in step:
            message = dict(step["write"])
            message.setdefault("run", run)
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()
        elif "write_raw" in step:
            sys.stdout.write(step["write_raw"])
            sys.stdout.flush()
        elif "exit" in step:
            sys.exit(step["exit"])
    while read():
        pass


if __name__ == "__main__":
    main()
