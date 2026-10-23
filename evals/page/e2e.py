#!/usr/bin/env python3
"""`cookie page`, end to end: the requests Cookie's page makes, against a real
model and a real folder. Standard library only.

  python3 evals/page/e2e.py --cookie target/debug/cookie --model bedrock:eu.anthropic.claude-sonnet-4-6 \
      --folder . --page web/out [--port 4799]

Starts `cookie page` with a fresh --home, drives it as the page does, restarts
it, and exits 1 on the first thing that is not as it should be. Costs a few
model calls.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ARGS = None
BASE = ""
ORIGIN = ""
PROJECT = "/api/gw/v1/projects/local/cookie"


def call(method, path, body=None, headers=None, expect=200):
    data = None if body is None else json.dumps(body).encode()
    h = {"content-type": "application/json", "origin": ORIGIN, **(headers or {})}
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, text, ctype = r.status, r.read().decode(), r.headers.get("content-type", "")
    except urllib.error.HTTPError as e:
        status, text, ctype = e.code, e.read().decode(), e.headers.get("content-type", "")
    if status != expect:
        fail(f"{method} {path}: HTTP {status}, wanted {expect}: {text[:300]}")
    return json.loads(text) if "json" in ctype and text else text


def fail(why):
    print(f"FAIL {why}")
    sys.exit(1)


def check(ok, what):
    if not ok:
        fail(what)
    print(f"ok   {what}")


def follow(run_id, deadline=240):
    """Open the live stream as the page does (a ticket, then the stream at the
    page's own address) and read frames until `done`."""
    path = f"/v1/projects/local/cookie/runs/{run_id}/stream"
    ticket = call("POST", "/api/gw/v1/stream-tickets", {"path": path, "method": "GET"})["ticket"]
    req = urllib.request.Request(f"{BASE}{path}?ticket={ticket}", headers={"origin": ORIGIN})
    frames, steps, text = 0, [], ""
    end = time.time() + deadline
    with urllib.request.urlopen(req, timeout=deadline) as r:
        check("text/event-stream" in r.headers.get("content-type", ""), "the stream is an event stream")
        event = None
        for raw in r:
            line = raw.decode().rstrip("\n")
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: ") and event == "live":
                f = json.loads(line[6:])
                frames += 1
                steps = f["steps"] if f["steps_from"] == 0 else steps + f["steps"]
                text = f["text"] or text
                if f["done"]:
                    return frames, steps, text, ticket
            if time.time() > end:
                fail("the stream did not finish in time")
    fail("the stream ended without a done frame")


def wait_done(run_id, deadline=240):
    end = time.time() + deadline
    while time.time() < end:
        run = call("GET", f"{PROJECT}/runs/{run_id}")
        if run["status"] != "running":
            return run
        time.sleep(1)
    fail(f"{run_id} still running")


def start(home):
    cmd = [ARGS.cookie, "page", ARGS.folder, "--model", ARGS.model, "--home", home, "--port", str(ARGS.port), "--page", ARGS.page]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    for _ in range(100):
        try:
            urllib.request.urlopen(f"{BASE}/api/cookie/who", timeout=1)
            return proc
        except Exception:
            if proc.poll() is not None:
                fail(f"cookie page exited: {proc.stderr.read()[:400]}")
            time.sleep(0.1)
    fail("cookie page did not start")


def main():
    global ARGS, BASE, ORIGIN
    ap = argparse.ArgumentParser()
    ap.add_argument("--cookie", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--folder", required=True)
    ap.add_argument("--page", required=True)
    ap.add_argument("--port", type=int, default=4799)
    ARGS = ap.parse_args()
    BASE = ORIGIN = f"http://127.0.0.1:{ARGS.port}"
    home = tempfile.mkdtemp(prefix="cookie-page-e2e-")
    proc = start(home)
    try:
        # The doors: only this machine, only the page.
        call("GET", "/api/cookie/who", headers={"host": "evil.example"}, expect=403)
        check(True, "a request for another host is refused (DNS rebinding)")
        call("GET", "/api/cookie/who", headers={"origin": "https://evil.example"}, expect=403)
        check(True, "a request from another site is refused")
        call("POST", f"{PROJECT}/jobs", {"text": "hi"}, headers={"origin": "https://evil.example"}, expect=403)
        check(True, "another site cannot start a job")

        # The page itself.
        req = urllib.request.Request(BASE + "/", headers={"origin": ORIGIN})
        opener = urllib.request.build_opener(type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda *a, **k: None}))
        try:
            opener.open(req, timeout=10)
            fail("/ did not redirect")
        except urllib.error.HTTPError as e:
            check(e.code == 302 and e.headers.get("location") == "/me/local/cookie", "/ opens the page")
        html = call("GET", "/me/local/cookie")
        check("<html" in html and "_next/static" in html, "the built page is served")
        call("GET", "/me/local/..%2f..%2f..%2fetc%2fpasswd", expect=404)
        check(True, "a path outside the page folder is not served")

        # What the page asks first.
        check(call("GET", "/api/cookie/who")["signed_in"] is True, "who: the person at this computer")
        me = call("GET", "/api/gw/identity/me")
        check(me["orgs"][0]["slug"] == "me", "me: one org")
        projects = call("GET", "/api/gw/provisioner/api/v1/projects?org=me")
        check(projects[0]["id"] == "local" and projects[0]["slug"] == "local", "projects: one folder")
        ov = call("GET", PROJECT)
        check(ov["enabled"] and ov["runs"] == [] and ov["credits"]["allowance"] == 0, "overview: empty, no credits")

        # A job, followed live.
        job = call("POST", f"{PROJECT}/jobs", {"text": "What does this project do? Name two files you looked at, with their paths."})
        frames, steps, text, ticket = follow(job["run_id"])
        check(frames >= 2, f"the stream sent {frames} frames")
        check(any(s["tool"] == "recall" for s in steps), "the folder reads show on the board as notes")
        check(all({"at_ms", "tool", "what", "ok"} <= s.keys() for s in steps), "every step has what the board draws")
        run = wait_done(job["run_id"])
        check(run["status"] == "done" and len(run["answer"] or "") > 80, "the job answered")
        check(run["steps"] and run["finished_at"], "the finished job keeps its steps")
        bad = urllib.request.Request(f"{BASE}/v1/projects/local/cookie/runs/{job['run_id']}/stream?ticket={ticket}", headers={"origin": ORIGIN})
        try:
            urllib.request.urlopen(bad, timeout=10)
            fail("a used ticket opened a stream")
        except urllib.error.HTTPError as e:
            check(e.code == 401, "a ticket opens one stream only")

        # A follow-up in the same conversation reads what came before.
        conv = run["conversation"]
        again = call("POST", f"{PROJECT}/jobs", {"text": "In one sentence: what did I ask you just before this?", "conversation": conv})
        run2 = wait_done(again["run_id"])
        check(run2["conversation"] == conv, "the follow-up stays in its conversation")
        check(any(w in (run2["answer"] or "").lower() for w in ("project", "files", "folder")), "the follow-up remembers the first question")

        # Stop.
        long = call("POST", f"{PROJECT}/jobs", {"text": "Read every file in this folder one by one and write a long report on each."})
        time.sleep(4)
        check(call("POST", f"{PROJECT}/runs/{long['run_id']}/stop", {})["stopping"] is True, "stop reaches a working job")
        stopped = wait_done(long["run_id"], 60)
        check(stopped["delivery"] == "stopped", "a stopped job says so")

        # The SOUL, and what Enkeon adds.
        call("PUT", f"{PROJECT}/soul", {"text": "Be brief. We sell to Baltic CTOs."})
        check(call("GET", PROJECT)["viewer"]["soul"] == "Be brief. We sell to Baltic CTOs.", "the SOUL is kept")
        call("POST", f"{PROJECT}/drafts/x", {"action": "send"}, expect=404)
        check(True, "team features answer plainly that they come with Enkeon")
        check(len(os.listdir(os.path.join(home, "runs"))) == 3, "each job is one file")
        check(os.path.exists(os.path.join(home, "conversations", f"{conv}.jsonl")), "each conversation is one session file")
    finally:
        proc.terminate()
        proc.wait(10)

    # Restart: everything is still there.
    proc = start(home)
    try:
        runs = call("GET", PROJECT)["runs"]
        check(len(runs) == 3 and all(r["status"] != "running" for r in runs), "after a restart the jobs are all there")
    finally:
        proc.terminate()
        proc.wait(10)
        shutil.rmtree(home, ignore_errors=True)
    print("cookie page: every check passed")


if __name__ == "__main__":
    main()
