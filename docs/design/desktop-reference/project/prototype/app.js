'use strict';
// Tako desktop prototype — windows, dock, statuses, boot (classic script; shares globals with the other prototype/*.js)
// ---------- windows DOM ----------
const els = new Map();
const ICON = {
  min: '<svg viewBox="0 0 12 12"><path d="M2.5 6h7"/></svg>',
  fl: '<svg viewBox="0 0 12 12"><rect x="1.8" y="3.8" width="6.4" height="6.4" rx="1.3"/><path d="M4.2 1.8h4.7a1.3 1.3 0 0 1 1.3 1.3v4.7"/></svg>',
  max: '<svg viewBox="0 0 12 12"><path d="M7 2.5h2.5V5M5 9.5H2.5V7M9.5 2.5 6.8 5.2M2.5 9.5l2.7-2.7"/></svg>',
  unmax: '<svg viewBox="0 0 12 12"><path d="M9.5 5H7V2.5M2.5 7H5v2.5M7 5l2.7-2.7M5 7 2.3 9.7"/></svg>',
  x: '<svg viewBox="0 0 12 12"><path d="M3 3l6 6M9 3l-6 6"/></svg>',
  restore: '<svg viewBox="0 0 12 12"><path d="M3 7.5 6 4.5l3 3"/></svg>',
};
function mount(w, opening) {
  const el = document.createElement('div');
  el.className = 'fw' + (opening && !reduce ? ' opening' : '');
  el.dataset.id = w.id;
  el.innerHTML = `
    <div class="fw-hd"><span class="ring"></span><span class="t"></span><span class="cwd"></span><span class="src"></span><span class="chip"></span>
      <div class="fw-btns">
        <button class="wb mn" title="Свернуть в кружок ⌘M">${ICON.min}</button>
        <button class="wb fl" title="Отлепить: поверх, во всех сессиях">${ICON.fl}</button>
        <button class="wb mx" title="На всё поле ⌃⌘F">${ICON.max}</button>
        <button class="wb x" title="Закрыть ⌘W">${ICON.x}</button>
      </div></div>
    <div class="fw-body"></div>
    <div class="dims"></div>
    ${['n', 's', 'e', 'w', 'nw', 'ne', 'sw', 'se'].map(d => `<div class="rz ${d}" data-d="${d}"></div>`).join('')}`;
  canvas.insertBefore(el, snapPrev);
  els.set(w.id, el);
  if (opening) el.addEventListener('animationend', () => el.classList.remove('opening'), { once: true });
  el.addEventListener('pointerdown', e => onDown(e, w.id), true);
  el.querySelector('.mn').addEventListener('click', e => { e.stopPropagation(); minimize(w.id); });
  el.querySelector('.fl').addEventListener('click', e => { e.stopPropagation(); toggleFloat(w.id); });
  el.querySelector('.mx').addEventListener('click', e => { e.stopPropagation(); toggleMax(w.id); });
  el.querySelector('.x').addEventListener('click', e => { e.stopPropagation(); askClose(w.id); });
  el.querySelector('.fw-hd').addEventListener('dblclick', e => { if (!e.target.closest('.wb')) toggleMax(w.id); });
  if (!S.z[w.id]) S.z[w.id] = ++zTop;
  return el;
}
function paint(w) {
  const el = els.get(w.id); if (!el) return;
  const r = winRect(w); if (!r) return;
  const z = (w.max ? 5000 : w.mode === 'float' ? 2000 : 10) + (S.z[w.id] || 0);
  Object.assign(el.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px', zIndex: z });
  el.classList.toggle('focus', S.focus === w.id);
  el.classList.toggle('float', w.mode === 'float');
  el.classList.toggle('max', w.max);
  el.classList.toggle('glow', w.status === 'waiting');
  el.classList.toggle('sweep', w.status === 'working');
  el.classList.toggle('errline', w.status === 'error');
  const prev = el.dataset.st, ring = el.querySelector('.fw-hd .ring');
  const fx = prev && prev !== w.status ? (w.status === 'done' ? ' pop' : w.status === 'error' ? ' fx-shake' : '') : (/ (pop|fx-shake)/.exec(ring.className) || [''])[0];
  ring.className = 'ring ' + ringOf(w) + fx;
  ring.setAttribute('style', pVar(w));
  if (fx && !ring._fx) { ring._fx = 1; setTimeout(() => { ring._fx = 0; ring.className = 'ring ' + ringOf(w); }, 800); }
  el.querySelector('.t').textContent = w.title;
  el.querySelector('.cwd').textContent = w.cwd;
  const src = el.querySelector('.src'), ses = findWin(w.id)[0];
  src.style.display = w.mode === 'float' ? '' : 'none'; src.textContent = ses ? ses.title : '';
  src.title = 'из сессии ' + (ses ? ses.title : '') + ' · видно во всех сессиях';
  const chip = el.querySelector('.chip'), c = chipOf(w);
  chip.className = 'chip ' + (c ? c[0] : ''); chip.textContent = c ? c[1] : ''; chip.style.display = c ? '' : 'none';
  const hd = el.querySelector('.fw-hd');
  if (prev !== w.status) {
    if (w.status === 'done' && prev) { const sh = document.createElement('span'); sh.className = 'fx-shim'; el.appendChild(sh); setTimeout(() => sh.remove(), 1000); }
    el.querySelector('.fw-body').innerHTML = CONTENT[w.kind] + (w.status === 'done' && w.kind === 'build' ? `<span class="b">└─</span> ✨ <span class="g">release profile completed</span>\n<span class="d">╰</span> <span class="e">❯</span> <span class="cur"></span>` : '');
  }
  el.dataset.st = w.status;
  let pl = hd.querySelector('.pline');
  if (w.status === 'progress') { if (!pl) { pl = document.createElement('span'); pl.className = 'pline'; hd.appendChild(pl); } pl.style.width = (w.p || 0) + '%'; }
  else if (pl) pl.remove();
  const mx = el.querySelector('.mx');
  if (mx.dataset.m !== String(w.max)) { mx.dataset.m = String(w.max); mx.innerHTML = w.max ? ICON.unmax : ICON.max; mx.title = w.max ? 'Вернуть в ячейку ⌃⌘F' : 'На всё поле ⌃⌘F'; }
  const fl = el.querySelector('.fl');
  fl.classList.toggle('on', w.mode === 'float');
  fl.title = w.mode === 'float' ? 'Вернуть в сетку' : 'Отлепить: поверх, во всех сессиях';
  el.querySelector('.dims').textContent = Math.round(r.w) + ' × ' + Math.round(r.h);
}
function renderDividers() {
  canvas.querySelectorAll('.div').forEach(d => d.remove());
  L.divs.forEach((d, i) => {
    const el = document.createElement('div');
    el.className = 'div ' + d.node.dir;
    Object.assign(el.style, { left: d.rect.x + 'px', top: d.rect.y + 'px', width: d.rect.w + 'px', height: d.rect.h + 'px' });
    el.addEventListener('pointerdown', e => onDivDown(e, d, el));
    canvas.insertBefore(el, snapPrev);
  });
}
function render(animate) {
  const s = cur();
  L = layout(s.tree, area());
  const shown = [...s.windows.filter(w => w.mode === 'tile'), ...S.sessions.flatMap(x => x.windows.filter(w => w.mode === 'float'))];
  for (const [id, el] of [...els]) if (!shown.find(w => w.id === id)) { el.remove(); els.delete(id); }
  for (const w of shown) {
    if (!els.has(w.id)) mount(w);
    const el = els.get(w.id);
    if (animate && !reduce) { el.classList.add('anim'); clearTimeout(el._t); el._t = setTimeout(() => el.classList.remove('anim'), 240); }
    paint(w);
  }
  renderDividers();
  emptyEl.classList.toggle('show', !s.windows.some(w => w.mode !== 'min'));
  renderDock();
  renderSidebar();
  if (S.measure) drawMeasure();
}
function focusWin(id) { S.focus = id; S.z[id] = ++zTop; render(); }
function switchSession(id) {
  if (S.active === id) return;
  const prev = S.sessions.find(x => x.id === S.active); if (prev) prev.confirm = false;
  S.active = id;
  const sNow = cur(); if (sNow) sNow.unread = false;
  const vis = cur().windows.filter(w => w.mode !== 'min');
  S.focus = vis.length ? vis[0].id : null;
  render();
}

// ---------- divider drag ----------
function onDivDown(e, d, el) {
  e.preventDefault();
  const n = d.node, R = d.R, horiz = n.dir === 'h';
  const total = (horiz ? R.w : R.h) - GAP;
  const minA = minSize(n.a, n.dir), minB = minSize(n.b, n.dir);
  el.classList.add('drag');
  document.body.style.cursor = horiz ? 'col-resize' : 'row-resize';
  const cr = canvas.getBoundingClientRect();
  const move = ev => {
    const p = horiz ? ev.clientX - cr.left - R.x - GAP / 2 : ev.clientY - cr.top - R.y - GAP / 2;
    n.r = Math.min(Math.max(p, minA), total - minB) / total;
    L = layout(cur().tree, area());
    for (const w of cur().windows) if (w.mode === 'tile') { paint(w); const we = els.get(w.id); we && we.classList.add('sizing'); }
    L.divs.forEach(dd => { if (dd.node === n) Object.assign(el.style, { left: dd.rect.x + 'px', top: dd.rect.y + 'px' }); });
  };
  const up = () => {
    removeEventListener('pointermove', move);
    document.body.style.cursor = '';
    els.forEach(we => we.classList.remove('sizing'));
    render();
  };
  addEventListener('pointermove', move);
  addEventListener('pointerup', up, { once: true });
}

// ---------- drop targets ----------
function dropTarget(px, py, dragId) {
  const s = cur(), { w: CW, h: CH } = cbounds();
  let t = null;
  if (px < EDGE) t = { edge: true, dir: 'h', after: false, hint: 'вся левая сторона' };
  else if (px > CW - EDGE) t = { edge: true, dir: 'h', after: true, hint: 'вся правая сторона' };
  else if (py < EDGE) t = { edge: true, dir: 'v', after: false, hint: 'весь верх' };
  else if (py > CH - EDGE) t = { edge: true, dir: 'v', after: true, hint: 'весь низ' };
  else {
    const id = Object.keys(L.rects).find(k => { const r = L.rects[k]; return k !== dragId && px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h; });
    if (!id) return null;
    const r = L.rects[id], fx = (px - r.x) / r.w, fy = (py - r.y) / r.h;
    const d = [['l', fx], ['r', 1 - fx], ['t', fy], ['b', 1 - fy]].sort((a, b) => a[1] - b[1])[0];
    if (d[1] > .35) return null; // middle of a window: no split, it stays on top
    const dir = d[0] === 'l' || d[0] === 'r' ? 'h' : 'v';
    if (dir === 'h' && r.w < 2 * MINW + GAP) return null;
    if (dir === 'v' && r.h < 2 * MINH + GAP) return null;
    const [, w] = findWin(id);
    t = { near: id, dir, after: d[0] === 'r' || d[0] === 'b', hint: { l: 'слева от', r: 'справа от', t: 'над', b: 'под' }[d[0]] + ' «' + w.title + '»' };
  }
  // simulate on a copy of the tree to get exact rects
  const sim = { tree: clone(s.tree) };
  if (t.edge) insertEdge(sim, dragId, t.dir, t.after); else insertNear(sim, dragId, t.near, t.dir, t.after);
  const lay = layout(sim.tree, area());
  t.rect = lay.rects[dragId];
  if (t.near) t.other = lay.rects[t.near];
  return t;
}
function showDrop(t) {
  snapPrev.classList.toggle('show', !!t);
  snapOther.classList.toggle('show', !!(t && t.other));
  snapHint.classList.toggle('show', !!t);
  if (!t) return;
  const put = (el, r) => Object.assign(el.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
  put(snapPrev, t.rect); if (t.other) put(snapOther, t.other);
  snapHint.textContent = t.hint;
  Object.assign(snapHint.style, { left: (t.rect.x + t.rect.w / 2) + 'px', top: (t.rect.y + t.rect.h / 2) + 'px' });
}

// ---------- window drag & float resize ----------
let op = null;
function floatSizeFrom(r) { return { w: Math.max(MINW, Math.min(r.w * .8, 640)), h: Math.max(MINH, Math.min(r.h * .8, 400)) }; }
function onDown(e, id) {
  if (e.button !== 0) return;
  const [s, w] = findWin(id);
  if (S.focus !== id) focusWin(id);
  if (e.target.closest('.wb,.confirm')) return;
  const rz = e.target.closest('.rz'), onHdr = e.target.closest('.fw-hd');
  if (!rz && !onHdr) return;
  e.preventDefault();
  const cr = canvas.getBoundingClientRect(), r = winRect(w);
  op = { id, mode: rz ? rz.dataset.d : 'move', sx: e.clientX, sy: e.clientY, r0: { ...r }, moved: false,
         fx: (e.clientX - cr.left - r.x) / r.w, gy: e.clientY - cr.top - r.y };
  if (rz) els.get(id).classList.add('sizing');
  document.body.style.cursor = rz ? getComputedStyle(rz).cursor : 'default';
  addEventListener('pointermove', onMove);
  addEventListener('pointerup', onUp, { once: true });
}
function onMove(e) {
  if (!op) return;
  const [s, w] = findWin(op.id), { w: CW, h: CH } = cbounds(), cr = canvas.getBoundingClientRect();
  const px = e.clientX - cr.left, py = e.clientY - cr.top;
  if (op.mode === 'move') {
    if (!op.moved) {
      if (Math.hypot(e.clientX - op.sx, e.clientY - op.sy) < 5) return;
      op.moved = true;
      const el = els.get(w.id);
      el.classList.remove('anim'); el.classList.add('dragging');
      if (w.max) w.max = false;
      if (w.mode === 'tile') {
        // leave the grid: the rest closes the gap, this one floats under the cursor
        op.from = 'tile';
        w.home = op.home = removeLeaf(s, w.id);
        const sz = floatSizeFrom(op.r0);
        w.mode = 'float';
        op.r0 = { x: px - sz.w * op.fx, y: py - Math.min(op.gy, HDR - 6), w: sz.w, h: sz.h };
        op.sx = e.clientX; op.sy = e.clientY;
        S.z[w.id] = ++zTop;
        render(true);
        el.classList.remove('anim');
      }
    }
    const r0 = op.r0, dx = e.clientX - op.sx, dy = e.clientY - op.sy;
    w.rect = { x: Math.min(Math.max(r0.x + dx, 80 - r0.w), CW - 80), y: Math.min(Math.max(r0.y + dy, 0), CH - HDR), w: r0.w, h: r0.h };
    op.drop = e.altKey ? null : dropTarget(px, py, w.id);
    showDrop(op.drop);
    paint(w);
    return;
  }
  // float resize from 8 sides
  const r0 = op.r0, d = op.mode, dx = e.clientX - op.sx, dy = e.clientY - op.sy;
  let { x, y, w: ww, h: hh } = r0;
  if (d.includes('e')) ww = Math.max(MINW, Math.min(r0.w + dx, CW - r0.x));
  if (d.includes('s')) hh = Math.max(MINH, Math.min(r0.h + dy, CH - r0.y));
  if (d.includes('w')) { const nx = Math.min(Math.max(r0.x + dx, 0), r0.x + r0.w - MINW); ww = r0.w + (r0.x - nx); x = nx; }
  if (d.includes('n')) { const ny = Math.min(Math.max(r0.y + dy, 0), r0.y + r0.h - MINH); hh = r0.h + (r0.y - ny); y = ny; }
  w.rect = { x, y, w: ww, h: hh };
  paint(w);
}
function onUp() {
  removeEventListener('pointermove', onMove);
  document.body.style.cursor = '';
  if (!op) return;
  const [s, w] = findWin(op.id), el = els.get(op.id);
  if (el) el.classList.remove('sizing', 'dragging');
  if (op.mode === 'move' && op.moved && w) {
    const t = op.drop;
    if (t) {
      if (s !== cur()) { moveTo(w, s, cur()); }
      const s2 = cur(); void s2;
      if (t.edge) insertEdge(cur(), w.id, t.dir, t.after); else insertNear(cur(), w.id, t.near, t.dir, t.after);
      w.mode = 'tile';
      render(true);
    } else render();
  }
  showDrop(null);
  op = null;
}

// ---------- float / max ----------
function bestNear(s, exceptId) {
  const ids = leaves(s.tree).filter(i => i !== exceptId);
  if (!ids.length) return null;
  if (S.focus && ids.includes(S.focus)) return S.focus;
  return ids.sort((a, b) => (L.rects[b].w * L.rects[b].h) - (L.rects[a].w * L.rects[a].h))[0];
}
function defaultDir(r) { return r && r.w >= 2 * MINW + GAP ? 'h' : 'v'; }
function dockIntoGrid(s, w, home) {
  if (home && home.root && !s.tree) { s.tree = leaf(w.id); }
  else if (home && home.near && leaves(s.tree).includes(home.near)) insertNear(s, w.id, home.near, home.dir, home.after, home.r || .5);
  else { const n = bestNear(s, w.id); insertNear(s, w.id, n, defaultDir(n && L.rects[n]), true); }
  w.mode = 'tile';
}
function toggleFloat(id) {
  const [s, w] = findWin(id);
  w.max = false;
  if (w.mode === 'tile') {
    const r = L.rects[w.id];
    w.home = removeLeaf(s, w.id);
    const sz = floatSizeFrom(r);
    w.rect = { x: r.x + (r.w - sz.w) / 2 + 24, y: r.y + (r.h - sz.h) / 2 + 24, w: sz.w, h: sz.h };
    w.mode = 'float';
  } else if (w.mode === 'float') {
    if (s !== cur()) { moveTo(w, s, cur()); w.home = null; }
    dockIntoGrid(cur(), w, w.home);
  }
  S.focus = id; S.z[id] = ++zTop;
  render(true);
}
function moveTo(w, from, to) { from.windows = from.windows.filter(x => x !== w); to.windows.push(w); }
function toggleMax(id) {
  const [, w] = findWin(id);
  w.max = !w.max;
  S.focus = id; S.z[id] = ++zTop;
  render(true);
}
function tileAll() {
  const s = cur();
  s.windows.filter(w => w.mode === 'float').forEach(w => { w.max = false; dockIntoGrid(s, w, null); });
  s.windows.forEach(w => w.max = false);
  render(true);
}

// ---------- minimize to a circle ----------
function dotRect(id) {
  const c = dockEl.querySelector(`[data-w="${id}"]`), cr = canvas.getBoundingClientRect();
  if (!c) return { x: cr.width - 214, y: cr.height - 44, w: 200, h: 30 };
  const r = c.getBoundingClientRect();
  return { x: r.left - cr.left, y: r.top - cr.top, w: r.width, h: r.height };
}
function flyGhost(from, to, dur, done) {
  const g = document.createElement('div');
  g.className = 'ghost'; g.innerHTML = '<div class="gh"></div>';
  canvas.appendChild(g);
  if (reduce) { g.remove(); done(); return; }
  const k = r => ({ left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px', borderRadius: r.r + 'px', opacity: r.o });
  g.animate([k(from), k(to)], { duration: dur, easing: 'cubic-bezier(.2,.8,.2,1)' }).onfinish = () => { g.remove(); done(); };
}
function minimize(id) {
  const [s, w] = findWin(id);
  const r = winRect(w);
  w.minFrom = w.mode; w.max = false;
  if (w.mode === 'tile') w.home = removeLeaf(s, w.id);
  w.mode = 'min';
  if (S.focus === id) { const v = s.windows.filter(x => x.mode !== 'min').sort((a, b) => (S.z[b.id] || 0) - (S.z[a.id] || 0)); S.focus = v[0] ? v[0].id : null; }
  render(true);
  const dot = dockEl.querySelector(`[data-w="${id}"]`);
  if (dot) dot.style.visibility = 'hidden';
  flyGhost({ ...r, r: 10, o: 1 }, { ...dotRect(id), r: 8, o: .6 }, 280, () => { if (dot) dot.style.visibility = ''; });
}
function restore(id) {
  const [s, w] = findWin(id);
  const from = dotRect(id);
  if (w.minFrom === 'float') w.mode = 'float'; else dockIntoGrid(s, w, w.home);
  S.focus = id; S.z[id] = ++zTop;
  const ws = cur().windows; // hide the window until the ghost lands
  render(true);
  const el = els.get(id); if (el) el.style.visibility = 'hidden';
  flyGhost({ ...from, r: 8, o: .6 }, { ...winRect(w), r: 10, o: 1 }, 260, () => { const e2 = els.get(id); if (e2) e2.style.visibility = ''; });
  void ws;
}
function renderDock() {
  const mins = cur().windows.filter(w => w.mode === 'min');
  for (const c of [...dockEl.children]) if (!mins.find(w => w.id === c.dataset.w)) c.remove();
  for (const w of mins) {
    let c = dockEl.querySelector(`[data-w="${w.id}"]`);
    if (!c) {
      c = document.createElement('div'); c.className = 'pill'; c.dataset.w = w.id;
      c.innerHTML = `<span class="ring sm"></span><span class="t"></span><span class="cwd"></span><span class="up" title="Развернуть обратно">${ICON.restore}</span>`;
      c.addEventListener('click', () => restore(w.id));
      dockEl.appendChild(c);
    }
    c.querySelector('.ring').className = 'ring sm ' + ringOf(w);
    c.querySelector('.ring').setAttribute('style', pVar(w));
    c.classList.toggle('sweep', w.status === 'working');
    c.querySelector('.t').textContent = w.title;
    c.querySelector('.cwd').textContent = w.cwd;
    c.title = `${w.title} — ${w.cwd} · клик вернёт терминал на место`;
    c.classList.toggle('glow', w.status === 'waiting');
    c.classList.toggle('errline', w.status === 'error');
  }
}

// ---------- close ----------
function askClose(id) {
  const [, w] = findWin(id), el = els.get(id);
  if (w.status !== 'working' && w.status !== 'waiting') { closeWin(id); return; }
  if (el.querySelector('.confirm')) return;
  const c = document.createElement('div'); c.className = 'confirm';
  c.innerHTML = `<b>${w.status === 'waiting' ? 'Агент ждёт ответа' : 'Процесс ещё работает'}</b>${w.title} завершится вместе с терминалом.<div class="acts"><button class="no">Отмена</button><button class="dang">Закрыть</button></div>`;
  el.appendChild(c);
  c.querySelector('.no').onclick = e => { e.stopPropagation(); c.remove(); };
  c.querySelector('.dang').onclick = e => { e.stopPropagation(); closeWin(id); };
}
function closeWin(id) {
  const [s, w] = findWin(id), el = els.get(id);
  const finish = () => {
    if (w.mode === 'tile') removeLeaf(s, id);
    s.windows = s.windows.filter(x => x !== w);
    if (el) { el.remove(); els.delete(id); }
    if (S.focus === id) { const v = s.windows.filter(x => x.mode !== 'min').sort((a, b) => (S.z[b.id] || 0) - (S.z[a.id] || 0)); S.focus = v[0] ? v[0].id : null; }
    render(true);
  };
  if (el && !reduce) { el.classList.add('closing'); setTimeout(finish, 140); } else finish();
}

// ---------- new window / session ----------
const KINDS = [['fish', 'shell'], ['claude', 'claude'], ['mitts build', 'build'], ['npm run dev', 'dev']];
let kindIdx = 0;
function newWindow() {
  const s = cur();
  const [title, kind] = KINDS[kindIdx++ % KINDS.length];
  const w = W(title, s.cwd, kind, kind === 'build' ? 'working' : 'idle');
  s.windows.push(w);
  const n = bestNear(s, null);
  const nr = n && L.rects[n];
  if (nr && nr.w < 2 * MINW + GAP && nr.h < 2 * MINH + GAP) {
    // no room to split: open on top instead
    const A = area(); w.mode = 'float';
    w.rect = { x: A.x + A.w / 2 - 300, y: A.y + A.h / 2 - 180, w: 600, h: 360 };
  } else insertNear(s, w.id, n, defaultDir(nr), true);
  S.focus = w.id; S.z[w.id] = ++zTop;
  mount(w, true);
  render(true);
}
function newSession(wsId) {
  wsId = wsId || (cur() ? cur().ws : 'def');
  const n = S.sessions.length + 1;
  const w = W('fish', '~', 'shell', 'idle');
  const ns = { id: 's' + Date.now(), ws: wsId, title: 'session ' + n, cwd: '~', branch: '', windows: [w], tree: leaf(w.id) };
  const last = S.sessions.map(x => x.ws).lastIndexOf(wsId);
  S.sessions.splice(last + 1, 0, ns);
  const ws = S.ws.find(x => x.id === wsId); if (ws) ws.closed = false;
  SB.q = ''; qEl.value = ''; SB.seg = 'all';
  switchSession(ns.id);
  startRename('s', ns.id);
}

// ---------- statuses & notifications ----------
function setStatus(id, st) {
  const [s, w] = findWin(id); if (!w) return;
  if (st === 'offline') { s.offline = true; render(); return; }
  if (s.offline && st !== 'offline') s.offline = false;
  const was = w.status; w.status = st;
  if (st === 'progress') { w.p = was === 'progress' ? w.p : 4; w.auto = true; }
  if (st === 'live') { w.prog = w.prog || (w.kind === 'dev' ? 'vite' : w.kind === 'ssh' ? 'ssh' : w.title.split(' ')[0]); w.quiet = w.quiet || 1; w.flow = false; }
  if (was !== st && (st === 'done' || st === 'error')) w.flashAt = performance.now();
  if (st === 'error' && !w.code) w.code = w.kind === 'dev' ? 1 : 101;
  if (s.id !== S.active && ['done', 'error', 'waiting'].includes(st)) s.unread = true;
  const visible = s.id === S.active && w.mode !== 'min' && S.focus === id && document.hasFocus();
  if (was !== st && ['waiting', 'done', 'error'].includes(st) && !visible) notify(w, s);
  render();
}
function notify(w, s) {
  if (!['waiting', 'done', 'error'].includes(w.status)) return;
  const TXT = { waiting: ['ждёт тебя', 'Allow command: mitts test -p auth?'], done: ['готово · exit 0', s.title], error: ['ошибка · exit ' + (w.code || 101), 'процесс завершился с ошибкой'] }[w.status];
  const where = w.mode === 'min' ? 'свёрнуто' : s.id !== S.active ? s.title : 'в фоне';
  const t = document.createElement('div'); t.className = 'toast';
  t.innerHTML = `<span class="ring sm ${ringOf(w)}"></span><div class="tx"><div class="h">${w.title} — ${TXT[0]}</div><div class="m">${TXT[1]}</div></div><span class="go">${where} →</span>`;
  t.onclick = () => { goTo(w.id); dismiss(t); };
  toastsEl.prepend(t);
  while (toastsEl.children.length > 3) toastsEl.lastChild.remove();
  setTimeout(() => dismiss(t), 4000);
}
function dismiss(t) { if (!t.isConnected) return; t.classList.add('out'); setTimeout(() => t.remove(), 180); }
function goTo(id) {
  const [s, w] = findWin(id); if (!w) return;
  if (s.id !== S.active) switchSession(s.id);
  if (w.mode === 'min') restore(id); else focusWin(id);
}

// ---------- measure ----------
function drawMeasure() {
  canvas.querySelectorAll('.mlab').forEach(n => n.remove());
  if (!S.measure) return;
  const lab = (x, y, t) => canvas.insertAdjacentHTML('beforeend', `<div class="mlab" style="left:${x}px;top:${y}px">${t}</div>`);
  lab(GAP + 4, GAP + 4, `поле ${canvas.clientWidth} × ${canvas.clientHeight} · сайдбар 240 · зазор 8`);
  for (const w of cur().windows) {
    if (w.mode === 'min') continue;
    const r = winRect(w); if (!r) continue;
    lab(r.x + 8, r.y + r.h - 22, `${w.mode === 'float' ? 'поверх' : 'ячейка'} ${Math.round(r.w)}×${Math.round(r.h)}`);
  }
  if (dockEl.children.length) { const r = dotRect(dockEl.children[0].dataset.w); lab(r.x, r.y - 22, 'плашка 30 · поверх поля · от края 14'); }
}

// ---------- demo bar & keys ----------
const notesEl = $('#notes');
document.addEventListener('click', e => {
  const b = e.target.closest('[data-act],[data-st]'); if (!b) return;
  if (b.dataset.st) { if (S.focus) setStatus(S.focus, b.dataset.st); return; }
  const a = b.dataset.act;
  if (a === 'new') newWindow();
  else if (a === 'newsession') newSession();
  else if (a === 'tile') tileAll();
  else if (a === 'bgerr') {
    const s = S.sessions.find(x => x.id !== S.active && !x.offline && x.windows.every(w => w.status !== 'error'));
    if (s) { const w = s.windows[0]; setStatus(w.id, 'working'); setTimeout(() => setStatus(w.id, 'error'), 900); }
  }
  else if (a === 'offline') { const s = S.sessions.find(x => x.id === 's4' && !x.offline) || S.sessions.find(x => !x.offline && x.id !== S.active); if (s) { s.offline = true; renderSidebar(); } }
  else if (a === 'closeall') cur().windows.slice().forEach(w => closeWin(w.id));
  else if (a === 'measure') { S.measure = !S.measure; app.classList.toggle('measure', S.measure); canvas.classList.toggle('grid', S.measure); b.classList.toggle('on', S.measure); drawMeasure(); }
  else if (a === 'rm') { document.body.classList.toggle('rm'); b.classList.toggle('on'); }
  else if (a === 'legend') { renderLegend(); $('#legend').classList.toggle('show'); b.classList.toggle('on'); }
  else if (a === 'notes') { notesEl.classList.toggle('show'); b.classList.toggle('on'); }
  else if (a === 'reset') location.reload();
  else if (a === 'bgwait') {
    const s = cur(); const w = s.windows.find(w => w.mode !== 'min' && w.id !== S.focus) || s.windows.find(w => w.id !== S.focus);
    if (w) { setStatus(w.id, 'working'); setTimeout(() => setStatus(w.id, 'waiting'), 900); }
  }
  else if (a === 'shelfdone') {
    const s = cur(); let w = s.windows.find(w => w.mode === 'min');
    if (!w) { w = s.windows.find(x => x.id !== S.focus) || s.windows[0]; if (!w) return; w.status = 'working'; minimize(w.id); }
    else setStatus(w.id, 'working');
    setTimeout(() => setStatus(w.id, 'done'), 1400);
  }
});
addEventListener('keydown', e => {
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); qEl.focus(); qEl.select(); return; }
  if (e.target.closest && e.target.closest('input,textarea')) return;
  if (e.key === 'Escape') { closeCtx(); document.querySelectorAll('.confirm').forEach(c => c.remove()); if (SB.kb) { SB.kb = null; renderSidebar(); } return; }
  if (e.altKey && e.key === 'Enter') { e.preventDefault(); nextWaiting(); return; }
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); moveKb(e.key === 'ArrowDown' ? 1 : -1); return; }
  if (e.key === 'Enter' && SB.kb) { const id = SB.kb; SB.kb = null; switchSession(id); renderSidebar(); return; }
  if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') { const s = S.sessions.find(x => x.id === (SB.kb || S.active)); if (s) { s.open = e.key === 'ArrowRight'; renderSidebar(); } return; }
  if (e.key === 'F2') { e.preventDefault(); startRename('s', SB.kb || S.active); return; }
  if (e.key === '/') { e.preventDefault(); qEl.focus(); return; }
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key.toLowerCase();
  if (k === 'n') newWindow();
  else if (k === 'm' && S.focus) minimize(S.focus);
  else if (k === 'f' && S.focus) toggleMax(S.focus);
  else if (k === 'p' && S.focus) toggleFloat(S.focus);
  else if (k === 't') tileAll();
  else if (k === 'w' && S.focus) askClose(S.focus);
});
addEventListener('resize', () => render());
addEventListener('blur', () => app.classList.add('blur'));
addEventListener('focus', () => app.classList.remove('blur'));

// ---------- ticks: progress fills up, live programs print in bursts ----------
setInterval(() => {
  let changed = false;
  for (const s of S.sessions) for (const w of s.windows) {
    if (w.status === 'progress' && w.auto) {
      w.p = Math.min(100, (w.p || 0) + 1.5); changed = true;
      if (w.p >= 100) { w.auto = false; setStatus(w.id, 'done'); }
    }
  }
  if (changed) { for (const w of cur().windows) if (w.status === 'progress') paint(w); renderDock(); refreshSidebarLive(); }
}, 220);
setInterval(() => {
  const now = performance.now();
  for (const s of S.sessions) for (const w of s.windows) {
    if (w.status !== 'live') continue;
    if (w.flow && now > w.flowUntil) { w.flow = false; w.quiet = 1; }
    else if (!w.flow && Math.random() < .3) { w.flow = true; w.flowUntil = now + 900 + Math.random() * 1600; }
    paint(w);
  }
  renderDock(); refreshSidebarLive();
}, 700);

// ---------- legend: every state on a real sidebar row ----------
const LEGEND = [
  ['idle', 'покой', 'серое кольцо, ничего не движется'],
  ['working', 'работает', 'комета по рамке 2.2 s, кольцо крутится 0.9 s'],
  ['progress', 'прогресс', 'OSC 9;4: кольцо наливается, линия 2 px снизу, %'],
  ['waiting', 'ждёт тебя', 'Claw-рамка дышит 1.6 s, свечение 16 px 30%'],
  ['done', 'готово', 'зелёный блик 0.9 s один раз, кольцо подпрыгивает'],
  ['error', 'ошибка', 'красная линия 2 px, дрожь 0.4 s один раз, exit N'],
  ['live-quiet', 'живёт · тихо', 'ssh / tail молчит: тусклое Ember-кольцо, «тихо 4m»'],
  ['live-flow', 'живёт · вывод', 'на каждую порцию вывода волна от кольца'],
  ['offline', 'офлайн', 'пунктир по рамке и кольцу, «переподключить»'],
];
function renderLegend() {
  const el = $('#legend');
  const demo = {
    idle: { status: 'idle' }, working: { status: 'working', title: 'mitts build' }, progress: { status: 'progress', p: 68, title: 'mitts build' },
    waiting: { status: 'waiting', ask: 'Allow mitts test?' }, done: { status: 'done' }, error: { status: 'error', code: 101, title: 'mitts test' },
    'live-quiet': { status: 'live', prog: 'tail', quiet: 4 }, 'live-flow': { status: 'live', prog: 'ssh', flow: true }, offline: { status: 'idle' },
  };
  el.innerHTML = `<h4>Все статусы<small>та же строка сайдбара, что слева · клик «показать» ставит статус терминалу в фокусе</small></h4><div class="lg">` + LEGEND.map(([k, n, t]) => {
    const w = { id: 'lg-' + k, title: 'session', cwd: '~/tako', ...demo[k] };
    const s = { id: 'lg' + k, title: n, cwd: '~/tako', branch: 'main', windows: [w], offline: k === 'offline' };
    const st = sessionStatus(s);
    const cls = ['row', st === 'waiting' && 'waiting glow', st === 'error' && 'error errline', st === 'working' && 'sweep', s.offline && 'offline'].filter(Boolean).join(' ');
    return `<div class="lg-c"><div class="${cls}" style="--sbg:#14100E"><div class="l1"><span class="exp"></span><span class="ring ${sessionRing(s)}" style="${pVar(w)}"></span><span class="t">${esc(n)}</span></div><div class="meta">${metaOf(s)}</div>${st === 'progress' ? `<span class="pfill" style="width:calc((100% - 16px) * .68)"></span>` : ''}</div>`
      + `<div class="lg-t">${esc(t)}</div><button data-show="${k}">показать на терминале →</button></div>`;
  }).join('') + '</div>';
  phaseVars(el);
}
document.addEventListener('click', e => {
  const b = e.target.closest('[data-show]'); if (!b || !S.focus) return;
  const k = b.dataset.show;
  if (k === 'live-quiet' || k === 'live-flow') { setStatus(S.focus, 'live'); const [, w] = findWin(S.focus); if (k === 'live-flow') { w.flow = true; w.flowUntil = performance.now() + 2500; } render(); }
  else setStatus(S.focus, k);
});

render();
