// Cookie characters: each agent is a living glass body of slow, domain-warped
// fluid (Cookie's own orb shader, web/components/central/CookieOrb.tsx), in
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
  const SHAPES = ["cookie", "bun", "macaron", "loaf"];
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
.face .sheen { grid-area: 1 / 1; z-index: 2; width: 45%; height: 100%; opacity: 0; pointer-events: none; border-radius: 40%; background: linear-gradient(90deg, transparent, rgb(255 255 255 / .55), transparent); mix-blend-mode: soft-light; filter: blur(2px); }`;
    document.head.prepend(css);
  }

  // A face is seeded by its owner's key and the agent's id, so another
  // person's look-alike agent never wears the same face. `salt` is the key.
  let ownSalt = "";
  const live = new Set();

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
    const [h, s] = HUES[(seed >>> 3) % HUES.length];
    return {
      seed,
      shape: SHAPES[seed % SHAPES.length],
      deep: hsl(h, s, 34), mid: hsl((h + 6) % 360, s, 58), light: hsl((h + 14) % 360, Math.min(s, 70), 92),
    };
  }

  /* ---------- the one shared renderer ---------- */
  const VERT = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";
  const FRAG = `
precision highp float;
uniform vec2 u_res; uniform float u_time, u_energy, u_seed; uniform int u_shape;
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
  return rbox(p - vec2(0.0, -0.02), vec2(0.82, 0.80), vec4(0.5, 0.2, 0.5, 0.2));
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
  vec2 p = uv / (0.45 + 0.55 * z) * 1.25 + u_seed * 0.37;
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
    const u = Object.fromEntries(["u_res", "u_time", "u_energy", "u_seed", "u_shape", "u_deep", "u_mid", "u_light"].map((n) => [n, gl.getUniformLocation(prog, n)]));
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
    const lk = look(salt ? salt + ":" + id : id);
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
    inner.append(canvas, eyes, sheen);
    root.append(inner);
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
    };
    st.nextBlink = performance.now() + gap(st);
    paint(st, performance.now(), true);
    if (!reduce) live.add(st);
    return {
      el: root,
      /** idle · received · thinking · working · waiting · done. Only work moves the face. */
      setMood(m) {
        const now = performance.now();
        // A new job or a finished one turns the face once, like a card catching light.
        if (m === "received" || (m === "done" && st.mood !== "idle")) turn(inner, sheen, m === "done" ? 760 : 900);
        if (m === "received") { st.ackAt = now; m = "thinking"; }
        if (m === "done") { st.happyAt = now; m = "idle"; }
        st.energyTarget = m === "working" ? 1 : m === "thinking" ? 0.6 : 0;
        if (st.mood !== m) { st.mood = m; st.nextGlance = 0; st.settled = false; st.nextBlink = now + gap(st); }
      },
      /** Hover: it notices you (a small "hi" and a look), and its fluid stirs while you stay. */
      peek(on) {
        if (st.mood !== "idle") return;
        if (on) { st.ackAt = performance.now(); st.energyTarget = 0.3; st.from = { ...st.gaze }; st.to = { x: 0, y: -0.25 }; st.sacStart = performance.now(); st.sacDur = 60; st.nextGlance = Infinity; st.blinkStart = performance.now() + 120; }
        else { st.energyTarget = 0; st.nextGlance = performance.now() + 200; }
      },
      stop() { live.delete(st); },
    };
  }

  // At rest: one slow blink every 6–10 s. At work: the measured, per-agent rate.
  /** One premium turn: a 3D spin about the vertical axis with a light sweep across the glass. */
  function turn(inner, sheen, ms) {
    if (reduce || !inner.animate) return;
    inner.getAnimations().forEach((a) => a.cancel());
    inner.animate(
      [
        { transform: "perspective(240px) translateY(0) rotateY(0deg) scale(1)" },
        { transform: "perspective(240px) translateY(-8%) rotateY(180deg) scale(1.1)", offset: 0.5 },
        { transform: "perspective(240px) translateY(0) rotateY(360deg) scale(1)" },
      ],
      { duration: ms, easing: "cubic-bezier(.65,0,.35,1)" },
    );
    sheen.animate(
      [
        { opacity: 0, transform: "translateX(-120%) skewX(-18deg)" },
        { opacity: 0.85, offset: 0.45 },
        { opacity: 0, transform: "translateX(140%) skewX(-18deg)" },
      ],
      { duration: ms, easing: "ease-out" },
    );
  }

  const gap = (s) => s.mood === "idle" ? 6000 + Math.random() * 4000 : (60000 / s.blinksPerMin) * (0.45 + Math.random() * 1.1);

  function target(mood) {
    if (mood === "thinking") return { x: -0.55 + Math.random() * 0.35, y: -0.75 };
    if (mood === "working") return { x: (Math.random() - 0.5) * 0.9, y: 0.6 };
    return { x: 0, y: 0 }; // idle and waiting: eyes on you
  }

  function paint(s, now, force) {
    const dt = Math.min(0.05, (now - s.last) / 1000);
    s.last = now;
    s.energy += (s.energyTarget - s.energy) * Math.min(1, dt * 2.5);
    const flowing = s.energy > 0.01;
    // The fluid flows only while the agent works; at rest it is still glass.
    if (flowing) s.clock += dt * (0.08 + 0.4 * s.energy);
    // ponytail: small faces repaint their fluid every third frame; per-face WebGL contexts if this ever looks steppy.
    if (R && (force || (flowing && (s.size >= 64 || (s.frame++ % 3) === 0)))) R.draw(s);

    const active = s.mood !== "idle";
    if (active && now >= s.nextGlance) {
      s.from = { ...s.gaze };
      s.to = target(s.mood);
      const deg = Math.hypot(s.to.x - s.from.x, s.to.y - s.from.y) * 15;
      s.sacStart = now;
      s.sacDur = 25 + 2.2 * deg;
      s.nextGlance = now + ({ waiting: 4000, thinking: 900, working: 650 }[s.mood] ?? 1200) + Math.random() * 2000;
      if (deg > 4 && Math.random() < 0.3 && s.blinkStart < 0) s.blinkStart = now;
    }
    if (!active && (s.gaze.x || s.gaze.y) && now >= s.nextGlance) {
      s.from = { ...s.gaze }; s.to = { x: 0, y: 0 }; s.sacStart = now; s.sacDur = 140; s.nextGlance = Infinity;
    }
    const t = Math.min(1, (now - s.sacStart) / s.sacDur), e = 1 - Math.pow(1 - t, 3);
    s.gaze.x = s.from.x + (s.to.x - s.from.x) * e;
    s.gaze.y = s.from.y + (s.to.y - s.from.y) * e;
    if (s.blinkStart < 0 && now >= s.nextBlink) s.blinkStart = now;
    let lid = 0;
    if (s.blinkStart >= 0) {
      const p = (now - s.blinkStart) / (s.mood === "thinking" ? 290 : 210);
      if (p >= 1) { s.blinkStart = -1; s.nextBlink = now + gap(s); }
      else lid = p < 0.38 ? p / 0.38 : 1 - (p - 0.38) / 0.62;
    }

    // Done: happy, closed eyes for 1.5 s, then still.
    const happy = s.happyAt >= 0 && now - s.happyAt < 1500;
    if (s.happyAt >= 0 && !happy) s.happyAt = -1;
    s.eyesWrap.classList.toggle("happy", happy);

    const busy = s.mood === "thinking" || s.mood === "working";
    const j = busy ? 0.02 : 0;
    const gx = s.gaze.x + (Math.random() - 0.5) * j, gy = s.gaze.y + (Math.random() - 0.5) * j;
    const open = happy ? 1 : Math.max(0.08, 1 - Math.max(lid, Math.max(0, gy) * 0.14, s.mood === "thinking" ? 0.12 : 0));
    s.eyesWrap.style.transform = `translate(${gx * s.size * 0.1}px, ${gy * s.size * 0.08 - s.size * 0.035}px)`;
    for (const eye of s.eyes) eye.style.transform = `scaleY(${open})`;

    // Body: still at rest. A "got it" squash on a new message, a sway while thinking,
    // a small bounce while working, one slow pulse while it waits for your yes.
    const sec = now / 1000;
    let sy = 1, ty = 0, rot = 0;
    if (s.mood === "thinking") rot = Math.sin(sec * 1.4 + s.phase) * 3;
    if (s.mood === "working") { const b = Math.abs(Math.sin(sec * 7 * s.bounce)); ty = -b * 0.03; sy += b * 0.025; }
    if (s.mood === "waiting") sy += Math.max(0, Math.sin(sec * 2.2)) * 0.03;
    if (s.ackAt >= 0) {
      const p = (now - s.ackAt) / 360;
      if (p >= 1) s.ackAt = -1;
      else sy -= Math.sin(p * Math.PI) * 0.09;
    }
    if (happy) { const p = (now - s.happyAt) / 520; if (p < 1) { ty = -Math.sin(p * Math.PI) * 0.1; } }
    s.root.style.transform = sy === 1 && !ty && !rot ? "" : `translateY(${ty * s.size}px) rotate(${rot}deg) scale(${2 - sy}, ${sy})`;
  }

  function loop(now) {
    if (!document.hidden) for (const s of live) s.root.isConnected ? paint(s, now) : live.delete(s);
    requestAnimationFrame(loop);
  }
  if (!reduce) requestAnimationFrame(loop);

  /** The owner's key (a short hex prefix): set once, before faces are drawn. */
  function setSalt(s) { ownSalt = s || ""; }
  /** A short, stable key prefix: enough to tell faces apart, cheap to hash. */
  const saltOf = (key) => (key || "").slice(0, 16);

  /** A face's own colour, for its name beside its words. */
  function color(id, salt = ownSalt) {
    const [r, g, b] = look(salt ? salt + ":" + id : id).mid;
    return `rgb(${Math.round(r * 255)} ${Math.round(g * 255)} ${Math.round(b * 255)})`;
  }

  return { create, look, setSalt, saltOf, color };
})();
