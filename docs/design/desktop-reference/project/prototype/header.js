'use strict';
// Tako desktop prototype — window title bar layer: minimal header, number slot, header menu, inline rename, split
const shortPath = p => p.replace(/^~\//, '');
function decorateHeader(el, id) {
  const hd = el.querySelector('.fw-hd');
  if (hd.querySelector('.num')) return;
  hd.querySelector('.chip').insertAdjacentHTML('afterend', '<span class="num"></span>');
  hd.addEventListener('contextmenu', e => { e.preventDefault(); winMenu(id, e.clientX, e.clientY); });
}
const _mountWin = mount;
mount = function (w, opening) {
  const el = _mountWin(w, opening);
  decorateHeader(el, w.id);
  return el;
};
for (const [id, el] of els) decorateHeader(el, id); // windows mounted before this layer loaded
const _paintWin = paint;
paint = function (w) {
  _paintWin(w);
  const el = els.get(w.id); if (!el) return;
  const hd = el.querySelector('.fw-hd');
  const cwd = shortPath(w.cwd);
  hd.querySelector('.cwd').textContent = w.title.includes(cwd) ? '' : cwd;
  const ses = findWin(w.id)[0], src = hd.querySelector('.src');
  src.textContent = w.mode === 'float' && ses && ses.id !== S.active ? '· ' + ses.title : '';
  src.style.display = src.textContent ? '' : 'none';
  const num = hd.querySelector('.num'); if (!num) return;
  num.textContent = w.status === 'progress' ? Math.round(w.p || 0) + '%' : w.status === 'error' ? 'exit ' + (w.code || 101) : '';
  num.className = 'num ' + (w.status === 'error' ? 'n-err' : 'n-prog');
};
function renameWindow(id) {
  const el = els.get(id), [, w] = findWin(id); if (!el) return;
  const t = el.querySelector('.fw-hd .t');
  const inp = document.createElement('input'); inp.className = 'ren'; inp.value = w.title;
  t.style.display = 'none'; t.after(inp); inp.focus(); inp.select();
  const done = save => { if (!inp.isConnected) return; if (save && inp.value.trim()) w.title = inp.value.trim(); inp.remove(); t.style.display = ''; render(); };
  inp.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') done(true); if (e.key === 'Escape') done(false); });
  inp.addEventListener('blur', () => done(true));
  inp.addEventListener('pointerdown', e => e.stopPropagation());
}
function splitFrom(id, dir) {
  const [s, w] = findWin(id); if (!w || w.mode !== 'tile') return;
  const nw = W('fish', w.cwd, 'shell', 'idle');
  s.windows.push(nw);
  insertNear(s, nw.id, id, dir, true);
  S.focus = nw.id; S.z[nw.id] = ++zTop;
  mount(nw, true); render(true);
}
winMenu = function (id, x, y) {
  const [s, w] = findWin(id);
  const go = f => () => { if (s.id !== S.active && w.mode !== 'float') switchSession(s.id); f(); };
  openCtx([
    { label: 'Переименовать', run: go(() => renameWindow(id)), off: w.mode === 'min' },
    '-',
    { label: 'Разделить вправо', kbd: 'D', off: w.mode !== 'tile', run: go(() => splitFrom(id, 'h')) },
    { label: 'Разделить вниз', kbd: '⇧D', off: w.mode !== 'tile', run: go(() => splitFrom(id, 'v')) },
    '-',
    { label: w.max ? 'Вернуть в ячейку' : 'Развернуть', kbd: 'F', off: w.mode === 'min', run: go(() => toggleMax(id)) },
    { label: w.mode === 'float' ? 'Вернуть в сетку' : 'Отлепить', kbd: 'P', off: w.mode === 'min', run: go(() => toggleFloat(id)) },
    { label: w.mode === 'min' ? 'Вернуть' : 'Свернуть', kbd: 'M', run: go(() => w.mode === 'min' ? restore(id) : minimize(id)) },
    '-',
    { label: 'Закрыть терминал', kbd: 'W', dang: true, run: go(() => askClose(id)) },
  ], x, y);
};
addEventListener('keydown', e => {
  if (e.target.closest && e.target.closest('input,textarea')) return;
  if (e.metaKey || e.ctrlKey || e.altKey || !S.focus) return;
  if (e.key === 'd') splitFrom(S.focus, 'h');
  else if (e.key === 'D') splitFrom(S.focus, 'v');
});
render();
