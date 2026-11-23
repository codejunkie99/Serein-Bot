// Ring formations: where each ring sits, how it is turned and how big it is, for ring k of n at
// time c.t. Each state of a look picks one, so a state changes the hologram's shape, not only its
// color. `facing` formations face the viewer instead of turning with the rig; `elev` and `dist`
// frame the camera for them; `spin` is how fast the rig turns.
import * as THREE from 'three';

const Z = new THREE.Vector3(0, 0, 1);
const Y = new THREE.Vector3(0, 1, 0);
const X = new THREE.Vector3(1, 0, 0);
const _q = new THREE.Quaternion();
const _v = new THREE.Vector3();
const _w = new THREE.Vector3();
const TAU = Math.PI * 2;
// The Serein logo is five circles tilted 62.3° (cos = 121.9 / 262), 72° apart: head-on they
// are its five ellipses.
const TILT = Math.acos(121.9 / 262);
const u = (k, n) => (n > 1 ? k / (n - 1) : 0);
const face = (o, x, y, z) => o.q.setFromUnitVectors(Z, _v.set(x, y, z).normalize());

export const FORMATIONS = {
  // Idle: the Serein logo, turning slowly so its depth shows.
  logo: {
    facing: false, elev: 0.16, dist: 1, spin: 0.25,
    place(o, k, n, c) {
      o.q.setFromAxisAngle(Z, (18 * Math.PI) / 180 + (k * TAU) / n);
      o.q.multiply(_q.setFromAxisAngle(Y, TILT));
      o.q.multiply(_q.setFromAxisAngle(Z, c.t * 0.15 * (k % 2 ? 1 : -1)));
      o.p.set(0, 0, 0);
      o.R = 1;
      o.arc = 1;
      o.hl = 0;
    },
  },
  // Listening: a dish of rings turned toward you; your voice ripples in from the rim.
  dish: {
    facing: true, elev: 0.08, dist: 1, spin: 0,
    place(o, k, n, c) {
      const f = u(k, n), wave = Math.sin(c.t * 9 - (n - 1 - k) * 1.5);
      o.q.setFromAxisAngle(X, -0.34 + 0.05 * Math.sin(c.t * 0.7));
      o.q.premultiply(_q.setFromAxisAngle(Y, 0.2 * Math.sin(c.t * 0.45)));
      o.p.set(0, 0, -0.4 + 0.55 * f * f).applyQuaternion(o.q);
      o.q.multiply(_q.setFromAxisAngle(Z, c.t * 0.3 * (k % 2 ? 1 : -1)));
      o.R = (0.26 + 0.86 * f) * (1 + (0.025 + c.level * 0.16) * wave);
      o.arc = 1;
      o.hl = c.level * (0.55 + 0.45 * wave);
    },
  },
  // Thinking: a gyroscope; every ring spins on its own axis at its own pace.
  gyro: {
    facing: false, elev: 0.2, dist: 1, spin: 0.35,
    place(o, k, n, c) {
      const y = 1 - (2 * (k + 0.5)) / n, r = Math.sqrt(Math.max(0, 1 - y * y)), a = k * 2.39996;
      face(o, Math.cos(a) * r, y, Math.sin(a) * r);
      _w.set(Math.sin(a * 1.7 + 0.3), Math.cos(a * 0.9), Math.sin(a * 0.3 + 1)).normalize();
      o.q.premultiply(_q.setFromAxisAngle(_w, c.t * (1.3 + 0.3 * k) * (k % 2 ? -1 : 1)));
      o.p.set(0, 0, 0);
      o.R = 0.6 + 0.24 * u(k, n);
      o.arc = 1;
      o.hl = 0;
    },
  },
  // Speaking: rings stand side by side like the bars of a voice meter and leap with each word.
  waveform: {
    facing: true, elev: 0.04, dist: 1, spin: 0,
    place(o, k, n, c) {
      const mid = (n - 1) / 2, bell = Math.exp(-(((k - mid) / (n * 0.3)) ** 2));
      const jit = 0.5 + 0.5 * Math.sin(c.t * 13 + k * 2.3) * Math.sin(c.t * 5.1 + k * 0.7);
      o.q.setFromAxisAngle(Y, 1.3 + 0.05 * Math.sin(c.t * 0.8 + k));
      o.p.set((k - mid) * 0.32 * Math.sqrt(5 / Math.max(n, 3)), 0, 0);
      o.R = 0.14 + (0.06 + (0.25 + 0.7 * c.env) * bell * (0.35 + 0.65 * jit)) + c.word * 0.32 * bell;
      o.arc = 1;
      o.hl = (c.env * 0.7 + c.word) * bell;
    },
  },
  // Working: an orrery; jobs ride the orbits as satellites.
  orbit: {
    facing: false, elev: 0.5, dist: 1.06, spin: 0.1,
    place(o, k, n, c) {
      const f = u(k, n), node = k * 1.3 + c.t * 0.12 * (1 + f);
      o.q.setFromUnitVectors(Z, Y);
      o.q.premultiply(_q.setFromAxisAngle(_v.set(Math.cos(node), 0, Math.sin(node)), (0.16 + 0.12 * f) * (k % 2 ? -1 : 1)));
      o.q.multiply(_q.setFromAxisAngle(Z, c.t * 0.4));
      o.p.set(0, 0, 0);
      o.R = 0.5 + 0.85 * f;
      o.arc = 1;
      o.hl = 0;
    },
  },
  // Needs you: a lantern of meridians around an equator, beating like a heart.
  lantern: {
    facing: false, elev: 0.18, dist: 1, spin: 0.5,
    place(o, k, n, c) {
      if (k === 0) o.q.setFromUnitVectors(Z, Y);
      else {
        const a = (Math.PI * (k - 1)) / Math.max(1, n - 1);
        face(o, Math.cos(a), 0, Math.sin(a));
      }
      o.p.set(0, 0, 0);
      o.R = (k === 0 ? 0.86 : 0.8) * (1 + 0.05 * c.beat);
      o.arc = 1;
      o.hl = c.beat * 0.6;
    },
  },
  // Error: the logo broken into arcs that drift apart and jolt.
  shatter: {
    facing: false, elev: 0.16, dist: 1.08, spin: 0.06,
    place(o, k, n, c) {
      o.q.setFromAxisAngle(Z, 0.3 + (k * TAU) / n);
      o.q.multiply(_q.setFromAxisAngle(Y, TILT + 0.5 * Math.sin(k * 2.7)));
      o.q.premultiply(_q.setFromAxisAngle(X, 0.4 * Math.sin(k * 1.9 + 1)));
      o.q.multiply(_q.setFromAxisAngle(Z, k * 1.3 + c.t * 0.1));
      const drift = 0.22 + 0.06 * Math.sin(c.t * 0.9 + k * 1.3) + c.jolt * 0.08 * Math.sin(k * 7.1 + 1);
      o.p.set(Math.sin(k * 2.1 + 0.5), Math.cos(k * 1.7 + 0.2) * 0.8, Math.sin(k * 3.3 + 1.1) * 0.6).normalize().multiplyScalar(drift);
      o.R = 0.92;
      o.arc = 0.42 + (0.18 * ((k * 37) % 5)) / 4;
      o.hl = c.jolt * 0.7;
    },
  },
  // Asleep: every ring settles into one dim horizon.
  horizon: {
    facing: false, elev: 0.3, dist: 1, spin: 0.04,
    place(o, k, n, c) {
      o.q.setFromUnitVectors(Z, Y);
      o.q.multiply(_q.setFromAxisAngle(Z, c.t * 0.05 * (k % 2 ? 1 : -1)));
      o.p.set(0, -0.12 + k * 0.012, 0);
      o.R = 1 + k * 0.04;
      o.arc = 1;
      o.hl = 0;
    },
  },
  // A reticle of nested gimbals facing you.
  halo: {
    facing: true, elev: 0.05, dist: 1, spin: 0,
    place(o, k, n, c) {
      o.q.setFromAxisAngle(X, 0.32 * Math.sin(c.t * 0.5 + k * 0.9));
      o.q.premultiply(_q.setFromAxisAngle(Y, 0.32 * Math.cos(c.t * 0.42 + k * 1.3)));
      o.q.multiply(_q.setFromAxisAngle(Z, c.t * (0.25 + 0.1 * k) * (k % 2 ? 1 : -1)));
      o.p.set(0, 0, 0);
      o.R = 0.3 + 0.75 * u(k, n);
      o.arc = 1;
      o.hl = 0;
    },
  },
  // Rings threaded on a turning spiral.
  helix: {
    facing: false, elev: 0.12, dist: 1.06, spin: 0.3,
    place(o, k, n, c) {
      const a = k * 1.2 + c.t * 0.9;
      o.p.set(0.3 * Math.cos(a), (k - (n - 1) / 2) * (1.5 / Math.max(n - 1, 1)), 0.3 * Math.sin(a));
      face(o, -Math.sin(a) * 0.8, 0.45, Math.cos(a) * 0.8);
      o.R = 0.42;
      o.arc = 1;
      o.hl = 0;
    },
  },
  // Petals opening around the core.
  crown: {
    facing: false, elev: 0.34, dist: 1, spin: 0.28,
    place(o, k, n, c) {
      const b = (k * TAU) / n, tilt = 0.95 + 0.1 * Math.sin(c.t * 0.8 + k * 1.1);
      o.p.set(0.4 * Math.cos(b), 0.05 + 0.04 * Math.sin(c.t * 1.2 + k), 0.4 * Math.sin(b));
      face(o, Math.cos(b) * Math.sin(tilt), Math.cos(tilt), Math.sin(b) * Math.sin(tilt));
      o.R = 0.5;
      o.arc = 1;
      o.hl = 0;
    },
  },
  // A stack of halos breathing in turn.
  tower: {
    facing: false, elev: 0.34, dist: 1.05, spin: 0.2,
    place(o, k, n, c) {
      o.q.setFromUnitVectors(Z, Y);
      o.q.multiply(_q.setFromAxisAngle(Z, c.t * 0.3 * (k % 2 ? 1 : -1)));
      o.p.set(0, (k - (n - 1) / 2) * (1.3 / Math.max(n - 1, 1)), 0);
      o.R = 0.5 + 0.14 * Math.sin(c.t * 1.6 + k * 0.9) + c.level * 0.3 * Math.sin(c.t * 8 - k);
      o.arc = 1;
      o.hl = 0;
    },
  },
};
