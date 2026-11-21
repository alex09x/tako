'use strict';
// Tako desktop prototype — sidebar chrome layer: "+" menu, settings that change the prototype live, shortcut sheet
const CFG = { font: '12.5', density: 'normal', motion: 'full', git: true, ports: true, toasts: true, split: 'auto', kids: 'all', dim: '.72',
  theme: 'ember', auto: false, dark: 'ember', light: 'paper' };

// ---------- themes: a theme is the terminal palette; the app chrome is derived from it ----------
const THEMES = {
  ember:    { name: 'Ember', tone: 'dark', term: '#1C1714', bg: '#14100E', fg: '#EDE6DF', red: '#D54E53', green: '#7BD88F', yellow: '#F0C674', blue: '#81A2BE', magenta: '#B294BB', cyan: '#8ABEB7' },
  midnight: { name: 'Midnight', tone: 'dark', term: '#181A1F', bg: '#121418', fg: '#E3E6EB', red: '#E06C75', green: '#98C379', yellow: '#E5C07B', blue: '#61AFEF', magenta: '#C678DD', cyan: '#56B6C2' },
  gruvbox:  { name: 'Gruvbox', tone: 'dark', term: '#282828', bg: '#1D2021', fg: '#EBDBB2', red: '#FB4934', green: '#B8BB26', yellow: '#FABD2F', blue: '#83A598', magenta: '#D3869B', cyan: '#8EC07C' },
  mocha:    { name: 'Mocha', tone: 'dark', term: '#1E1E2E', bg: '#181825', fg: '#CDD6F4', red: '#F38BA8', green: '#A6E3A1', yellow: '#F9E2AF', blue: '#89B4FA', magenta: '#CBA6F7', cyan: '#94E2D5' },
  paper:    { name: 'Paper', tone: 'light', term: '#FAF7F2', bg: '#F0EBE4', fg: '#1A1512', red: '#C82829', green: '#5E8C00', yellow: '#B98500', blue: '#4271AE', magenta: '#8959A8', cyan: '#3E999F' },
  latte:    { name: 'Latte', tone: 'light', term: '#EFF1F5', bg: '#E6E9EF', fg: '#4C4F69', red: '#D20F39', green: '#40A02B', yellow: '#DF8E1D', blue: '#1E66F5', magenta: '#8839EF', cyan: '#179299' },
};
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const mix = (a, b, t) => { const A = hex(a), B = hex(b); return '#' + A.map((v, i) => Math.round(v + (B[i] - v) * t).toString(16).padStart(2, '0')).join(''); };
const sysDark = () => SYS.dark;
const SYS = { dark: matchMedia('(prefers-color-scheme: dark)').matches };
function activeTheme() { return CFG.auto ? (sysDark() ? CFG.dark : CFG.light) : CFG.theme; }
function applyTheme() {
  const t = THEMES[activeTheme()], d = t.tone === 'dark', root = document.documentElement.style;
  const v = {
    '--bg': t.bg, '--term': t.term, '--text': t.fg,
    '--card': mix(t.term, t.fg, d ? .07 : .06), '--hover': mix(t.bg, t.fg, d ? .045 : .05), '--hover2': mix(t.term, t.fg, d ? .12 : .1),
    '--field': d ? mix(t.bg, t.term, .5) : t.term, '--pillbg': mix(t.term, t.fg, d ? .07 : .04),
    '--line': mix(t.bg, t.fg, d ? .09 : .11), '--line2': mix(t.bg, t.fg, d ? .15 : .17),
    '--sub': mix(t.fg, t.bg, .27), '--dim': mix(t.fg, t.bg, .45), '--mute': mix(t.fg, t.bg, .6), '--deep': mix(t.fg, t.bg, .72),
    '--ok': t.green, '--err': t.red, '--yellow': t.yellow, '--blue': t.blue, '--purple': t.magenta,
  };
  for (const k in v) root.setProperty(k, v[k]);
  document.documentElement.dataset.tone = t.tone;
}
// window lists under sessions: open for every session unless the user folded one
const _renderSidebar = renderSidebar;
renderSidebar = () => { for (const s of S.sessions) if (s.open === undefined && CFG.kids === 'all') s.open = true; _renderSidebar(); };

function applyCfg() {
  applyTheme();
  document.documentElement.style.setProperty('--fs', CFG.font + 'px');
  $('#sb').classList.toggle('compact', CFG.density === 'compact');
  document.body.classList.toggle('rm', CFG.motion === 'off');
  document.documentElement.style.setProperty('--dimo', CFG.dim);
  render();
}
// no progress status: a terminal cannot know how far a command is, so a running command is just "working"
const noProgress = w => { if (w.status === 'progress') { w.status = 'working'; delete w.p; w.auto = false; } };
S.sessions.forEach(s => s.windows.forEach(noProgress));
const _initialState = initialState;
initialState = () => { const st = _initialState(); (st.sessions || []).forEach(s => s.windows.forEach(noProgress)); return st; };
const _setStatus = setStatus;
setStatus = (id, st, ...rest) => _setStatus(id, st === 'progress' ? 'working' : st, ...rest);
LEGEND.splice(LEGEND.findIndex(l => l[0] === 'progress'), 1);

// settings feed the existing pieces
const _metaOf = metaOf;
metaOf = s => { const g = s.showGit, p = s.showPorts; if (!CFG.git) s.showGit = false; if (!CFG.ports) s.showPorts = false; const r = _metaOf(s); s.showGit = g; s.showPorts = p; return r; };
const _notify = notify;
notify = (w, s) => { if (CFG.toasts) _notify(w, s); };
const _defaultDir = defaultDir;
defaultDir = r => CFG.split === 'auto' ? _defaultDir(r) : CFG.split;

// popovers
let popEl = null, scrimEl = null;
function closePop() { if (popEl) popEl.remove(); if (scrimEl) scrimEl.remove(); popEl = scrimEl = null; document.querySelectorAll('.fb.on,.ib.on').forEach(b => b.classList.remove('on')); }
function openPop(cls, html, place, modal) {
  closePop(); closeCtx();
  if (modal) { scrimEl = document.createElement('div'); scrimEl.className = 'scrim'; scrimEl.onclick = closePop; document.body.appendChild(scrimEl); }
  popEl = document.createElement('div'); popEl.className = 'pop ' + cls; popEl.innerHTML = html; document.body.appendChild(popEl);
  place(popEl); return popEl;
}
addEventListener('pointerdown', e => { if (popEl && !popEl.contains(e.target) && !e.target.closest('.fb,.sb-ic .ib') && !scrimEl) closePop(); }, true);

// "+" menu
$('#addBtn').addEventListener('click', e => {
  const r = e.currentTarget.getBoundingClientRect();
  openCtx([
    { label: 'Новая сессия', kbd: '⌘T', run: () => newSession() },
    { label: 'Новый терминал здесь', kbd: '⌘N', run: () => newWindow() },
    { label: 'Подключиться по SSH…', kbd: '⌘⇧S', run: () => sshPop() },
    '-',
    { label: 'Новый workspace', run: () => newWorkspace() },
  ], r.right - 210, r.bottom + 6);
});
function sshPop() {
  const sb = $('#sb').getBoundingClientRect();
  const el = openPop('ssh', `<label>SSH-хост</label><input placeholder="user@host или алиас из ~/.ssh/config" spellcheck="false"><div class="recent">${['prod-db', 'prod-1', 'ram11', 'alex@build-mac'].map(h => `<b>${h}</b>`).join('')}</div>`,
    p => { p.style.left = (sb.left + 10) + 'px'; p.style.top = (sb.top + 46) + 'px'; });
  const inp = el.querySelector('input'); inp.focus();
  const go = host => {
    host = host.trim(); if (!host) return;
    closePop();
    const w = W('ssh ' + host, host.includes('@') ? host : 'alex@' + host, 'ssh', 'live'); w.prog = 'ssh'; w.quiet = 1;
    const ns = { id: 's' + Date.now(), ws: cur() ? cur().ws : 'def', title: host.replace(/^.*@/, ''), cwd: 'ssh ' + host, branch: '', windows: [w], tree: leaf(w.id) };
    const last = S.sessions.map(x => x.ws).lastIndexOf(ns.ws); S.sessions.splice(last + 1, 0, ns);
    switchSession(ns.id);
  };
  inp.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') go(inp.value); if (e.key === 'Escape') closePop(); });
  el.querySelectorAll('.recent b').forEach(b => b.onclick = () => go(b.textContent));
}

// settings
const seg = (k, opts) => `<div class="sg" data-k="${k}">${opts.map(([v, l]) => `<button data-v="${v}" class="${CFG[k] === v ? 'on' : ''}">${l}</button>`).join('')}</div>`;
const tog = k => `<button class="tg ${CFG[k] ? 'on' : ''}" data-t="${k}"></button>`;
const swatch = k => { const t = THEMES[k]; return `<i style="background:${t.term}"><u style="background:${t.bg}"></u>`
  + [t.red, t.green, t.yellow, t.blue, t.magenta].map((c, i) => `<b style="background:${c};top:8px;margin-left:${i * 8}px"></b>`).join('')
  + `<s style="background:${t.fg};top:19px"></s><s style="background:${t.fg};top:26px;right:22px;opacity:.45"></s></i>`; };
const themeGrid = (k, filter) => `<div class="thg" data-k="${k}">${Object.keys(THEMES).filter(x => !filter || THEMES[x].tone === filter).map(x => `<button class="th ${CFG[k] === x ? 'on' : ''}" data-v="${x}">${swatch(x)}<span>${THEMES[x].name}</span></button>`).join('')}</div>`;
function settingsHtml() {
  const look = CFG.auto
    ? `<div class="r"><span>Тёмная</span></div>${themeGrid('dark', 'dark')}<div class="r" style="margin-top:6px"><span>Светлая</span></div>${themeGrid('light', 'light')}
       <div class="r" style="margin-top:4px"><span style="color:var(--mute)">система сейчас: ${sysDark() ? 'тёмная' : 'светлая'}</span><a data-sys style="color:var(--claw);cursor:pointer">переключить</a></div>`
    : themeGrid('theme');
  return `<h5>Настройки</h5>
  <div class="sec">Внешний вид</div>
  <div class="r"><span>Как в системе</span>${tog('auto')}</div>
  ${look}
  <div class="sec">Терминал</div>
  <div class="r"><span>Неактивные терминалы</span>${seg('dim', [['1', 'как есть'], ['.72', 'тусклее'], ['.5', 'сильно']])}</div>
  <div class="r"><span>Шрифт</span>${seg('font', [['11', '11'], ['12.5', '12.5'], ['14', '14']])}</div>
  <div class="r"><span>Новый терминал</span>${seg('split', [['auto', 'авто'], ['h', 'справа'], ['v', 'снизу']])}</div>
  <div class="sec">Сайдбар</div>
  <div class="r"><span>Строки</span>${seg('density', [['normal', 'две'], ['compact', 'одна']])}</div>
  <div class="r"><span>Терминалы сессий</span>${seg('kids', [['all', 'у всех'], ['active', 'у открытой']])}</div>
  <div class="r"><span>Ветка git</span>${tog('git')}</div>
  <div class="r"><span>Порты</span>${tog('ports')}</div>
  <div class="sec">Поведение</div>
  <div class="r"><span>Анимации</span>${seg('motion', [['full', 'все'], ['off', 'без']])}</div>
  <div class="r"><span>Уведомления</span>${tog('toasts')}</div>
  <div class="ft"><span>Tako 0.1.10</span><a data-keys>клавиши ?</a></div>`;
}
function settingsPop() {
  const b = $('#setBtn'), r = b.getBoundingClientRect();
  b.classList.add('on');
  const el = openPop('set', settingsHtml(), p => { const w = p.getBoundingClientRect().width, t = r.bottom + 8; p.style.left = Math.max(12, Math.min(r.right - w, innerWidth - w - 12)) + 'px'; p.style.top = t + 'px'; p.style.maxHeight = (innerHeight - t - 12) + 'px'; p.style.overflow = 'auto'; });
  el.addEventListener('click', e => {
    const s = e.target.closest('.sg button'), t = e.target.closest('[data-t]');
    const th = e.target.closest('.th');
    if (th) CFG[th.closest('.thg').dataset.k] = th.dataset.v;
    else if (e.target.closest('[data-sys]')) SYS.dark = !SYS.dark;
    else if (s) { const k = s.closest('.sg').dataset.k; CFG[k] = s.dataset.v; if (k === 'kids') S.sessions.forEach(x => x.open = undefined); }
    else if (t) { CFG[t.dataset.t] = !CFG[t.dataset.t]; if (t.dataset.t === 'auto' && CFG.auto) { CFG.dark = THEMES[CFG.theme].tone === 'dark' ? CFG.theme : CFG.dark; CFG.light = THEMES[CFG.theme].tone === 'light' ? CFG.theme : CFG.light; } }
    else if (e.target.closest('[data-keys]')) { keysPop(); return; }
    else return;
    const sc = el.scrollTop; el.innerHTML = settingsHtml(); el.scrollTop = sc; applyCfg();
  });
}
$('#setBtn').addEventListener('click', () => popEl && popEl.classList.contains('set') ? closePop() : settingsPop());

// shortcut sheet
const KEYS = [
  [['⌘', 'T'], 'новая сессия'], [['⌘', 'N'], 'новый терминал (делит текущий)'], [['D'], 'разделить вправо · ⇧D вниз'],
  [['⌘', 'K'], 'поиск по сессиям'], [['⌥', '⏎'], 'к следующему, кто ждёт'], [['↑', '↓'], 'курсор по сессиям, ⏎ открыть'],
  [['F'], 'развернуть терминал'], [['P'], 'отлепить, поверх всех сессий'], [['M'], 'свернуть в плашку'], [['W'], 'закрыть терминал'],
  [['T'], 'все терминалы в сетку'], [['F2'], 'переименовать сессию'], [['⌘', ','], 'настройки'], [['?'], 'эта шпаргалка'],
];
function keysPop() {
  $('#keyBtn').classList.add('on');
  openPop('keys', `<h5>Клавиши</h5><dl>${KEYS.map(([k, d]) => `<dt>${k.map(x => `<kbd>${x}</kbd>`).join('')}</dt><dd>${d}</dd>`).join('')}</dl>`,
    p => { const b = p.getBoundingClientRect(); p.style.left = (innerWidth - b.width) / 2 + 'px'; p.style.top = (innerHeight - b.height) / 2 + 'px'; }, true);
}
$('#keyBtn').addEventListener('click', () => popEl && popEl.classList.contains('keys') ? closePop() : keysPop());
addEventListener('keydown', e => {
  if (e.target.closest && e.target.closest('input,textarea')) return;
  if (e.key === 'Escape' && popEl) { closePop(); return; }
  if ((e.metaKey || e.ctrlKey) && e.key === ',') { e.preventDefault(); settingsPop(); }
  else if (e.key === '?') keysPop();
});
applyCfg();
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', e => { SYS.dark = e.matches; if (CFG.auto) applyCfg(); });
// every looping status animation runs on one clock: same name and period = same phase, wherever and whenever it was mounted
(function lockPhase() {
  for (const a of document.getAnimations()) {
    const t = a.effect.getTiming();
    if (t.iterations !== Infinity || a.playState !== 'running') continue;
    const want = -t.delay;
    if (a.startTime === null || Math.abs(a.startTime - want) > 0.5) a.startTime = want;
  }
  requestAnimationFrame(lockPhase);
})();
