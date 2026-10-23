"use client";

// Cookie's face: a living amber orb with two eyes.
//
// The orb is our own shader — a sphere of slow, domain-warped fluid, lit from
// the upper left: diffuse light, a warm glow inside the lower rim, a fresnel
// edge and one specular point, so it reads as glass with something alive in
// it. Thinking speeds the fluid up; the change eases in, never snaps.
//
// The eyes are HTML over the orb, so they stay crisp at any size. They blink
// on an irregular clock (sometimes twice), look at what Cookie is looking at
// when told to, and otherwise follow the pointer at rest.
//
// Below LIVE_MIN px — or without WebGL — the orb is a still CSS sphere with
// the same eyes. A page should hold one or two live orbs, not dozens: each
// one is a WebGL context and browsers cap them.

import { useEffect, useRef, useState } from "react";
import s from "./CookieOrb.module.css";

export type Look = { x: number; y: number } | null;

const LIVE_MIN = 24;

const VERT = `attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }`;

const FRAG = `
precision highp float;
uniform vec2 u_res;
uniform float u_time;
uniform float u_energy;
uniform vec3 u_deep;
uniform vec3 u_mid;
uniform vec3 u_light;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
const mat2 R = mat2(0.8, 0.6, -0.6, 0.8);
float fbm(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++) { v += a * noise(p); p = R * p * 2.03; a *= 0.5; }
  return v;
}

void main() {
  vec2 uv = (gl_FragCoord.xy * 2.0 - u_res) / u_res.y;
  float r = length(uv);
  float z = sqrt(max(0.0, 1.0 - r * r));
  vec3 n = normalize(vec3(uv, z));

  // Fluid on the sphere: coordinates stretch toward the rim, so it curves.
  vec2 p = uv / (0.45 + 0.55 * z) * 1.25;
  float t = u_time;
  vec2 q = vec2(fbm(p + vec2(0.0, t * 0.9)), fbm(p + vec2(5.2, 1.3) - t * 0.7));
  vec2 w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2) + t * 0.5), fbm(p + 3.0 * q + vec2(8.3, 2.8) - t * 0.4));
  float f = fbm(p + 2.4 * w);

  // Light at the top, deep amber settling at the bottom, the fluid between.
  float h = clamp(0.48 - uv.y * 0.42 + (f - 0.5) * (0.85 + 0.25 * u_energy), 0.0, 1.0);
  vec3 col = mix(u_light, u_mid, smoothstep(0.18, 0.55, h));
  col = mix(col, u_deep, smoothstep(0.55, 0.98, h));

  vec3 L = normalize(vec3(-0.45, 0.62, 0.64));
  col *= 0.8 + 0.3 * clamp(dot(n, L), 0.0, 1.0);
  // Warm light caught inside the lower rim.
  col += u_mid * 0.35 * pow(1.0 - z, 1.6) * smoothstep(0.3, -0.9, uv.y);
  // The glass edge and the one bright point.
  col += vec3(1.0, 0.93, 0.84) * pow(1.0 - z, 3.0) * 0.32;
  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
  col += pow(clamp(dot(n, H), 0.0, 1.0), 70.0) * 0.6;

  float px = 2.0 / u_res.y;
  float a = 1.0 - smoothstep(1.0 - 1.5 * px, 1.0, r);
  gl_FragColor = vec4(min(col, 1.0) * a, a);
}
`;

const DEEP: [number, number, number] = [0.74, 0.33, 0.08];
const MID: [number, number, number] = [0.93, 0.56, 0.24];
const LIGHT: [number, number, number] = [1.0, 0.96, 0.9];

function useLiveOrb(canvas: React.RefObject<HTMLCanvasElement | null>, size: number, live: boolean, energy: number, onLost: () => void) {
  const target = useRef(energy);
  target.current = energy;
  useEffect(() => {
    const cv = canvas.current;
    if (!live || !cv) return;
    const gl = cv.getContext("webgl", { alpha: true, antialias: true, premultipliedAlpha: true });
    if (!gl) return onLost();
    const sh = (type: number, src: string) => {
      const x = gl.createShader(type)!;
      gl.shaderSource(x, src);
      gl.compileShader(x);
      return gl.getShaderParameter(x, gl.COMPILE_STATUS) ? x : null;
    };
    const vs = sh(gl.VERTEX_SHADER, VERT);
    const fs = sh(gl.FRAGMENT_SHADER, FRAG);
    const prog = gl.createProgram();
    if (!vs || !fs || !prog) return onLost();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return onLost();
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
    const at = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(at);
    gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
    const u = (n: string) => gl.getUniformLocation(prog, n);
    gl.uniform3f(u("u_deep"), ...DEEP);
    gl.uniform3f(u("u_mid"), ...MID);
    gl.uniform3f(u("u_light"), ...LIGHT);
    const px = Math.round(size * Math.min(window.devicePixelRatio || 1, 2));
    cv.width = px;
    cv.height = px;
    gl.viewport(0, 0, px, px);
    gl.uniform2f(u("u_res"), px, px);
    const uTime = u("u_time");
    const uEnergy = u("u_energy");

    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let visible = true;
    const io = new IntersectionObserver(([e]) => (visible = e.isIntersecting));
    io.observe(cv);
    const lost = (e: Event) => {
      e.preventDefault();
      onLost();
    };
    cv.addEventListener("webglcontextlost", lost);

    // The fluid's clock runs faster while thinking; energy eases toward its target.
    let e = target.current;
    let clock = 3.7;
    let last = performance.now();
    let raf = 0;
    const draw = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      e += (target.current - e) * Math.min(1, dt * 2.5);
      clock += dt * (0.1 + 0.32 * e);
      if (visible) {
        gl.uniform1f(uTime, clock);
        gl.uniform1f(uEnergy, e);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      }
      if (!still) raf = requestAnimationFrame(draw);
    };
    draw(last);
    return () => {
      cancelAnimationFrame(raf);
      io.disconnect();
      cv.removeEventListener("webglcontextlost", lost);
      gl.deleteBuffer(buf);
      gl.deleteProgram(prog);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
    };
  }, [canvas, size, live, onLost]);
}

/** Blinks on an irregular clock: every 2.4–6 s, now and then twice. */
function useBlink(): boolean {
  const [shut, setShut] = useState(false);
  useEffect(() => {
    let id: ReturnType<typeof setTimeout>;
    const once = (then: () => void) => {
      setShut(true);
      id = setTimeout(() => {
        setShut(false);
        then();
      }, 110);
    };
    const next = () => {
      id = setTimeout(() => once(() => (Math.random() < 0.22 ? (id = setTimeout(() => once(next), 160)) : next())), 2400 + Math.random() * 3600);
    };
    next();
    return () => clearTimeout(id);
  }, []);
  return shut;
}

/** Where the pointer is, relative to an element, as a vector of length ≤ 1. */
function usePointerLook(el: React.RefObject<HTMLElement | null>, on: boolean): Look {
  const [look, setLook] = useState<Look>(null);
  useEffect(() => {
    if (!on || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let raf = 0;
    const move = (ev: PointerEvent) => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const r = el.current?.getBoundingClientRect();
        if (!r) return;
        const dx = ev.clientX - (r.left + r.width / 2);
        const dy = ev.clientY - (r.top + r.height / 2);
        const d = Math.hypot(dx, dy);
        const k = Math.min(1, d / 360) / (d || 1);
        setLook({ x: dx * k, y: dy * k });
      });
    };
    window.addEventListener("pointermove", move);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("pointermove", move);
    };
  }, [el, on]);
  return look;
}

export function CookieOrb({
  size = 32,
  thinking = false,
  look = null,
  follow = false,
  className,
  style,
}: {
  size?: number;
  /** The fluid quickens and the eyes wander upward, as if working something out. */
  thinking?: boolean;
  /** Where to look (a vector, length ≤ 1). Wins over `follow`. */
  look?: Look;
  /** Follow the pointer when nothing else is being looked at. */
  follow?: boolean;
  className?: string;
  style?: React.CSSProperties;
}) {
  const root = useRef<HTMLSpanElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [glOk, setGlOk] = useState(true);
  const live = glOk && size >= LIVE_MIN;
  const onLost = useRef(() => setGlOk(false)).current;
  useLiveOrb(canvas, size, live, thinking ? 1 : 0, onLost);
  const shut = useBlink();
  const pointer = usePointerLook(root, follow && !look && !thinking);

  // Thinking: the eyes drift between a few points up and to the side.
  const [wander, setWander] = useState<Look>(null);
  useEffect(() => {
    if (!thinking || look) return setWander(null);
    const spots = [{ x: 0.55, y: -0.7 }, { x: -0.35, y: -0.75 }, { x: 0.15, y: -0.9 }, { x: 0.7, y: -0.35 }];
    let i = 0;
    setWander(spots[0]);
    const id = setInterval(() => setWander(spots[(i = (i + 1) % spots.length)]), 1400);
    return () => clearInterval(id);
  }, [thinking, look]);

  const gaze = look ?? wander ?? pointer ?? { x: 0, y: 0 };
  const eye = { w: Math.max(1.6, size * 0.095), h: Math.max(3, size * 0.235) };
  return (
    <span
      ref={root}
      className={`${s.orb} ${className ?? ""}`}
      data-live={live ? "true" : undefined}
      data-thinking={thinking ? "true" : undefined}
      style={{ width: size, height: size, ...style }}
      aria-hidden
    >
      {live && <canvas ref={canvas} className={s.gl} />}
      <span
        className={s.eyes}
        style={{
          gap: size * 0.15,
          transform: `translate(${gaze.x * size * 0.1}px, ${gaze.y * size * 0.08 - size * 0.035}px)`,
        }}
      >
        {[0, 1].map((k) => (
          <i
            key={k}
            style={{
              width: eye.w,
              height: eye.h,
              transform: shut ? "scaleY(0.1)" : thinking ? "scaleY(0.86)" : undefined,
            }}
          />
        ))}
      </span>
    </span>
  );
}
