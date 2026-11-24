'use strict';
// Tako desktop prototype — sidebar (4a) (classic script; shares globals with the other prototype/*.js)
// ---------- sidebar ----------
const esc = t => String(t).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const WS_COLORS = ['#8ABEB7', '#B294BB', '#F0C674', '#7BD88F', '#D54E53', '#FF7A3D', '#81A2BE'];
const SB = { q: '', seg: 'all', kb: null, order: [], rename: null, drag: null };
const qEl = $('#q'), sbSearch = $('#sbSearch');
const needsSession = s => !s.offline && s.windows.some(w => w.status === 'waiting' || w.status === 'error');
const flashAge = s => Math.min(...s.windows.map(w => w.flashAt ? performance.now() - w.flashAt : 1e9));
function sessionMatches(s, q) {
  if (!q) return true;
  const hay = [s.title, s.cwd, s.branch || '', ...s.windows.map(w => w.title)].join(' ').toLowerCase();
  return q.toLowerCase().split(/\s+/).every(p => hay.includes(p));
}
function hl(text, q) {
  const t = esc(text); if (!q) return t;
  const p = q.trim().split(/\s+/)[0]; if (!p) return t;
  const i = text.toLowerCase().indexOf(p.toLowerCase()); if (i < 0) return t;
  return esc(text.slice(0, i)) + '<mark>' + esc(text.slice(i, i + p.length)) + '</mark>' + esc(text.slice(i + p.length));
}
function metaOf(s) {
  if (s.confirm) return `Работает процесс. Закрыть? <span class="lnk" data-yes>Закрыть</span> <span class="lnk no" data-no>Отмена</span>`;
  if (s.offline) return `offline · <span class="lnk" data-rc>переподключить</span>`;
  const top = topWin(s), st = top ? top.status : 'idle';
  if (st === 'waiting') return esc(top.ask || 'ждёт ответа');
  if (st === 'error') return `exit ${top.code || 101} · ${esc(top.title)}`;
  if (st === 'progress') return `${esc(top.title)} · ${Math.round(top.p || 0)}%`;
  if (st === 'working') return `${esc(top.title)} · работает`;
  if (st === 'live') return top.flow ? `${esc(top.prog || top.title)} · идёт вывод` : `${esc(top.prog || top.title)} · тихо ${top.quiet || 1}m`;
  const parts = [esc(s.cwd)];
  if (s.showGit !== false && s.branch) parts.push(`<span class="br">⎇ ${esc(s.branch)}</span>`);
  if (s.showPorts && s.ports) parts.push(esc(s.ports));
  return parts.join(' · ');
}
function renderSidebar() {
  const q = SB.q.trim();
  let html = '', total = S.sessions.length, needs = S.sessions.filter(needsSession).length, shownAny = false;
  SB.order = [];
  for (const ws of S.ws) {
    const all = S.sessions.filter(s => s.ws === ws.id);
    const ss = all.filter(s => sessionMatches(s, q) && (SB.seg === 'all' || needsSession(s)));
    const filtering = q || SB.seg !== 'all';
    if (filtering && !ss.length) continue;
    shownAny = true;
    const attn = all.filter(needsSession).length;
    const closed = ws.closed && !filtering;
    const nm = SB.rename && SB.rename.kind === 'ws' && SB.rename.id === ws.id
      ? `<input data-ren value="${esc(ws.name)}">` : esc(ws.name);
    html += `<div class="ws ${closed ? 'closed' : ''}" data-ws="${ws.id}"><span class="chev">▾</span><span class="wdot" data-color style="background:${ws.color}" title="Цвет"></span><span class="nm">${nm}</span>`
      + `<span class="n">${attn ? `<span class="cnt">${attn}</span>` : ''}${all.length}</span>`
      + `<span class="act"><button data-a="add" title="Новая сессия здесь">+</button><button data-a="menu" title="Ещё">⋯</button></span></div>`;
    if (closed) continue;
    for (const s of ss) {
      SB.order.push(s.id);
      const st = sessionStatus(s), on = s.id === S.active;
      const many = s.windows.length > 1, open = many && (s.open ?? on);
      const title = SB.rename && SB.rename.kind === 's' && SB.rename.id === s.id ? `<input data-ren value="${esc(s.title)}">` : hl(s.title, q);
      const top = topWin(s), age = flashAge(s);
      const cls = ['row', on && 'on', SB.kb === s.id && 'kb', st === 'waiting' && 'waiting glow', st === 'error' && 'error errline', st === 'working' && 'sweep', s.offline && 'offline'].filter(Boolean).join(' ');
      const ringFx = st === 'error' && age < 400 ? ` fx-shake" style="animation-delay:-${Math.round(age)}ms` : st === 'done' && age < 700 ? ` pop" style="animation-delay:-${Math.round(age)}ms` : '';
      html += `<div class="${cls}" data-s="${s.id}" data-st="${st}" draggable="true"><div class="l1">`
        + `<span class="exp" ${many ? 'data-exp' : ''}>${many ? (open ? '▾' : '▸') : ''}</span>`
        + `<span class="ring ${sessionRing(s)}${ringFx}" data-ring-s="${s.id}" style="${top ? pVar(top) : ''}"></span><span class="t">${title}</span>`
        + `${s.unread ? '<span class="unread" title="есть новое"></span>' : ''}`
        + `${many ? `<span class="rt">${s.windows.length}</span>` : ''}<span class="rx" title="Закрыть сессию">✕</span></div>`
        + `<div class="meta" data-meta-s="${s.id}">${metaOf(s)}</div>`
        + `${st === 'progress' ? `<span class="pfill" data-pf-s="${s.id}" style="width:calc((100% - 16px) * ${(top.p || 0) / 100})"></span>` : ''}`
        + `${st === 'done' && age < 900 ? `<span class="fx-shim" style="animation-delay:-${Math.round(age)}ms"></span>` : ''}</div>`;
      if (open) s.windows.forEach((w, i) => {
        const md = w.mode === 'min' ? '<span class="md" title="свёрнуто">◦</span>' : w.mode === 'float' ? '<span class="md" title="отлеплено, поверх">⧉</span>' : '';
        html += `<div class="kid ${S.focus === w.id && w.mode !== 'min' && on ? 'focus' : ''} ${w.mode === 'min' ? 'min' : ''}" data-w="${w.id}"><span class="ring sm ${ringOf(w)}" data-ring-w="${w.id}" style="${pVar(w)}"></span><span class="t">${esc(w.title)}</span>${md}<span class="tag">${i + 1}</span></div>`;
      });
    }
  }
  if (!shownAny) html = `<div class="sb-empty">${q ? `Ничего не найдено по «${esc(q)}»` : 'Никто не ждёт.<br>Всё спокойно.'}</div>`;
  else if (!q && SB.seg === 'all') html += `<span class="sb-newws" data-newws>+ Workspace</span>`;
  sbList.innerHTML = html;
  phaseVars(sbList);
  $('#sbCount').textContent = total;
  $('#needsLbl').textContent = needs ? `Needs you · ${needs}` : 'Needs you';
  $('#needsBtn').classList.toggle('attn', needs > 0);
  sbSearch.classList.toggle('has-q', !!SB.q);
  document.querySelectorAll('.seg').forEach(b => b.classList.toggle('on', b.dataset.seg === SB.seg));
  const inp = sbList.querySelector('input[data-ren]');
  if (inp) { inp.focus(); inp.select(); }
}
// live refresh without rebuilding the list (keeps every animation running)
function refreshSidebarLive() {
  if (SB.rename || SB.drag) return;
  for (const row of sbList.querySelectorAll('.row[data-s]')) {
    const s = S.sessions.find(x => x.id === row.dataset.s); if (!s) continue;
    if (row.dataset.st !== sessionStatus(s)) { renderSidebar(); return; }
    const top = topWin(s), ring = row.querySelector('[data-ring-s]');
    const want = 'ring ' + sessionRing(s);
    if (ring && ring.className !== want && !/fx-shake|pop/.test(ring.className)) ring.className = want;
    if (ring && top) ring.setAttribute('style', pVar(top));
    const m = row.querySelector('[data-meta-s]'); if (m) m.innerHTML = metaOf(s);
    const pf = row.querySelector('[data-pf-s]'); if (pf && top) pf.style.width = `calc((100% - 16px) * ${(top.p || 0) / 100})`;
  }
  for (const r of sbList.querySelectorAll('[data-ring-w]')) {
    const [, w] = findWin(r.dataset.ringW); if (!w) continue;
    const want = 'ring sm ' + ringOf(w); if (r.className !== want) r.className = want;
    r.setAttribute('style', pVar(w));
  }
}
// rename
function startRename(kind, id) { SB.rename = { kind, id }; renderSidebar(); }
function commitRename(save) {
  const inp = sbList.querySelector('input[data-ren]'), r = SB.rename;
  if (!r) return;
  SB.rename = null;
  const v = inp ? inp.value.trim() : '';
  if (save && v) {
    if (r.kind === 'ws') S.ws.find(x => x.id === r.id).name = v;
    else { const s = S.sessions.find(x => x.id === r.id); if (s) s.title = v; }
  }
  render();
}
sbList.addEventListener('keydown', e => {
  if (!e.target.matches('input[data-ren]')) return;
  if (e.key === 'Enter') { e.preventDefault(); commitRename(true); }
  if (e.key === 'Escape') { e.preventDefault(); commitRename(false); }
  e.stopPropagation();
});
sbList.addEventListener('focusout', e => { if (e.target.matches('input[data-ren]')) setTimeout(() => SB.rename && commitRename(true), 0); });

// clicks
sbList.addEventListener('click', e => {
  if (e.target.closest('input')) return;
  const sEl = e.target.closest('.row'), wsEl = e.target.closest('.ws'), k = e.target.closest('.kid');
  if (e.target.closest('[data-newws]')) return newWorkspace();
  if (sEl) {
    const s = S.sessions.find(x => x.id === sEl.dataset.s);
    if (e.target.closest('[data-rc]')) { reconnect(s); return; }
    if (e.target.closest('[data-yes]')) { s.confirm = false; removeSession(s.id); return; }
    if (e.target.closest('[data-no]')) { s.confirm = false; renderSidebar(); return; }
    if (e.target.closest('.rx')) { closeSession(s.id); return; }
    if (e.target.closest('[data-exp]')) { s.open = !(s.open ?? s.id === S.active); renderSidebar(); return; }
    SB.kb = null;
    switchSession(s.id); return;
  }
  if (k) { const [, w] = findWin(k.dataset.w); const [ws] = findWin(k.dataset.w); if (ws.id !== S.active) switchSession(ws.id); if (w.mode === 'min') restore(w.id); else focusWin(w.id); return; }
  if (wsEl) {
    const ws = S.ws.find(x => x.id === wsEl.dataset.ws);
    const a = e.target.closest('[data-a]');
    if (a && a.dataset.a === 'add') { newSession(ws.id); return; }
    if (a && a.dataset.a === 'menu') { const r = a.getBoundingClientRect(); wsMenu(ws, r.left, r.bottom + 4); return; }
    if (e.target.closest('[data-color]')) { const r = e.target.getBoundingClientRect(); colorMenu(ws, r.left, r.bottom + 6); return; }
    ws.closed = !ws.closed; renderSidebar();
  }
});
sbList.addEventListener('dblclick', e => {
  const sEl = e.target.closest('.row'), nm = e.target.closest('.ws .nm');
  if (sEl && e.target.closest('.t')) startRename('s', sEl.dataset.s);
  else if (nm) startRename('ws', nm.closest('.ws').dataset.ws);
});
sbList.addEventListener('contextmenu', e => {
  const sEl = e.target.closest('.row'), wsEl = e.target.closest('.ws'), k = e.target.closest('.kid');
  if (!sEl && !wsEl && !k) return;
  e.preventDefault();
  if (k) winMenu(k.dataset.w, e.clientX, e.clientY);
  else if (sEl) sessionMenu(S.sessions.find(x => x.id === sEl.dataset.s), e.clientX, e.clientY);
  else wsMenu(S.ws.find(x => x.id === wsEl.dataset.ws), e.clientX, e.clientY);
});

// drag & drop sessions (reorder, move between workspaces)
sbList.addEventListener('dragstart', e => {
  const r = e.target.closest('.row'); if (!r || SB.rename) { e.preventDefault(); return; }
  SB.drag = r.dataset.s; r.classList.add('dragging');
  e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', SB.drag);
});
sbList.addEventListener('dragend', () => { SB.drag = null; clearDrop(); renderSidebar(); });
function clearDrop() { sbList.querySelectorAll('.dropa,.dropb,.drop').forEach(n => n.classList.remove('dropa', 'dropb', 'drop')); }
sbList.addEventListener('dragover', e => {
  if (!SB.drag) return;
  const r = e.target.closest('.row'), w = e.target.closest('.ws');
  if (!r && !w) return;
  e.preventDefault(); clearDrop();
  if (r) { if (r.dataset.s === SB.drag) return; const b = r.getBoundingClientRect(); r.classList.add(e.clientY < b.top + b.height / 2 ? 'dropb' : 'dropa'); }
  else w.classList.add('drop');
});
sbList.addEventListener('drop', e => {
  if (!SB.drag) return; e.preventDefault();
  const s = S.sessions.find(x => x.id === SB.drag);
  const r = sbList.querySelector('.dropa,.dropb'), w = sbList.querySelector('.ws.drop');
  S.sessions = S.sessions.filter(x => x !== s);
  if (r) {
    const t = S.sessions.find(x => x.id === r.dataset.s);
    s.ws = t.ws;
    S.sessions.splice(S.sessions.indexOf(t) + (r.classList.contains('dropa') ? 1 : 0), 0, s);
  } else if (w) {
    s.ws = w.dataset.ws;
    const ws = S.ws.find(x => x.id === s.ws); ws.closed = false;
    S.sessions.push(s);
  } else S.sessions.push(s);
  SB.drag = null; clearDrop(); renderSidebar();
});

// search & segments
qEl.addEventListener('input', () => { SB.q = qEl.value; SB.kb = null; renderSidebar(); });
qEl.addEventListener('keydown', e => {
  if (e.key === 'Escape') { qEl.value = ''; SB.q = ''; renderSidebar(); qEl.blur(); }
  if (e.key === 'ArrowDown') { e.preventDefault(); qEl.blur(); moveKb(1); }
  if (e.key === 'Enter' && SB.order.length) { switchSession(SB.kb || SB.order[0]); qEl.blur(); }
  e.stopPropagation();
});
$('#qClr').addEventListener('click', e => { e.preventDefault(); qEl.value = ''; SB.q = ''; renderSidebar(); });
document.querySelectorAll('.seg').forEach(b => b.addEventListener('click', () => { SB.seg = b.dataset.seg; SB.kb = null; renderSidebar(); }));
function nextWaiting() {
  const list = S.sessions.filter(s => !s.offline && s.windows.some(w => w.status === 'waiting'));
  if (!list.length) return;
  const i = list.findIndex(s => s.id === S.active);
  const s = list[(i + 1) % list.length];
  const w = s.windows.find(w => w.status === 'waiting');
  goTo(w.id);
}
$('#needsBtn').addEventListener('click', nextWaiting);
$('#nextWait').addEventListener('click', nextWaiting);

// keyboard cursor in the list
function moveKb(d) {
  if (!SB.order.length) return;
  const curId = SB.kb || S.active, i = SB.order.indexOf(curId);
  SB.kb = SB.order[Math.max(0, Math.min(SB.order.length - 1, (i < 0 ? -1 : i) + d))];
  renderSidebar();
  const el = sbList.querySelector(`.row[data-s="${SB.kb}"]`); el && el.scrollIntoView({ block: 'nearest' });
}

// session / workspace operations
function reconnect(s) {
  s.offline = false; s.windows.forEach(w => { if (w.status === 'idle') w.status = 'idle'; });
  toast2('●', `${s.title} — снова на связи`);
  render();
}
function closeSession(id) {
  const s = S.sessions.find(x => x.id === id);
  if (s.windows.some(w => w.status === 'working' || w.status === 'waiting')) { s.confirm = true; renderSidebar(); return; }
  removeSession(id);
}
function removeSession(id) {
  const i = SB.order.indexOf(id);
  S.sessions = S.sessions.filter(x => x.id !== id);
  if (!S.sessions.length) { newSession('def'); return; }
  if (S.active === id) {
    const nextId = SB.order[i + 1] || SB.order[i - 1] || S.sessions[0].id;
    S.active = null; switchSession(S.sessions.find(x => x.id === nextId) ? nextId : S.sessions[0].id);
  } else render();
}
function newWorkspace() {
  const ws = { id: 'ws' + Date.now(), name: 'Workspace', color: WS_COLORS[S.ws.length % WS_COLORS.length], closed: false };
  S.ws.push(ws); startRename('ws', ws.id);
}
function moveSessionTo(s, wsId) {
  S.sessions = S.sessions.filter(x => x !== s); s.ws = wsId;
  const last = S.sessions.map(x => x.ws).lastIndexOf(wsId);
  S.sessions.splice(last + 1, 0, s); S.ws.find(x => x.id === wsId).closed = false; renderSidebar();
}

// context menus
let ctxEl = null;
function closeCtx() { if (ctxEl) { ctxEl.remove(); ctxEl = null; } }
function openCtx(items, x, y) {
  closeCtx();
  const mk = list => list.map(it => it === '-' ? '<div class="sep"></div>'
    : `<div class="it ${it.dang ? 'dang' : ''} ${it.off ? 'off' : ''}" data-i="${it.id || ''}">${it.sw ? `<span class="sw" style="background:${it.sw}"></span>` : ''}${esc(it.label)}${it.kbd ? `<kbd>${it.kbd}</kbd>` : ''}${it.chk ? '<span class="chk">✓</span>' : ''}${Array.isArray(it.sub) ? '<span class="ar">▸</span><div class="sub">' + mk(it.sub) + '</div>' : ''}</div>`).join('');
  const acts = {};
  const walk = l => l.forEach(it => { if (it === '-') return; if (it.id) acts[it.id] = it.run; if (Array.isArray(it.sub)) walk(it.sub); }); // note: '-'.sub is String.prototype.sub
  let n = 0; const tag = l => l.forEach(it => { if (it !== '-') { if (it.run) it.id = 'a' + (n++); if (Array.isArray(it.sub)) tag(it.sub); } });
  tag(items); walk(items);
  ctxEl = document.createElement('div'); ctxEl.className = 'ctx'; ctxEl.innerHTML = mk(items);
  document.body.appendChild(ctxEl);
  const b = ctxEl.getBoundingClientRect();
  ctxEl.style.left = Math.min(x, innerWidth - b.width - 8) + 'px';
  ctxEl.style.top = Math.min(y, innerHeight - b.height - 8) + 'px';
  ctxEl.addEventListener('click', e => { const it = e.target.closest('.it'); if (!it || !acts[it.dataset.i]) return; e.stopPropagation(); const f = acts[it.dataset.i]; closeCtx(); f(); });
}
addEventListener('pointerdown', e => { if (ctxEl && !e.target.closest('.ctx')) closeCtx(); }, true);
function sessionMenu(s, x, y) {
  openCtx([
    { label: 'Открыть', run: () => switchSession(s.id) },
    { label: 'Переименовать', kbd: 'F2', run: () => startRename('s', s.id) },
    { label: 'Новый терминал в сессии', kbd: '⌘N', run: () => { switchSession(s.id); newWindow(); } },
    { label: 'Переместить в', sub: S.ws.filter(w => w.id !== s.ws).map(w => ({ label: w.name, sw: w.color, run: () => moveSessionTo(s, w.id) })) },
    '-',
    { label: 'Показывать ветку git', chk: s.showGit !== false, run: () => { s.showGit = s.showGit === false; renderSidebar(); } },
    { label: 'Показывать порты', chk: !!s.showPorts, off: !s.ports, run: () => { s.showPorts = !s.showPorts; renderSidebar(); } },
    { label: 'Отметить прочитанным', off: !s.unread, run: () => { s.unread = false; renderSidebar(); } },
    s.offline ? { label: 'Переподключить', run: () => reconnect(s) } : null,
    '-',
    { label: 'Закрыть сессию', kbd: '⌘⇧W', dang: true, run: () => closeSession(s.id) },
  ].filter(Boolean), x, y);
}
function wsMenu(ws, x, y) {
  const n = S.sessions.filter(s => s.ws === ws.id).length;
  openCtx([
    { label: 'Новая сессия здесь', run: () => newSession(ws.id) },
    { label: 'Переименовать', run: () => startRename('ws', ws.id) },
    { label: 'Цвет', sub: WS_COLORS.map(c => ({ label: c, sw: c, chk: ws.color === c, run: () => { ws.color = c; renderSidebar(); } })) },
    { label: ws.closed ? 'Развернуть' : 'Свернуть', run: () => { ws.closed = !ws.closed; renderSidebar(); } },
    '-',
    { label: n ? `Удалить (сначала убери ${n} сесс.)` : 'Удалить workspace', dang: true, off: n > 0 || S.ws.length < 2, run: () => { S.ws = S.ws.filter(w => w !== ws); renderSidebar(); } },
  ], x, y);
}
function colorMenu(ws, x, y) {
  openCtx(WS_COLORS.map(c => ({ label: c, sw: c, chk: ws.color === c, run: () => { ws.color = c; renderSidebar(); } })), x, y);
}
function winMenu(id, x, y) {
  const [s, w] = findWin(id);
  const go = f => () => { if (s.id !== S.active) switchSession(s.id); f(); };
  openCtx([
    { label: w.mode === 'min' ? 'Вернуть' : 'Фокус', run: go(() => w.mode === 'min' ? restore(id) : focusWin(id)) },
    { label: w.mode === 'float' ? 'Вернуть в сетку' : 'Отлепить (поверх)', off: w.mode === 'min', run: go(() => toggleFloat(id)) },
    { label: 'Свернуть', off: w.mode === 'min', kbd: '⌘M', run: go(() => minimize(id)) },
    '-',
    { label: 'Закрыть терминал', kbd: '⌘W', dang: true, run: go(() => askClose(id)) },
  ], x, y);
}

// sidebar width
(() => {
  const rz = $('#sbRz'), sb = $('#sb');
  rz.addEventListener('pointerdown', e => {
    e.preventDefault(); rz.classList.add('drag'); document.body.style.cursor = 'col-resize';
    const x0 = e.clientX, w0 = sb.getBoundingClientRect().width;
    const mv = ev => { sb.style.setProperty('--sbw', Math.max(200, Math.min(380, w0 + ev.clientX - x0)) + 'px'); render(); };
    addEventListener('pointermove', mv);
    addEventListener('pointerup', () => { removeEventListener('pointermove', mv); rz.classList.remove('drag'); document.body.style.cursor = ''; }, { once: true });
  });
  rz.addEventListener('dblclick', () => { sb.style.removeProperty('--sbw'); render(); });
})();
function toast2(icon, text) {
  const t = document.createElement('div'); t.className = 'toast';
  t.innerHTML = `<span class="ring sm r-done"></span><div class="tx"><div class="h">${esc(text)}</div></div>`;
  toastsEl.prepend(t); setTimeout(() => dismiss(t), 2600);
}

