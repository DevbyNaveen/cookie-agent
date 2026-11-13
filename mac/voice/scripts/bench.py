#!/usr/bin/env python3
"""EnkeonDict: word error rate and latency of Enkeon's on-device speech path, clip by clip.

  scripts/bench.py DIR [--helper PATH] [--cleanup STYLE] [--fast]
  scripts/bench.py --make-synthetic DIR      (a smoke set spoken by macOS voices)

DIR holds clips (any format afconvert reads: .wav .m4a .aiff .caf .mp3) and, next to each, a .txt with
exactly what was said. Subfolders are categories (clean/, names/, accented/, noisy/, …) and are
reported separately. Audio is fed at real speed in 100 ms buffers, as the microphone would, unless --fast.

Latency is from the last audio buffer ("key up") to the final text: the part the person waits for.
Synthetic clips measure the pipeline, not people: real EnkeonDict clips are recorded voices.
"""
import argparse, json, os, struct, subprocess, sys, tempfile, time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT_HELPER = os.path.join(ROOT, "Helpers", "enkeon-sense", ".build", "release", "enkeon-sense")
AUDIO = (".wav", ".m4a", ".aiff", ".aif", ".caf", ".mp3")

SYNTHETIC = {
    "clean": [("Samantha", "Please send the quarterly report to the whole team before Friday afternoon."),
              ("Daniel", "The meeting moved to Wednesday at three, so we have one more day to prepare."),
              ("Karen", "Can you check whether the invoice was paid and let me know by tomorrow?")],
    "names": [("Samantha", "Send the Halvorsen pricing to Maria and copy Jonas on the thread."),
              ("Daniel", "Brightline Retail wants the Slack integration before their trial ends."),
              ("Moira", "Ask Priya to update the Enkeon roadmap with the Gossip launch dates.")],
    "accented": [("Rishi", "We need to finish the dashboard changes and push them before the demo."),
                 ("Aman", "Please share the onboarding document with the new engineers today."),
                 ("Tessa", "The customer asked for a refund because the order arrived late.")],
    "numbers": [("Samantha", "We agreed on twenty five dollars per seat for one hundred and twenty seats."),
                ("Daniel", "Call me at four thirty and book the room for the fourteenth of November.")],
}


UNITS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
                                       "fifteen sixteen seventeen eighteen nineteen".split())}
TENS = {w: 10 * (i + 2) for i, w in enumerate("twenty thirty forty fifty sixty seventy eighty ninety".split())}
ORDINALS = {"first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
            "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "twentieth": 20,
            "thirtieth": 30}


def numbers_as_digits(tokens):
    """Spoken numbers as the recognizer writes them, so formatting isn't scored as an error:
    "twenty five" → 25, "one hundred and twenty" → 120, "fourteenth" → 14th, "four thirty" → 430 (as heard: 4:30)."""
    out, i = [], 0
    while i < len(tokens):
        value, j, used = 0, i, False
        while j < len(tokens):
            t = tokens[j]
            if t in UNITS and not (used and value % 100 and value % 10):
                value += UNITS[t]; used = True
            elif t in TENS and not (used and value % 100):
                value += TENS[t]; used = True
            elif t == "hundred" and used:
                value *= 100
            elif t == "and" and used and j + 1 < len(tokens) and (tokens[j + 1] in UNITS or tokens[j + 1] in TENS):
                pass
            elif t in ORDINALS:
                out.append(f"{value + ORDINALS[t] if used else ORDINALS[t]}th"); j += 1; used = None
                break
            else:
                break
            j += 1
        if used is None:
            i = j
        elif used:
            # "four thirty" (a time) is two groups the recognizer writes as one: join consecutive groups.
            if out and out[-1].isdigit() and i > 0 and (tokens[i - 1] in UNITS or tokens[i - 1] in TENS):
                out[-1] += str(value)
            else:
                out.append(str(value))
            i = j
        else:
            out.append(tokens[i]); i += 1
    return out


def words(text):
    import re
    text = re.sub(r"\$(\d[\d,]*(?:\.\d+)?)", r"\1 dollars", text)  # "$25" is how "twenty five dollars" is written
    text = re.sub(r"(\d),(\d{3})", r"\1\2", text)
    keep = "".join(c.lower() if c.isalnum() or c.isspace() or c == "'" else " " for c in text)
    tokens = [t[:-2] + "th" if t[:-2].isdigit() and t[-2:] in ("st", "nd", "rd") else t for t in keep.split()]
    return numbers_as_digits(tokens)


def wer(reference, hypothesis):
    r, h = words(reference), words(hypothesis)
    if not r:
        return 0.0 if not h else 1.0
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        previous, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            current = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, previous + (r[i - 1] != h[j - 1]))
            previous = current
    return d[len(h)] / len(r)


class Helper:
    def __init__(self, path):
        self.proc = subprocess.Popen([path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.n = 0

    def send(self, obj, payload=b""):
        body = json.dumps(obj).encode()
        self.proc.stdin.write(struct.pack(">I", len(body)) + body + struct.pack(">I", len(payload)) + payload)
        self.proc.stdin.flush()

    def receive(self):
        head = self.proc.stdout.read(4)
        if len(head) < 4:
            sys.exit("the helper stopped")
        body = json.loads(self.proc.stdout.read(struct.unpack(">I", head)[0]))
        self.proc.stdout.read(struct.unpack(">I", self.proc.stdout.read(4))[0])
        return body

    def next_id(self):
        self.n += 1
        return f"b{self.n}"


def pcm16(path, tmp):
    wav = os.path.join(tmp, "clip.wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, wav], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import wave
    with wave.open(wav, "rb") as audio:
        if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() != 16000:
            raise ValueError("afconvert did not produce mono 16 kHz PCM16")
        return audio.readframes(audio.getnframes())


def transcribe(helper, pcm, realtime):
    sid = helper.next_id()
    helper.send({"op": "speech.start", "id": sid, "locale": "en-US"})
    started = helper.receive()
    if not started.get("ok"):
        raise RuntimeError(started.get("error", "speech.start failed"))
    for i in range(0, len(pcm), 3200):
        helper.send({"op": "speech.audio", "id": sid}, pcm[i:i + 3200])
        if realtime:
            time.sleep(0.1)
    key_up = time.perf_counter()
    helper.send({"op": "speech.finish", "id": sid})
    while True:
        event = helper.receive()
        if event.get("event") == "final":
            return event.get("text", ""), (time.perf_counter() - key_up) * 1000
        if event.get("error") or event.get("event") not in (None, "volatile"):
            raise RuntimeError(str(event))


def cleanup(helper, text, style):
    helper.send({"op": "cleanup.warm", "id": helper.next_id(), "style": style})
    time.sleep(1.0)  # the person is still talking while it warms
    cid = helper.next_id()
    started = time.perf_counter()
    helper.send({"op": "cleanup", "id": cid, "text": text, "style": style})
    reply = helper.receive()
    return reply.get("text") or "", (time.perf_counter() - started) * 1000, reply.get("error")


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))] if ordered else float("nan")


def make_synthetic(directory):
    for category, lines in SYNTHETIC.items():
        os.makedirs(os.path.join(directory, category), exist_ok=True)
        for index, (voice, text) in enumerate(lines):
            base = os.path.join(directory, category, f"{voice.lower()}-{index}")
            subprocess.run(["say", "-v", voice, "-o", base + ".aiff", text], check=True)
            open(base + ".txt", "w").write(text + "\n")
    import wave
    silent_dir = os.path.join(directory, "silence")
    os.makedirs(silent_dir, exist_ok=True)
    with wave.open(os.path.join(silent_dir, "quiet.wav"), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(16000)
        audio.writeframes(b"\0" * 64000)
    with open(os.path.join(silent_dir, "quiet.txt"), "w") as reference:
        reference.write("")
    print(f"wrote {sum(len(v) for v in SYNTHETIC.values())} synthetic speech clips and one silence clip to {directory}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dir")
    parser.add_argument("--helper", default=DEFAULT_HELPER)
    parser.add_argument("--cleanup", metavar="STYLE", help="also time the clean-up (neutral, formal, casual, lowercase)")
    parser.add_argument("--fast", action="store_true", help="feed audio as fast as possible (latency is then not meaningful)")
    parser.add_argument("--make-synthetic", action="store_true")
    args = parser.parse_args()
    if args.make_synthetic:
        return make_synthetic(args.dir)

    clips = sorted(os.path.join(dp, f) for dp, _, fs in os.walk(args.dir) for f in fs if f.lower().endswith(AUDIO))
    if not clips:
        sys.exit(f"no clips in {args.dir}")
    helper = Helper(args.helper)
    helper.send({"op": "hello", "id": "hello-1"})
    hello = helper.receive()
    if not hello.get("speech"):
        sys.exit("the helper has no speech model for this language yet (run again once macOS installs it)")

    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for clip in clips:
            reference_path = os.path.splitext(clip)[0] + ".txt"
            if not os.path.exists(reference_path):
                print(f"skip {clip}: no .txt next to it")
                continue
            reference = open(reference_path).read().strip()
            category = os.path.relpath(os.path.dirname(clip), args.dir).split(os.sep)[0] or "."
            heard, latency = transcribe(helper, pcm16(clip, tmp), realtime=not args.fast)
            row = {"clip": os.path.relpath(clip, args.dir), "category": category, "wer": wer(reference, heard),
                   "latency_ms": latency, "heard": heard, "reference": reference}
            if args.cleanup:
                cleaned, cleanup_ms, error = cleanup(helper, heard, args.cleanup)
                row.update(cleanup_ms=cleanup_ms, cleaned=cleaned or error or "", cleaned_wer=wer(reference, cleaned) if cleaned else None)
            rows.append(row)
            note = f"  cleanup {row['cleanup_ms']:.0f} ms" if args.cleanup else ""
            print(f"{row['wer'] * 100:5.1f}% WER  {latency:6.0f} ms{note}  {row['clip']}")
            if row["wer"] > 0:
                print(f"         said:  {reference}\n         heard: {heard}")
    helper.proc.stdin.close()

    print("\ncategory        clips   WER    p50 ms   p95 ms" + ("   cleanup p50" if args.cleanup else ""))
    for category in sorted({r["category"] for r in rows}) + ["ALL"]:
        group = [r for r in rows if category == "ALL" or r["category"] == category]
        total_words = sum(len(words(r["reference"])) for r in group)
        errors = sum(r["wer"] * len(words(r["reference"])) for r in group)
        latencies = [r["latency_ms"] for r in group]
        line = f"{category:14s} {len(group):6d}  {errors / max(total_words, 1) * 100:5.1f}%  {percentile(latencies, 50):7.0f}  {percentile(latencies, 95):7.0f}"
        if args.cleanup:
            line += f"   {percentile([r['cleanup_ms'] for r in group], 50):8.0f}"
        print(line)
    with open(os.path.join(args.dir, "results.json"), "w") as out:
        json.dump(rows, out, indent=2)
    print(f"\nper-clip results: {os.path.join(args.dir, 'results.json')}")


if __name__ == "__main__":
    main()
