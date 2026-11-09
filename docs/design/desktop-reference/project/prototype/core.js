'use strict';
// Tako desktop prototype — model, split tree, layout (classic script; shares globals with the other prototype/*.js)
const $ = (s, r = document) => r.querySelector(s);
const canvas = $('#canvas'), dockEl = $('#dock'), toastsEl = $('#toasts'), emptyEl = $('#empty'), sbList = $('#sbList'), app = $('#app');
const snapPrev = $('#snapPrev'), snapOther = $('#snapOther'), snapHint = $('#snapHint');
const MINW = 360, MINH = 200, HDR = 30, GAP = 8, EDGE = 28, DOCKH = 50;
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

const CONTENT = {
  claude: `<span class="d">$</span> claude "Refactor auth middleware"
<span class="d">●</span> Reading src/auth/jwt.rs <span class="d">(142 lines)</span>
<span class="d">●</span> Proposed edit src/auth/jwt.rs <span class="g">+38</span> <span class="r">-12</span>

<span class="c">? Allow command: mitts test -p auth?</span>
  <span class="c">❯ 1. Yes</span>
    2. Yes, and don't ask again
    3. No
`,
  build: `<span class="d">$</span> mitts build --release
<span class="c">⚡ Mitts Build</span> <span class="d">build [release] ────────────────────</span>
<span class="b">┌─</span> Compiled target [release]
<span class="b">│</span>  <span class="d">└─</span> <span class="y">[cache]</span> Restored vte@0.13.0::lib:vte
<span class="b">│</span>  <span class="d">└─</span> <span class="y">[compile]</span> Compiled tako-core@0.9.2::lib:tako_core
`,
  shell: `Welcome to fish, the friendly interactive shell
Type <span class="y">help</span> for instructions on how to use fish
<span class="d">╭</span> <span class="e">~/tako</span> <span class="d">on</span> <span class="p">main</span> <span class="d">±2</span>
<span class="d">╰</span> <span class="e">❯</span> <span class="cur"></span>`,
  test: `<span class="d">$</span> mitts test --workspace
<span class="c">⚡ Mitts Build</span> <span class="d">test [dev] ────────────────────</span>
running 48 tests
test parser::osc133 ... <span class="g">ok</span>
test grid::reflow_wide_char ... <span class="r">FAILED</span>
test result: <span class="r">FAILED</span>. 47 passed; 1 failed
<span class="b">└─</span> <span class="r">dev profile failed</span> <span class="d">(Test harness failed)</span>
<span class="d">╰</span> <span class="r">❯</span> <span class="cur"></span>`,
  dev: `<span class="d">$</span> npm run dev
  <span class="g">VITE</span> v5.4.2  ready in 412 ms
  <span class="d">➜</span>  Local:   <span class="b">http://localhost:3000/</span>
  <span class="d">➜</span>  press <span class="y">h</span> to show help
<span class="d">14:02:11</span> <span class="b">[hmr]</span> /src/App.tsx
`,
  ssh: `<span class="d">$</span> ssh prod-db
Last login: Sat Nov  7 09:12:40 from 10.0.4.2
<span class="g">alex@prod-db</span>:<span class="b">~</span>$ psql -c 'select count(*) from jobs'
 count
-------
 18402
<span class="g">alex@prod-db</span>:<span class="b">~</span>$ <span class="cur"></span>`,
};

// ---------- model ----------
// session.tree: null | {t:'leaf', id} | {t:'split', dir:'h'|'v', r:0..1, a, b}
// window.mode: 'tile' | 'float' | 'min' ; minFrom: 'tile'|'float' ; home: where to re-insert
let seq = 1;
const W = (title, cwd, kind, status) => ({ id: 'w' + (seq++), title, cwd, kind, status, mode: 'tile', rect: null, max: false, home: null });
const leaf = id => ({ t: 'leaf', id });
const split = (dir, a, b, r = .5) => ({ t: 'split', dir, r, a, b });

function initialState() {
  seq = 1;
  const s1 = [W('fish', '~/tako', 'shell', 'idle'), W('claude · auth', '~/tako-backend', 'claude', 'waiting'), W('mitts build', '~/tako-core', 'build', 'progress')];
  s1[1].ask = 'Allow mitts test -p auth?'; s1[2].p = 68;
  const s2 = [W('mitts test', '~/tako-core', 'test', 'error')];
  const s5 = [W('psql migrations', '~/tako-db', 'ssh', 'done')];
  const s3 = [W('npm run dev', '~/web-ui', 'dev', 'live'), W('fish', '~/web-ui', 'shell', 'idle')]; s3[0].prog = 'vite'; s3[0].quiet = 12;
  const s8 = [W('codex review', '~/tako-core', 'build', 'working')];
  const s6 = [W('gemini · a11y', '~/web-ui', 'claude', 'waiting')]; s6[0].ask = 'Which palette should we apply?';
  const s4 = [W('ssh prod-db', 'alex@prod-db', 'ssh', 'live')]; s4[0].prog = 'ssh'; s4[0].quiet = 1;
  const s9 = [W('tail voice-p.log', '~/logs', 'ssh', 'live')]; s9[0].prog = 'tail'; s9[0].quiet = 4;
  const s7 = [W('ssh prod-1', 'alex@prod-1', 'ssh', 'idle')];
  s1[2].mode = 'min'; s1[2].minFrom = 'tile'; s1[2].home = { near: s1[1].id, dir: 'v', after: true };
  const S0 = (id, ws, title, cwd, branch, windows, tree, extra = {}) => ({ id, ws, title, cwd, branch, windows, tree, ...extra });
  return {
    ws: [
      { id: 'def', name: 'Default', color: '#8ABEB7', closed: false },
      { id: 'fe', name: 'Frontend', color: '#B294BB', closed: false },
      { id: 'inf', name: 'Infra (k8s)', color: '#F0C674', closed: false },
    ],
    sessions: [
      S0('s1', 'def', 'tako', '~/tako', 'main ±2', s1, split('h', leaf(s1[0].id), leaf(s1[1].id), .45)),
      S0('s2', 'def', 'tako-core tests', '~/tako-core', 'feat/sidebar ±3', s2, leaf(s2[0].id), { unread: true }),
      S0('s8', 'def', 'codex review', '~/tako-core', 'feat/sidebar ±3', s8, leaf(s8[0].id)),
      S0('s5', 'def', 'psql migrations', '~/tako-db', 'main', s5, leaf(s5[0].id)),
      S0('s3', 'fe', 'web-ui', '~/web-ui', 'design/tokens', s3, split('v', leaf(s3[0].id), leaf(s3[1].id), .4), { ports: ':3000', showPorts: true }),
      S0('s6', 'fe', 'gemini · a11y audit', '~/web-ui', 'a11y', s6, leaf(s6[0].id)),
      S0('s4', 'inf', 'prod-db', 'ssh prod-db', '', s4, leaf(s4[0].id)),
      S0('s9', 'inf', 'voice-p.log', '~/logs', '', s9, leaf(s9[0].id)),
      S0('s7', 'inf', 'prod-1', 'ssh prod-1', '', s7, leaf(s7[0].id), { offline: true }),
    ],
    active: 's1', focus: s1[1].id, z: {}, measure: false,
  };
}
let S = initialState();
let zTop = 10;
const cur = () => S.sessions.find(s => s.id === S.active);
const findWin = id => { for (const s of S.sessions) { const w = s.windows.find(w => w.id === id); if (w) return [s, w]; } return [null, null]; };

// ---------- tree ops ----------
function leaves(n, out = []) { if (!n) return out; if (n.t === 'leaf') out.push(n.id); else { leaves(n.a, out); leaves(n.b, out); } return out; }
function parentOf(n, id, p = null) { if (!n) return null; if (n.t === 'leaf') return n.id === id ? { p } : null; return parentOf(n.a, id, n) || parentOf(n.b, id, n); }
function removeLeaf(s, id) { // returns where it was, for re-insert
  const t = s.tree; if (!t) return null;
  if (t.t === 'leaf') { if (t.id === id) { s.tree = null; return { root: true }; } return null; }
  const walk = (n, gp) => {
    if (n.t !== 'split') return null;
    for (const side of ['a', 'b']) {
      const c = n[side];
      if (c.t === 'leaf' && c.id === id) {
        const sib = side === 'a' ? n.b : n.a;
        if (!gp) s.tree = sib; else gp.node[gp.side] = sib;
        return { near: leaves(sib)[0], dir: n.dir, after: side === 'b', r: side === 'a' ? n.r : 1 - n.r };
      }
      const r = walk(c, { node: n, side }); if (r) return r;
    }
    return null;
  };
  return walk(t, null);
}
function replaceLeaf(n, id, f) {
  if (!n) return n;
  if (n.t === 'leaf') return n.id === id ? f(n) : n;
  n.a = replaceLeaf(n.a, id, f); n.b = replaceLeaf(n.b, id, f); return n;
}
function insertNear(s, newId, nearId, dir, after, r = .5) {
  if (!s.tree) { s.tree = leaf(newId); return; }
  if (!nearId || !leaves(s.tree).includes(nearId)) { insertEdge(s, newId, dir, after); return; }
  s.tree = replaceLeaf(s.tree, nearId, old => after ? split(dir, old, leaf(newId), 1 - r) : split(dir, leaf(newId), old, r));
}
function insertEdge(s, newId, dir, after) {
  s.tree = !s.tree ? leaf(newId) : after ? split(dir, s.tree, leaf(newId), .5) : split(dir, leaf(newId), s.tree, .5);
}
const clone = n => n && JSON.parse(JSON.stringify(n));

// ---------- layout ----------
function cbounds() { return { w: canvas.clientWidth, h: canvas.clientHeight }; }
function area() { const { w, h } = cbounds(); return { x: GAP, y: GAP, w: w - 2 * GAP, h: h - 2 * GAP }; }
function minSize(n, dir) {
  if (n.t === 'leaf') return dir === 'h' ? MINW : MINH;
  const a = minSize(n.a, dir), b = minSize(n.b, dir);
  return n.dir === dir ? a + b + GAP : Math.max(a, b);
}
function layout(n, R, rects = {}, divs = []) {
  if (!n) return { rects, divs };
  if (n.t === 'leaf') { rects[n.id] = R; return { rects, divs }; }
  if (n.dir === 'h') {
    const aw = Math.round((R.w - GAP) * n.r);
    layout(n.a, { x: R.x, y: R.y, w: aw, h: R.h }, rects, divs);
    layout(n.b, { x: R.x + aw + GAP, y: R.y, w: R.w - aw - GAP, h: R.h }, rects, divs);
    divs.push({ node: n, R, rect: { x: R.x + aw, y: R.y, w: GAP, h: R.h } });
  } else {
    const ah = Math.round((R.h - GAP) * n.r);
    layout(n.a, { x: R.x, y: R.y, w: R.w, h: ah }, rects, divs);
    layout(n.b, { x: R.x, y: R.y + ah + GAP, w: R.w, h: R.h - ah - GAP }, rects, divs);
    divs.push({ node: n, R, rect: { x: R.x, y: R.y + ah, w: R.w, h: GAP } });
  }
  return { rects, divs };
}
let L = { rects: {}, divs: [] };
function winRect(w) { return w.max ? area() : w.mode === 'float' ? w.rect : L.rects[w.id]; }

// ---------- status helpers (1b + 5a) ----------
// window.status: idle | working | progress (p) | waiting (ask) | done | error (code) | live (prog, flow, quiet)
const PRI = ['ghost', 'error', 'waiting', 'working', 'progress', 'done', 'live', 'idle'];
const RINGCLS = { idle: 'r-idle', working: 'r-work', progress: 'r-prog', waiting: 'r-attn', done: 'r-done', error: 'r-err', ghost: 'r-ghost' };
const RING = RINGCLS; // legacy name used by toasts
const ringOf = w => w.status === 'live' ? (w.flow ? 'r-flow' : 'r-calm') : RINGCLS[w.status];
const pVar = w => w.status === 'progress' ? `--p:${Math.round(w.p || 0)}` : '';
function chipOf(w) {
  switch (w.status) {
    case 'waiting': return ['c-attn', 'ждёт тебя'];
    case 'error': return ['c-err', 'exit ' + (w.code || 101)];
    case 'done': return ['c-ok', 'exit 0'];
    case 'working': return ['c-work', 'работает'];
    case 'progress': return ['c-work', Math.round(w.p || 0) + '%'];
    case 'live': return w.flow ? ['c-live', w.prog || 'живёт'] : ['c-quiet', 'тихо ' + (w.quiet || 1) + 'm'];
    default: return null;
  }
}
const topWin = s => { let best = null; for (const w of s.windows) if (!best || PRI.indexOf(w.status) < PRI.indexOf(best.status)) best = w; return best; };
const sessionStatus = s => s.offline ? 'ghost' : (topWin(s) ? topWin(s).status : 'idle');
const sessionRing = s => s.offline ? 'r-ghost' : (topWin(s) ? ringOf(topWin(s)) : 'r-idle');
function phaseVars(el) { const t = performance.now(); for (const T of [900, 1000, 1600, 2200]) el.style.setProperty('--ph' + T, -(t % T) + 'ms'); }
