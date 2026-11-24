// Cookie characters: each agent is a living glass body of slow, domain-warped
// fluid (ported from Cookie's own orb shader), in
// its own colours and its own baked shape, with eyes that move the way eyes do.
//
// One WebGL context draws every body: each frame it renders a face at its own
// size and copies the pixels into that face's 2D canvas, so a long roster never
// hits the browser's cap on WebGL contexts.
//
// Eye rules are the Cookie Motion System spec (Enkeon space cookie-tauri-app):
// blinks 0.2–0.3 s at a per-agent 8–20 a minute and likelier on a gaze shift,
// saccades ≈ 2.2 ms per degree + 25 ms, a look up and away while thinking,
// eyes on the work while working. At rest the face is still (Grok Bot's lesson:
// motion means work); only a slow blink every 6–10 s says it is alive.

const Faces = (() => {
  // The first four are dealt to agents by id; "biscuit" is Cookie's own.
  const SHAPES = ["cookie", "bun", "macaron", "loaf", "biscuit"];
  const DEALT = 4;
  // [hue, saturation] per agent: amber, berry, blueberry, matcha, plum, mint, caramel, rose, lemon, lagoon.
  const HUES = [[28, 82], [338, 70], [222, 72], [96, 48], [272, 52], [160, 52], [20, 62], [352, 74], [48, 88], [192, 66]];
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // The face's own look travels with this file, so a relay's card page draws the same faces.
  if (!document.getElementById("face-css")) {
    const css = document.createElement("style");
    css.id = "face-css";
    css.textContent = `
.face { position: relative; display: inline-grid; place-items: center; flex: none; transform-origin: 50% 100%; isolation: isolate; }
.face canvas { grid-area: 1 / 1; width: 100%; height: 100%; filter: drop-shadow(0 2px 3px rgb(0 0 0 / .32)); }
.face .eyes { grid-area: 1 / 1; position: relative; z-index: 1; display: flex; align-items: center; }
.face .eyes i { display: block; border-radius: 999px; background: #22120a; box-shadow: 0 .5px 0 rgb(255 255 255 / .28); transform-origin: 50% 55%; }
.face .eyes.happy i { background: none; box-shadow: none; width: calc(var(--ew) * 2.1) !important; height: calc(var(--ew) * 1.05) !important; border: max(1.6px, calc(var(--ew) * .42)) solid #22120a; border-bottom: 0; border-radius: 999px 999px 0 0; }
.face .flip { grid-area: 1 / 1; width: 100%; height: 100%; display: grid; place-items: center; transform-style: preserve-3d; position: relative; }
.face .flip > canvas, .face .flip > .eyes { grid-area: 1 / 1; }
.face .mouth { position: absolute; left: 50%; top: 66%; z-index: 1; width: 0; height: 0; opacity: 0; background: #22120a; border-radius: 999px; transform: translate(-50%, -50%); box-shadow: 0 .5px 0 rgb(255 255 255 / .22); transition: opacity .16s ease, width .14s cubic-bezier(.2,.8,.2,1), height .1s ease, border-radius .16s ease; pointer-events: none; }
.face .mouth.smile { background: none; box-shadow: none; border: var(--mw) solid #22120a; border-top: 0; border-radius: 0 0 999px 999px; }
.face .orbit { position: absolute; left: 50%; top: 50%; z-index: 3; font-size: var(--gs); line-height: 1; opacity: 0; transition: opacity .2s ease; pointer-events: none; filter: drop-shadow(0 1px 1.5px rgb(0 0 0 / .45)); will-change: transform; }
.face .zz { position: absolute; right: -2%; top: -6%; z-index: 3; font: 700 var(--zs)/1 -apple-system, system-ui, sans-serif; color: rgb(255 255 255 / .85); opacity: 0; pointer-events: none; text-shadow: 0 1px 2px rgb(0 0 0 / .5); }
.face.err canvas { filter: drop-shadow(0 2px 3px rgb(0 0 0 / .32)) drop-shadow(0 0 calc(var(--fs) * .12) rgb(236 70 70 / .85)) saturate(1.25) hue-rotate(-8deg); }
.face canvas { transition: filter .25s ease; }
.cookie-confetti { position: fixed; z-index: 2000; width: 7px; height: 7px; border-radius: 2px; pointer-events: none; will-change: transform, opacity; }
.face .sheen { grid-area: 1 / 1; z-index: 2; width: 45%; height: 100%; opacity: 0; pointer-events: none; border-radius: 40%; background: linear-gradient(90deg, transparent, rgb(255 255 255 / .55), transparent); mix-blend-mode: soft-light; filter: blur(2px); }`;
    document.head.prepend(css);
  }

  // A face is seeded by its owner's key and the agent's id, so another
  // person's look-alike agent never wears the same face. `salt` is the key.
  let ownSalt = "";
  const live = new Set();
  /** Every face on screen by agent id, so the app can reach "Writing Desk" wherever it is drawn. */
  const byId = new Map();
  let dozeAfter = 25 * 60 * 1000; // asleep after this long with nothing to do
  const mouse = { x: -1e4, y: -1e4, at: 0 };
  addEventListener("pointermove", (e) => { mouse.x = e.clientX; mouse.y = e.clientY; mouse.at = performance.now(); }, { passive: true });

  // Which glyph circles the face while a tool runs: by what the tool does, from its own name.
  function glyphFor(tool) {
    const n = String(tool || "").toLowerCase();
    if (/search|web|find|lookup|recall/.test(n)) return n.includes("recall") ? "🧠" : "🔍";
    if (/read|file|open|list/.test(n)) return "📄";
    if (/write|edit|patch|draft|note|remember/.test(n)) return n.includes("remember") || n.includes("note") ? "🧠" : "✏️";
    if (/message|talk|ask_agent|send|reply|deal/.test(n)) return "💬";
    if (/mail|inbox|gmail/.test(n)) return "✉️";
    if (/calendar|event|remind|routine|schedule/.test(n)) return "📅";
    if (/command|run_code|shell|code/.test(n)) return "⚙️";
    if (/url|page|site|browse/.test(n)) return "🌐";
    return "✨";
  }

  function seedOf(id) {
    let h = 2166136261; // FNV-1a, the same family of stable hash the Swift app uses
    for (const c of String(id)) { h ^= c.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; }
    return h;
  }

  function hsl(h, s, l) {
    s /= 100; l /= 100;
    const k = (n) => (n + h / 30) % 12, a = s * Math.min(l, 1 - l);
    const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return [f(0), f(8), f(4)];
  }

  function look(id) {
    const seed = seedOf(id);
    // Cookie, the agent everyone starts with: a round biscuit, in brown.
    if (id === "cookie") {
      // The same spread as every agent (deep 34, mid 58, light 92), in brown: chocolate, caramel, cream.
      return { seed, shape: "biscuit", deep: hsl(21, 64, 24), mid: hsl(26, 60, 42), light: hsl(34, 64, 80) };
    }
    const [h, s] = HUES[(seed >>> 3) % HUES.length];
    return {
      seed,
      shape: SHAPES[seed % DEALT],
      deep: hsl(h, s, 34), mid: hsl((h + 6) % 360, s, 58), light: hsl((h + 14) % 360, Math.min(s, 70), 92),
    };
  }

  /* ---------- the one shared renderer ---------- */
  const VERT = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";
  const FRAG = `
precision highp float;
uniform vec2 u_res; uniform float u_time, u_energy, u_seed; uniform int u_shape;
uniform vec2 u_roll; // how far the surface has turned (x: a spin, y: a flip), so the fluid rolls with it
uniform vec3 u_deep, u_mid, u_light;
float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float noise(vec2 p){ vec2 i = floor(p), f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1,0)), u.x), mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), u.x), u.y); }
const mat2 R = mat2(0.8, 0.6, -0.6, 0.8);
float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++){ v += a * noise(p); p = R * p * 2.03; a *= 0.5; } return v; }
// Rounded box with its own radius per corner: (top-right, bottom-right, top-left, bottom-left).
float rbox(vec2 p, vec2 b, vec4 r){ r.xy = (p.x > 0.0) ? r.xy : r.zw; r.x = (p.y > 0.0) ? r.x : r.y;
  vec2 q = abs(p) - b + r.x; return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x; }
float sdf(vec2 p){
  if (u_shape == 0){ float a = atan(p.y, p.x); return length(p) - (0.86 + 0.028 * sin(6.0 * a + u_seed) + 0.018 * sin(11.0 * a + 2.0 * u_seed)); }
  if (u_shape == 1) return rbox(p - vec2(0.0, -0.04), vec2(0.86, 0.76), vec4(0.74, 0.26, 0.74, 0.26));
  if (u_shape == 2) return rbox(p - vec2(0.0, -0.02), vec2(0.92, 0.68), vec4(0.62));
  if (u_shape == 3) return rbox(p - vec2(0.0, -0.02), vec2(0.82, 0.80), vec4(0.5, 0.2, 0.5, 0.2));
  // Cookie's own: a smooth round biscuit with a faintly scalloped rim.
  float a = atan(p.y, p.x);
  return length(p) - (0.84 + 0.011 * cos(12.0 * a));
}
void main(){
  vec2 uv = (gl_FragCoord.xy * 2.0 - u_res) / u_res.y * 1.04;
  float d = sdf(uv);
  float px = 2.6 / u_res.y;
  float a = 1.0 - smoothstep(-px, px * 0.4, d);
  if (a <= 0.0){ gl_FragColor = vec4(0.0); return; }
  // A sphere-like normal from the distance to the edge, so every shape reads as glass.
  vec2 e = vec2(0.004, 0.0);
  vec2 g = normalize(vec2(sdf(uv + e.xy) - sdf(uv - e.xy), sdf(uv + e.yx) - sdf(uv - e.yx)) + 1e-5);
  float inner = clamp(-d / 0.62, 0.0, 1.0);
  float z = sqrt(1.0 - (1.0 - inner) * (1.0 - inner));
  vec3 n = normalize(vec3(g * (1.0 - z) * 1.4, z));
  // The fluid: coordinates stretch toward the rim, so it curves with the body.
  vec2 p = uv / (0.45 + 0.55 * z) * 1.25 + u_seed * 0.37 + u_roll * 3.2;
  float t = u_time;
  vec2 q = vec2(fbm(p + vec2(0.0, t * 0.9)), fbm(p + vec2(5.2, 1.3) - t * 0.7));
  vec2 w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2) + t * 0.5), fbm(p + 3.0 * q + vec2(8.3, 2.8) - t * 0.4));
  float f = fbm(p + 2.4 * w);
  float h = clamp(0.48 - uv.y * 0.42 + (f - 0.5) * (0.85 + 0.25 * u_energy), 0.0, 1.0);
  vec3 col = mix(u_light, u_mid, smoothstep(0.18, 0.55, h));
  col = mix(col, u_deep, smoothstep(0.55, 0.98, h));
  if (u_shape == 0){ // chocolate chips, set in the dough, not in the fluid
    float c = noise(uv * 5.2 + u_seed * 1.7);
    float face = smoothstep(0.62, 0.48, length((uv - vec2(0.0, 0.08)) * vec2(0.9, 1.4)));
    col = mix(col, u_deep * 0.5, smoothstep(0.80, 0.84, c) * smoothstep(-0.06, -0.16, d) * (1.0 - face) * 0.8);
  }
  if (u_shape == 2){ // the macaron's filling
    float band = smoothstep(0.075, 0.035, abs(uv.y + 0.06 + 0.02 * sin(uv.x * 9.0 + u_seed)));
    col = mix(col, mix(u_light, vec3(1.0), 0.45), band * 0.85);
  }
  vec3 L = normalize(vec3(-0.45, 0.62, 0.64));
  col *= 0.8 + 0.3 * clamp(dot(n, L), 0.0, 1.0);
  col += u_mid * 0.35 * pow(1.0 - z, 1.6) * smoothstep(0.3, -0.9, uv.y);
  col += vec3(1.0, 0.93, 0.84) * pow(1.0 - z, 3.0) * 0.32;
  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
  col += pow(clamp(dot(n, H), 0.0, 1.0), 70.0) * 0.6;
  gl_FragColor = vec4(min(col, 1.0) * a, a);
}`;

  const R = (() => {
    const cv = document.createElement("canvas");
    const gl = cv.getContext("webgl", { alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: true, antialias: false });
    if (!gl) return null;
    const sh = (type, src) => { const x = gl.createShader(type); gl.shaderSource(x, src); gl.compileShader(x); return gl.getShaderParameter(x, gl.COMPILE_STATUS) ? x : null; };
    const vs = sh(gl.VERTEX_SHADER, VERT), fs = sh(gl.FRAGMENT_SHADER, FRAG), prog = gl.createProgram();
    if (!vs || !fs) return null;
    gl.attachShader(prog, vs); gl.attachShader(prog, fs); gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
    gl.useProgram(prog);
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const at = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(at);
    gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
    const u = Object.fromEntries(["u_res", "u_time", "u_energy", "u_seed", "u_shape", "u_deep", "u_mid", "u_light", "u_roll"].map((n) => [n, gl.getUniformLocation(prog, n)]));
    cv.width = cv.height = 512;
    return {
      draw(face) {
        const px = face.px;
        if (cv.width < px) cv.width = cv.height = px;
        gl.viewport(0, 0, px, px);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform2f(u.u_res, px, px);
        gl.uniform1f(u.u_time, face.clock);
        gl.uniform1f(u.u_energy, face.energy);
        gl.uniform1f(u.u_seed, (face.look.seed % 997) / 97);
        gl.uniform2f(u.u_roll, face.rollX || 0, face.rollY || 0);
        gl.uniform1i(u.u_shape, SHAPES.indexOf(face.look.shape));
        gl.uniform3f(u.u_deep, ...face.look.deep);
        gl.uniform3f(u.u_mid, ...face.look.mid);
        gl.uniform3f(u.u_light, ...face.look.light);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        face.ctx.clearRect(0, 0, px, px);
        face.ctx.drawImage(cv, 0, cv.height - px, px, px, 0, 0, px, px);
      },
    };
  })();

  /* ---------- a face ---------- */
  function create(id, size = 44, salt = ownSalt) {
    const lk = look(salt && id !== "cookie" ? salt + ":" + id : id);
    const root = document.createElement("span");
    root.className = "face";
    root.style.width = root.style.height = size + "px";
    root.setAttribute("aria-hidden", "true");
    const canvas = document.createElement("canvas");
    const px = Math.round(size * Math.min(devicePixelRatio || 1, 2));
    canvas.width = canvas.height = px;
    const eyes = document.createElement("span");
    eyes.className = "eyes";
    const ew = Math.max(2.4, size * 0.105), eh = Math.max(4, size * 0.22);
    eyes.innerHTML = `<i style="width:${ew}px;height:${eh}px"></i><i style="width:${ew}px;height:${eh}px"></i>`;
    eyes.style.gap = size * (0.15 + ((lk.seed >>> 7) % 3) * 0.02) + "px";
    eyes.style.setProperty("--ew", ew + "px");
    // The body and eyes turn together inside `flip`; the root keeps breathing and hopping.
    const inner = document.createElement("span");
    inner.className = "flip";
    const sheen = document.createElement("span");
    sheen.className = "sheen";
    // The mouth: hidden at rest, it speaks (with the real audio), listens, smiles and frets.
    const mouth = document.createElement("span");
    mouth.className = "mouth";
    root.style.setProperty("--fs", size + "px");
    root.style.setProperty("--mw", Math.max(1.4, size * 0.035) + "px");
    inner.append(canvas, eyes, mouth, sheen);
    // What it's doing, circling it; and a sleepy "z" when it has nothing to do for long.
    const orbit = document.createElement("span");
    orbit.className = "orbit";
    root.style.setProperty("--gs", Math.max(9, size * 0.3) + "px");
    const zz = document.createElement("span");
    zz.className = "zz";
    zz.textContent = "z";
    root.style.setProperty("--zs", Math.max(8, size * 0.24) + "px");
    root.append(inner, orbit, zz);
    if (!R) {
      const rgb = (c) => `rgb(${c.map((v) => Math.round(v * 255)).join(" ")})`;
      canvas.style.background = `radial-gradient(circle at 35% 28%, ${rgb(lk.light)}, ${rgb(lk.mid)} 55%, ${rgb(lk.deep)})`;
      canvas.style.borderRadius = "50%";
    }
    const st = {
      look: lk, root, ctx: canvas.getContext("2d"), px, size, eyes: [...eyes.children], eyesWrap: eyes,
      clock: 3.7 + (lk.seed % 100) / 10, energy: 0, energyTarget: 0, last: performance.now(), frame: lk.seed % 3,
      blinksPerMin: 8 + (lk.seed % 13), phase: (lk.seed % 1000) / 160, bounce: 0.7 + ((lk.seed >>> 11) % 5) * 0.12,
      gaze: { x: 0, y: 0 }, from: { x: 0, y: 0 }, to: { x: 0, y: 0 },
      sacStart: 0, sacDur: 1, nextGlance: 0, blinkStart: -1, nextBlink: 0,
      mood: "idle", ackAt: -1, happyAt: -1, settled: false,
      id, inner, sheen, mouth, orbit, zz, mouthMode: "", talk: 0, talkTarget: 0, listening: false,
      tool: null, orbitAngle: (lk.seed % 628) / 100, errAt: -1, perkAt: -1, glance: null, squish: 0, pressed: false, spring: null,
      lastActive: performance.now(), dozing: false, roll: null, rollX: 0, rollY: 0, hopAt: -1, hopMs: 0, hopH: 0, wakeAt: -1, scanAt: 0, rect: null, rectAt: 0,
    };
    st.nextBlink = performance.now() + gap(st);
    paint(st, performance.now(), true);
    if (!reduce) live.add(st);
    if (!byId.has(id)) byId.set(id, new Set());
    byId.get(id).add(st);

    // Petting: press and hold to squish it like jelly; let go and it springs back, pleased.
    let holdTimer = 0;
    root.addEventListener("pointerdown", (e) => {
      if (reduce || e.button !== 0 || root.closest("[data-no-pet]")) return;
      holdTimer = setTimeout(() => { st.pressed = true; st.spring = null; wake(st); }, 140);
    });
    const release = () => {
      clearTimeout(holdTimer);
      if (!st.pressed) return;
      st.pressed = false;
      st.spring = { at: performance.now(), from: st.squish };
      st.happyAt = performance.now();
      st.mouthFlash = { mode: "smile", until: performance.now() + 1100 };
    };
    addEventListener("pointerup", release);
    addEventListener("pointercancel", release);

    const handle = {
      el: root,
      /** idle · received · thinking · writing · working · waiting · done · error. Only work moves the face. */
      setMood(m) {
        const now = performance.now();
        wake(st);
        if (m === "error") { st.errAt = now; m = "idle"; }
        // A new job or a finished one turns the face once, like a card catching light.
        if (m === "received" || (m === "done" && st.mood !== "idle")) turn(st, m === "done" ? 760 : 900);
        if (m === "received") { st.ackAt = now; m = "thinking"; }
        if (m === "done") { st.happyAt = now; m = "idle"; }
        // Thinking, the fluid slows and gathers; working and writing, it runs.
        st.energyTarget = m === "working" ? 1 : m === "writing" ? 0.8 : m === "thinking" ? 0.35 : 0;
        if (m === "writing" && st.mood !== "writing") st.scanAt = now;
        if (st.mood !== m) { st.mood = m; st.nextGlance = 0; st.settled = false; st.nextBlink = now + gap(st); }
      },
      /** Hover: it notices you (a small "hi" and a look), and its fluid stirs while you stay. */
      peek(on) {
        if (on) wake(st);
        if (st.mood !== "idle") return;
        if (on) { st.ackAt = performance.now(); st.energyTarget = 0.3; st.from = { ...st.gaze }; st.to = { x: 0, y: -0.25 }; st.sacStart = performance.now(); st.sacDur = 60; st.nextGlance = Infinity; st.blinkStart = performance.now() + 120; }
        else { st.energyTarget = 0; st.nextGlance = performance.now() + 200; }
      },
      stop() { live.delete(st); byId.get(id)?.delete(st); },
      /** Voice: how loud its own voice is right now (0–1); the mouth follows it. 0 closes it. */
      talk(level) { st.talkTarget = Math.max(0, Math.min(1, level || 0)); if (level) wake(st); },
      /** Voice: it's listening to you (a small "o"). */
      listen(on) { st.listening = !!on; if (on) wake(st); },
      /** A tool is running: its glyph circles the face. null takes it away. */
      tool(name) { st.tool = name ? glyphFor(name) : null; st.orbit.textContent = st.tool ?? ""; if (name) wake(st); },
      /** Something went wrong: a quick head-shake and a red flush. */
      error() { st.errAt = performance.now(); wake(st); },
      /** It heard its name: a small hop and wide eyes. */
      perk() { st.perkAt = performance.now(); wake(st); st.ackAt = performance.now(); },
      /** Look toward a point on screen (a teammate's face) for a moment. */
      glanceAt(x, y, ms = 1400) { st.glance = { x, y, until: performance.now() + ms }; wake(st); },
      /** A trick: the face rolls round the body. kind: front, back, double, spin, spin2. */
      flip(kind = "front", ms) {
        const k = { front: ["x", 1, 820], back: ["x", -1, 820], double: ["x", 2, 1150], spin: ["y", 1, 760], spin2: ["y", 2, 1050] }[kind] ?? ["x", 1, 820];
        roll(st, k[0], k[1], ms ?? k[2]); wake(st);
      },
      /** Confetti in its own colours, from where it sits. */
      celebrate() { celebrate(st); st.happyAt = performance.now(); st.mouthFlash = { mode: "smile", until: performance.now() + 1400 }; wake(st); },
      get id() { return id; },
      rect() { return root.getBoundingClientRect(); },
    };
    st.handle = handle;
    return handle;
  }

  function wake(s) {
    s.lastActive = performance.now();
    if (s.dozing) { s.dozing = false; s.wakeAt = performance.now(); s.ackAt = performance.now(); }
  }

  function celebrate(s) {
    if (reduce) return;
    const r = s.root.getBoundingClientRect();
    const rgb = (c) => `rgb(${c.map((v) => Math.round(v * 255)).join(" ")})`;
    const colors = [rgb(s.look.light), rgb(s.look.mid), rgb(s.look.deep), "#fff"];
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    for (let i = 0; i < 26; i++) {
      const d = document.createElement("span");
      d.className = "cookie-confetti";
      d.style.background = colors[i % colors.length];
      d.style.left = cx + "px"; d.style.top = cy + "px";
      if (i % 3 === 0) d.style.borderRadius = "50%";
      document.body.append(d);
      const ang = -Math.PI / 2 + (Math.random() - 0.5) * Math.PI * 1.4;
      const v = 70 + Math.random() * 110, dx = Math.cos(ang) * v, dy = Math.sin(ang) * v;
      const spin = (Math.random() - 0.5) * 720;
      d.animate(
        [
          { transform: "translate(-50%, -50%) rotate(0deg) scale(1)", opacity: 1 },
          { transform: `translate(calc(-50% + ${dx}px), calc(-50% + ${dy}px)) rotate(${spin / 2}deg) scale(1)`, opacity: 1, offset: 0.45 },
          { transform: `translate(calc(-50% + ${dx * 1.3}px), calc(-50% + ${dy + 120}px)) rotate(${spin}deg) scale(.6)`, opacity: 0 },
        ],
        { duration: 1100 + Math.random() * 500, easing: "cubic-bezier(.2,.7,.4,1)" },
      ).onfinish = () => d.remove();
    }
  }

  // At rest: one slow blink every 6–10 s. At work: the measured, per-agent rate.
  /** One premium turn: the body stays put while its face rolls once around it (a ball
   *  turning, never a card edge-on), with a hop and a light sweep across the glass. */
  function turn(st, ms) {
    if (reduce) return;
    roll(st, "y", 1, ms);
    st.hopAt = performance.now(); st.hopMs = ms; st.hopH = 0.08;
    if (st.sheen.animate) st.sheen.animate(
      [
        { opacity: 0, transform: "translateX(-120%) skewX(-18deg)" },
        { opacity: 0.85, offset: 0.45 },
        { opacity: 0, transform: "translateX(140%) skewX(-18deg)" },
      ],
      { duration: ms, easing: "ease-out" },
    );
  }

  /** Turn the surface: axis "x" is a flip (the face goes up over the top, or down for
   *  turns < 0), "y" a spin (round the side). `turns` whole turns over `ms`. */
  function roll(st, axis, turns, ms) {
    st.roll = { axis, turns, start: performance.now(), ms, base: axis === "x" ? st.rollY || 0 : st.rollX || 0 };
  }

  const gap = (s) => s.mood === "idle" ? 6000 + Math.random() * 4000 : (60000 / s.blinksPerMin) * (0.45 + Math.random() * 1.1);

  function target(mood) {
    if (mood === "thinking") return { x: -0.55 + Math.random() * 0.35, y: -0.75 };
    if (mood === "working") return { x: (Math.random() - 0.5) * 0.9, y: 0.6 };
    // Waiting for your yes: it glances down toward the approve button, then back at you.
    if (mood === "waiting") return Math.random() < 0.55 ? { x: 0.4, y: 0.7 } : { x: 0, y: 0 };
    return { x: 0, y: 0 }; // idle: eyes on you
  }

  /** The face's place on screen, measured at most every `ms` (layout reads are not free). */
  function rectOf(s, now, ms) {
    if (!s.rect || now - s.rectAt > ms) { s.rect = s.root.getBoundingClientRect(); s.rectAt = now; }
    return s.rect;
  }

  function paint(s, now, force) {
    const dt = Math.min(0.05, (now - s.last) / 1000);
    s.last = now;
    const sec = now / 1000;

    // Long with nothing to do: it dozes (eyes half shut, a slow "z"), until anything wakes it.
    if (!s.dozing && s.mood === "idle" && !s.pressed && !s.talkTarget && !s.tool && now - s.lastActive > dozeAfter) s.dozing = true;
    if (s.dozing && s.mood !== "idle") s.dozing = false;

    // A roll of the surface: the angle eases out (fast start, soft settle), the fluid scrolls with it.
    let rollA = 0, rollAxis = null, rolling = false;
    if (s.roll) {
      const p = Math.min(1, (now - s.roll.start) / s.roll.ms);
      const k = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2; // ease in-out cubic
      rollA = k * s.roll.turns * Math.PI * 2;
      rollAxis = s.roll.axis;
      const scroll = s.roll.base + (k * s.roll.turns) * 0.62;
      if (rollAxis === "x") s.rollY = scroll; else s.rollX = scroll;
      rolling = true;
      if (p >= 1) s.roll = null;
    }
    s.energy += (s.energyTarget - s.energy) * Math.min(1, dt * 2.5);
    const flowing = s.energy > 0.01 || s.talk > 0.02;
    // The fluid flows only while the agent works (or talks); at rest it is still glass.
    if (flowing) s.clock += dt * (0.08 + 0.4 * Math.max(s.energy, s.talk * 0.8));
    // ponytail: small faces repaint their fluid every third frame; per-face WebGL contexts if this ever looks steppy.
    if (R && (force || rolling || (flowing && (s.size >= 64 || (s.frame++ % 3) === 0)))) R.draw(s);

    const active = s.mood !== "idle";
    if (active && s.mood !== "writing" && now >= s.nextGlance) {
      s.from = { ...s.gaze };
      s.to = target(s.mood);
      const deg = Math.hypot(s.to.x - s.from.x, s.to.y - s.from.y) * 15;
      s.sacStart = now;
      s.sacDur = 25 + 2.2 * deg;
      s.nextGlance = now + ({ waiting: 1600, thinking: 900, working: 650 }[s.mood] ?? 1200) + Math.random() * 2000;
      if (deg > 4 && Math.random() < 0.3 && s.blinkStart < 0) s.blinkStart = now;
    }
    if (!active && (s.gaze.x || s.gaze.y) && now >= s.nextGlance && !s.glance) {
      s.from = { ...s.gaze }; s.to = { x: 0, y: 0 }; s.sacStart = now; s.sacDur = 140; s.nextGlance = Infinity;
    }
    const t = Math.min(1, (now - s.sacStart) / s.sacDur), e = 1 - Math.pow(1 - t, 3);
    let gazeX = s.from.x + (s.to.x - s.from.x) * e;
    let gazeY = s.from.y + (s.to.y - s.from.y) * e;

    // Writing: the eyes read back along the line it's writing, then return for the next.
    if (s.mood === "writing") {
      const p = ((now - s.scanAt) % 1150) / 1150;
      gazeX = p < 0.84 ? -0.62 + 1.24 * (p / 0.84) : 0.62 - 1.24 * ((p - 0.84) / 0.16);
      gazeY = 0.42 + Math.sin(sec * 9) * 0.03;
    }
    // A glance at a teammate's face (a handoff), wherever it sits on screen.
    if (s.glance) {
      if (now > s.glance.until) { s.glance = null; s.from = { x: gazeX, y: gazeY }; s.to = { x: 0, y: 0 }; s.sacStart = now; s.sacDur = 160; }
      else {
        const r = rectOf(s, now, 150);
        const dx = s.glance.x - (r.left + r.width / 2), dy = s.glance.y - (r.top + r.height / 2), d = Math.hypot(dx, dy) || 1;
        gazeX = (dx / d) * 0.95; gazeY = (dy / d) * 0.9;
      }
    }
    // Idle and awake: its eyes follow your pointer when it's near.
    else if (!active && !s.dozing && s.size >= 30 && now - mouse.at < 4000) {
      const r = rectOf(s, now, 120);
      const dx = mouse.x - (r.left + r.width / 2), dy = mouse.y - (r.top + r.height / 2), d = Math.hypot(dx, dy);
      const reach = Math.max(220, s.size * 5);
      if (d < reach) {
        const k = Math.min(1, d / (s.size * 1.2));
        gazeX = (dx / (d || 1)) * 0.85 * k; gazeY = (dy / (d || 1)) * 0.8 * k;
      }
    }
    // Eased toward the goal, so a pointer flicking past doesn't snap the eyes.
    s.gaze.x += (gazeX - s.gaze.x) * Math.min(1, dt * (s.glance || s.mood === "writing" ? 30 : 14));
    s.gaze.y += (gazeY - s.gaze.y) * Math.min(1, dt * (s.glance || s.mood === "writing" ? 30 : 14));

    if (s.blinkStart < 0 && now >= s.nextBlink && !s.dozing) s.blinkStart = now;
    let lid = 0;
    if (s.blinkStart >= 0) {
      const p = (now - s.blinkStart) / (s.mood === "thinking" ? 290 : 210);
      if (p >= 1) { s.blinkStart = -1; s.nextBlink = now + gap(s); }
      else lid = p < 0.38 ? p / 0.38 : 1 - (p - 0.38) / 0.62;
    }

    // Done (or petted): happy, closed eyes for a moment.
    const happy = s.happyAt >= 0 && now - s.happyAt < 1500;
    if (s.happyAt >= 0 && !happy) s.happyAt = -1;
    s.eyesWrap.classList.toggle("happy", happy);

    const perk = s.perkAt >= 0 && now - s.perkAt < 520 ? (now - s.perkAt) / 520 : -1;
    if (s.perkAt >= 0 && perk < 0) s.perkAt = -1;
    const woke = s.wakeAt >= 0 && now - s.wakeAt < 450;
    if (s.wakeAt >= 0 && !woke) s.wakeAt = -1;
    const busy = s.mood === "thinking" || s.mood === "working";
    const j = busy ? 0.02 : 0;
    const gx = s.gaze.x + (Math.random() - 0.5) * j, gy = s.gaze.y + (Math.random() - 0.5) * j;
    let open = happy ? 1 : Math.max(0.08, 1 - Math.max(lid, Math.max(0, gy) * 0.14, s.mood === "thinking" ? 0.12 : 0));
    if (s.dozing) open = Math.min(open, 0.2 + Math.sin(sec * 0.9) * 0.05);
    let eyeScale = 1;
    if (perk >= 0) eyeScale = 1 + Math.sin(perk * Math.PI) * 0.22;
    if (woke) eyeScale = 1.25;
    // On a roll, the features travel over the curve: foreshortened toward the rim,
    // gone round the back, and back again from the other side.
    let rx = 0, ry = 0, fsx = 1, fsy = 1, front = 1;
    if (rollAxis) {
      const c = Math.cos(rollA), sn = Math.sin(rollA);
      // Gone before they reach the rim, so they never sit outside the body.
      front = Math.max(0, Math.min(1, (c - 0.3) / 0.35));
      if (rollAxis === "x") { ry = -sn * s.size * 0.3; fsy = Math.max(0.05, Math.abs(c)); }
      else { rx = sn * s.size * 0.28; fsx = Math.max(0.05, Math.abs(c)); }
    }
    s.eyesWrap.style.opacity = front;
    s.eyesWrap.style.transform = `translate(${gx * s.size * 0.1 + rx}px, ${gy * s.size * 0.08 - s.size * 0.035 + ry}px) scale(${fsx}, ${fsy})`;
    for (const eye of s.eyes) eye.style.transform = `scale(${eyeScale}, ${open * eyeScale})`;

    // The mouth: speaking with the real voice, an "o" when listening, hearing its name or
    // waking, a fret while it waits for your yes or after a mistake, a smile when pleased.
    s.talk += (s.talkTarget - s.talk) * Math.min(1, dt * 22);
    const err = s.errAt >= 0 && now - s.errAt < 1300 ? (now - s.errAt) / 1300 : -1;
    if (s.errAt >= 0 && err < 0) s.errAt = -1;
    const flash = s.mouthFlash && now < s.mouthFlash.until ? s.mouthFlash.mode : null;
    let mode = "";
    if (s.talkTarget > 0.01 || s.talk > 0.04) mode = "talk";
    else if (flash) mode = flash;
    else if (s.listening) mode = "o";
    else if (perk >= 0 || woke) mode = "o";
    else if (err >= 0 || s.mood === "waiting") mode = "flat";
    else if (happy && s.size >= 40) mode = "smile";
    if (s.size < 30) mode = "";
    const S = s.size, m = s.mouth;
    if (mode !== s.mouthMode) { m.classList.toggle("smile", mode === "smile"); s.mouthMode = mode; }
    let mw = 0, mh = 0, mr = "999px", mt = "", mo = mode ? 1 : 0;
    if (mode === "talk") { mw = S * (0.12 + s.talk * 0.06); mh = S * (0.025 + s.talk * 0.13); mr = "45% 45% 50% 50%"; }
    else if (mode === "o") { mw = mh = S * 0.085; mr = "50%"; }
    else if (mode === "flat") { mw = S * 0.13; mh = Math.max(1.5, S * 0.028); mt = ` rotate(${err >= 0 ? -8 : -4}deg)`; }
    else if (mode === "smile") { mw = S * 0.2; mh = S * 0.085; mr = ""; }
    m.style.opacity = mo;
    if (mode) { m.style.width = mw + "px"; m.style.height = mh + "px"; if (mr) m.style.borderRadius = mr; else m.style.removeProperty("border-radius"); }
    if (rollAxis) m.style.opacity = mo * front;
    m.style.transform = `translate(calc(-50% + ${gx * S * 0.07 + rx * 1.15}px), calc(-50% + ${gy * S * 0.05 - S * 0.02 + ry * 1.25}px)) scale(${fsx}, ${fsy})${mt}`;

    // What it's doing, circling it: the tool's glyph on a tilted orbit, behind it on the far side.
    if (s.tool && S >= 34) {
      s.orbitAngle += dt * 2.4;
      const R2 = S * 0.66, x = Math.cos(s.orbitAngle) * R2, y = Math.sin(s.orbitAngle) * R2 * 0.42 - S * 0.08;
      const front = Math.sin(s.orbitAngle) > 0;
      s.orbit.style.opacity = 1;
      s.orbit.style.zIndex = front ? 3 : 0;
      s.orbit.style.transform = `translate(-50%, -50%) translate(${x}px, ${y}px) scale(${front ? 1 : 0.78})`;
    } else s.orbit.style.opacity = 0;

    // Asleep: a slow "z" rises and fades.
    if (s.dozing && S >= 34) {
      const p = (sec % 2.6) / 2.6;
      s.zz.style.opacity = String(Math.sin(p * Math.PI) * 0.9);
      s.zz.style.transform = `translate(${p * S * 0.12}px, ${-p * S * 0.35}px) scale(${0.7 + p * 0.5})`;
    } else s.zz.style.opacity = 0;

    // Body: still at rest. A "got it" squash on a new message, a sway while thinking,
    // a small bounce while working, a lean toward you while it waits for your yes.
    let sy = 1, sx = 1, ty = 0, rot = 0, lean = 1;
    if (s.mood === "thinking") rot = Math.sin(sec * 1.4 + s.phase) * 3;
    if (s.mood === "working") { const b = Math.abs(Math.sin(sec * 7 * s.bounce)); ty = -b * 0.03; sy += b * 0.025; }
    if (s.mood === "writing") { ty = -Math.abs(Math.sin(sec * 11)) * 0.012; }
    if (s.mood === "waiting") { lean = 1.06 + Math.max(0, Math.sin(sec * 2.2)) * 0.02; ty = -0.02; }
    if (s.dozing) { sy += Math.sin(sec * 1.1) * 0.018; ty = 0.015; }
    if (s.ackAt >= 0) {
      const p = (now - s.ackAt) / 360;
      if (p >= 1) s.ackAt = -1;
      else sy -= Math.sin(p * Math.PI) * 0.09;
    }
    if (happy) { const p = (now - s.happyAt) / 520; if (p < 1) { ty = -Math.sin(p * Math.PI) * 0.1; } }
    if (s.hopAt >= 0 && s.hopAt !== undefined) {
      const p = (now - s.hopAt) / s.hopMs;
      if (p >= 1) s.hopAt = -1;
      else if (p < 0.12) sy -= (p / 0.12) * 0.1;                                  // crouch
      else if (p < 0.85) { const q = (p - 0.12) / 0.73; ty = Math.min(ty, -Math.sin(q * Math.PI) * s.hopH); sy += Math.sin(q * Math.PI) * 0.06; } // up, stretched
      else sy -= Math.sin(((p - 0.85) / 0.15) * Math.PI) * 0.12;                 // land
    }
    if (perk >= 0) ty = Math.min(ty, -Math.sin(perk * Math.PI) * 0.18);
    // A mistake: a quick head-shake, dying out.
    if (err >= 0) { const p = Math.min(1, err * 2); rot += Math.sin(p * Math.PI * 6) * 9 * (1 - p); }
    s.root.classList.toggle("err", err >= 0 && err < 0.75);
    // Petting: pressed, it squashes like jelly; let go, it springs back with a damped wobble.
    if (s.pressed) s.squish += (1 - s.squish) * Math.min(1, dt * 14);
    else if (s.spring) {
      const t2 = (now - s.spring.at) / 1000;
      s.squish = s.spring.from * Math.exp(-t2 * 5.5) * Math.cos(t2 * 24);
      if (t2 > 1.1) { s.spring = null; s.squish = 0; }
    } else s.squish = 0;
    sy -= s.squish * 0.2; sx += s.squish * 0.2;
    const fx = (2 - sy) * sx * lean, fy = sy * lean;
    const still = fx === 1 && fy === 1 && !ty && !rot;
    s.root.style.transform = still ? "" : `translateY(${ty * s.size}px) rotate(${rot}deg) scale(${fx}, ${fy})`;
  }

  function loop(now) {
    if (!document.hidden) for (const s of live) { if (s.root.isConnected) paint(s, now); else { live.delete(s); byId.get(s.id)?.delete(s); } }
    requestAnimationFrame(loop);
  }
  if (!reduce) requestAnimationFrame(loop);

  /** The owner's key (a short hex prefix): set once, before faces are drawn. */
  function setSalt(s) { ownSalt = s || ""; }
  /** A short, stable key prefix: enough to tell faces apart, cheap to hash. */
  const saltOf = (key) => (key || "").slice(0, 16);

  /** A face's own colour, for its name beside its words. */
  function color(id, salt = ownSalt) {
    const [r, g, b] = look(salt && id !== "cookie" ? salt + ":" + id : id).mid;
    return `rgb(${Math.round(r * 255)} ${Math.round(g * 255)} ${Math.round(b * 255)})`;
  }

  /** Every face of one agent on screen right now (the list, the header, the call…). */
  function of(id) {
    const set = byId.get(id);
    if (!set) return [];
    return [...set].filter((st) => st.root.isConnected).map((st) => st.handle).filter(Boolean);
  }
  /** One after another, a small hop each: a standup, everyone reporting in turn. */
  function wave(ids, gapMs = 160) {
    ids.forEach((id, i) => setTimeout(() => of(id).forEach((f) => f.perk()), i * gapMs));
  }
  /** How long an idle face waits before it dozes. */
  function setDozeAfter(ms) { dozeAfter = ms; }

  return { create, look, setSalt, saltOf, color, of, wave, setDozeAfter, glyphFor };
})();
