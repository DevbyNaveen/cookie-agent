// Voice: dictate into the composer (the mic), or talk with an agent hands-free
// (the waveform button: a call that listens, sends what you said, and speaks
// the reply as it is written). Speech becomes text on this Mac (whisper.cpp)
// when its model is downloaded, else through ElevenLabs or OpenAI. Replies are
// spoken by ElevenLabs in Cookie's voice (Jessica, as on Cookie for Mac) when a
// key is saved; without one, by the Mac's own voice.

const Voice = (() => {
  /* ---------- shared audio ---------- */
  let ctx = null;
  const audioCtx = () => (ctx ??= new (window.AudioContext || window.webkitAudioContext)());

  async function openMic() {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      toast("No microphone here", "This window can't record. Use the desktop app, or a current browser.", "error");
      return null;
    }
    let stream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true } }); }
    catch { toast("Microphone blocked", "Allow Cookie to use the microphone in System Settings → Privacy & Security → Microphone.", "error"); return null; }
    const ac = audioCtx();
    if (ac.state === "suspended") await ac.resume().catch(() => {});
    const analyser = ac.createAnalyser();
    analyser.fftSize = 1024;
    const source = ac.createMediaStreamSource(stream);
    source.connect(analyser);
    const buf = new Float32Array(analyser.fftSize);
    return {
      stream, analyser,
      level() { analyser.getFloatTimeDomainData(buf); let sum = 0; for (const v of buf) sum += v * v; return Math.sqrt(sum / buf.length); },
      close() { source.disconnect(); stream.getTracks().forEach((t) => t.stop()); },
    };
  }

  const mimeType = () => ["audio/webm;codecs=opus", "audio/mp4", "audio/ogg;codecs=opus", "audio/webm"].find((t) => MediaRecorder.isTypeSupported?.(t)) ?? "";

  function record(stream) {
    const type = mimeType();
    const rec = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
    const chunks = [];
    rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
    const done = new Promise((ok) => { rec.onstop = () => ok(new Blob(chunks, { type: rec.mimeType || type || "audio/webm" })); });
    rec.start(250);
    return { rec, done, stop() { if (rec.state !== "inactive") rec.stop(); return done; } };
  }

  async function transcribe(blob) {
    const b64 = await new Promise((ok, no) => { const r = new FileReader(); r.onload = () => ok(String(r.result).split(",")[1]); r.onerror = no; r.readAsDataURL(blob); });
    const t = blob.type;
    const ext = t.includes("mp4") ? "m4a" : t.includes("ogg") ? "ogg" : "webm";
    return call("transcribe", { audio: b64, ext });
  }

  const clock = (ms) => { const s = Math.floor(ms / 1000); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; };

  /* ---------- speaking ---------- */
  // ElevenLabs when a key is saved (fetched ahead, played in order), else the Mac's voice.
  let eleven = true, warned = false, outAnalyser = null;
  const outBuf = new Float32Array(512);
  function outLevel() {
    if (!outAnalyser) return 0;
    outAnalyser.getFloatTimeDomainData(outBuf);
    let sum = 0; for (const v of outBuf) sum += v * v;
    return Math.sqrt(sum / outBuf.length);
  }

  async function fetchSpeech(text) {
    if (!eleven) return null;
    try { return await call("speak", { text }); }
    catch (e) {
      const why = String(e);
      if (/No ElevenLabs key/.test(why)) eleven = false;
      else if (!warned) { warned = true; toast("ElevenLabs didn't speak", why + " Your Mac's voice speaks instead.", "error"); }
      return null;
    }
  }

  /** Plays one piece; resolves when it has been heard (or stopped). */
  function play(b64, text, stopper) {
    return new Promise((done) => {
      if (b64) {
        const a = new Audio("data:audio/mpeg;base64," + b64);
        try {
          const ac = audioCtx();
          outAnalyser ??= (() => { const an = ac.createAnalyser(); an.fftSize = 512; an.connect(ac.destination); return an; })();
          ac.createMediaElementSource(a).connect(outAnalyser);
        } catch {}
        a.onended = a.onerror = () => done();
        stopper.stop = () => { a.pause(); done(); };
        a.play().catch(() => done());
      } else if ("speechSynthesis" in window) {
        const u = new SpeechSynthesisUtterance(text);
        u.onend = u.onerror = () => done();
        stopper.stop = () => { speechSynthesis.cancel(); done(); };
        speechSynthesis.speak(u);
      } else done();
    });
  }

  /** A queue of sentences: each is fetched as soon as it arrives, and they play one after another. */
  function speaker(onIdle) {
    const queue = [];
    let playing = false, cancelled = false;
    const stopper = { stop: () => {} };
    async function pump() {
      if (playing) return;
      playing = true;
      while (queue.length && !cancelled) {
        const item = queue.shift();
        const b64 = await item.audio;
        if (cancelled) break;
        await play(b64, item.text, stopper);
      }
      playing = false;
      if (!cancelled) onIdle?.();
    }
    return {
      say(text) { const t = text.trim(); if (!t || cancelled) return; queue.push({ text: t, audio: fetchSpeech(t) }); pump(); },
      get busy() { return playing || queue.length > 0; },
      cancel() { cancelled = true; queue.length = 0; stopper.stop(); },
    };
  }

  /* ---------- dictation (the mic) ---------- */
  let dict = null;

  async function startDictation() {
    if (dict || call_) return;
    const mic = await openMic();
    if (!mic) return;
    dict = { mic, take: record(mic.stream), at: Date.now(), timer: 0, raf: 0 };
    document.body.classList.add("dictating");
    $("dictate").hidden = false;
    $("dictate").classList.remove("busy");
    $("input").placeholder = "Listening…";
    const bars = [...$("dictate-level").children];
    const tick = () => {
      if (!dict) return;
      $("dictate-time").textContent = clock(Date.now() - dict.at);
      const l = Math.min(1, dict.mic.level() * 14);
      bars.forEach((b, i) => { const shape = 1 - Math.abs(i - 2) * 0.22; b.style.transform = `scaleY(${(0.25 + l * shape * 2.2).toFixed(2)})`; });
      dict.raf = requestAnimationFrame(tick);
    };
    tick();
    syncSend();
  }

  /** Stop listening; the words go into the composer, and are sent when `andSend`. */
  async function finishDictation(andSend) {
    const d = dict;
    if (!d || d.finishing) return;
    d.finishing = true;
    cancelAnimationFrame(d.raf);
    const blob = await d.take.stop();
    d.mic.close();
    const long = Date.now() - d.at > 600 && blob.size > 1000;
    $("dictate").classList.add("busy");
    $("input").placeholder = "Writing down what you said…";
    try {
      if (long) {
        const text = await transcribe(blob);
        const ta = $("input");
        ta.value = ta.value.trim() ? ta.value.replace(/\s*$/, " ") + text : text;
        autosize();
      }
    } catch (e) {
      toast("Couldn't write it down", String(e), "error", () => openSettings("general"));
      andSend = false;
    } finally {
      dict = null;
      document.body.classList.remove("dictating");
      $("dictate").hidden = true;
      syncSend();
      $("input").focus();
    }
    if (andSend && $("input").value.trim()) $("composer").requestSubmit();
  }

  $("mic").onclick = () => (dict ? finishDictation(false) : startDictation());
  $("dictate-stop").onclick = () => finishDictation(false);

  /* ---------- the call (the waveform button) ---------- */
  // listening → hearing (you talk) → writing (transcribing) → thinking (the agent works)
  // → speaking (its reply, sentence by sentence) → listening again.
  let call_ = null;
  const LABEL = { listening: "Listening", hearing: "Listening", writing: "Writing it down", thinking: "Thinking", speaking: "Speaking", muted: "Muted" };

  function iconButton(name, label, cls = "") {
    const b = el("button", "vc-btn " + cls);
    b.type = "button"; b.title = label; b.setAttribute("aria-label", label);
    b.append(icon(name));
    return b;
  }

  async function startCall() {
    if (call_) { endCall(); return; }
    if (!current) return;
    if (dict) await finishDictation(false);
    const agent = current;
    const mic = await openMic();
    if (!mic) return;
    const box = $("voice-call");
    // Cookie's call: the agent's own face, larger, in a glow of its colour that breathes
    // with whoever is talking. No box around it; the backdrop fades into the chat.
    box.style.setProperty("--vc", Faces.color(agent.id));
    const face = Faces.create(agent.id, 64);
    face.setMood("received");
    const halo = el("div", "vc-halo");
    for (let i = 0; i < 3; i++) halo.append(el("i"));
    const left = el("button", "vc-face");
    left.type = "button"; left.title = "Interrupt"; left.setAttribute("aria-label", "Interrupt");
    left.append(face.el);
    const stage = el("div", "vc-stage");
    stage.append(halo, left);
    const state = el("div", "vc-state", "Listening");
    const gear = iconButton("gear", "Voice settings");
    const caps = iconButton("chat", "Captions");
    const mute = iconButton("mic", "Mute");
    const end = iconButton("x", "End voice chat", "end");
    const caption = el("div", "vc-caption");
    caption.hidden = true;
    const controls = el("div", "vc-controls");
    controls.append(gear, caps, mute, end);
    const wave = halo; // the loop drives the halo
    box.replaceChildren(stage, state, caption, controls);
    box.hidden = false;
    requestAnimationFrame(() => box.classList.add("on"));
    document.body.classList.add("in-call");

    const c = call_ = {
      agent, mic, face, state: "listening", take: null, at: Date.now(),
      floor: 0.004, voicedMs: 0, quietMs: 0, last: performance.now(), raf: 0,
      glow: 0, reply: "", spoke: false, speech: null, muted: false, barge: 0,
    };

    const set = (s) => {
      c.state = s;
      state.textContent = LABEL[s];
      box.dataset.state = s;
      face.setMood(s === "speaking" ? "working" : s === "thinking" || s === "writing" ? "thinking" : "idle");
    };
    c.set = set;

    gear.onclick = () => openSettings("general");
    caps.onclick = () => { caption.hidden = !caption.hidden; caps.classList.toggle("on", !caption.hidden); };
    mute.onclick = () => {
      c.muted = !c.muted;
      mic.stream.getAudioTracks().forEach((t) => (t.enabled = !c.muted));
      mute.classList.toggle("on", c.muted);
      mute.title = c.muted ? "Unmute" : "Mute";
      mute.setAttribute("aria-label", mute.title);
      if (c.muted && (c.state === "listening" || c.state === "hearing")) { c.take?.stop(); c.take = null; set("muted"); }
      else if (!c.muted && c.state === "muted") listen();
    };
    end.onclick = () => endCall();
    left.onclick = () => { if (c.state === "speaking") { c.speech?.cancel(); listen(); } };
    c.caption = (t) => { caption.textContent = t; };

    listen();
    const loop = (now) => {
      if (call_ !== c) return;
      if (current?.id !== c.agent.id || view !== "chat") { endCall(); return; }
      const dt = Math.min(100, now - c.last); c.last = now;
      const lin = c.muted ? 0 : mic.level();
      if (c.state === "listening" || c.state === "hearing") hear(lin, dt);
      else if (c.state === "speaking" && lin > Math.max(0.06, c.floor * 12)) {
        // Talking over the reply stops it, as on a phone.
        c.barge += dt;
        if (c.barge > 280) { c.speech?.cancel(); listen(); }
      } else c.barge = 0;
      const shown = c.state === "speaking" ? (outLevel() || (0.02 + Math.random() * 0.03)) : c.state === "thinking" || c.state === "writing" ? 0.004 + 0.004 * Math.sin(now / 160) : lin;
      // Eased toward the level: quick to rise, slow to fall, like breath.
      const target = Math.min(1, shown * 16);
      c.glow += (target - c.glow) * (target > c.glow ? 0.35 : 0.08);
      wave.childNodes.forEach((ring, i) => {
        const k = 1 + c.glow * (0.18 + i * 0.16);
        ring.style.transform = `scale(${k.toFixed(3)})`;
        ring.style.opacity = (0.16 + c.glow * (0.5 - i * 0.12)).toFixed(3);
      });
      face.el.style.transform = c.state === "speaking" || c.state === "hearing" ? `translateY(${(-c.glow * 3).toFixed(2)}px) scale(${(1 + c.glow * 0.06).toFixed(3)})` : "";
      c.raf = requestAnimationFrame(loop);
    };
    c.raf = requestAnimationFrame(loop);
  }

  /** Waiting for you to talk: record, and decide by loudness when you start and stop. */
  function listen() {
    const c = call_;
    if (!c) return;
    c.take?.stop();
    c.take = c.muted ? null : record(c.mic.stream);
    c.voicedMs = 0; c.quietMs = 0; c.barge = 0; c.reply = ""; c.spoke = false; c.waiting = false;
    c.listenAt = performance.now();
    c.set(c.muted ? "muted" : "listening");
  }

  function hear(lin, dt) {
    const c = call_;
    // The room's noise floor follows quiet moments slowly, and never drifts up while you talk.
    if (c.state === "listening" && lin < c.floor * 2.5) c.floor = c.floor * 0.97 + lin * 0.03;
    const loud = lin > Math.max(0.012, c.floor * 3.2);
    if (c.state === "listening") {
      c.voicedMs = loud ? c.voicedMs + dt : Math.max(0, c.voicedMs - dt / 2);
      if (c.voicedMs > 140) { c.set("hearing"); c.quietMs = 0; }
      // Nothing said for a while: start a fresh recording so it stays small.
      else if (performance.now() - c.listenAt > 30000) listen();
      return;
    }
    c.voicedMs += loud ? dt : 0;
    c.quietMs = loud ? 0 : c.quietMs + dt;
    if (c.quietMs > 1000) heard();
  }

  async function heard() {
    const c = call_;
    const take = c.take; c.take = null;
    c.set("writing");
    const blob = await take.stop();
    if (call_ !== c) return;
    if (c.voicedMs < 350 || blob.size < 1500) { listen(); return; }
    let text = "";
    try { text = (await transcribe(blob)).trim(); }
    catch (e) {
      if (!/No speech/.test(String(e))) { toast("Couldn't write it down", String(e), "error", () => openSettings("general")); endCall(); return; }
    }
    if (call_ !== c) return;
    if (!text) { listen(); return; }
    c.caption(`You: ${text}`);
    c.set("thinking");
    c.reply = ""; c.spoke = false; c.waiting = true;
    c.speech = speaker(() => { if (call_ === c && !c.waiting) listen(); });
    $("input").value = text;
    autosize();
    $("composer").requestSubmit();
  }

  /** Whole sentences from the reply so far go to the voice; code stays in the chat. */
  function release(final) {
    const c = call_;
    let buf = c.reply;
    if (!final && (buf.match(/```/g)?.length ?? 0) % 2) return; // inside a code block
    const cut = final ? buf.length : (() => { let at = -1; const re = /[.!?…](?=\s)|\n/g; let m; while ((m = re.exec(buf))) at = m.index + 1; return at; })();
    if (cut < 1 || (!final && cut < 24)) return;
    const piece = buf.slice(0, cut);
    c.reply = buf.slice(cut);
    const words = plain(piece.replace(/```[\s\S]*?```/g, " "));
    if (words) {
      if (!c.spoke) { c.spoke = true; c.set("speaking"); }
      c.caption(plain(words));
      c.speech.say(words);
    }
  }

  function onText(ev) {
    const c = call_;
    if (!c || !c.waiting || ev.agent !== c.agent.id) return;
    c.reply += ev.text;
    release(false);
  }

  function onDone(ev, job) {
    const c = call_;
    if (!c || !c.waiting || ev.agent !== c.agent.id) return;
    c.waiting = false;
    if (ev.status === "done" && !job?.acc && ev.answer) c.reply += ev.answer;
    if (ev.status === "done") release(true);
    if (!c.speech?.busy) listen();
  }

  function endCall() {
    const c = call_;
    if (!c) return;
    call_ = null;
    cancelAnimationFrame(c.raf);
    c.speech?.cancel();
    c.take?.stop();
    c.mic.close();
    c.face.stop();
    const box = $("voice-call");
    box.classList.remove("on");
    setTimeout(() => { if (!call_) { box.hidden = true; box.replaceChildren(); } }, 220);
    document.body.classList.remove("in-call");
    if (current?.id === c.agent.id && view === "chat") {
      $("log").append(event([icon("wave"), `Voice chat · ${clock(Date.now() - c.at)}`], "voice-line"));
      scrollDown();
    }
  }

  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (call_) { e.preventDefault(); endCall(); }
    else if (dict) { e.preventDefault(); finishDictation(false); }
  });

  return { startCall, endCall, onText, onDone, finishDictation, dictating: () => !!dict, speaker };
})();

/* ---------- read aloud ---------- */
let speaking = null;
function speakButton(text) {
  const b = el("button");
  b.type = "button";
  b.title = "Read aloud";
  b.setAttribute("aria-label", "Read aloud");
  b.append(icon("wave"));
  b.onclick = () => {
    const was = speaking;
    if (was) { was.voice.cancel(); was.btn.classList.remove("on"); speaking = null; if (was.btn === b) return; }
    const words = plain(text).slice(0, 4000);
    const me = { btn: b, voice: Voice.speaker(() => { if (speaking === me) { speaking = null; b.classList.remove("on"); } }) };
    speaking = me; b.classList.add("on");
    // In sentences, so the first one is heard while the rest are still being made.
    (words.match(/[^.!?…]+[.!?…]*\s*/g) ?? [words]).reduce((acc, s) => {
      if (acc.length && (acc[acc.length - 1] + s).length < 280) acc[acc.length - 1] += s; else acc.push(s);
      return acc;
    }, []).forEach((s) => me.voice.say(s));
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

  // Hearing you.
  const missing = [!st.whisper && "whisper.cpp", !st.ffmpeg && "ffmpeg"].filter(Boolean);
  const elsewhere = st.eleven ? "ElevenLabs" : st.cloud ? "OpenAI" : null;
  let control = null, note;
  if (st.local) note = "Ready: speech becomes text on this Mac. Nothing leaves it.";
  else if (missing.length) note = `For speech to stay on this Mac, it needs ${missing.join(" and ")}: in a terminal, brew install ${missing.map((m) => m === "whisper.cpp" ? "whisper-cpp" : m).join(" ")}.${elsewhere ? ` Until then ${elsewhere} writes it down.` : ""}`;
  else {
    note = elsewhere ? `${elsewhere} writes it down now. Download the speech model to keep it on this Mac.` : "Download the speech model once (148 MB) and talk to any agent.";
    control = button("Download", "primary small", async (e) => {
      const b = e.currentTarget; b.disabled = true; b.textContent = "Downloading…";
      try { await call("voice_setup"); toast("Voice is ready", "Tap the waveform in any chat.", "good"); refreshSettings(); }
      catch (err) { toast("Couldn't set up voice", String(err), "error"); b.disabled = false; b.textContent = "Download"; }
    });
  }
  g.append(setRow("Talk to your agents", note, control));

  // Speaking to you.
  if (st.eleven) {
    const pick = el("select", "pick");
    pick.setAttribute("aria-label", "ElevenLabs voice");
    const opt = (id, name) => { const o = el("option", null, name); o.value = `${id}|${name}`; return o; };
    pick.append(opt(st.voice, st.voice_name));
    pick.value = `${st.voice}|${st.voice_name}`;
    call("voice_voices").then((vs) => {
      const seen = new Set([st.voice]);
      if (st.voice !== "cgSgspJ2msm6clMCkdW9") { pick.append(opt("cgSgspJ2msm6clMCkdW9", "Jessica (Cookie's voice)")); seen.add("cgSgspJ2msm6clMCkdW9"); }
      vs.filter((v) => !seen.has(v.id)).forEach((v) => pick.append(opt(v.id, v.name)));
    }).catch(() => {});
    pick.onchange = async () => {
      try { await call("voice_choose", { voice: pick.value }); toast("Voice changed", pick.selectedOptions[0]?.textContent ?? "", "good"); }
      catch (e) { toast("Couldn't change the voice", String(e), "error"); }
    };
    const hear = button("Hear it", "small", () => Voice.speaker().say(`Hi, I'm ${current?.name ?? "Cookie"}. This is how I sound.`));
    const wrap = el("div", "set-controls");
    wrap.append(pick, hear);
    g.append(setRow("Spoken replies", `ElevenLabs speaks replies in ${st.voice_name}, on ElevenLabs' fastest voice. What's said is sent to ElevenLabs.`, wrap));
  } else if (st.mac_key) {
    g.append(setRow("Spoken replies", "Cookie for Mac has an ElevenLabs key. Use it here too, so replies sound like Cookie (macOS asks once to share it).", button("Use it", "primary small", async (e) => {
      const b = e.currentTarget; b.disabled = true;
      try { await call("voice_use_mac_key"); toast("ElevenLabs is on", "Replies now speak in Cookie's voice.", "good"); refreshSettings(); }
      catch (err) { toast("Couldn't take the key", String(err), "error"); b.disabled = false; }
    })));
  } else {
    g.append(setRow("Spoken replies", "Your Mac's own voice speaks now. Add an ElevenLabs key in Models to hear Cookie's voice (Jessica).", button("Add key", "small", () => openSettings("models"))));
  }
  parts.push(g);
  return parts;
};
