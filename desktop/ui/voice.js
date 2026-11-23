// Voice: talk instead of typing (the mic in the composer), and hear replies
// read aloud. Speech becomes text on this Mac (whisper.cpp) once its model is
// downloaded in Settings → General; nothing leaves the computer.
let rec = null, recChunks = [], recStream = null, recTimer = null, recStart = 0;

function micState(state) {
  const mic = $("mic");
  mic.classList.toggle("recording", state === "recording");
  mic.classList.toggle("busy", state === "transcribing");
  mic.setAttribute("aria-label", state === "recording" ? "Stop and transcribe" : "Talk");
  mic.title = state === "recording" ? "Stop" : "Talk";
  const ta = $("input");
  if (state === "recording") {
    recStart = Date.now();
    const tick = () => { const s = Math.floor((Date.now() - recStart) / 1000); ta.placeholder = `Listening… ${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")} — tap the mic to stop`; };
    tick(); recTimer = setInterval(tick, 500);
  } else {
    clearInterval(recTimer);
    ta.placeholder = state === "transcribing" ? "Writing down what you said…" : current ? `Message ${current.name}` : "Message";
  }
}

async function startRecording() {
  if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
    toast("No microphone here", "This window can't record. Use the desktop app, or a current browser.", "error");
    return;
  }
  try { recStream = await navigator.mediaDevices.getUserMedia({ audio: true }); }
  catch { toast("Microphone blocked", "Allow Cookie to use the microphone in System Settings → Privacy & Security → Microphone.", "error"); return; }
  const type = ["audio/webm;codecs=opus", "audio/mp4", "audio/ogg;codecs=opus", "audio/webm"].find((t) => MediaRecorder.isTypeSupported?.(t)) ?? "";
  rec = new MediaRecorder(recStream, type ? { mimeType: type } : undefined);
  recChunks = [];
  rec.ondataavailable = (e) => { if (e.data.size) recChunks.push(e.data); };
  rec.onstop = finishRecording;
  rec.start(250);
  micState("recording");
}

async function finishRecording() {
  recStream?.getTracks().forEach((t) => t.stop());
  const type = rec?.mimeType || "audio/webm";
  rec = null;
  const blob = new Blob(recChunks, { type });
  if (Date.now() - recStart < 600 || blob.size < 1000) { micState("idle"); return; }
  micState("transcribing");
  try {
    const b64 = await new Promise((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result).split(",")[1]); r.onerror = no; r.readAsDataURL(blob); });
    const ext = type.includes("mp4") ? "m4a" : type.includes("ogg") ? "ogg" : "webm";
    const text = await call("transcribe", { audio: b64, ext });
    const ta = $("input");
    ta.value = ta.value ? ta.value.replace(/\s*$/, " ") + text : text;
    autosize(); syncSend(); ta.focus();
  } catch (e) {
    toast("Couldn't write it down", String(e), "error", () => openSettings("general"));
  } finally { micState("idle"); }
}

$("mic").onclick = () => (rec ? rec.stop() : startRecording());

/* ---------- read aloud ---------- */
let speaking = null;
function speakButton(text) {
  if (!("speechSynthesis" in window)) return null;
  const b = el("button");
  b.type = "button";
  b.title = "Read aloud";
  b.setAttribute("aria-label", "Read aloud");
  b.append(icon("wave"));
  b.onclick = () => {
    if (speaking === b) { speechSynthesis.cancel(); return; }
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(plain(text).slice(0, 4000));
    u.onend = u.onerror = () => { if (speaking === b) { speaking = null; b.classList.remove("on"); } };
    speaking = b; b.classList.add("on");
    speechSynthesis.speak(u);
  };
  return b;
}

/* ---------- Settings → General: voice ---------- */
const generalPane = SETTINGS.general;
SETTINGS.general = async () => {
  const parts = await generalPane();
  const st = await call("voice_status").catch(() => null);
  if (!st) return parts;
  parts.push(el("h3", "group-title", "Voice"));
  const g = el("div", "group");
  const missing = [!st.whisper && "whisper.cpp", !st.ffmpeg && "ffmpeg"].filter(Boolean);
  let control = null, note;
  if (st.local) note = "Ready: speech becomes text on this Mac. Nothing leaves it.";
  else if (missing.length) note = `Needs ${missing.join(" and ")} on this Mac: in a terminal, brew install ${missing.map((m) => m === "whisper.cpp" ? "whisper-cpp" : m).join(" ")}${st.cloud ? ". Until then OpenAI writes it down." : "."}`;
  else {
    note = st.cloud ? "OpenAI writes it down now. Download the speech model to keep it on this Mac." : "Download the speech model once (148 MB) and talk to any agent.";
    control = button("Download", "primary small", async (e) => {
      const b = e.currentTarget; b.disabled = true; b.textContent = "Downloading…";
      try { await call("voice_setup"); toast("Voice is ready", "Tap the mic in any chat.", "good"); refreshSettings(); }
      catch (err) { toast("Couldn't set up voice", String(err), "error"); b.disabled = false; b.textContent = "Download"; }
    });
  }
  g.append(setRow("Talk to your agents", note, control));
  g.append(setRow("Read replies aloud", "Every reply has a read-aloud button, in your Mac's own voice.", null));
  parts.push(g);
  return parts;
};
