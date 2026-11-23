// Relay's hologram: rings in a formation around a core of points, and nothing else: the page is
// transparent, so the light floats over whatever is behind the view.
// Each state of the look names a formation and a core shape, so a state change rebuilds the
// hologram's shape with a staggered morph. It reacts to the voice level, spoken words and the
// jobs Relay runs, bursts when work is done and fractures on errors. The page talks to nothing
// but its host: no network, no storage.
import * as THREE from 'three';
import { FullScreenQuad } from 'three/addons/postprocessing/Pass.js';
import { FORMATIONS } from './formations.js';
import { shape, MOTION, random } from './cores.js';
import { normalize, STATES } from './look.js';

const TAU = Math.PI * 2;
const ease = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
const smooth = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t); };
const CALM = new Set(['idle', 'dormant']);
const POINTS = 1400;
// Frames a second for each steady state: voice states follow speech closely, quiet ones barely move.
const STEADY_FPS = { idle: 20, listening: 20, thinking: 20, speaking: 24, working: 20, alert: 20, error: 20, dormant: 8 };
// After this many quiet seconds a state settles to fewer frames; 0 frames means it eases to a stop
// and holds still until something happens (a new state, a job, a word, the pointer).
const SETTLE = { idle: [15, 0], dormant: [5, 0], working: [30, 8], thinking: [30, 10], alert: [30, 12], error: [15, 0], listening: [1e9, 24], speaking: [1e9, 24] };
const EASE_OUT = 1.5;
const MAX_JOBS = 8;
const TRAIL = 22;

// All rings in one instanced draw: each ring's turn and place is its instance matrix, its radius,
// drawn arc, highlight and comet position are instance attributes.
const RING_VS = `attribute float iR;attribute float iArc;attribute float iHl;attribute float iHead;uniform float r;uniform float rScale;
varying vec3 vN;varying vec3 vV;varying vec3 vW;varying vec2 vUv;varying vec3 vI;
void main(){vUv=uv;vI=vec3(iArc,iHl,iHead);float a=uv.x*6.28318530718,b=uv.y*6.28318530718,R=iR*rScale;
vec3 n=vec3(cos(b)*cos(a),cos(b)*sin(a),sin(b));vec3 p=vec3((R+r*cos(b))*cos(a),(R+r*cos(b))*sin(a),r*sin(b));
vec4 w=modelMatrix*instanceMatrix*vec4(p,1.0);vW=w.xyz;vec4 mv=viewMatrix*w;vV=-mv.xyz;
vN=normalize(mat3(viewMatrix)*mat3(modelMatrix)*mat3(instanceMatrix)*n);gl_Position=projectionMatrix*mv;}`;
const RING_FS = `uniform float time;uniform float gain;uniform float reveal;uniform vec3 col;uniform vec3 rim;
uniform float dashes;uniform float duty;uniform float comet;uniform float flow;uniform float alpha;
varying vec3 vN;varying vec3 vV;varying vec3 vW;varying vec2 vUv;varying vec3 vI;
void main(){float arc=vI.x,hl=vI.y,head=vI.z;float f=pow(1.0-abs(dot(normalize(vN),normalize(vV))),2.0);float x=vUv.x;
float drawn=arc>0.995?1.0:smoothstep(0.0,0.02,x)*(1.0-smoothstep(arc-0.02,arc,x));
float d=dashes>0.5?step(fract(x*dashes),duty):1.0;float s=fract(head-x);float cm=comet*(exp(-s*s*2600.0)*1.4+0.5*exp(-s*16.0));
float scan=0.88+0.12*sin(vW.y*90.0-time*4.0);float fl=flow*(0.5+0.5*sin(x*62.83-time*7.0));
float a=(0.1+f*0.62+fl*0.35+cm)*scan*(1.0+hl)*d*drawn;float vis=1.0-smoothstep(reveal-0.03,reveal+0.03,vW.y);
float edge=exp(-pow((vW.y-reveal)*26.0,2.0))*drawn;a=a*vis+edge*0.8;vec3 c=mix(col,rim,clamp(f+cm+hl*0.5+edge,0.0,1.0));
gl_FragColor=vec4(c,clamp(a*gain*alpha,0.0,1.0));}`;
const POINT_VS = `attribute float seed;uniform float size;uniform float time;uniform float scale;uniform float boost;varying float vB;varying float vY;
void main(){vec4 w=modelMatrix*vec4(position,1.0);vY=w.y;vec4 mv=viewMatrix*w;gl_Position=projectionMatrix*mv;
float tw=0.55+0.45*sin(time*(1.3+seed*3.0)+seed*40.0);vB=(0.35+0.65*fract(seed*7.13))*tw*(1.0+boost);
gl_PointSize=max(1.6,size*scale*(0.6+0.8*fract(seed*3.7))/max(0.5,-mv.z));}`;
const POINT_FS = `uniform vec3 col;uniform vec3 rim;uniform float gain;uniform float reveal;varying float vB;varying float vY;
void main(){vec2 q=gl_PointCoord-0.5;float d=dot(q,q);if(d>0.25)discard;float a=exp(-d*16.0)*vB;
float vis=1.0-smoothstep(reveal-0.03,reveal+0.03,vY);vec3 c=mix(col,rim,clamp(vB*0.8,0.0,1.0));gl_FragColor=vec4(c,clamp(a*gain*vis,0.0,1.0));}`;
// The glow in five small passes (a dual Kawase filter): the scene's bright parts at a half, a
// quarter and an eighth of the size, then back up, each level adding the one beside it, so the
// glow is tight near the light and wide and smooth further out.
const QUAD_VS = 'varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}';
const DOWN_FS = `uniform sampler2D t;uniform vec2 texel;uniform float threshold;varying vec2 vUv;
void main(){vec3 c=texture2D(t,vUv).rgb*4.0+texture2D(t,vUv+texel*vec2(-1.0,-1.0)).rgb+texture2D(t,vUv+texel*vec2(1.0,-1.0)).rgb
+texture2D(t,vUv+texel*vec2(-1.0,1.0)).rgb+texture2D(t,vUv+texel*vec2(1.0,1.0)).rgb;c*=0.125;
if(threshold>0.0)c*=smoothstep(threshold,threshold+0.1,max(c.r,max(c.g,c.b)));gl_FragColor=vec4(c,1.0);}`;
const UP_FS = `uniform sampler2D t;uniform sampler2D add;uniform vec2 texel;varying vec2 vUv;
void main(){vec3 c=texture2D(t,vUv+texel*vec2(-2.0,0.0)).rgb+texture2D(t,vUv+texel*vec2(2.0,0.0)).rgb+texture2D(t,vUv+texel*vec2(0.0,-2.0)).rgb
+texture2D(t,vUv+texel*vec2(0.0,2.0)).rgb+(texture2D(t,vUv+texel*vec2(-1.0,1.0)).rgb+texture2D(t,vUv+texel*vec2(1.0,1.0)).rgb
+texture2D(t,vUv+texel*vec2(-1.0,-1.0)).rgb+texture2D(t,vUv+texel*vec2(1.0,-1.0)).rgb)*2.0;gl_FragColor=vec4(c/12.0+texture2D(add,vUv).rgb,1.0);}`;
// Last pass: glow added, ACES tone mapping and sRGB, then chromatic fringe, scanlines, grain,
// vignette and glitch rows. On a transparent page the light itself becomes the alpha, so the
// hologram floats over whatever is behind the view; in light appearance it becomes colored ink.
// Light added to a white page shows nothing, so the light keeps some coverage of its own (`edge`)
// wherever the glow is lit: a bright backdrop darkens under it, and a dark one changes little.
const FINAL_FS = `uniform sampler2D tScene;uniform sampler2D tG;uniform float strength;uniform float exposure;
uniform float time;uniform float amount;uniform float glitch;uniform float scan;uniform float grain;uniform float vig;uniform float opaque;
uniform float ink;uniform float cover;uniform float edge;uniform vec3 bg;uniform vec2 res;uniform vec2 c0;uniform float rad;uniform float aspect;varying vec2 vUv;
float hash(vec2 p){return fract(sin(dot(p,vec2(12.9898,78.233)))*43758.5453);}
vec3 rrt(vec3 v){vec3 a=v*(v+0.0245786)-0.000090537;vec3 b=v*(0.983729*v+0.4329510)+0.238081;return a/b;}
vec3 aces(vec3 c){const mat3 I=mat3(vec3(0.59719,0.07600,0.02840),vec3(0.35458,0.90834,0.13383),vec3(0.04823,0.01566,0.83777));
const mat3 O=mat3(vec3(1.60475,-0.10208,-0.00327),vec3(-0.53108,1.10813,-0.07276),vec3(-0.07367,-0.00605,1.07602));
return clamp(O*rrt(I*(c*exposure/0.6)),0.0,1.0);}
vec3 srgb(vec3 c){return mix(c*12.92,1.055*pow(c,vec3(0.4166667))-0.055,step(vec3(0.0031308),c));}
vec3 light(vec2 uv){return srgb(aces(texture2D(tScene,uv).rgb+strength*texture2D(tG,uv).rgb));}
void main(){vec2 uv=vUv;float row=floor(uv.y*60.0);float g=step(0.965,hash(vec2(row,floor(time*24.0))))*glitch;
uv.x+=g*(hash(vec2(time,row))-0.5)*0.045;vec2 d=uv-0.5;float r2=dot(d,d);vec2 off=d*amount*(0.002+r2*0.012);
vec3 b=light(uv);vec3 c=amount>0.001?vec3(light(uv+off).r,b.g,light(uv-off).b):b;
c*=1.0-scan*0.1*(0.5+0.5*sin(gl_FragCoord.y*1.5708));float lit=smoothstep(0.0,0.04,max(c.r,max(c.g,c.b)));
c+=(hash(uv*res+fract(time*7.0))-0.5)*grain*0.05*lit;c*=mix(1.0,smoothstep(0.98,0.32,length(d)),vig);
float near=1.0-smoothstep(rad*0.85,rad*1.55,length(vec2((vUv.x-c0.x)*aspect,vUv.y-c0.y)));
float fade=smoothstep(0.0,0.05,min(vUv.x,1.0-vUv.x))*smoothstep(0.0,0.08,min(vUv.y,1.0-vUv.y));
c=max(c-0.003,0.0)*mix(near*fade,1.0,opaque);float a=clamp(max(c.r,max(c.g,c.b)),0.0,1.0);
vec3 deep=min(mix(vec3(dot(c,vec3(0.299,0.587,0.114))),c,1.6)*0.62,vec3(a));c=mix(c,max(deep,0.0),ink);
a=max(a*mix(cover,1.0,max(ink,opaque)),edge*smoothstep(0.03,0.25,a)*(1.0-ink)*(1.0-opaque));
gl_FragColor=opaque>0.5?vec4(c+bg*(1.0-a),1.0):vec4(c,a);}`;

function glowTexture() {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d'), gr = g.createRadialGradient(64, 64, 0, 64, 64, 64);
  gr.addColorStop(0, 'rgba(255,255,255,1)');
  gr.addColorStop(0.22, 'rgba(255,255,255,.35)');
  gr.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = gr;
  g.fillRect(0, 0, 128, 128);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}
const additive = { transparent: true, blending: THREE.AdditiveBlending, depthWrite: false };
// The rings' bright outlines and dashes and the jobs' trails, all in one line buffer.
const LINE = 96;
const DASH = 40;
const COS = Float32Array.from({ length: LINE + 1 }, (_, i) => Math.cos((i / LINE) * TAU));
const SIN = Float32Array.from({ length: LINE + 1 }, (_, i) => Math.sin((i / LINE) * TAU));
function pose() { return { q: new THREE.Quaternion(), p: new THREE.Vector3(), R: 1, arc: 1, hl: 0 }; }

export class Avatar {
  constructor(host, options = {}) {
    this.host = host;
    this.o = Object.assign({ transparent: true, background: '#02040b', quality: 'high', interactive: true, still: false, active: true }, options);
    this.emit = typeof options.onEvent === 'function' ? options.onEvent : () => {};
    this.reduced = typeof options.reducedMotion === 'boolean' ? options.reducedMotion : matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.low = this.o.quality === 'low';
    this.active = this.o.active !== false;
    // On a light background the light is drawn as colored ink, so it still reads.
    this.theme = this.o.theme === 'light' ? 'light' : 'dark';
    // The scene is antialiased in its own target; the canvas only receives the final pass, so it
    // needs no antialiasing of its own (that would be resolved again every frame for nothing).
    const renderer = new THREE.WebGLRenderer({ antialias: false, alpha: true, premultipliedAlpha: true, powerPreference: 'low-power' });
    this.renderer = renderer;
    renderer.setPixelRatio(this.o.pixelRatio > 0 ? this.o.pixelRatio : Math.min(this.low ? 1 : 2, window.devicePixelRatio || 1));
    renderer.setClearColor(0x000000, 0);
    // Draw calls are counted over a whole frame (scene and glow passes), for checks.
    renderer.info.autoReset = false;
    renderer.domElement.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block';
    host.appendChild(renderer.domElement);

    this.scene = new THREE.Scene();
    this.camera = new THREE.PerspectiveCamera(34, 16 / 9, 0.1, 80);
    const target = (samples) => new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples, depthBuffer: samples > 0 });
    this.rt = { scene: target(this.low ? 0 : 4), d1: target(0), d2: target(0), d3: target(0), u2: target(0), u1: target(0) };
    const pass = (fragmentShader, uniforms) => new THREE.ShaderMaterial({ uniforms, vertexShader: QUAD_VS, fragmentShader, depthTest: false, depthWrite: false, blending: THREE.NoBlending });
    this.down = pass(DOWN_FS, { t: { value: null }, texel: { value: new THREE.Vector2() }, threshold: { value: 0 } });
    this.up = pass(UP_FS, { t: { value: null }, add: { value: null }, texel: { value: new THREE.Vector2() } });
    this.fx = pass(FINAL_FS, {
      tScene: { value: this.rt.scene.texture }, tG: { value: this.rt.u1.texture },
      strength: { value: 0.5 }, exposure: { value: 0.85 },
      time: { value: 0 }, amount: { value: 1 }, glitch: { value: 0 }, scan: { value: 0.5 }, grain: { value: 0.3 },
      vig: { value: 0.5 }, opaque: { value: this.o.transparent ? 0 : 1 }, bg: { value: new THREE.Color(this.o.background) }, res: { value: new THREE.Vector2(640, 360) },
      c0: { value: new THREE.Vector2(0.5, 0.5) }, rad: { value: 0.45 }, aspect: { value: 16 / 9 }, ink: { value: this.o.theme === 'light' ? 1 : 0 },
      // Light adds to what is behind it: little coverage (premultiplied color above its alpha
      // composites as added light). `edge` is the least coverage wherever the glow is lit, so the
      // light stays visible over a bright page. A mid-tone backdrop darkens under the glow too.
      cover: { value: 0.3 }, edge: { value: 0.4 },
    });
    this.quad = new FullScreenQuad(this.fx);

    this.U = { time: { value: 0 }, gain: { value: 1 }, reveal: { value: -3 }, col: { value: new THREE.Color() }, rim: { value: new THREE.Color() } };
    this.comet = { value: 0.6 };
    this.flow = { value: 0 };
    this.unit = new THREE.Vector3(1, 1, 1);
    this.GT = glowTexture();
    this.rig = new THREE.Group();
    this.scene.add(this.rig);
    this.rings = [];
    this.buildStatic();

    // Time, state and reactions.
    this.T = 0;
    this.ft = 0;
    this.bootT = 0;
    this.spinAcc = 0;
    this.yaw = 0;
    this.pitch = 0;
    this.vyaw = 0;
    this.vpitch = 0;
    this.hx = 0;
    this.hy = 0;
    this.camAz = 0;
    this.camEl = 0.16;
    this.camDist = 6;
    this.level = 0;
    this.levelTarget = 0;
    this.env = 0;
    this.word = 0;
    this.lastWord = -9;
    this.jolt = 0;
    this.joltT = -9;
    this.nextJolt = 0;
    this.burstT = -9;
    this.glitchUntil = 0;
    this.nextGlitch = 5;
    this.spike = 0;
    this.speed = 1;
    this.glow = 1;
    this.m0 = -1;
    this.c0 = -1;
    this.previews = [];
    // Jobs that finished and faded out: the host may keep listing them, they do not come back.
    this.retired = new Set();
    this.paused = false;
    this.dead = false;
    this.measured = 0;
    this.frames = 0;
    this.fpsT = 0;
    this.hostState = STATES.includes(this.o.state) && this.o.state !== 'done' ? this.o.state : 'idle';
    this.lastActivity = performance.now();
    this.shown = this.hostState;
    this.ctx = { t: 0, level: 0, env: 0, word: 0, beat: 0, jolt: 0 };
    this.tmp = pose();
    this.q1 = new THREE.Quaternion();
    this.q2 = new THREE.Quaternion();
    this.v1 = new THREE.Vector3();
    this.v2 = new THREE.Vector3();
    this.cTarget = new THREE.Color();
    this.rTarget = new THREE.Color();
    this.cDone = new THREE.Color();
    this.rDone = new THREE.Color();
    this.cFail = new THREE.Color();
    this.euler = new THREE.Euler(0, 0, 0, 'XYZ');
    this.rigQ = new THREE.Quaternion();

    this.applyLook(this.o.look, { boot: true });
    this.fit();
    this.resize = new ResizeObserver(() => this.fit());
    this.resize.observe(host);
    if (this.o.interactive) this.listen();
    this.onVisibility = () => { if (!document.hidden) { this.last = performance.now(); this.activity(); } };
    document.addEventListener('visibilitychange', this.onVisibility);
    this.loopFn = (now) => this.loop(now);
    this.last = performance.now();
    if (this.o.still) this.settle();
    else this.schedule();
    this.emit({ type: 'ready', webgl: renderer.capabilities.isWebGL2 ? 2 : 1 });
  }

  // MARK: scene

  buildStatic() {
    const S = this.scene, U = this.U, GT = this.GT;
    this.halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: GT, opacity: 0, ...additive }));
    this.halo.scale.setScalar(0.7);
    this.rig.add(this.halo);
    this.coreG = new THREE.Group();
    this.rig.add(this.coreG);
    this.waves = [];
    for (let i = 0; i < 6; i++) {
      const w = new THREE.Mesh(new THREE.RingGeometry(0.985, 1, 160), new THREE.MeshBasicMaterial({ color: 0xffffff, opacity: 0, side: THREE.DoubleSide, ...additive }));
      w.visible = false;
      w.userData = { t: 9, color: new THREE.Color(), strength: 1 };
      S.add(w);
      this.waves.push(w);
    }
    // Satellites: one per job Relay runs.
    this.sats = [];
    for (let i = 0; i < MAX_JOBS; i++) {
      const sprite = new THREE.Sprite(new THREE.SpriteMaterial({ map: GT, opacity: 0, ...additive }));
      sprite.scale.setScalar(0.16);
      sprite.visible = false;
      S.add(sprite);
      this.sats.push({ sprite, id: null, state: 'running', born: 0, changed: 0, gone: -1, color: new THREE.Color() });
    }
  }

  buildRings() {
    for (const o of [this.ringMesh, this.twinMesh, this.lines]) {
      if (!o) continue;
      this.scene.remove(o);
      o.geometry.dispose();
      o.material.dispose();
    }
    const L = this.look, n = L.rings.count, style = L.rings.style, U = this.U;
    const geo = new THREE.PlaneGeometry(1, 1, this.low ? 160 : 256, 10);
    const attr = (name) => { const a = new THREE.InstancedBufferAttribute(new Float32Array(n), 1); a.setUsage(THREE.DynamicDrawUsage); geo.setAttribute(name, a); return a; };
    this.ringAttr = { R: attr('iR'), arc: attr('iArc'), hl: attr('iHl'), head: attr('iHead') };
    const dashes = style === 'dashed' ? 48 : style === 'dotted' ? 120 : 0, duty = style === 'dotted' ? 0.3 : 0.55;
    const material = (r, rScale, alpha) => new THREE.ShaderMaterial({
      uniforms: {
        time: U.time, gain: U.gain, reveal: U.reveal, col: U.col, rim: U.rim, r: { value: r }, rScale: { value: rScale },
        dashes: { value: dashes }, duty: { value: duty }, comet: this.comet, flow: this.flow, alpha: { value: alpha },
      },
      vertexShader: RING_VS, fragmentShader: RING_FS, side: THREE.DoubleSide, ...additive,
    });
    this.ringMesh = new THREE.InstancedMesh(geo, material(L.rings.thickness, 1, 1), n);
    this.ringMesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    this.ringMesh.frustumCulled = false;
    this.scene.add(this.ringMesh);
    this.twinMesh = null;
    if (style === 'double') {
      this.twinMesh = new THREE.InstancedMesh(geo, material(L.rings.thickness * 0.45, 1.08, 0.7), n);
      this.twinMesh.instanceMatrix = this.ringMesh.instanceMatrix;
      this.twinMesh.frustumCulled = false;
      this.scene.add(this.twinMesh);
    }
    // Outlines (LINE segments a ring), dashes (DASH a ring) and job trails, in one draw.
    const segments = n * (LINE + DASH) + MAX_JOBS * (TRAIL - 1);
    const lg = new THREE.BufferGeometry();
    lg.setAttribute('position', new THREE.BufferAttribute(new Float32Array(segments * 6), 3).setUsage(THREE.DynamicDrawUsage));
    lg.setAttribute('color', new THREE.BufferAttribute(new Float32Array(segments * 6), 3).setUsage(THREE.DynamicDrawUsage));
    this.lines = new THREE.LineSegments(lg, new THREE.LineBasicMaterial({ vertexColors: true, ...additive }));
    this.lines.frustumCulled = false;
    this.scene.add(this.lines);
    this.rings = Array.from({ length: n }, (_, k) => ({ m: new THREE.Matrix4(), pose: pose(), from: pose(), hl: 0, head: k * 0.37, dash: 0, R: 1 }));
  }

  buildCore() {
    if (this.points) {
      this.coreG.remove(this.points);
      this.points.geometry.dispose();
      this.points.material.dispose();
    }
    const N = Math.round((this.low ? POINTS / 2 : POINTS) * this.look.core.density);
    this.N = N;
    const pos = new Float32Array(N * 3), seed = new Float32Array(N), r = random(99);
    this.delay = new Float32Array(N);
    this.coreFrom = new Float32Array(N * 3);
    for (let i = 0; i < N; i++) { seed[i] = r(); this.delay[i] = r() * 0.45; }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setAttribute('seed', new THREE.BufferAttribute(seed, 1));
    this.seed = seed;
    const U = this.U;
    this.pointMat = new THREE.ShaderMaterial({
      uniforms: { time: U.time, gain: U.gain, reveal: U.reveal, col: U.col, rim: U.rim, size: { value: 0.026 }, scale: { value: this.pointScale || 600 }, boost: { value: 0 } },
      vertexShader: POINT_VS, fragmentShader: POINT_FS, ...additive,
    });
    this.points = new THREE.Points(g, this.pointMat);
    this.points.frustumCulled = false;
    this.coreG.add(this.points);
  }

  // MARK: look and state

  /** Applies a look. A new ring count, style or density rebuilds the hologram, which then
   *  materializes again; anything else morphs in place. */
  applyLook(look, { boot = false } = {}) {
    const next = normalize(look), prev = this.look;
    this.look = next;
    const rebuild = boot || !prev || prev.rings.count !== next.rings.count || prev.rings.style !== next.rings.style
      || prev.rings.thickness !== next.rings.thickness || prev.core.density !== next.core.density;
    if (rebuild) {
      this.buildRings();
      this.buildCore();
      this.form = null;
      this.coreShape = null;
      // Materialize: the rings rise from one horizon and the core from a spark.
      this.place('horizon', true);
      this.coreFrom.set(shape('spark', this.N));
      this.points.geometry.attributes.position.array.set(this.coreFrom);
      this.bootT = 0;
      this.reveal = { from: -1.95, to: 1.5, dur: boot ? 1.6 : 1.1 };
      if (!boot) this.glitchUntil = this.T + 0.18;
    }
    const d = next.states.done;
    this.tone(this.cDone.set(d.primary), this.rDone.set(d.rim));
    this.cFail.set(next.states.error.primary);
    if (!rebuild) { this.glitchUntil = this.T + 0.15; this.spike = 1; this.wave(next.states[this.shown].rim, 0.8); }
    if (!this.form) {
      // First frame of a (re)build: start from where it materializes and morph to the state.
      this.form = 'horizon';
      this.coreShape = 'spark';
    }
    this.morphTo(this.shown, { force: true, delay: rebuild ? 0.3 : 0 });
    if (this.camera) this.fit();
  }

  setLook(look) { this.applyLook(look); this.activity(); this.touch(); }

  setState(state) {
    if (!STATES.includes(state) || state === 'done') return;
    this.hostState = state;
    if (!this.previews.length) this.show(state);
    this.touch();
  }

  /** A still hologram (previews) draws again at rest after every change. */
  touch() { if (this.o.still && !this.dead) this.settle(); }

  /** Something happened: the hologram moves again, at full life, from the next display frame. */
  activity() {
    this.lastActivity = performance.now();
    this.wake();
  }
  /** Seconds since anything happened, and how far a settling state has eased to a stop (0–1). */
  quiet() { return (performance.now() - this.lastActivity) / 1000; }
  stillness() {
    const [after, slow] = SETTLE[this.shown] || [30, 12];
    return slow > 0 ? 0 : Math.min(1, Math.max(0, (this.quiet() - after) / EASE_OUT));
  }

  /** Something changed: draw it at the next display frame instead of after the current sleep. */
  wake() {
    if (this.dead || this.paused || this.o.still || this.raf) return;
    clearTimeout(this.timer);
    this.timer = 0;
    this.raf = requestAnimationFrame(this.loopFn);
  }

  show(state) {
    if (state === this.shown) return;
    this.shown = state;
    this.activity();
    this.morphTo(state);
    if (state === 'error') { this.glitchUntil = this.T + 0.5; this.joltT = this.T; }
  }

  morphTo(state, { force = false, delay = 0 } = {}) {
    const st = this.look.states[state];
    this.tone(this.cTarget.set(st.primary), this.rTarget.set(st.rim));
    if (force || st.formation !== this.form) {
      for (const r of this.rings) { r.from.q.copy(r.pose.q); r.from.p.copy(r.pose.p); r.from.R = r.pose.R; r.from.arc = r.pose.arc; }
      this.form = st.formation;
      this.m0 = this.T + delay;
      if (!force) { this.wave(st.rim, 0.6); this.spike = 1; }
    }
    if (force || st.core !== this.coreShape) {
      this.coreFrom.set(this.points.geometry.attributes.position.array);
      this.coreShape = st.core;
      this.c0 = this.T + delay;
    }
  }

  /** Puts every ring at a formation at once (used when the hologram materializes). */
  place(name, reset) {
    const F = FORMATIONS[name], n = this.rings.length;
    for (let k = 0; k < n; k++) {
      const r = this.rings[k];
      F.place(this.tmp, k, n, this.ctx);
      r.pose.q.copy(this.tmp.q);
      r.pose.p.copy(this.tmp.p);
      r.pose.R = this.tmp.R;
      r.pose.arc = this.tmp.arc;
      if (reset) { r.from.q.copy(r.pose.q); r.from.p.copy(r.pose.p); r.from.R = r.pose.R; r.from.arc = r.pose.arc; }
    }
  }

  // MARK: reactions from the host

  setLevel(v) { this.levelTarget = Math.max(0, Math.min(1, Number(v) || 0)); }
  /** A spoken word: the voice meter leaps. */
  pulse(strength = 0.7) {
    this.activity();
    this.word = Math.max(this.word, Math.max(0.2, Math.min(1, Number(strength) || 0.7)));
    this.lastWord = this.T;
    if (Math.random() < 0.34) this.wave(this.look.states[this.shown].rim, 0.35);
  }
  event(kind) {
    this.activity();
    if (kind === 'done') {
      this.burstT = this.T;
      this.wave(this.look.states.done.rim, 1);
      setTimeout(() => this.wave(this.look.states.done.primary, 0.7), 180);
    } else if (kind === 'error') {
      this.glitchUntil = this.T + 0.5;
      this.joltT = this.T;
      this.wave(this.look.states.error.primary, 0.6);
    } else if (kind === 'tap') {
      this.wave(this.look.states[this.shown].rim, 0.8);
      this.spike = 1;
    }
  }
  /** Jobs as satellites: [{id, state: running | done | failed}]. */
  setJobs(list) {
    const seen = new Set();
    for (const job of Array.isArray(list) ? list.slice(0, MAX_JOBS) : []) {
      const id = String(job.id), state = ['running', 'done', 'failed'].includes(job.state) ? job.state : 'running';
      seen.add(id);
      if (this.retired.has(id)) { if (state !== 'running') continue; this.retired.delete(id); }
      let s = this.sats.find((x) => x.id === id);
      if (!s) {
        s = this.sats.find((x) => x.id === null);
        if (!s) continue;
        Object.assign(s, { id, state, born: this.T, changed: this.T, gone: -1 });
        this.activity();
        if (state === 'running') this.wave(this.look.states.working.rim, 0.4);
      } else if (s.state !== state) {
        s.state = state;
        s.changed = this.T;
        this.activity();
        if (state === 'done') this.wave(this.look.states.done.rim, 0.5);
      }
      if (s.state !== 'running' && s.gone < 0) s.gone = this.T + (s.state === 'done' ? 3 : 5);
    }
    for (const s of this.sats) if (s.id !== null && !seen.has(s.id) && s.gone < 0) s.gone = this.T + 0.6;
    this.touch();
  }
  /** Shows a state, or every state in turn ('tour'), then goes back to the real one. */
  preview(state, seconds = 6) {
    const secs = Math.max(1, Math.min(30, Number(seconds) || 6));
    const list = state === 'tour' ? STATES.filter((s) => s !== 'done') : STATES.includes(state) ? [state] : [];
    if (!list.length) return false;
    // Timed by the clock, so a tour takes as long as asked even when frames come slowly.
    const each = Math.max(1.2, secs / list.length), now = performance.now() / 1000;
    this.previews = list.map((s, i) => ({ state: s, until: now + each * (i + 1) }));
    if (state === 'tour') this.previews.push({ state: 'done', until: now + each * list.length + 0.1 });
    this.show(this.previews[0].state === 'done' ? this.hostState : this.previews[0].state);
    this.activity();
    return true;
  }
  setActive(on) {
    if (on && !this.active) this.activity();
    this.active = !!on;
  }
  /** 'light' or 'dark': what is behind the view. */
  setTheme(theme) {
    const t = theme === 'light' ? 'light' : 'dark';
    if (t === this.theme) return;
    this.theme = t;
    this.fx.uniforms.ink.value = t === 'light' ? 1 : 0;
    const d = this.look.states.done;
    this.tone(this.cDone.set(d.primary), this.rDone.set(d.rim));
    this.morphTo(this.shown);
    this.activity();
    this.touch();
  }
  /** On a light background the edge light keeps the body's hue instead of going white. */
  tone(primary, rim) {
    if (this.theme === 'light') rim.lerp(primary, 0.55);
  }
  setPaused(on) {
    this.paused = !!on;
    if (this.paused) this.halt();
    else { this.last = performance.now(); this.schedule(); }
  }
  halt() {
    cancelAnimationFrame(this.raf);
    clearTimeout(this.timer);
    this.raf = this.timer = 0;
  }
  info() {
    return {
      state: this.shown, host: this.hostState, formation: this.form, core: this.coreShape, look: this.look.name, rings: this.rings.length,
      draws: this.renderer.info.render.calls,
      points: this.N, fps: Math.round(this.measured), compact: this.compact, theme: this.theme,
      jobs: this.sats.filter((s) => s.id !== null).length, webgl: this.renderer.capabilities.isWebGL2 ? 2 : 1,
    };
  }
  /** Renders a settled frame now (for previews and checks) and returns it as a PNG data URL. */
  snapshot() {
    // A PNG stores straight alpha, which cannot hold added light: the frame is drawn with full
    // coverage for it.
    const cover = this.fx.uniforms.cover.value;
    this.fx.uniforms.cover.value = 1;
    this.render();
    const url = this.renderer.domElement.toDataURL('image/png');
    this.fx.uniforms.cover.value = cover;
    return url;
  }
  /** Skips the materializing and every morph: the next frame shows the state at rest. */
  settle(t = 6) {
    this.T = Math.max(this.T, t);
    this.ft = Math.max(this.ft, t);
    this.bootT = 99;
    this.m0 = this.c0 = -9;
    this.coreDirty = true;
    this.U.col.value.copy(this.cTarget);
    this.U.rim.value.copy(this.rTarget);
    this.speed = this.look.states[this.shown].speed * this.look.motion;
    this.glow = this.look.states[this.shown].glow;
    // A still frame shows the voice states mid-word, as they look while they move.
    if (this.shown === 'speaking') { this.env = 0.65; this.word = 0.5; }
    if (this.shown === 'listening') this.level = Math.max(this.level, 0.55);
    this.step(0);
    this.render();
  }
  destroy() {
    this.dead = true;
    this.halt();
    this.resize.disconnect();
    document.removeEventListener('visibilitychange', this.onVisibility);
    this.unlisten?.();
    Object.values(this.rt).forEach((t) => t.dispose());
    this.renderer.dispose();
    this.renderer.domElement.remove();
  }

  // MARK: input

  listen() {
    const el = this.host;
    let down = null;
    const at = (e) => { const r = el.getBoundingClientRect(); return [(e.clientX - r.left) / r.width - 0.5, (e.clientY - r.top) / r.height - 0.5]; };
    const onDown = (e) => {
      down = { x: e.clientX, y: e.clientY, t: performance.now(), moved: 0 };
      this.activity();
      try { el.setPointerCapture(e.pointerId); } catch (_) { /* no capture */ }
    };
    const onMove = (e) => {
      [this.hx, this.hy] = at(e);
      // The pointer over a still hologram wakes it.
      if (this.quiet() > 1) this.activity();
      if (!down) return;
      const dx = e.clientX - down.x, dy = e.clientY - down.y;
      down.moved += Math.abs(dx) + Math.abs(dy);
      down.x = e.clientX;
      down.y = e.clientY;
      if (down.moved > 6) {
        this.dragging = true;
        this.vyaw = dx * 0.008;
        this.vpitch = dy * 0.006;
        this.yaw += this.vyaw;
        this.pitch = Math.max(-0.8, Math.min(0.8, this.pitch + this.vpitch));
      }
    };
    const onUp = (e) => {
      if (down && down.moved <= 6 && performance.now() - down.t < 450) { this.event('tap'); this.emit({ type: 'tap' }); }
      down = null;
      this.dragging = false;
      try { el.releasePointerCapture(e.pointerId); } catch (_) { /* released */ }
    };
    const onLeave = () => { this.hx = this.hy = 0; };
    const noMenu = (e) => e.preventDefault();
    el.addEventListener('pointerdown', onDown);
    el.addEventListener('pointermove', onMove);
    el.addEventListener('pointerup', onUp);
    el.addEventListener('pointercancel', onUp);
    el.addEventListener('pointerleave', onLeave);
    el.addEventListener('contextmenu', noMenu);
    this.unlisten = () => {
      el.removeEventListener('pointerdown', onDown);
      el.removeEventListener('pointermove', onMove);
      el.removeEventListener('pointerup', onUp);
      el.removeEventListener('pointercancel', onUp);
      el.removeEventListener('pointerleave', onLeave);
      el.removeEventListener('contextmenu', noMenu);
    };
  }

  // MARK: frame

  fit() {
    const W = this.host.clientWidth || 640, H = this.host.clientHeight || 360;
    this.W = W;
    this.H = H;
    this.renderer.setSize(W, H, false);
    const pr = this.renderer.getPixelRatio(), w = Math.max(1, Math.round(W * pr)), h = Math.max(1, Math.round(H * pr));
    this.rt.scene.setSize(w, h);
    for (const [t, d] of [[this.rt.d1, 2], [this.rt.u1, 2], [this.rt.d2, 4], [this.rt.u2, 4], [this.rt.d3, 8]]) t.setSize(Math.ceil(w / d), Math.ceil(h / d));
    this.fx.uniforms.res.value.set(W * pr, H * pr);
    this.pointScale = (H * pr) / (2 * Math.tan(THREE.MathUtils.degToRad(17)));
    if (this.pointMat) this.pointMat.uniforms.scale.value = this.pointScale;
    this.camera.aspect = W / H;
    this.camera.updateProjectionMatrix();
    this.compact = H < 150 || W < 180;
    // Framed on the rings alone: the circle fills the height, the voice meter the width.
    const t = Math.tan(THREE.MathUtils.degToRad(17));
    this.baseDist = Math.max(1.3 / t, 1.45 / (t * this.camera.aspect));
    // A resized canvas is blank until it is drawn again, even when the hologram holds still.
    if (this.o.still) this.settle();
    else if (this.loopFn) this.activity();
  }

  /** Full speed only while the hologram changes shape; a steady state needs far fewer frames,
   *  and fewer still behind other windows. */
  fps() {
    if (this.paused || document.hidden) return 0;
    const busy = this.dragging || this.T - this.m0 < 1.6 || this.T - this.c0 < 1.6 || this.T - this.burstT < 2.2
      || this.bootT < 1.8 || this.previews.length > 0;
    const [after, slow] = SETTLE[this.shown] || [30, 12];
    const quiet = this.quiet();
    let fps = busy ? 60 : STEADY_FPS[this.shown] || 24;
    // A host may ask for smoother steady motion (⌥Space's floating hologram, while it is shown).
    if (!busy && this.o.minFps > 0 && this.shown !== 'dormant') fps = Math.max(fps, this.o.minFps);
    if (!busy && quiet > after) {
      if (slow > 0) fps = Math.min(fps, slow);
      else if (quiet > after + EASE_OUT) return 0;
    }
    if (!this.active) fps = Math.min(fps, this.shown === 'dormant' ? 5 : 12);
    if (this.reduced || this.low) fps = Math.min(fps, 30);
    if (this.o.maxFps > 0) fps = Math.min(fps, this.o.maxFps);
    return fps;
  }

  loop(now) {
    this.raf = 0;
    if (this.dead) return;
    const fps = this.fps();
    const elapsed = (now - this.last) / 1000;
    // At display speed a timer and a subsequent animation callback can miss the same
    // refresh on every frame. Keep the display deadline across frames so jitter
    // does not accumulate, and drop missed frames after a stall.
    const displaySpeed = fps >= 60;
    if (!displaySpeed) this.nextDisplayFrame = undefined;
    if (!fps) this.last = now;
    else if (displaySpeed ? now + 1 >= (this.nextDisplayFrame ?? now) : elapsed >= 1 / fps - 0.004) {
      if (displaySpeed) {
        const period = 1000 / fps;
        const due = this.nextDisplayFrame ?? now;
        this.nextDisplayFrame = now - due >= period ? now + period : due + period;
      }
      this.last = now;
      this.frames++;
      if (now - this.fpsT > 1000) { this.measured = (this.frames * 1000) / (now - this.fpsT); this.frames = 0; this.fpsT = now; }
      this.step(Math.min(0.1, elapsed));
      this.render();
    }
    this.schedule();
  }

  /** Sleeps until the next frame is due, then asks for one display frame: asking for every
   *  display frame and skipping most of them keeps the whole app awake. */
  schedule() {
    if (this.dead || this.paused || this.o.still || this.raf || this.timer) return;
    const fps = this.fps();
    // Still or hidden: no timer at all; activity(), a state from the host or the page becoming
    // visible again wakes the loop.
    if (!fps) return;
    const wait = this.last + 1000 / fps - performance.now();
    if (fps < 60 && wait > 8) {
      this.timer = setTimeout(() => { this.timer = 0; this.raf = requestAnimationFrame(this.loopFn); }, wait - 6);
    } else this.raf = requestAnimationFrame(this.loopFn);
  }

  render() {
    const r = this.renderer, rt = this.rt, q = this.quad;
    const run = (material, to) => { q.material = material; r.setRenderTarget(to); q.render(r); };
    r.info.reset();
    r.setRenderTarget(rt.scene);
    r.clear();
    r.render(this.scene, this.camera);
    const down = this.down.uniforms, up = this.up.uniforms;
    [[rt.scene, rt.d1, 0.08], [rt.d1, rt.d2, 0], [rt.d2, rt.d3, 0]].forEach(([from, to, threshold]) => {
      down.t.value = from.texture;
      down.texel.value.set(1 / from.width, 1 / from.height);
      down.threshold.value = threshold;
      run(this.down, to);
    });
    [[rt.d3, rt.d2, rt.u2], [rt.u2, rt.d1, rt.u1]].forEach(([from, beside, to]) => {
      up.t.value = from.texture;
      up.add.value = beside.texture;
      up.texel.value.set(1 / to.width, 1 / to.height);
      run(this.up, to);
    });
    run(this.fx, null);
  }

  step(rawDt) {
    const dt = rawDt * (this.reduced ? 0.5 : 1) * (1 - this.stillness()), L = this.look;
    this.T += dt;
    this.bootT += rawDt;
    const T = this.T;
    // A preview (look_show) plays its states, then the host's state comes back.
    if (this.previews.length) {
      const clock = performance.now() / 1000;
      while (this.previews.length && clock >= this.previews[0].until) this.previews.shift();
      const next = this.previews.length ? this.previews[0].state : this.hostState;
      if (next === 'done') { this.event('done'); this.previews.shift(); this.show(this.previews.length ? this.previews[0].state : this.hostState); }
      else this.show(next);
    }
    const st = L.states[this.shown];
    const k3 = 1 - Math.exp(-dt * 3);
    this.speed += (st.speed * L.motion - this.speed) * k3;
    this.ft += dt * this.speed;
    this.glow += (st.glow - this.glow) * k3;
    this.U.time.value = T;
    this.fx.uniforms.time.value = T;

    // Voice, words, heartbeat, jolts.
    const lk = 1 - Math.exp(-dt * (this.levelTarget > this.level ? 25 : 6));
    this.level += (this.levelTarget - this.level) * lk;
    const speaking = this.shown === 'speaking';
    if (speaking && T - this.lastWord > 0.55 && Math.random() < dt * 3.5) { this.word = Math.max(this.word, 0.45 + Math.random() * 0.4); }
    this.word *= Math.exp(-dt * 7);
    this.env += ((speaking ? 0.3 + this.word * 0.7 : 0) - this.env) * (1 - Math.exp(-dt * 10));
    const listening = this.shown === 'listening';
    const level = listening ? Math.max(this.level, this.previews.length ? 0.35 + 0.3 * Math.sin(T * 7) * Math.sin(T * 2.3) : 0) : this.level * 0.3;
    const ph = (T % 1.15) / 1.15, beat = Math.exp(-(((ph - 0.05) / 0.05) ** 2)) + 0.6 * Math.exp(-(((ph - 0.27) / 0.05) ** 2));
    if (this.shown === 'error' && T > this.nextJolt) { this.joltT = T; this.nextJolt = T + 0.6 + Math.random() * 1.4; if (Math.random() < 0.5) this.glitchUntil = T + 0.1; }
    this.jolt = Math.exp(-(T - this.joltT) * 12);
    const bx = T - this.burstT, burst = bx < 0 || bx > 2.4 ? 0 : bx < 0.15 ? bx / 0.15 : Math.exp(-(bx - 0.15) * 2.2);
    this.spike *= Math.exp(-dt * 4);
    const c = this.ctx;
    c.t = this.ft;
    c.level = level;
    c.env = this.env;
    c.word = this.word;
    c.beat = this.shown === 'alert' ? beat : 0;
    c.jolt = this.jolt;

    // Colors: the state's palette, flashed toward the done palette by a burst.
    const U = this.U, kc = 1 - Math.exp(-dt * 3.2);
    U.col.value.lerp(this.cTarget, kc);
    U.rim.value.lerp(this.rTarget, kc);
    if (burst > 0) { U.col.value.lerp(this.cDone, burst * 0.6); U.rim.value.lerp(this.rDone, burst * 0.6); }
    U.gain.value = 1;
    const boot = this.reveal ? smooth(0, this.reveal.dur, this.bootT) : 1;
    U.reveal.value = boot < 1 ? this.reveal.from + (this.reveal.to - this.reveal.from) * boot : 99;
    if (this.reveal && boot >= 1 && !this.revealed) { this.revealed = true; this.wave(st.rim, 0.9); }
    if (boot < 1) this.revealed = false;

    // The rig: auto-spin for formations that turn, drag on top, inertia after a drag.
    const F = FORMATIONS[this.form];
    if (!this.dragging) {
      this.yaw += this.vyaw;
      this.vyaw *= Math.exp(-dt * 3);
      this.vpitch *= Math.exp(-dt * 3);
      this.pitch *= 1 - (1 - Math.exp(-dt * 1.2));
      if (F.facing) this.yaw += (Math.round(this.yaw / TAU) * TAU - this.yaw) * (1 - Math.exp(-dt * 1.5));
      this.spinAcc += dt * F.spin * this.speed;
    }
    const dragQ = this.q1.setFromEuler(this.euler.set(this.pitch, this.yaw, 0, 'XYZ'));
    const spinQ = this.q2.setFromAxisAngle(THREE.Object3D.DEFAULT_UP, this.spinAcc);
    const rigQ = this.rigQ.copy(dragQ).multiply(spinQ);
    const bob = 0.05 * Math.sin(T * 0.9);
    this.rig.position.set(0, bob, 0);
    this.rig.quaternion.copy(dragQ);

    // Rings: the formation's pose, blended from where each ring was, one ring after another.
    const n = this.rings.length, tmp = this.tmp, mDur = this.reduced ? 0.7 : 1.1;
    const thinking = this.shown === 'thinking';
    const RA = this.ringAttr, lp = this.lines.geometry.attributes.position.array, lc = this.lines.geometry.attributes.color.array;
    const fade = this.glow * (boot < 1 ? smooth(0.2, 1, boot) : 1), rim = U.rim.value, body = U.col.value;
    let v = 0;
    const put = (x1, y1, z1, x2, y2, z2, r, g, b) => {
      lp[v] = x1; lp[v + 1] = y1; lp[v + 2] = z1; lp[v + 3] = x2; lp[v + 4] = y2; lp[v + 5] = z2;
      lc[v] = lc[v + 3] = r; lc[v + 1] = lc[v + 4] = g; lc[v + 2] = lc[v + 5] = b;
      v += 6;
    };
    for (let k = 0; k < n; k++) {
      const r = this.rings[k];
      F.place(tmp, k, n, c);
      const rq = F.facing ? dragQ : rigQ;
      tmp.p.applyQuaternion(rq);
      tmp.q.premultiply(rq);
      const w = this.m0 < -1 ? 1 : ease((T - this.m0 - k * 0.07) / mDur);
      const P = r.pose;
      if (w >= 1) { P.q.copy(tmp.q); P.p.copy(tmp.p); P.R = tmp.R; P.arc = tmp.arc; }
      else {
        P.q.slerpQuaternions(r.from.q, tmp.q, w);
        P.p.lerpVectors(r.from.p, tmp.p, w);
        P.R = r.from.R + (tmp.R - r.from.R) * w;
        P.arc = r.from.arc + (tmp.arc - r.from.arc) * w;
      }
      const flight = w > 0 && w < 1 ? Math.sin(Math.PI * w) : 0;
      this.v1.copy(P.p);
      this.v1.y += bob;
      r.m.compose(this.v1, P.q, this.unit);
      this.ringMesh.setMatrixAt(k, r.m);
      const R = (r.R = Math.max(0.1, P.R * (1 - 0.1 * flight) * (1 + 0.28 * burst)));
      // Highlights: the formation's own, a sweep while thinking, the voice, a beat, a burst.
      let h = tmp.hl + flight * 0.5 + burst;
      if (thinking) { const sw = (this.ft * 2.2) % n; let d = Math.abs(sw - k); d = Math.min(d, n - d); h += Math.max(0, 1 - d * 1.4) * 0.8; }
      if (this.shown === 'alert' && this.form !== 'lantern') h += beat * 0.5;
      if (speaking && this.form !== 'waveform') h += this.env * 0.5;
      if (listening && this.form !== 'dish') h += level * 0.6;
      r.hl += (h - r.hl) * (1 - Math.exp(-dt * 10));
      r.head = (r.head + dt * (0.12 + 0.05 * k) * (k % 2 ? -1 : 1) * this.speed) % 1;
      RA.R.array[k] = R;
      RA.arc.array[k] = P.arc;
      RA.hl.array[k] = r.hl;
      RA.head.array[k] = r.head < 0 ? r.head + 1 : r.head;
      // The bright outline (only the drawn arc) and the dashes just outside it.
      const e = r.m.elements, la = Math.min(1, 0.42 * fade * (1 + r.hl)), drawn = Math.round(LINE * Math.min(1, P.arc));
      for (let i = 0; i < LINE; i++) {
        const on = i < drawn ? la : 0, x1 = COS[i] * R, y1 = SIN[i] * R, x2 = COS[i + 1] * R, y2 = SIN[i + 1] * R;
        put(e[0] * x1 + e[4] * y1 + e[12], e[1] * x1 + e[5] * y1 + e[13], e[2] * x1 + e[6] * y1 + e[14],
          e[0] * x2 + e[4] * y2 + e[12], e[1] * x2 + e[5] * y2 + e[13], e[2] * x2 + e[6] * y2 + e[14], rim.r * on, rim.g * on, rim.b * on);
      }
      r.dash += dt * 0.25 * (k % 2 ? 1 : -1) * (1 + this.speed);
      const da = P.arc > 0.99 ? Math.min(1, 0.3 * fade * (1 + r.hl * 0.8)) : 0, DR = R * 1.05;
      for (let i = 0; i < DASH; i++) {
        const a1 = ((i / DASH) * TAU) + r.dash, a2 = a1 + (TAU / DASH) * 0.35;
        const x1 = Math.cos(a1) * DR, y1 = Math.sin(a1) * DR, x2 = Math.cos(a2) * DR, y2 = Math.sin(a2) * DR;
        put(e[0] * x1 + e[4] * y1 + e[12], e[1] * x1 + e[5] * y1 + e[13], e[2] * x1 + e[6] * y1 + e[14],
          e[0] * x2 + e[4] * y2 + e[12], e[1] * x2 + e[5] * y2 + e[13], e[2] * x2 + e[6] * y2 + e[14], body.r * da, body.g * da, body.b * da);
      }
    }
    this.ringMesh.instanceMatrix.needsUpdate = true;
    for (const a of Object.values(RA)) a.needsUpdate = true;
    this.comet.value = CALM.has(this.shown) ? (this.shown === 'dormant' ? 0.15 : 0.6) : 0.9;
    this.flow.value = speaking ? this.env : listening ? level : 0;

    // Core: every point travels from its old place to the new shape, swirling on the way.
    const N = this.N, pos = this.points.geometry.attributes.position.array, target = shape(this.coreShape, N), from = this.coreFrom;
    const cDur = this.reduced ? 0.6 : 0.95, scatter = this.coreShape === 'scatter';
    let moving = scatter;
    if (this.c0 > -2 && T - this.c0 < cDur + 0.5) moving = true;
    if (moving || this.coreDirty) {
      for (let i = 0; i < N; i++) {
        const w = this.c0 < -2 ? 1 : ease((T - this.c0 - this.delay[i]) / cDur);
        const j = i * 3;
        let x = from[j] + (target[j] - from[j]) * w, y = from[j + 1] + (target[j + 1] - from[j + 1]) * w, z = from[j + 2] + (target[j + 2] - from[j + 2]) * w;
        if (w < 1) {
          const a = (1 - w) * 2.2 * (i % 2 ? 1 : -1), ca = Math.cos(a), sa = Math.sin(a), s = 1 + 0.45 * Math.sin(Math.PI * w);
          const nx = (x * ca - z * sa) * s;
          z = (x * sa + z * ca) * s;
          x = nx;
          y *= s;
        }
        if (scatter) { const sd = this.seed[i] * 20; x += 0.04 * Math.sin(T * 0.8 + sd); y += 0.04 * Math.sin(T * 0.7 + sd * 1.3); z += 0.04 * Math.sin(T * 0.9 + sd * 0.7); }
        pos[j] = x;
        pos[j + 1] = y;
        pos[j + 2] = z;
      }
      this.points.geometry.attributes.position.needsUpdate = true;
      this.coreDirty = moving;
    }
    const m = MOTION[this.coreShape] || MOTION.orb;
    this.coreSpin = (this.coreSpin || 0) + dt * m.spin * this.speed * (thinking ? 1.8 : 1);
    this.coreTilt = (this.coreTilt ?? 0) + (m.tilt - (this.coreTilt ?? 0)) * k3;
    this.coreG.rotation.set(this.coreTilt + m.tumble * Math.sin(T * 0.4), this.coreSpin + m.sway * Math.sin(T * 0.8), 0, 'XYZ');
    const breath = 1 + 0.03 * Math.sin(T * 2);
    const sc = L.core.size * breath * (1 + level * 0.35) * (1 + this.env * 0.16) * (1 + burst * 0.9) * (this.shown === 'alert' ? 1 + 0.06 * beat : 1);
    this.coreG.scale.setScalar(sc);
    this.pointMat.uniforms.boost.value = burst * 1.2 + this.word * 0.5 + level * 0.5 + this.jolt * 0.8;
    this.halo.material.opacity = 0.42 * this.glow * (boot < 1 ? boot : 1) * (1 + burst + this.word * 0.4 + level * 0.4);
    this.halo.material.color.copy(U.col.value);
    this.halo.scale.setScalar(0.7 * (1 + 0.06 * Math.sin(T * 2.4) + this.env * 0.25 + burst * 0.6));

    // Shock waves.
    for (const w of this.waves) {
      if (!w.visible) continue;
      w.userData.t += dt;
      const x = w.userData.t / 1.6;
      if (x >= 1) { w.visible = false; continue; }
      w.position.copy(this.rig.position);
      w.quaternion.copy(this.camera.quaternion);
      w.scale.setScalar(0.15 + 2.4 * x * (0.6 + 0.4 * w.userData.strength));
      w.material.opacity = 0.45 * (1 - x) * (1 - x) * w.userData.strength;
      w.material.color.copy(w.userData.color);
    }

    // Satellites ride the rings, trailing light.
    for (let i = 0; i < this.sats.length; i++) {
      const sat = this.sats[i];
      if (sat.id !== null && sat.gone > 0 && T > sat.gone + 0.8) {
        if (sat.state !== 'running') this.retired.add(sat.id);
        sat.id = null;
        sat.sprite.visible = false;
      }
      if (sat.id === null) {
        for (let j = 0; j < TRAIL - 1; j++) put(0, 0, 0, 0, 0, 0, 0, 0, 0);
        continue;
      }
      const ring = this.rings[i % n], e = ring.m.elements, R = ring.R;
      const dir = i % 2 ? -1 : 1, a = dir * (T * (0.9 + 0.08 * i)) + i * 2.1;
      const life = (sat.gone > 0 ? Math.min(1, Math.max(0, 1 - (T - sat.gone) / 0.8)) : 1) * Math.min(1, (T - sat.born) / 0.4);
      sat.color.copy(sat.state === 'done' ? this.rDone : sat.state === 'failed' ? this.cFail : U.rim.value);
      const flick = sat.state === 'failed' ? 0.6 + 0.4 * Math.sin(T * 30) : sat.state === 'done' && T - sat.changed < 0.6 ? 2 : 1;
      const x = Math.cos(a) * R, y = Math.sin(a) * R;
      sat.sprite.visible = true;
      sat.sprite.position.set(e[0] * x + e[4] * y + e[12], e[1] * x + e[5] * y + e[13], e[2] * x + e[6] * y + e[14]);
      sat.sprite.material.color.copy(sat.color);
      sat.sprite.material.opacity = 0.9 * life * flick;
      sat.sprite.scale.setScalar(0.2 + (sat.state === 'done' && T - sat.changed < 0.6 ? 0.16 : 0));
      for (let j = 0; j < TRAIL - 1; j++) {
        const b1 = a - dir * j * 0.04, b2 = b1 - dir * 0.04, f = (1 - j / TRAIL) ** 1.4 * life;
        const x1 = Math.cos(b1) * R, y1 = Math.sin(b1) * R, x2 = Math.cos(b2) * R, y2 = Math.sin(b2) * R;
        put(e[0] * x1 + e[4] * y1 + e[12], e[1] * x1 + e[5] * y1 + e[13], e[2] * x1 + e[6] * y1 + e[14],
          e[0] * x2 + e[4] * y2 + e[12], e[1] * x2 + e[5] * y2 + e[13], e[2] * x2 + e[6] * y2 + e[14], sat.color.r * f, sat.color.g * f, sat.color.b * f);
      }
    }
    this.lines.geometry.attributes.position.needsUpdate = true;
    this.lines.geometry.attributes.color.needsUpdate = true;

    // Camera: framed for the formation, drifting with the pointer.
    const still = this.reduced || this.o.still;
    const az = still ? 0 : this.hx * 0.5 + 0.12 * Math.sin(T * 0.11);
    const el = F.elev + (still ? 0 : this.hy * 0.25 + 0.03 * Math.sin(T * 0.17));
    const kc2 = this.o.still ? 1 : 1 - Math.exp(-dt * 2.5);
    this.camAz += (az - this.camAz) * kc2;
    this.camEl += (el - this.camEl) * kc2;
    this.camDist += (this.baseDist * F.dist - this.camDist) * kc2;
    this.camera.position.set(Math.sin(this.camAz) * Math.cos(this.camEl) * this.camDist, Math.sin(this.camEl) * this.camDist, Math.cos(this.camAz) * Math.cos(this.camEl) * this.camDist);
    this.camera.lookAt(0, 0, 0);
    this.camera.updateMatrixWorld();

    // Post: light only around the hologram; bloom with the state's glow; glitches the look allows.
    const fu = this.fx.uniforms, pv = this.v2.set(0, bob, 0).project(this.camera), fx = L.effects, g = this.glow;
    fu.c0.value.set(pv.x * 0.5 + 0.5, pv.y * 0.5 + 0.5);
    fu.rad.value = 1.45 / (2 * Math.tan(THREE.MathUtils.degToRad(17)) * this.camDist);
    fu.aspect.value = this.W / this.H;
    fu.strength.value = fx.bloom * 0.95 * g * (1 + burst * 0.6) * (this.compact ? 0.6 : 1) * (this.theme === 'light' ? 0.55 : 1);
    if (!this.reduced && fx.glitch > 0 && T > this.nextGlitch) { this.glitchUntil = T + 0.12; this.nextGlitch = T + (6 + Math.random() * 7) / Math.max(0.15, fx.glitch); }
    const glitching = !this.reduced && !this.o.still && (T < this.glitchUntil || this.bootT < 0.25) && fx.glitch > 0;
    this.fx.uniforms.glitch.value = glitching ? Math.max(0.35, fx.glitch) : 0;
    this.fx.uniforms.amount.value = fx.aberration * 2 * (1 + this.spike * 1.5 + (this.shown === 'alert' ? 0.4 : 0) + this.jolt);
    this.fx.uniforms.scan.value = fx.scanlines;
    this.fx.uniforms.grain.value = this.o.still ? 0 : fx.grain;
    this.fx.uniforms.vig.value = this.compact ? 0.2 : 0.55;
  }

  wave(color, strength = 1) {
    const w = this.waves.find((x) => !x.visible);
    if (!w) return;
    w.userData.t = 0;
    w.userData.strength = strength;
    w.userData.color.set(color);
    w.visible = true;
  }
}
