#!/usr/bin/env python3
"""End-to-end check of cookie-sense: a known sentence, spoken by `say`, must come back as text.

  scripts/check-sense.py [path/to/cookie-sense]

Exits 0 when every expected word is heard, 1 otherwise, 2 when the helper has no speech model here.
"""
import json, os, struct, subprocess, sys, tempfile

SENTENCE = "Send the Halvorsen pricing to Maria on Friday"
EXPECTED = ["send", "pricing", "maria", "friday"]  # "Halvorsen" is a name the model may not know; that is the dictionary's job

helper = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "cookie-sense", ".build", "release", "cookie-sense")

with tempfile.TemporaryDirectory() as tmp:
    aiff, wav = os.path.join(tmp, "s.aiff"), os.path.join(tmp, "s.wav")
    subprocess.run(["say", "-o", aiff, SENTENCE], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    pcm = open(wav, "rb").read()
    pcm = pcm[pcm.index(b"data") + 8:]  # 16 kHz mono 16-bit little-endian, what the app sends

proc = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

def send(obj, payload=b""):
    body = json.dumps(obj).encode()
    proc.stdin.write(struct.pack(">I", len(body)) + body + struct.pack(">I", len(payload)) + payload)
    proc.stdin.flush()

def receive():
    head = proc.stdout.read(4)
    if len(head) < 4:
        sys.exit("helper closed its output")
    body = json.loads(proc.stdout.read(struct.unpack(">I", head)[0]))
    proc.stdout.read(struct.unpack(">I", proc.stdout.read(4))[0])
    return body

send({"op": "hello", "id": "hello-1"})
hello = receive()
print("hello:", hello)
# Enkeon dictation's clean-up lives in this helper now: the op is known. Without Apple Intelligence it
# may answer that it's unavailable, never "unknown op".
send({"op": "cleanup", "id": "c1", "text": "um so we ship friday", "style": "neutral"})
reply = receive()
print("cleanup:", reply)
if "unknown op" in str(reply.get("error", "")):
    sys.exit("cookie-sense doesn't know Enkeon dictation's clean-up")
if not hello.get("speech"):
    print("no installed speech model for this language here (the helper asked for it to be installed)")
    sys.exit(2)

send({"op": "speech.start", "id": "s1", "locale": "en-US"})
started = receive()
assert started.get("ok"), started
for i in range(0, len(pcm), 3200):  # 100 ms buffers, like the microphone
    send({"op": "speech.audio", "id": "s1"}, pcm[i:i + 3200])
send({"op": "speech.finish", "id": "s1"})

while True:
    event = receive()
    if event.get("event") == "final":
        break
    if event.get("error") or event.get("event") not in (None, "volatile"):
        sys.exit(f"helper failed: {event}")

text = event.get("text", "")
print("heard:", text)
missing = [w for w in EXPECTED if w not in text.lower()]
proc.stdin.close()
if missing:
    print("missing:", missing)
    sys.exit(1)
print("ok")
