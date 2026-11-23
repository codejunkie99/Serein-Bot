// Relay's look: what the hologram is made of and how each state appears. Serein validates every
// look in Swift (SereinCore/RelayLook.swift) before it reaches this page; this normalizer only
// keeps the renderer safe if a field is missing or out of range.
import PRESETS from './presets.json';

export { PRESETS };
export const STATES = ['idle', 'listening', 'thinking', 'speaking', 'working', 'alert', 'error', 'dormant', 'done'];
export const FORMATIONS = ['logo', 'dish', 'gyro', 'waveform', 'orbit', 'lantern', 'shatter', 'horizon', 'halo', 'helix', 'crown', 'tower'];
export const CORES = ['orb', 'lattice', 'crystal', 'cube', 'star', 'torus', 'knot', 'galaxy', 'helix', 'heart', 'scatter', 'spark'];
export const STYLES = ['solid', 'dashed', 'dotted', 'double'];
export const EFFECTS = ['bloom', 'scanlines', 'grain', 'glitch', 'aberration'];
export const DEFAULT = PRESETS[0];

const num = (v, lo, hi, d) => (typeof v === 'number' && Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : d);
const hex = (v) => (typeof v === 'string' && /^#[0-9a-f]{6}$/i.test(v) ? v.toLowerCase() : null);
const oneOf = (v, list, d) => (list.includes(v) ? v : d);
const obj = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? v : {});

/** A complete look with every state resolved: colors, formation, core, speed and glow. */
export function normalize(look) {
  const L = obj(look), D = DEFAULT;
  const pal = obj(L.palette), rings = obj(L.rings), core = obj(L.core), fx = obj(L.effects), S = obj(L.states);
  const primary = hex(pal.primary) || D.palette.primary, rim = hex(pal.rim) || D.palette.rim;
  const shape = oneOf(core.shape, CORES, D.core.shape);
  const out = {
    name: typeof L.name === 'string' && L.name.trim() ? L.name.trim().slice(0, 40) : D.name,
    palette: { primary, rim },
    rings: {
      count: Math.round(num(rings.count, 3, 8, D.rings.count)),
      thickness: num(rings.thickness, 0.006, 0.05, D.rings.thickness),
      style: oneOf(rings.style, STYLES, D.rings.style),
    },
    core: { shape, size: num(core.size, 0.5, 1.6, D.core.size), density: num(core.density, 0.25, 1, D.core.density) },
    effects: {},
    motion: num(L.motion, 0.25, 2, D.motion),
    states: {},
  };
  for (const k of EFFECTS) out.effects[k] = num(fx[k], 0, 1, D.effects[k]);
  for (const s of STATES) {
    const v = obj(S[s]), d = obj(D.states[s]);
    out.states[s] = {
      formation: oneOf(v.formation, FORMATIONS, d.formation || 'logo'),
      core: oneOf(v.core, CORES, shape),
      primary: hex(v.primary) || primary,
      rim: hex(v.rim) || rim,
      speed: num(v.speed, 0.25, 3, 1),
      glow: num(v.glow, 0.3, 1.6, s === 'dormant' ? 0.5 : 1),
    };
  }
  return out;
}
