// Tako desktop prototype — window affordances asked for by Alex (2026-11-08):
// 1) Settings sit strictly in the centre of the app window: no side-jumping per scope or page.
// 2) An explicit «Плавающее окно» ⇄ «В сетку» action in the pane header and context menu; a floating pane keeps its
//    last free rect, drags and resizes on the canvas, overlaps, takes focus/z-order and goes to the shelf as before.

// ---------- settings: centred, adaptive height, content scrolls ----------
placeSet = p => {
  const a = $('#app').getBoundingClientRect();
  const h = Math.min(640, Math.max(360, a.height - 24));
  p.style.height = h + 'px';
  p.style.width = Math.min(600, a.width - 24) + 'px';
  p.style.left = Math.round(a.left + (a.width - p.offsetWidth) / 2) + 'px';
  p.style.top = Math.round(Math.max(a.top + 12, a.top + (a.height - h) / 2)) + 'px';
};
addEventListener('resize', () => { const p = document.querySelector('.pop.setwin'); if (p) placeSet(p); });

// ---------- floating pane: one compact header icon (SF Symbol rectangle.on.rectangle), pressed while floating ----------
const _paintFloatBtn = paint;
paint = w => {
  _paintFloatBtn(w);
  const el = els.get(w.id), fl = el && el.querySelector('.wb.fl'); if (!fl) return;
  const on = w.mode === 'float';
  if (fl.dataset.sym !== String(on)) { fl.dataset.sym = String(on); fl.innerHTML = '<i class="sym" aria-hidden="true"></i>'; }
  fl.classList.toggle('on', on);
  fl.title = on ? 'Развернуть — вернуть в сетку сессии' : 'Плавающее окно';
  fl.setAttribute('aria-label', on ? 'Развернуть' : 'Плавающее окно');
  fl.setAttribute('aria-pressed', String(on));
};
// a pane that was floating before comes back to its own rect, not a fresh default one
const _toggleFloatKeepRect = toggleFloat;
toggleFloat = id => {
  const [, w] = findWin(id); if (!w) return;
  if (w.mode === 'float' && w.rect) w.floatRect = { ...w.rect };
  _toggleFloatKeepRect(id);
  if (w.mode === 'float' && w.floatRect) {
    const { w: CW, h: CH } = cbounds(), r = w.floatRect;
    w.rect = { x: Math.min(Math.max(r.x, 0), CW - Math.min(r.w, CW)), y: Math.min(Math.max(r.y, 0), CH - Math.min(r.h, CH)), w: Math.min(r.w, CW), h: Math.min(r.h, CH) };
    render(true);
  }
};
// context menu: the same words as the header button, plus Оформление… from settings.js
winMenu = (id, x, y) => {
  const [s, w] = findWin(id);
  const go = f => () => { if (s.id !== S.active) switchSession(s.id); f(); };
  ctxExtra = lookItem({ kind: 'w', id });
  openCtx([
    { label: w.mode === 'min' ? 'Вернуть' : 'Фокус', run: go(() => w.mode === 'min' ? restore(id) : focusWin(id)) },
    { label: w.mode === 'float' ? 'Вернуть в сетку' : 'Плавающее окно', kbd: 'P', off: w.mode === 'min', run: go(() => toggleFloat(id)) },
    { label: w.max ? 'Вернуть в ячейку' : 'На всё поле', kbd: '⌃⌘F', off: w.mode === 'min', run: go(() => toggleMax(id)) },
    { label: 'Свернуть на полку', off: w.mode === 'min', kbd: '⌘M', run: go(() => minimize(id)) },
    '-',
    { label: 'Закрыть терминал', kbd: '⌘W', dang: true, run: go(() => askClose(id)) },
  ], x, y);
};
render();
// the real-Tako layer (reality.js / reality.css) loads after everything else
// then the settings modules, in order (dynamic scripts are async unless told otherwise)
for (const c of ['reality', 'prefs', 'prefs-detail']) { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = `prototype/${c}.css`; document.head.append(l); }
for (const f of ['reality', 'prefs-model', 'prefs-themes', 'prefs-keys', 'prefs-window', 'prefs-wire', 'prefs-spec', 'prefs-detail']) { const sc = document.createElement('script'); sc.src = `prototype/${f}.js`; sc.async = false; document.body.append(sc); }
