// Core shapes: where each of the core's points sits. A state change morphs every point from the
// old shape to the new one. Shapes are fixed point clouds about 0.4 across; the renderer turns,
// breathes and pulses them.
const TAU = Math.PI * 2;
const PHI = (1 + Math.sqrt(5)) / 2;

/** Seeded random numbers, so a shape is the same on every launch. */
export function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function polyEdges(verts, length) {
  const segs = [];
  for (let i = 0; i < verts.length; i++)
    for (let j = i + 1; j < verts.length; j++) {
      const d = Math.hypot(verts[i][0] - verts[j][0], verts[i][1] - verts[j][1], verts[i][2] - verts[j][2]);
      if (Math.abs(d - length) < 1e-3) segs.push([verts[i], verts[j]]);
    }
  return segs;
}
const ICO = (() => {
  const v = [];
  for (const a of [-1, 1]) for (const b of [-1, 1]) v.push([0, a, b * PHI], [a, b * PHI, 0], [b * PHI, 0, a]);
  return v;
})();
const ICO_EDGES = polyEdges(ICO, 2);
const ICO_DIRS = ICO.map((p) => { const l = Math.hypot(...p); return p.map((x) => x / l); });
const OCTA = [[1, 0, 0], [-1, 0, 0], [0, 1.5, 0], [0, -1.5, 0], [0, 0, 1], [0, 0, -1]];
const OCTA_EDGES = [];
for (let i = 0; i < 6; i++) for (let j = i + 1; j < 6; j++) if (Math.floor(i / 2) !== Math.floor(j / 2)) OCTA_EDGES.push([OCTA[i], OCTA[j]]);
const CUBE = [];
for (const x of [-1, 1]) for (const y of [-1, 1]) for (const z of [-1, 1]) CUBE.push([x, y, z]);
const CUBE_EDGES = polyEdges(CUBE, 2);
const TESSERACT = [
  ...CUBE_EDGES,
  ...CUBE_EDGES.map(([a, b]) => [a.map((x) => x * 0.5), b.map((x) => x * 0.5)]),
  ...CUBE.map((p) => [p, p.map((x) => x * 0.5)]),
];

function along(out, i, segs, scale, r, jitter) {
  const [a, b] = segs[i % segs.length], t = r();
  for (let d = 0; d < 3; d++) out[i * 3 + d] = (a[d] + (b[d] - a[d]) * t) * scale + (r() - 0.5) * jitter;
}

const SHAPES = {
  orb(out, i, n, r) {
    const y = 1 - (2 * (i + 0.5)) / n, s = Math.sqrt(Math.max(0, 1 - y * y)), a = i * 2.39996;
    const rad = r() < 0.85 ? 0.36 + (r() - 0.5) * 0.02 : 0.08 + r() * 0.24;
    out[i * 3] = Math.cos(a) * s * rad;
    out[i * 3 + 1] = y * rad;
    out[i * 3 + 2] = Math.sin(a) * s * rad;
  },
  lattice(out, i, n, r) { along(out, i, ICO_EDGES, 0.24, r, 0.012); },
  crystal(out, i, n, r) {
    if (r() < 0.82) along(out, i, OCTA_EDGES, 0.3, r, 0.01);
    else { const k = r(), y = (r() - 0.5) * 0.7; out[i * 3] = (k - 0.5) * 0.12 * (1 - Math.abs(y) * 2); out[i * 3 + 1] = y; out[i * 3 + 2] = (r() - 0.5) * 0.12 * (1 - Math.abs(y) * 2); }
  },
  cube(out, i, n, r) { along(out, i, TESSERACT, 0.27, r, 0.01); },
  star(out, i, n, r) {
    const d = ICO_DIRS[i % ICO_DIRS.length], t = 0.05 + 0.44 * Math.pow(r(), 0.7), j = (1 - t / 0.5) * 0.05;
    for (let k = 0; k < 3; k++) out[i * 3 + k] = d[k] * t + (r() - 0.5) * j;
  },
  torus(out, i, n, r) {
    const a = r() * TAU, b = r() * TAU, R = 0.34, w = 0.085;
    out[i * 3] = (R + w * Math.cos(b)) * Math.cos(a);
    out[i * 3 + 1] = (R + w * Math.cos(b)) * Math.sin(a);
    out[i * 3 + 2] = w * Math.sin(b);
  },
  knot(out, i, n, r) {
    const s = r() * TAU, k = 0.13, j = 0.03;
    out[i * 3] = (2 + Math.cos(3 * s)) * Math.cos(2 * s) * k + (r() - 0.5) * j;
    out[i * 3 + 1] = (2 + Math.cos(3 * s)) * Math.sin(2 * s) * k + (r() - 0.5) * j;
    out[i * 3 + 2] = Math.sin(3 * s) * k + (r() - 0.5) * j;
  },
  galaxy(out, i, n, r) {
    if (r() < 0.15) {
      const a = r() * TAU, y = r() * 2 - 1, s = Math.sqrt(1 - y * y), rad = 0.07 * Math.cbrt(r());
      out[i * 3] = Math.cos(a) * s * rad; out[i * 3 + 1] = y * rad * 0.7; out[i * 3 + 2] = Math.sin(a) * s * rad;
      return;
    }
    const rr = 0.05 + 0.42 * Math.sqrt(r()), arm = i % 3;
    const a = (arm * TAU) / 3 + rr * 6 + ((r() - 0.5) * 0.5) / (0.3 + rr);
    out[i * 3] = Math.cos(a) * rr;
    out[i * 3 + 1] = (r() - 0.5) * 0.05 * (1 - rr * 1.5);
    out[i * 3 + 2] = Math.sin(a) * rr;
  },
  helix(out, i, n, r) {
    const strand = i % 3, h = 0.95, rad = 0.17;
    if (strand < 2) {
      const t = r(), a = t * TAU * 2 + strand * Math.PI;
      out[i * 3] = Math.cos(a) * rad; out[i * 3 + 1] = (t - 0.5) * h; out[i * 3 + 2] = Math.sin(a) * rad;
    } else {
      const t = Math.round(r() * 13) / 13, a = t * TAU * 2, s = r() * 2 - 1;
      out[i * 3] = Math.cos(a) * rad * s; out[i * 3 + 1] = (t - 0.5) * h; out[i * 3 + 2] = Math.sin(a) * rad * s;
    }
  },
  heart(out, i, n, r) {
    const t = r() * TAU, inside = r() < 0.35, f = inside ? Math.sqrt(r()) : 1, k = 0.021;
    const x = 16 * Math.sin(t) ** 3, y = 13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t);
    out[i * 3] = x * k * f + (r() - 0.5) * 0.01;
    out[i * 3 + 1] = y * k * f + 0.05;
    out[i * 3 + 2] = (r() - 0.5) * (inside ? 0.16 : 0.07);
  },
  scatter(out, i, n, r) {
    const a = r() * TAU, y = r() * 2 - 1, s = Math.sqrt(1 - y * y), rad = 0.25 + 0.6 * Math.cbrt(r());
    out[i * 3] = Math.cos(a) * s * rad; out[i * 3 + 1] = y * rad * 0.8; out[i * 3 + 2] = Math.sin(a) * s * rad;
  },
  spark(out, i, n, r) {
    const a = r() * TAU, y = r() * 2 - 1, s = Math.sqrt(1 - y * y), rad = 0.05 * Math.pow(r(), 1.5);
    out[i * 3] = Math.cos(a) * s * rad; out[i * 3 + 1] = y * rad; out[i * 3 + 2] = Math.sin(a) * s * rad;
  },
};

/** How each shape is turned: spin about y, a fixed tilt, a tumble about x, and a sway. */
export const MOTION = {
  orb: { spin: 0.25, tilt: 0, tumble: 0, sway: 0 },
  lattice: { spin: 0.7, tilt: 0.3, tumble: 0.35, sway: 0 },
  crystal: { spin: 0.9, tilt: 0, tumble: 0, sway: 0 },
  cube: { spin: 0.6, tilt: 0.5, tumble: 0.3, sway: 0 },
  star: { spin: 0.5, tilt: 0.2, tumble: 0.25, sway: 0 },
  torus: { spin: 0.4, tilt: -0.5, tumble: 0, sway: 0 },
  knot: { spin: 0.8, tilt: 0.2, tumble: 0.2, sway: 0 },
  galaxy: { spin: 0.5, tilt: 0.42, tumble: 0, sway: 0 },
  helix: { spin: 0.9, tilt: 0.1, tumble: 0, sway: 0 },
  heart: { spin: 0, tilt: 0, tumble: 0, sway: 0.55 },
  scatter: { spin: 0.08, tilt: 0, tumble: 0.05, sway: 0 },
  spark: { spin: 0.1, tilt: 0, tumble: 0, sway: 0 },
};

const cache = new Map();
/** The shape's points for `n` points: a cached array of n × 3 numbers. */
export function shape(name, n) {
  const key = name + ':' + n;
  if (!cache.has(key)) {
    const out = new Float32Array(n * 3), r = random(0x5e1e + name.length * 977 + n), make = SHAPES[name] || SHAPES.orb;
    for (let i = 0; i < n; i++) make(out, i, n, r);
    cache.set(key, out);
  }
  return cache.get(key);
}
