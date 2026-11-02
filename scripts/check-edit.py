#!/usr/bin/env python3
"""Smoke-test the real on-device voice editor, without microphone or text injection.

Exit 2 means the model is unavailable; passing is not a broad accuracy benchmark.
"""
import argparse
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", nargs="?", default=str(
        Path(__file__).resolve().parents[1] / "Helpers/enkeon-sense/.build/release/enkeon-sense"))
    args = parser.parse_args()
    process = subprocess.Popen([args.helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def read_exact(count, deadline):
        result = bytearray()
        while len(result) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise TimeoutError("edit helper exceeded its deadline")
            part = os.read(process.stdout.fileno(), count - len(result))
            if not part:
                raise RuntimeError("edit helper closed its output")
            result.extend(part)
        return bytes(result)

    def call(request):
        raw = json.dumps(request).encode()
        process.stdin.write(struct.pack(">I", len(raw)) + raw + struct.pack(">I", 0))
        process.stdin.flush()
        deadline = time.monotonic() + 30
        size = struct.unpack(">I", read_exact(4, deadline))[0]
        if size > 8 * 1024 * 1024:
            raise RuntimeError("oversized helper reply")
        reply = json.loads(read_exact(size, deadline))
        payload_size = struct.unpack(">I", read_exact(4, deadline))[0]
        if payload_size > 8 * 1024 * 1024:
            raise RuntimeError("oversized helper payload")
        read_exact(payload_size, deadline)
        if reply.get("id") != request["id"] or reply.get("error"):
            raise RuntimeError(f"helper request failed: {reply}")
        return reply

    try:
        hello = call({"op": "hello", "id": "edit-check-hello"})
        if not hello.get("cleanup"):
            print("On-device editor unavailable:", hello.get("cleanupNote", "unknown reason"))
            return 2
        fixtures = [
            ("We is ready.", "Fix the grammar.", ["we are ready"]),
            ("I wanted to let you know that the report will be ready by Friday afternoon at the latest.",
             "Make this shorter. Keep the deadline.", ["report", "friday", "afternoon"]),
        ]
        for index, (source, instruction, expected) in enumerate(fixtures):
            started = time.monotonic()
            reply = call({"op": "rewrite", "id": f"edit-check-{index}", "mode": "edit",
                          "text": source, "instruction": instruction, "samples": []})
            output = reply.get("text", "")
            print(f"{index + 1}: {time.monotonic() - started:.2f}s — {output}")
            if not output or any(term not in output.lower() for term in expected):
                raise AssertionError("edit fixture failed: " + repr(output))
        print("Edit helper smoke checks passed (2 English fixtures; no UI insertion tested).")
        return 0
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    raise SystemExit(main())
