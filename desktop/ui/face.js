// Cookie characters: each agent is a small 3D sweet, ray-marched and lit like a
// product shot (a key light, a softbox mirrored in the gloss, a rim from behind,
// light glowing through thin edges, a soft shadow on the table), with slow
// domain-warped fluid inside its body, in its own colours and its own shape.
// The eyes and mouth are part of the body: glossy beads set into the surface
// with real lids, a mouth that opens with a tongue inside, cheeks that blush.
// The whole body turns in 3D: toward your pointer, round in a flip, shaking no.
//
// One WebGL context draws every body: each frame it renders a face at its own
// size and copies the pixels into that face's 2D canvas, so a long roster never
// hits the browser's cap on WebGL contexts. A face is redrawn only when
// something about it changed, so a still roster costs nothing.
//
// Eye rules are the Cookie Motion System spec (Enkeon space cookie-tauri-app):
// blinks 0.2–0.3 s at a per-agent 8–20 a minute and likelier on a gaze shift,
// saccades ≈ 2.2 ms per degree + 25 ms, a look up and away while thinking,
// eyes on the work while working. At rest the face is still (Grok Bot's lesson:
// motion means work); only a slow blink every 6–10 s says it is alive.

const Faces = (() => {
  // The first four are dealt to agents by id; "biscuit" is Cookie's own.
  const SHAPES = ["gumdrop", "bun", "macaron", "mochi", "biscuit"];
  const DEALT = 4;
  // [hue, saturation] per agent: amber, berry, blueberry, matcha, plum, mint, caramel, rose, lemon, lagoon.
  const HUES = [[28, 82], [338, 70], [222, 72], [96, 48], [272, 52], [160, 52], [20, 62], [352, 74], [48, 88], [192, 66]];
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  // The canvas reaches past the face's box on every side, for hops, flips and the shadow
  // (a face that does big jumps asks for more room: `view`).
  const VIEW = 1.36;

  // The face's own look travels with this file, so a relay's card page draws the same faces.
  if (!document.getElementById("face-css")) {
    const css = document.createElement("style");
    css.id = "face-css";
    css.textContent = `
.face { position: relative; display: inline-grid; place-items: center; flex: none; transform-origin: 50% 100%; isolation: isolate; }
.face canvas { grid-area: 1 / 1; width: 100%; height: 100%; }
.face canvas:not(.gl) { filter: drop-shadow(0 2px 3px rgb(0 0 0 / .32)); }
.face canvas.gl { position: absolute; pointer-events: none; }
.face.gl .eyes, .face.gl .mouth, .face.gl .sheen { display: none; }
.face .eyes { grid-area: 1 / 1; position: relative; z-index: 1; display: flex; align-items: center; }
.face .eyes i { display: block; border-radius: 999px; background: #22120a; box-shadow: 0 .5px 0 rgb(255 255 255 / .28); transform-origin: 50% 55%; }
.face .eyes.happy i { background: none; box-shadow: none; width: calc(var(--ew) * 2.1) !important; height: calc(var(--ew) * 1.05) !important; border: max(1.6px, calc(var(--ew) * .42)) solid #22120a; border-bottom: 0; border-radius: 999px 999px 0 0; }
.face .flip { grid-area: 1 / 1; width: 100%; height: 100%; display: grid; place-items: center; position: relative; }
.face .flip > canvas:not(.gl), .face .flip > .eyes { grid-area: 1 / 1; }
.face .mouth { position: absolute; left: 50%; top: 66%; z-index: 1; width: 0; height: 0; opacity: 0; background: #22120a; border-radius: 999px; transform: translate(-50%, -50%); pointer-events: none; transition: opacity .16s ease, width .14s cubic-bezier(.2,.8,.2,1), height .1s ease; }
.face .mouth.smile { background: none; border: var(--mw) solid #22120a; border-top: 0; border-radius: 0 0 999px 999px; }
.face .orbit { position: absolute; left: 50%; top: 50%; z-index: 3; font-size: var(--gs); line-height: 1; opacity: 0; transition: opacity .2s ease; pointer-events: none; filter: drop-shadow(0 1px 1.5px rgb(0 0 0 / .45)); will-change: transform; }
.face .zz { position: absolute; right: -2%; top: -6%; z-index: 3; font: 700 var(--zs)/1 -apple-system, system-ui, sans-serif; color: rgb(255 255 255 / .85); opacity: 0; pointer-events: none; text-shadow: 0 1px 2px rgb(0 0 0 / .5); }
.face.err canvas { filter: drop-shadow(0 0 calc(var(--fs) * .1) rgb(236 70 70 / .8)); }
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
    // Half the distance between the eyes, a little different per agent.
    const ex = 0.25 + ((seed >>> 7) % 3) * 0.025;
    // Cookie, the agent everyone starts with: a round biscuit, in brown.
    if (id === "cookie") {
      // The same spread as every agent (deep 34, mid 58, light 92), in brown: chocolate, caramel, cream.
      return { seed, ex: 0.27, shape: "biscuit", deep: hsl(21, 64, 24), mid: hsl(26, 60, 42), light: hsl(34, 64, 80) };
    }
    const [h, s] = HUES[(seed >>> 3) % HUES.length];
    return {
      seed, ex,
      shape: SHAPES[seed % DEALT],
      deep: hsl(h, s, 34), mid: hsl((h + 6) % 360, s, 58), light: hsl((h + 14) % 360, Math.min(s, 70), 92),
    };
  }

  /* ---------- the one shared renderer ---------- */
  const VERT = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";
  const FRAG = `
precision highp float;
uniform vec2 u_res;
uniform float u_time, u_energy, u_seed, u_sec, u_ex, u_view;
uniform int u_shape;
uniform vec3 u_deep, u_mid, u_light;
uniform mat3 u_rot;    // world -> body
uniform vec4 u_body;   // hop (face units, up), width scale, height scale, jelly wobble
uniform vec4 u_eye;    // gaze x, gaze y (+ is down), lid open 0..1, eye size
uniform vec4 u_lids;   // happy arcs 0..1, lower lid (squint), blush, red flush
uniform vec4 u_mouth;  // mode, width, height (or the smile's arc), tilt
const vec3 INK = vec3(0.075, 0.045, 0.04);

float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float noise(vec2 p){ vec2 i = floor(p), f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1,0)), u.x), mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), u.x), u.y); }
const mat2 R = mat2(0.8, 0.6, -0.6, 0.8);
float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++){ v += a * noise(p); p = R * p * 2.03; a *= 0.5; } return v; }
float smin(float a, float b, float k){ float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }
float smax(float a, float b, float k){ return -smin(-a, -b, k); }
float sdEll(vec3 p, vec3 r){ float k0 = length(p / r), k1 = length(p / (r * r)); return k0 * (k0 - 1.0) / k1; }
float sdRBox(vec3 p, vec3 b, float r){ vec3 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r; }
// An arc about +y with half-aperture sc = (sin, cos), radius ra, stroke rb (Inigo Quilez).
float sdArc(vec2 p, vec2 sc, float ra, float rb){ p.x = abs(p.x); return ((sc.y * p.x > sc.x * p.y) ? length(p - sc * ra) : abs(length(p) - ra)) - rb; }

float base(){ return u_shape == 4 ? -0.95 : u_shape == 2 ? -0.74 : -0.70; }

// Cookie's chocolate chips, kept off the face.
float chips(vec2 p){
  vec2 s = p * 4.0 + u_seed * 1.3;
  vec2 c = floor(s), f = fract(s) - 0.5;
  vec2 o = (vec2(hash(c + 3.1), hash(c + 7.7)) - 0.5) * 0.45;
  float r = 0.12 + 0.07 * hash(c + 1.9);
  float m = step(0.5, hash(c)) * smoothstep(r, r - 0.05, length(f - o));
  return m * smoothstep(0.52, 0.64, length((p - vec2(0.0, -0.08)) * vec2(0.95, 1.2)));
}

float body(vec3 p){
  if (u_shape == 0){ // gumdrop: tall and soft, narrower at the top, flat underneath
    float k = 1.0 + 0.17 * clamp(p.y + 0.04, -1.0, 1.0);
    float d = sdEll(vec3(p.x * k, p.y + 0.04, p.z * k), vec3(0.80, 0.84, 0.70)) / k;
    return smax(d, -(p.y + 0.70), 0.14);
  }
  if (u_shape == 1){ // bun: a soft dome on a rounded base
    float b = sdRBox(p - vec3(0.0, -0.36, 0.0), vec3(0.80, 0.34, 0.60), 0.30);
    return smin(b, sdEll(p, vec3(0.86, 0.72, 0.66)), 0.16);
  }
  if (u_shape == 2){ // macaron: two shells and the filling between
    float top = sdEll(p - vec3(0.0, 0.24, 0.0), vec3(0.92, 0.44, 0.74));
    float bot = sdEll(p - vec3(0.0, -0.42, 0.0), vec3(0.90, 0.32, 0.72));
    float fill = sdEll(p - vec3(0.0, -0.11, 0.0), vec3(0.83, 0.15, 0.66));
    return smin(min(top, bot), fill, 0.04);
  }
  if (u_shape == 3){ // mochi: a squishy dome that sags wider at the bottom
    vec3 q = p - vec3(0.0, -0.06, 0.0);
    q.xz *= 1.0 + 0.12 * q.y;
    return smax(sdEll(q, vec3(0.92, 0.70, 0.76)), -(p.y + 0.70), 0.24);
  }
  // Cookie's own: a thick round biscuit, scalloped rim, chips raised from the face.
  float a = atan(p.y, p.x);
  float r = length(p.xy) - (0.80 + 0.012 * cos(12.0 * a));
  float h = abs(p.z) - 0.15;
  float d = length(max(vec2(r, h), 0.0)) + min(max(r, h), 0.0) - 0.15;
  if (p.z > 0.0) d -= 0.04 * chips(p.xy);
  return d;
}

// World to body: lifted by the hop, squashed from the base, wobbling like jelly, turned.
vec3 toBody(vec3 p){
  float b = base();
  vec3 q = p - vec3(0.0, u_body.x, 0.0);
  q.y = (q.y - b) / u_body.z + b;
  q.xz /= u_body.y;
  q.x += sin(q.y * 5.0 + u_sec * 22.0) * u_body.w * 0.05;
  return u_rot * q;
}
float map(vec3 p){ return body(toBody(p)) * min(u_body.y, u_body.z) * 0.85; }
// Body to world, for a direction (u_rot is a rotation, so its inverse is its transpose).
vec3 toWorld(vec3 v){ return vec3(dot(u_rot[0], v), dot(u_rot[1], v), dot(u_rot[2], v)); }

const vec3 KEY = vec3(-0.5, 0.78, 0.55);
vec3 softbox(vec3 n, vec3 V, float fres){
  vec3 r = reflect(-V, n);
  vec3 Lw = normalize(vec3(-0.6, 0.62, 0.5));
  float rl = dot(r, Lw);
  if (rl <= 0.0) return vec3(0.0);
  vec3 ax = normalize(cross(Lw, vec3(0.0, 1.0, 0.0))), ay = cross(ax, Lw);
  vec2 k = abs(vec2(dot(r, ax), dot(r, ay)) / rl) - vec2(0.42, 0.26) + 0.12;
  float box = length(max(k, 0.0)) + min(max(k.x, k.y), 0.0) - 0.12;
  return vec3(1.0, 0.98, 0.95) * smoothstep(0.06, -0.04, box) * (0.3 + 0.6 * fres);
}

vec3 light(vec3 alb, vec3 p, vec3 n, vec3 V, float gloss, float sss){
  vec3 L = normalize(KEY);
  float wrap = clamp((dot(n, L) + 0.45) / 1.45, 0.0, 1.0);
  float nv = clamp(dot(n, V), 0.0, 1.0);
  float fres = pow(1.0 - nv, 2.4);
  float ao = clamp(0.55 + 0.45 * map(p + n * 0.12) / 0.12, 0.0, 1.0);
  float ground = smoothstep(base() - 0.05, base() + 0.35, p.y - u_body.x);
  vec3 c = alb * (0.30 + 0.78 * wrap) * mix(0.7, 1.0, ground);
  c += alb * u_mid * 0.35 * clamp(-n.y, 0.0, 1.0);              // light bounced off the table
  c += (alb * 1.25 + u_light * 0.15) * fres * 0.42 * sss;       // light glowing through the edge
  c *= ao;
  vec3 H = normalize(L + V);
  float nh = clamp(dot(n, H), 0.0, 1.0);
  c += (pow(nh, 110.0) * 0.85 + pow(nh, 14.0) * 0.06) * gloss;  // the clear coat
  c += softbox(n, V, fres) * 0.85 * gloss;
  float rim = pow(1.0 - nv, 3.5) * smoothstep(-0.1, 0.7, dot(n, normalize(vec3(0.75, 0.35, -0.4))));
  c += mix(u_light, vec3(0.8, 0.9, 1.0), 0.5) * rim * 0.55;
  return c;
}

// One eye, set into the body at c: a glossy bead under real lids, or a happy arc.
void eye(inout vec3 col, vec2 q, vec2 c, float aa, vec3 V){
  float sc = u_eye.w, open = u_eye.z, happy = u_lids.x;
  vec2 rad = vec2(0.115, 0.175) * sc;
  vec2 e = (q - c) / rad;
  float de = (length(e) - 1.0) * rad.x;
  // the upper lid comes down with a curved edge; the lower comes up in a squint
  float top = mix(-0.15, 1.08, open) + 0.32 * e.x * e.x;
  float bot = mix(-1.08, -0.2, u_lids.y) - 0.25 * e.x * e.x;
  float inBead = 1.0 - smoothstep(-aa, aa, de);
  float shown = inBead * (1.0 - smoothstep(-aa, aa, (e.y - top) * rad.y)) * smoothstep(-aa, aa, (e.y - bot) * rad.y);
  vec3 lid = col * mix(1.0, 0.86, inBead);
  lid *= 1.0 - 0.3 * smoothstep(0.07 * sc, 0.0, de) * (1.0 - inBead); // the socket's soft shadow
  // the bead: near-black glass, warm light low inside it, and its shine
  float z = sqrt(max(0.0, 1.0 - dot(e, e)));
  vec3 nb = normalize(toWorld(normalize(vec3(e * 0.85, z + 0.2))));
  vec3 bead = INK + u_deep * 0.1;
  bead += mix(u_mid, u_light, 0.3) * 0.3 * smoothstep(-0.1, -0.95, e.y) * (1.0 - abs(e.x) * 0.6);
  vec3 H = normalize(normalize(KEY) + V);
  bead += pow(clamp(dot(nb, H), 0.0, 1.0), 220.0) * 1.4;
  bead += softbox(nb, V, 0.6) * 0.5;
  float cl = 1.0 - smoothstep(0.036 * sc - aa, 0.036 * sc + aa, length((e - vec2(-0.3, 0.42)) * rad));
  float cl2 = 1.0 - smoothstep(0.016 * sc - aa, 0.016 * sc + aa, length((e - vec2(0.32, -0.42)) * rad));
  bead += cl * 0.95 + cl2 * 0.55;
  vec3 open3 = mix(lid, bead, shown);
  // the lash line where the lid meets the eye; a thick curve when the eye is closed
  float hw = sqrt(max(0.0, 1.0 - top * top)) + 0.12;
  float lash = (1.0 - smoothstep(-aa, aa, abs((e.y - top) * rad.y) - 0.03 * sc))
             * (1.0 - smoothstep(-aa, aa, (abs(e.x) - hw) * rad.x)) * step(top, 1.0);
  open3 = mix(open3, INK, lash);
  // happy: a thick ^ in place of the eye
  float arc = sdArc(q - c + vec2(0.0, 0.06 * sc), vec2(0.891, 0.454), 0.105 * sc, 0.034 * sc);
  vec3 glad = mix(col, INK, 1.0 - smoothstep(-aa, aa, arc));
  col = mix(open3, glad, happy);
}

// The mouth at c: talking or "o" opens it (a tongue inside); flat, smiling or fretting draws it.
void mouth(inout vec3 col, vec2 q, vec2 c, float aa){
  float mode = u_mouth.x;
  if (mode < 0.5) return;
  vec2 p = q - c;
  float tl = u_mouth.w;
  p = mat2(cos(tl), sin(tl), -sin(tl), cos(tl)) * p;
  float w = u_mouth.y, h = u_mouth.z, lw = 0.036;
  if (mode < 2.5){
    vec2 pp = p;
    if (mode < 1.5 && pp.y > 0.0) pp.y *= 1.4; // talking: a flatter top lip
    float d = (length(pp / vec2(w, h)) - 1.0) * min(w, h);
    vec3 cav = vec3(0.17, 0.05, 0.05);
    float tongue = 1.0 - smoothstep(-0.08, 0.08, length((p - vec2(0.0, -h * 0.95)) / vec2(w * 0.78, h * 0.62)) - 1.0);
    cav = mix(cav, vec3(0.86, 0.36, 0.4), tongue * 0.9);
    cav *= mix(1.0, 0.55, smoothstep(-h, h, p.y));
    col = mix(col, cav, 1.0 - smoothstep(-aa, aa, d));
    col = mix(col, INK, 1.0 - smoothstep(-aa, aa, abs(d) - 0.014));
    return;
  }
  float d;
  if (mode < 3.5){ vec2 a = p; a.x = max(abs(a.x) - w, 0.0); d = length(a) - lw; }   // flat
  else if (mode < 5.5){                                                              // smile
    vec2 s = vec2(sin(h), cos(h));
    float ra = w / s.x;
    d = sdArc(vec2(p.x, -(p.y - ra * s.y - 0.02)), s, ra, lw);
  } else { d = max(abs(p.y - 0.018 * sin(p.x * 34.0)) - lw * 0.85, abs(p.x) - w); }  // a fret
  col = mix(col, INK, 1.0 - smoothstep(-aa, aa, d));
}

vec3 shade(vec3 p, vec3 rd, float pxW){
  vec2 k = vec2(0.0015, -0.0015);
  vec3 n = normalize(k.xyy * map(p + k.xyy) + k.yyx * map(p + k.yyx) + k.yxy * map(p + k.yxy) + k.xxx * map(p + k.xxx));
  vec3 pl = toBody(p);
  vec3 nl = normalize(u_rot * n);
  vec3 V = -rd;
  // the fluid inside, in the body's own space so it turns with it
  vec2 fp = pl.xy * 1.15 + pl.z * 0.45 + u_seed * 0.37;
  float t = u_time;
  vec2 q = vec2(fbm(fp + vec2(0.0, t * 0.9)), fbm(fp + vec2(5.2, 1.3) - t * 0.7));
  vec2 w = vec2(fbm(fp + 3.0 * q + vec2(1.7, 9.2) + t * 0.5), fbm(fp + 3.0 * q + vec2(8.3, 2.8) - t * 0.4));
  float f = fbm(fp + 2.4 * w);
  float h = clamp(0.48 - pl.y * 0.42 + (f - 0.5) * (0.85 + 0.25 * u_energy), 0.0, 1.0);
  vec3 alb = mix(u_light, u_mid, smoothstep(0.18, 0.55, h));
  alb = mix(alb, u_deep, smoothstep(0.55, 0.98, h));
  float gloss = 1.0, sss = 1.0, ey = -0.02, my = -0.36;
  if (u_shape == 0){ // sugar glitter that twinkles as the body turns
    vec3 g = pl * 26.0, gc = floor(g);
    float spark = step(0.9, hash(gc.xy + gc.z * 7.1)) * smoothstep(0.3, 0.1, length(fract(g.xy) - 0.5));
    float glint = pow(clamp(dot(reflect(rd, n), normalize(KEY)), 0.0, 1.0), 6.0);
    alb += spark * (0.25 + 1.4 * glint);
  } else if (u_shape == 1){ // a glossy icing cap with drips
    ey = -0.06; my = -0.40;
    float line = 0.44 + 0.06 * sin(pl.x * 7.0 + u_seed * 3.0) + 0.05 * sin(pl.z * 8.0 + u_seed);
    float ice = smoothstep(line - 0.015, line + 0.015, pl.y);
    alb = mix(alb, mix(u_light, vec3(1.0, 0.98, 0.95), 0.55), ice * 0.92);
    gloss = 0.75 + 0.55 * ice;
  } else if (u_shape == 2){ // cream between the shells
    ey = 0.21; my = -0.11;
    float top = sdEll(pl - vec3(0.0, 0.24, 0.0), vec3(0.92, 0.44, 0.74));
    float bot = sdEll(pl - vec3(0.0, -0.42, 0.0), vec3(0.90, 0.32, 0.72));
    float fill = sdEll(pl - vec3(0.0, -0.11, 0.0), vec3(0.83, 0.15, 0.66));
    float cream = smoothstep(0.012, -0.012, fill - min(top, bot));
    alb = mix(alb, mix(u_light, vec3(1.0, 0.97, 0.92), 0.6), cream);
    gloss = mix(0.9, 0.45, cream);
  } else if (u_shape == 3){ // a dusting of flour on a soft, satin skin
    ey = -0.08; my = -0.42;
    vec2 fg = pl.xy * 34.0 + pl.z * 20.0;
    float speck = step(0.93, hash(floor(fg))) * smoothstep(0.28, 0.08, length(fract(fg) - 0.5));
    alb = mix(alb, vec3(1.0), speck * 0.35);
    gloss = 0.45; sss = 1.6;
  } else { // baked: matte with tiny pits, glossy chocolate
    ey = 0.06; my = -0.30;
    float cm = chips(pl.xy) * step(0.0, pl.z);
    alb *= 0.93 + 0.07 * noise(pl.xy * 18.0);
    alb = mix(alb, u_deep * 0.42, cm);
    gloss = mix(0.35, 0.95, cm); sss = 0.6;
  }
  vec3 col = light(alb, p, n, V, gloss, sss);
  if (nl.z > 0.02 && pl.z > 0.0){
    float aa = pxW * 0.9 / max(nl.z, 0.3);
    vec2 g = vec2(u_eye.x * 0.07, -u_eye.y * 0.055);
    vec2 fq = pl.xy;
    // cheeks that blush when it's pleased or petted
    for (int i = 0; i < 2; i++){
      float s = i == 0 ? -1.0 : 1.0;
      float bl = smoothstep(0.17, 0.0, length((fq - vec2(s * (u_ex + 0.14), ey - 0.2) - g * 0.5) * vec2(1.0, 1.5)));
      col = mix(col, vec3(1.0, 0.45, 0.5), u_lids.z * 0.55 * bl);
    }
    eye(col, fq, vec2(-u_ex, ey) + g, aa, V);
    eye(col, fq, vec2(u_ex, ey) + g, aa, V);
    mouth(col, fq, vec2(0.0, my) + g * 0.75, aa);
  }
  col = mix(col, vec3(0.95, 0.22, 0.2) * (0.5 + 0.5 * dot(col, vec3(0.33))), u_lids.w * 0.45);
  return col / (1.0 + max(col - 0.85, 0.0)); // a soft shoulder, so highlights never clip flat
}

void main(){
  vec2 uv = (gl_FragCoord.xy * 2.0 - u_res) / u_res.y * u_view;
  float pxW = 2.0 * u_view / u_res.y;
  // a camera a little above, so the top of each body shows, like a product shot
  const float CA = 0.12;
  vec3 ro = vec3(0.0, 6.0 * sin(CA), 6.0 * cos(CA));
  vec3 fw = normalize(-ro), rt = vec3(1.0, 0.0, 0.0), up = cross(rt, fw);
  vec3 rd = normalize(uv.x * rt + uv.y * up + 6.0 * fw);
  // the shadow on the table: it stays on the ground, smaller and fainter as the body hops
  float lift = max(u_body.x, 0.0);
  vec2 sq = vec2(uv.x / ((u_shape == 4 ? 0.55 : 0.8) * u_body.y * (1.0 + lift * 0.5)), (uv.y - base() * 0.99 + 0.02) / (0.12 * (1.0 + lift * 0.6)));
  float shadow = exp(-dot(sq, sq) * 2.0) * 0.5 * (1.0 - min(lift * 1.8, 0.75));
  vec4 o = vec4(0.0);
  vec3 oc = ro - vec3(0.0, u_body.x, 0.0);
  float rb = 1.3 * max(u_body.y, u_body.z);
  float bq = dot(oc, rd), disc = bq * bq - (dot(oc, oc) - rb * rb);
  if (disc > 0.0){
    float t = -bq - sqrt(disc), t1 = -bq + sqrt(disc), dmin = 1e3, tmin = t;
    bool hit = false;
    for (int i = 0; i < 90; i++){
      float d = map(ro + rd * t);
      if (d < dmin){ dmin = d; tmin = t; }
      if (d < 0.0012){ hit = true; break; }
      t += d;
      if (t > t1) break;
    }
    // a ray that just grazes the body still lights a little of the pixel: a smooth edge
    float cover = hit ? 1.0 : 1.0 - smoothstep(0.0, pxW * 0.9, dmin);
    if (cover > 0.0) o = vec4(shade(ro + rd * (hit ? t : tmin), rd, pxW) * cover, cover);
  }
  gl_FragColor = o + vec4(0.0, 0.0, 0.0, shadow) * (1.0 - o.a);
}`;

  const R = (() => {
    const cv = document.createElement("canvas");
    const gl = cv.getContext("webgl", { alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: true, antialias: false });
    if (!gl) return null;
    const sh = (type, src) => {
      const x = gl.createShader(type); gl.shaderSource(x, src); gl.compileShader(x);
      if (gl.getShaderParameter(x, gl.COMPILE_STATUS)) return x;
      console.warn("face shader:", gl.getShaderInfoLog(x));
      return null;
    };
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
    const names = ["u_res", "u_time", "u_energy", "u_seed", "u_sec", "u_ex", "u_view", "u_shape", "u_deep", "u_mid", "u_light", "u_rot", "u_body", "u_eye", "u_lids", "u_mouth"];
    const u = Object.fromEntries(names.map((n) => [n, gl.getUniformLocation(prog, n)]));
    cv.width = cv.height = 512;
    return {
      draw(face) {
        const px = face.px, v = face.u;
        if (cv.width < px) cv.width = cv.height = px;
        gl.viewport(0, 0, px, px);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform2f(u.u_res, px, px);
        gl.uniform1f(u.u_time, face.clock);
        gl.uniform1f(u.u_energy, face.energy);
        gl.uniform1f(u.u_seed, (face.look.seed % 997) / 97);
        gl.uniform1f(u.u_sec, (performance.now() / 1000) % 1000);
        gl.uniform1f(u.u_ex, face.look.ex);
        gl.uniform1f(u.u_view, face.view);
        gl.uniform1i(u.u_shape, SHAPES.indexOf(face.look.shape));
        gl.uniform3f(u.u_deep, ...face.look.deep);
        gl.uniform3f(u.u_mid, ...face.look.mid);
        gl.uniform3f(u.u_light, ...face.look.light);
        gl.uniformMatrix3fv(u.u_rot, false, rotation(v[2], v[3], v[4]));
        gl.uniform4f(u.u_body, v[5], v[6], v[7], v[8]);
        gl.uniform4f(u.u_eye, v[9], v[10], v[11], v[12]);
        gl.uniform4f(u.u_lids, v[13], v[14], v[15], v[16]);
        gl.uniform4f(u.u_mouth, v[17], v[18], v[19], v[20]);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        const fxOn = face.parts.length || face.emit.length;
        face.ctx.clearRect(0, 0, px, px);
        if (fxOn) drawFx(face, false);
        face.ctx.drawImage(cv, 0, cv.height - px, px, px, 0, 0, px, px);
        if (fxOn) drawFx(face, true);
      },
    };
  })();

  /** The body's turn, body → world: tilt · yaw · pitch. Sent as rows, which GLSL reads as
   *  columns: the transpose, which for a rotation is the inverse (world → body). */
  function rotation(yaw, pitch, tilt) {
    const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch), ct = Math.cos(tilt), st = Math.sin(tilt);
    const mul = (A, B) => A.map((r) => [0, 1, 2].map((j) => r[0] * B[0][j] + r[1] * B[1][j] + r[2] * B[2][j]));
    const M = mul([[ct, -st, 0], [st, ct, 0], [0, 0, 1]], mul([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]], [[1, 0, 0], [0, cp, -sp], [0, sp, cp]]));
    return new Float32Array([...M[0], ...M[1], ...M[2]]);
  }

  // Mouth shapes, as the shader numbers them.
  const MOUTH = { "": 0, talk: 1, o: 2, flat: 3, smile: 4, rest: 5, fret: 6 };

  /* ---------- effects round the body: wind, swoosh, fire, sparkle, dust ----------
   * Drawn on the face's own 2D canvas in two passes, behind the body and in front of it,
   * so a ribbon of wind wraps round it and flames lick up from behind. Positions are in
   * face units (the box is ±1, y up), the same space the shader draws the body in. */
  const rand = (a, b) => a + Math.random() * (b - a);
  const mixc = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
  const groundOf = (s) => (s.look.shape === "biscuit" ? -0.95 : -0.72);
  const hopOf = (s) => (s.u ? s.u[5] : 0);

  function addFx(s, kind, ms = 900) {
    const now = performance.now(), hop = hopOf(s), g = groundOf(s);
    if (kind === "sparkle") {
      for (let i = 0; i < 14; i++) {
        const a = (i / 14) * Math.PI * 2 + rand(-0.2, 0.2), v = rand(1.3, 2.3);
        // from just outside the body, outward, so it never sparkles over the face
        s.parts.push({ k: "star", x: Math.cos(a) * 0.95, y: hop + Math.sin(a) * 0.9, vx: Math.cos(a) * v, vy: Math.sin(a) * v, age: 0, life: rand(0.55, 0.9), r: rand(0.08, 0.15), rot: rand(0, 3), vr: rand(-6, 6), front: true });
      }
      return;
    }
    if (kind === "dust") {
      for (let i = 0; i < 12; i++) {
        const side = i % 2 ? 1 : -1;
        s.parts.push({ k: "dust", x: side * rand(0.25, 0.7), y: g + rand(0.02, 0.12), vx: side * rand(0.5, 1.3), vy: rand(0.05, 0.35), age: 0, life: rand(0.45, 0.8), r: rand(0.08, 0.14), front: Math.random() < 0.5 });
      }
      return;
    }
    s.emit.push({ kind, at: now, until: now + ms, acc: 0 });
  }

  /** Spawns from the live effects, moves every particle. True while anything is showing. */
  function stepFx(s, now, dt) {
    if (!s.emit.length && !s.parts.length) return false;
    const hop = hopOf(s), g = groundOf(s);
    s.emit = s.emit.filter((e) => now < e.until + 450);
    for (const e of s.emit) {
      if (now > e.until) continue;
      if (e.kind === "fire") {
        e.acc += dt * 110;
        for (; e.acc >= 1; e.acc--) {
          const air = hop > 0.25;
          if (air) { // a rocket's trail: out of the bottom, left behind in the air
            s.parts.push({ k: "fire", x: rand(-0.3, 0.3), y: hop + g + 0.12, vx: rand(-0.25, 0.25), vy: rand(-1.1, -0.4), age: 0, life: rand(0.35, 0.6), r: rand(0.16, 0.28), front: Math.random() < 0.4 });
          } else { // flames all round the base, rising behind and beside the body
            // behind and beside it, never over the face: an aura of flame round the silhouette
            const a = Math.random() * Math.PI * 2, rr = rand(0.55, 1.0);
            s.parts.push({ k: "fire", x: Math.cos(a) * rr, y: g + rand(0.05, 0.5), vx: Math.cos(a) * rand(0.15, 0.45), vy: rand(0.8, 1.7), age: 0, life: rand(0.5, 0.95), r: rand(0.18, 0.34), front: false });
          }
          if (Math.random() < 0.14) s.parts.push({ k: "ember", x: rand(-0.95, 0.95), y: hop + g + rand(0.1, 0.5), vx: rand(-0.4, 0.4), vy: rand(1.0, 1.9), age: 0, life: rand(0.8, 1.4), r: rand(0.022, 0.04), ph: rand(0, 6), front: false });
        }
      }
      if (e.kind === "wind" && hop < 0.35) { // the wind kicks up a little dust from the table
        e.acc += dt * 14;
        for (; e.acc >= 1; e.acc--) { const side = Math.random() < 0.5 ? -1 : 1; s.parts.push({ k: "dust", x: side * rand(0.5, 0.9), y: g + 0.04, vx: side * rand(0.3, 0.8), vy: rand(0.1, 0.4), age: 0, life: rand(0.4, 0.7), r: rand(0.06, 0.11), front: Math.random() < 0.5 }); }
      }
    }
    const drag = Math.exp(-dt * 3.2);
    for (const q of s.parts) {
      q.age += dt;
      if (q.k === "fire") { q.vy += 1.8 * dt; q.vx *= 0.97; }
      else if (q.k === "ember") { q.vy -= 0.2 * dt; q.x += Math.sin(q.age * 9 + q.ph) * 0.4 * dt; }
      else if (q.k === "star") { q.vx *= drag; q.vy = q.vy * drag - 0.6 * dt; q.rot += q.vr * dt; }
      else if (q.k === "dust") { q.vx *= drag; q.vy *= drag; }
      q.x += q.vx * dt; q.y += q.vy * dt;
    }
    s.parts = s.parts.filter((q) => q.age < q.life);
    if (s.parts.length > 400) s.parts.splice(0, s.parts.length - 400);
    return true;
  }

  function fireColor(t) {
    if (t < 0.3) return mixc([255, 246, 205], [255, 196, 70], t / 0.3);
    if (t < 0.65) return mixc([255, 196, 70], [244, 96, 24], (t - 0.3) / 0.35);
    return mixc([244, 96, 24], [130, 32, 12], (t - 0.65) / 0.35);
  }

  function drawFx(s, front) {
    const c = s.ctx, px = s.px, k = px / (2 * s.view), half = px / 2;
    const X = (x) => half + x * k, Y = (y) => half - y * k;
    const now = performance.now(), hop = hopOf(s), g = groundOf(s);
    const tint = s.look.light.map((v) => Math.round(v * 255));
    c.save();
    // ribbons of wind (round the body) and swoosh trails (beside a flip)
    for (const e of s.emit) {
      const env = Math.min(1, (now - e.at) / 150) * Math.max(0, Math.min(1, 1 - (now - e.until) / 450));
      if (env <= 0) continue;
      const t = (now - e.at) / 1000;
      if (e.kind === "fire" && !front) { // the heat: a glow behind the body
        const gr = c.createRadialGradient(X(0), Y(hop + g + 0.5), 0, X(0), Y(hop + g + 0.5), 1.5 * k);
        gr.addColorStop(0, `rgba(255,130,40,${0.32 * env})`);
        gr.addColorStop(1, "rgba(255,80,20,0)");
        c.fillStyle = gr; c.fillRect(0, 0, px, px);
      }
      if (e.kind !== "wind" && e.kind !== "swoosh") continue;
      c.lineCap = "round";
      const N = 22, ribbons = e.kind === "wind" ? 3 : 2;
      for (let i = 0; i < ribbons; i++) {
        for (let j = 0; j < N; j++) {
          const head = t * (e.kind === "wind" ? 11 : 9) + i * (Math.PI * 2 / ribbons);
          const a0 = head - j * 0.075, a1 = a0 - 0.08;
          let x0, y0, x1, y1, near;
          if (e.kind === "wind") {
            const yc = hop + (-0.42 + i * 0.4) + Math.sin(t * 3 + i) * 0.05, rx = 1.0 + i * 0.1, ry = 0.27;
            x0 = Math.cos(a0) * rx; y0 = yc + Math.sin(a0) * ry; x1 = Math.cos(a1) * rx; y1 = yc + Math.sin(a1) * ry;
            near = Math.sin(a0) < 0;
          } else {
            const side = i ? 1 : -1;
            x0 = side * (0.96 + 0.1 * Math.cos(a0)); y0 = hop + Math.sin(a0) * 1.05; x1 = side * (0.96 + 0.1 * Math.cos(a1)); y1 = hop + Math.sin(a1) * 1.05;
            near = Math.cos(a0) > 0;
          }
          if (near !== front) continue;
          const fade = 1 - j / N;
          c.strokeStyle = `rgba(${mixc([255, 255, 255], tint, 0.35).map(Math.round).join(",")},${0.75 * fade * env})`;
          c.lineWidth = Math.max(0.8, 0.1 * k * fade);
          c.beginPath(); c.moveTo(X(x0), Y(y0)); c.lineTo(X(x1), Y(y1)); c.stroke();
        }
      }
    }
    // particles
    for (const q of s.parts) {
      if (q.front !== front) continue;
      const t = q.age / q.life;
      if (q.k === "fire") {
        c.globalCompositeOperation = "lighter";
        const [r, gg, b] = fireColor(t), rr = q.r * (1 - t * 0.55) * k, a = Math.pow(1 - t, 1.2) * 0.85;
        const gr = c.createRadialGradient(X(q.x), Y(q.y), 0, X(q.x), Y(q.y), rr);
        gr.addColorStop(0, `rgba(${r | 0},${gg | 0},${b | 0},${a})`);
        gr.addColorStop(1, `rgba(${r | 0},${gg | 0},${b | 0},0)`);
        c.fillStyle = gr; c.beginPath(); c.arc(X(q.x), Y(q.y), rr, 0, 7); c.fill();
      } else if (q.k === "ember") {
        c.globalCompositeOperation = "lighter";
        c.fillStyle = `rgba(255,${200 - t * 120 | 0},90,${(1 - t) * (0.6 + 0.4 * Math.sin(q.age * 30))})`;
        c.beginPath(); c.arc(X(q.x), Y(q.y), Math.max(0.6, q.r * k), 0, 7); c.fill();
      } else if (q.k === "star") {
        c.globalCompositeOperation = "lighter";
        const sz = q.r * k * Math.sin(Math.min(1, t * 1.6) * Math.PI) + 0.5, a = 1 - t * t;
        c.translate(X(q.x), Y(q.y)); c.rotate(q.rot);
        c.fillStyle = `rgba(${mixc([255, 255, 255], tint, 0.25).map(Math.round).join(",")},${a})`;
        c.beginPath();
        for (let m = 0; m < 8; m++) { const rad = m % 2 ? sz * 0.28 : sz, an = (m / 8) * Math.PI * 2; c.lineTo(Math.cos(an) * rad, Math.sin(an) * rad); }
        c.closePath(); c.fill();
        c.setTransform(1, 0, 0, 1, 0, 0);
      } else if (q.k === "dust") {
        c.globalCompositeOperation = "source-over";
        const rr = q.r * (1 + t * 1.6) * k;
        const gr = c.createRadialGradient(X(q.x), Y(q.y), 0, X(q.x), Y(q.y), rr);
        gr.addColorStop(0, `rgba(205,196,186,${0.3 * (1 - t)})`);
        gr.addColorStop(1, "rgba(205,196,186,0)");
        c.fillStyle = gr; c.beginPath(); c.arc(X(q.x), Y(q.y), rr, 0, 7); c.fill();
      }
    }
    c.restore();
  }

  /* ---------- a face ---------- */
  /** opts.view: how far the canvas reaches past the box (1.36; 2.4 for a stage with big jumps). */
  function create(id, size = 44, salt = ownSalt, opts = {}) {
    const lk = look(salt && id !== "cookie" ? salt + ":" + id : id);
    const root = document.createElement("span");
    root.className = R ? "face gl" : "face";
    root.style.width = root.style.height = size + "px";
    root.setAttribute("aria-hidden", "true");
    const canvas = document.createElement("canvas");
    const view = R ? Math.max(1.2, opts.view || VIEW) : 1;
    const px = Math.round(size * view * Math.min(devicePixelRatio || 1, 2));
    canvas.width = canvas.height = px;
    if (R) {
      canvas.className = "gl";
      canvas.style.width = canvas.style.height = view * 100 + "%";
      canvas.style.left = canvas.style.top = -(view - 1) * 50 + "%";
    }
    // Without WebGL the old flat face draws: a gradient body, eyes and mouth in HTML.
    const eyes = document.createElement("span");
    eyes.className = "eyes";
    const ew = Math.max(2.4, size * 0.105), eh = Math.max(4, size * 0.22);
    eyes.innerHTML = `<i style="width:${ew}px;height:${eh}px"></i><i style="width:${ew}px;height:${eh}px"></i>`;
    eyes.style.gap = size * (0.15 + ((lk.seed >>> 7) % 3) * 0.02) + "px";
    eyes.style.setProperty("--ew", ew + "px");
    const inner = document.createElement("span");
    inner.className = "flip";
    const sheen = document.createElement("span");
    sheen.className = "sheen";
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
      look: lk, root, ctx: canvas.getContext("2d"), px, size, view, parts: [], emit: [], eyes: [...eyes.children], eyesWrap: eyes,
      clock: 3.7 + (lk.seed % 100) / 10, energy: 0, energyTarget: 0, last: performance.now(), frame: lk.seed % 3,
      blinksPerMin: 8 + (lk.seed % 13), phase: (lk.seed % 1000) / 160, bounce: 0.7 + ((lk.seed >>> 11) % 5) * 0.12,
      gaze: { x: 0, y: 0 }, from: { x: 0, y: 0 }, to: { x: 0, y: 0 },
      sacStart: 0, sacDur: 1, nextGlance: 0, blinkStart: -1, nextBlink: 0,
      mood: "idle", ackAt: -1, happyAt: -1, settled: false,
      id, inner, sheen, mouth, orbit, zz, mouthMode: "", talk: 0, talkTarget: 0, listening: false,
      tool: null, orbitAngle: (lk.seed % 628) / 100, errAt: -1, perkAt: -1, glance: null, squish: 0, pressed: false, spring: null,
      lastActive: performance.now(), dozing: false, roll: null, hopAt: -1, hopMs: 0, hopH: 0, wakeAt: -1, scanAt: 0, rect: null, rectAt: 0,
      // eased expression levels, so a smile or a squint arrives instead of snapping
      happyK: 0, squintK: 0, blushK: 0, landAt: -1, u: null, drawn: null,
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
        // A new job or a finished one turns the face once, like a ball catching light.
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
      /** A trick: the body rolls round. kind: front, back, double, spin, spin2. */
      flip(kind = "front", ms) {
        const k = { front: ["x", 1, 820], back: ["x", -1, 820], double: ["x", 2, 1150], spin: ["y", 1, 760], spin2: ["y", 2, 1050], corkscrew: ["xy", 1, 1000] }[kind] ?? ["x", 1, 820];
        roll(st, k[0], k[1], ms ?? k[2]); wake(st);
      },
      /** A real jump: crouch, take off stretched, land squashed with a jelly tremble and a
       *  puff of dust. h is the height as a share of its size; the shadow stays on the table. */
      jump(h = 0.4, ms = 900) { if (reduce) return; st.hopAt = performance.now(); st.hopMs = ms; st.hopH = h; wake(st); },
      /** An effect round the body for ms: wind (swirling ribbons), swoosh (flip trails),
       *  fire (flames, embers, a rocket trail in the air), sparkle and dust (one burst). */
      fx(kind, ms = 900) { if (!reduce && R) addFx(st, kind, ms); wake(st); },
      /** Squish! A big jelly wobble. */
      jelly() { st.spring = { at: performance.now(), from: 0.95 }; st.happyAt = performance.now(); wake(st); },
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

  /** One premium turn: the whole body spins round once in 3D, with a hop. */
  function turn(st, ms) {
    if (reduce) return;
    roll(st, "y", 1, ms);
    st.hopAt = performance.now(); st.hopMs = ms; st.hopH = 0.08;
    if (!R && st.sheen.animate) st.sheen.animate(
      [
        { opacity: 0, transform: "translateX(-120%) skewX(-18deg)" },
        { opacity: 0.85, offset: 0.45 },
        { opacity: 0, transform: "translateX(140%) skewX(-18deg)" },
      ],
      { duration: ms, easing: "ease-out" },
    );
  }

  /** Roll the body: axis "x" is a flip (the face goes up over the top, or down for
   *  turns < 0), "y" a spin round the side. `turns` whole turns over `ms`. */
  function roll(st, axis, turns, ms) {
    st.roll = { axis, turns, start: performance.now(), ms };
  }

  // At rest: one slow blink every 6–10 s. At work: the measured, per-agent rate.
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

  const ease = (k, goal, dt, rate) => k + (goal - k) * Math.min(1, dt * rate);

  function paint(s, now, force) {
    const dt = Math.min(0.05, (now - s.last) / 1000);
    s.last = now;
    const sec = now / 1000;

    // Long with nothing to do: it dozes (eyes half shut, a slow "z"), until anything wakes it.
    if (!s.dozing && s.mood === "idle" && !s.pressed && !s.talkTarget && !s.tool && now - s.lastActive > dozeAfter) s.dozing = true;
    if (s.dozing && s.mood !== "idle") s.dozing = false;

    // A roll: the angle eases in and out, a whole number of turns.
    let rollA = 0, rollAxis = null;
    if (s.roll) {
      const p = Math.min(1, (now - s.roll.start) / s.roll.ms);
      const k = p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2; // ease in-out cubic
      rollA = k * s.roll.turns * Math.PI * 2;
      rollAxis = s.roll.axis;
      if (p >= 1) s.roll = null;
    }
    s.energy += (s.energyTarget - s.energy) * Math.min(1, dt * 2.5);
    const flowing = s.energy > 0.01 || s.talk > 0.02;
    // The fluid flows only while the agent works (or talks); at rest it is still glass.
    if (flowing) s.clock += dt * (0.08 + 0.4 * Math.max(s.energy, s.talk * 0.8));

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
    // Idle and awake: it follows your pointer when it's near.
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

    const perk = s.perkAt >= 0 && now - s.perkAt < 520 ? (now - s.perkAt) / 520 : -1;
    if (s.perkAt >= 0 && perk < 0) s.perkAt = -1;
    const woke = s.wakeAt >= 0 && now - s.wakeAt < 450;
    if (s.wakeAt >= 0 && !woke) s.wakeAt = -1;
    const busy = s.mood === "thinking" || s.mood === "working";
    const j = busy ? 0.02 : 0;
    const gx = s.gaze.x + (Math.random() - 0.5) * j, gy = s.gaze.y + (Math.random() - 0.5) * j;
    let open = happy ? 1 : Math.max(0, 1 - Math.max(lid, Math.max(0, gy) * 0.14, s.mood === "thinking" ? 0.12 : 0));
    if (s.dozing) open = Math.min(open, 0.2 + Math.sin(sec * 0.9) * 0.05);
    let eyeScale = 1;
    if (perk >= 0) eyeScale = 1 + Math.sin(perk * Math.PI) * 0.22;
    if (woke) eyeScale = 1.25;

    // The mouth: speaking with the real voice, an "o" when listening, hearing its name or
    // waking, a fret while it waits for your yes or after a mistake, a smile when pleased,
    // and on a big face at rest, the faintest content smile.
    s.talk += (s.talkTarget - s.talk) * Math.min(1, dt * 22);
    const err = s.errAt >= 0 && now - s.errAt < 1300 ? (now - s.errAt) / 1300 : -1;
    if (s.errAt >= 0 && err < 0) s.errAt = -1;
    const flash = s.mouthFlash && now < s.mouthFlash.until ? s.mouthFlash.mode : null;
    let mode = "";
    if (s.talkTarget > 0.01 || s.talk > 0.04) mode = "talk";
    else if (flash) mode = flash;
    else if (s.listening) mode = "o";
    else if (perk >= 0 || woke) mode = "o";
    else if (err >= 0) mode = "fret";
    else if (s.mood === "waiting") mode = "flat";
    else if (happy && s.size >= 40) mode = "smile";
    else if (R && !active && !s.dozing && s.size >= 56) mode = "rest";
    if (s.size < (R ? 24 : 30)) mode = "";

    // Body: still at rest. A "got it" squash on a new message, a sway while thinking,
    // a small bounce while working, a lean toward you while it waits for your yes.
    let sy = 1, sx = 1, ty = 0, rot = 0, lean = 1, shake = 0;
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
    if (s.hopAt >= 0) {
      const p = (now - s.hopAt) / s.hopMs;
      if (p >= 1) { s.hopAt = -1; s.landAt = now; if (s.hopH >= 0.15 && R) addFx(s, "dust"); }
      else if (p < 0.12) sy -= (p / 0.12) * 0.1;                                  // crouch
      else if (p < 0.85) { const q = (p - 0.12) / 0.73; ty = Math.min(ty, -Math.sin(q * Math.PI) * s.hopH); sy += Math.sin(q * Math.PI) * 0.06; } // up, stretched
      else sy -= Math.sin(((p - 0.85) / 0.15) * Math.PI) * 0.12;                 // land
    }
    if (perk >= 0) ty = Math.min(ty, -Math.sin(perk * Math.PI) * 0.18);
    // A mistake: a quick shake of the head, dying out.
    if (err >= 0) { const p = Math.min(1, err * 2); shake = Math.sin(p * Math.PI * 6) * (1 - p); }
    s.root.classList.toggle("err", err >= 0 && err < 0.75);
    // Petting: pressed, it squashes like jelly; let go, it springs back with a damped wobble.
    let wob = 0;
    if (s.pressed) s.squish += (1 - s.squish) * Math.min(1, dt * 14);
    else if (s.spring) {
      const t2 = (now - s.spring.at) / 1000;
      s.squish = s.spring.from * Math.exp(-t2 * 5.5) * Math.cos(t2 * 24);
      wob = 0.7 * Math.exp(-t2 * 4);
      if (t2 > 1.1) { s.spring = null; s.squish = 0; }
    } else s.squish = 0;
    // A landing sets the jelly trembling for a moment.
    if (s.landAt >= 0) { const t3 = (now - s.landAt) / 1000; if (t3 > 0.6) s.landAt = -1; else wob = Math.max(wob, 0.5 * Math.exp(-t3 * 7)); }
    sy -= s.squish * 0.2; sx += s.squish * 0.2;

    // Expressions ease in and out, so a smile or a squint arrives instead of snapping.
    s.happyK = ease(s.happyK, happy ? 1 : 0, dt, 16);
    s.squintK = ease(s.squintK, s.mood === "working" ? 0.38 : s.mood === "writing" ? 0.26 : err >= 0 ? 0.3 : 0, dt, 9);
    s.blushK = ease(s.blushK, Math.max(happy ? 0.85 : 0, s.squish), dt, 8);

    const S = s.size;
    if (R) {
      // 3D: the head turns toward where the eyes look (the eyes lead, the head follows),
      // rolls round in a trick, shakes no after a mistake, sways while thinking.
      const yaw = gx * 0.34 + (rollAxis === "y" || rollAxis === "xy" ? rollA : 0) + shake * 0.42;
      const pitch = gy * 0.24 - (rollAxis === "x" || rollAxis === "xy" ? rollA : 0);
      const tilt = -rot * Math.PI / 180;
      let mw = 0, mh = 0, mt = 0;
      if (mode === "talk") { mw = 0.11 + s.talk * 0.05; mh = 0.035 + s.talk * 0.12; }
      else if (mode === "o") { mw = mh = 0.075; }
      else if (mode === "flat") { mw = 0.1; mt = 0.07; }
      else if (mode === "fret") { mw = 0.12; mt = 0.1; }
      else if (mode === "smile") { mw = 0.15; mh = 1.0; }
      else if (mode === "rest") { mw = 0.07; mh = 0.8; }
      const lw = lean;
      s.u = [
        0, 0, yaw, pitch, tilt,
        -ty * 2, sx * lw * (2 - sy), sy * lw, wob,
        gx, gy, open, eyeScale,
        s.happyK, s.squintK, s.blushK, err >= 0 && err < 0.75 ? 1 - err / 0.75 : 0,
        MOUTH[mode] ?? 0, mw, mh, mt,
      ];
      // Redraw only when something changed. Small faces repaint a flowing body every third frame.
      const prev = s.drawn;
      let changed = force || !prev || wob > 0.001;
      if (!changed) for (let i = 2; i < s.u.length; i++) if (Math.abs(s.u[i] - prev[i]) > 0.0015) { changed = true; break; }
      if (!changed && flowing && (S >= 64 || (s.frame++ % 3) === 0)) changed = true;
      if (stepFx(s, now, dt)) changed = true;
      if (changed) { R.draw(s); s.drawn = s.u; }
      s.root.style.transform = "";
    } else {
      // The flat fallback: HTML eyes and mouth over a gradient body.
      s.eyesWrap.classList.toggle("happy", happy);
      s.eyesWrap.style.transform = `translate(${gx * S * 0.1}px, ${gy * S * 0.08 - S * 0.035}px)`;
      for (const eye of s.eyes) eye.style.transform = `scale(${eyeScale}, ${Math.max(0.08, open) * eyeScale})`;
      const m = s.mouth;
      const dmode = mode === "fret" ? "flat" : mode;
      if (dmode !== s.mouthMode) { m.classList.toggle("smile", dmode === "smile"); s.mouthMode = dmode; }
      let mw = 0, mh = 0, mr = "999px", mt = "";
      if (dmode === "talk") { mw = S * (0.12 + s.talk * 0.06); mh = S * (0.025 + s.talk * 0.13); mr = "45% 45% 50% 50%"; }
      else if (dmode === "o") { mw = mh = S * 0.085; mr = "50%"; }
      else if (dmode === "flat") { mw = S * 0.13; mh = Math.max(1.5, S * 0.028); mt = ` rotate(${err >= 0 ? -8 : -4}deg)`; }
      else if (dmode === "smile") { mw = S * 0.2; mh = S * 0.085; mr = ""; }
      m.style.opacity = dmode ? 1 : 0;
      if (dmode) { m.style.width = mw + "px"; m.style.height = mh + "px"; if (mr) m.style.borderRadius = mr; else m.style.removeProperty("border-radius"); }
      m.style.transform = `translate(calc(-50% + ${gx * S * 0.07}px), calc(-50% + ${gy * S * 0.05 - S * 0.02}px))${mt}`;
      rot += shake * 9;
      const fx = (2 - sy) * sx * lean, fy = sy * lean;
      const still = fx === 1 && fy === 1 && !ty && !rot;
      s.root.style.transform = still ? "" : `translateY(${ty * S}px) rotate(${rot}deg) scale(${fx}, ${fy})`;
    }

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
