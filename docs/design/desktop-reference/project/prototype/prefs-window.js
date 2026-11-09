'use strict';
// Tako desktop prototype — the settings window: one centred window, a section list with search, and the pages.
// Appearance has a level (Общие › workspace › терминал); every other section is app-wide and says so.
const PSET = { q: '', hl: null, msg: '' };
const PF_IC = {
  general: '<path d="M8 5.6a2.4 2.4 0 1 0 0 4.8 2.4 2.4 0 0 0 0-4.8Z"/><path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1"/>',
  look: '<path d="M8 2a6 6 0 1 0 0 12c.9 0 1.3-.6 1.1-1.3-.3-.9.3-1.7 1.2-1.7H12a2 2 0 0 0 2-2A6 6 0 0 0 8 2Z"/><circle cx="5.2" cy="7" r=".7"/><circle cx="7.6" cy="4.8" r=".7"/><circle cx="10.4" cy="5.8" r=".7"/>',
  term: '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="m4.6 6.4 2 1.6-2 1.6M8.2 10h3"/>',
  win: '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="M1.8 5.6h12.4M7 5.6v7.6"/>',
  quick: '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="M1.8 7.4h12.4"/><path d="M6.4 9.6 8 11l1.6-1.4" opacity=".7"/>',
  keys: '<rect x="1.8" y="4.2" width="12.4" height="7.6" rx="1.6"/><path d="M4.4 6.7h.01M6.8 6.7h.01M9.2 6.7h.01M11.6 6.7h.01M5.2 9.3h5.6"/>',
  agents: '<path d="M8 2.2 9.3 6l3.9.1-3.1 2.4 1.1 3.8L8 10.1l-3.2 2.2 1.1-3.8-3.1-2.4L6.7 6 8 2.2Z"/>',
  perms: '<path d="M8 1.9 13 3.8v3.7c0 3-2 5.3-5 6.6-3-1.3-5-3.6-5-6.6V3.8L8 1.9Z"/><path d="m5.8 8 1.6 1.6 2.8-3"/>',
  adv: '<path d="M2.5 4.5h7M12 4.5h1.5M2.5 11.5h2M7 11.5h6.5"/><circle cx="10.6" cy="4.5" r="1.4"/><circle cx="5.6" cy="11.5" r="1.4"/>',
};
const PF_SECS = [['general', 'Общее'], ['look', 'Оформление'], ['term', 'Терминал'], ['win', 'Окна и workspace'], ['quick', 'Quick Terminal'], ['keys', 'Клавиши'], ['agents', 'Агенты'], ['perms', 'Уведомления и доступы'], ['adv', 'Дополнительно']];
const pfIcon = id => `<svg viewBox="0 0 16 16" class="pf-ic">${PF_IC[id]}</svg>`;

// ---------- one settings row: title, what it does, the real key, when it applies ----------
function pfCtl(it) {
  const v = pfGet(it.id);
  if (it.type === 'bool') return `<button class="tg ${v ? 'on' : ''}" data-ps="${it.id}" aria-pressed="${!!v}"></button>`;
  if (it.type === 'opt') return `<span class="pf-seg">${it.opts.map(([x, l]) => `<button data-ps="${it.id}" data-v="${x}" class="${v === x ? 'on' : ''}">${l}</button>`).join('')}</span>`;
  if (it.type === 'num') return pfStepper('pn-' + it.id, v, it.min, it.max, it.step, it.unit);
  if (it.type === 'color') return `<label class="pf-color"><input type="color" data-pcol="${it.id}" value="${v}"><code>${String(v).toUpperCase()}</code></label>`;
  if (it.type === 'pos') return `<span class="pf-pos">${it.opts.map(([x, l]) => `<button data-ps="${it.id}" data-v="${x}" class="p-${x} ${v === x ? 'on' : ''}" title="${l}"><i></i></button>`).join('')}</span><span class="pf-src">${it.opts.find(o => o[0] === v)[1]}</span>`;
}
function pfRow(it) {
  const chg = PREFS.set[it.id] !== undefined;
  return `<div class="pf-row ${PSET.hl === it.id ? 'hl' : ''}" data-row="${it.id}"><div class="pf-rl"><b>${it.t}</b>${it.d ? `<span>${it.d}</span>` : ''}<code>${it.id}${it.when ? ` · ${it.when}` : ''}</code></div>
    <div class="pf-rc">${pfCtl(it)}${chg ? `<a class="pf-rst" data-sreset="${it.id}" title="Вернуть стандартное">↺</a>` : ''}</div></div>`;
}
const pfRows = (sec, ids) => (ids || PF_SET.filter(x => x.sec === sec).map(x => x.id)).map(id => pfRow(PF_SET.find(x => x.id === id))).join('');
const pfGroup = (h, html, note) => `<section class="pf-blk"><header><h4>${h}</h4>${note ? `<span class="pf-src">${note}</span>` : ''}</header>${html}</section>`;

const PF_PAGES = {
  general: () => pfGroup('Закрытие', pfRows(0, ['confirm-close-surface']))
    + pfGroup('Новые окна и терминалы', pfRows(0, ['window-inherit-working-directory', 'window-inherit-font-size']))
    + pfGroup('Первый запуск', `<div class="pf-row"><div class="pf-rl"><b>Мастер настройки</b><span>Тема, агенты и доступы — пошагово, можно закончить позже.</span><code>Tako › Set Up Tako…</code></div><div class="pf-rc"><button class="pf-btn" data-wizard>Открыть мастер…</button></div></div>`),
  look: pfPageLook,
  term: () => pfGroup('Курсор', pfRows(0, ['cursor-style', 'cursor-style-blink']), 'для всех терминалов, если тема не задаёт свой')
    + pfGroup('Мышь и выделение', pfRows(0, ['mouse-hide-while-typing', 'copy-on-select']))
    + pfGroup('Вставка', pfRows(0, ['safe-paste']))
    + pfGroup('Шелл', pfRows(0, ['shell-integration'])),
  win: () => pfGroup('Workspace', pfRows(0, ['workspace-sync-window-frame']))
    + pfGroup('Окно', pfRows(0, ['background-blur']), 'стиль вкладок (tab-style) не показан: верхних вкладок в этом дизайне нет')
    + (IDEAS.on ? pfGroup('Предложения макета', fr('Неактивные терминалы', seg('dim', [['1', 'как есть'], ['.72', 'тусклее'], ['.5', 'сильно']])) + fr('Новый терминал', seg('split', [['auto', 'авто'], ['h', 'справа'], ['v', 'снизу']]))
      + fr('Строки сайдбара', seg('density', [['normal', 'две'], ['compact', 'одна']])) + fr('Ветка git', tog('git')) + fr('Порты', tog('ports')) + fr('Анимации', seg('motion', [['full', 'все'], ['off', 'без']])), 'идеи — в Tako 526 таких ключей не нашли') : ''),
  quick: () => pfGroup('Положение', pfRows(0, ['quick-terminal-position', 'quick-terminal-autohide']), 'выпадающий терминал без сайдбара')
    + pfGroup('Вызов', `<div class="pf-row"><div class="pf-rl"><b>Сочетание</b><span>Работает, пока Tako активен. Глобальный вызов из других приложений — отдельно, через Универсальный доступ.</span><code>toggle_quick_terminal</code></div><div class="pf-rc">${pfKHtml(pfKActive('toggle_quick_terminal'))}<button class="pf-btn" data-go="keys" data-kfind="Quick Terminal">Изменить…</button></div></div>`),
  keys: pfPageKeys,
  agents: () => PAGE_BODY.agents(),
  perms: () => PAGE_BODY.perms(),
  adv: () => pfGroup('Цвета статусов', pfRows('adv'), 'одинаковы во всех темах — статус узнаётся всегда')
    + pfGroup('Где это хранится', `<div class="pf-store"><p><code>~/.config/tako/config</code> общие настройки, тема Общих, keybind</p><p><code>~/.config/tako/themes/</code> свои темы, по файлу на тему</p><p><code>Appearance.json</code> оформление workspace и терминалов, по UUID</p></div>`)
    + pfGroup('Конфиг', `<pre class="pf-conf">${pfEsc(pfConfigPreview())}</pre>`, 'то, что этот макет записал бы; отсутствующий ключ = стандартное значение'),
};
function pfConfigPreview() {
  const L = ['# ~/.config/tako/config', `theme = ${CFG.theme}`];
  for (const [k, v] of Object.entries(PREFS.look.global)) L.push(`${k} = ${v}`);
  for (const [k, v] of Object.entries(PREFS.set)) L.push(`${k} = ${v}`);
  for (const [a, t] of Object.entries(PREFS.keys)) L.push(`keybind = ${t === 'unbound' ? (PF_KDEF[a] || '') + '=unbind' : t + '=' + a}`);
  const doc = { version: 1, workspaces: PREFS.look.workspaces, panes: PREFS.look.panes };
  L.push('', '# Appearance.json', JSON.stringify(doc, null, 1));
  if (IDEAS.on && Object.keys(PREFS.look.sessions).length) L.push('', '# расширение: sessions (в 526 нет)', JSON.stringify(PREFS.look.sessions, null, 1));
  for (const [n, c] of Object.entries(PREFS.themes)) L.push('', `# themes/${n}`, pfConfigText(c));
  return L.join('\n');
}

// ---------- search across every section ----------
function pfIndex() {
  const ix = PF_SET.map(it => ({ sec: it.sec, id: it.id, t: it.t, s: `${it.t} ${it.d} ${it.id} ${it.alias || ''}` }));
  for (const [id, t, s] of [['theme', 'Тема', 'тема пресет цвета палитра theme'], ['font-family', 'Шрифт', 'шрифт font family моноширинный'], ['font-size', 'Размер шрифта', 'размер шрифта font-size pt'],
    ['colors', 'Цвета поверх темы', 'фон текст курсор выделение background foreground cursor selection'], ['editor', 'Своя тема, дублировать', 'новая тема дублировать копия редактор']]) ix.push({ sec: 'look', id, t, s });
  for (const [a, t] of PF_KA) ix.push({ sec: 'keys', id: a, t, s: `${t} ${a} ${pfKStr(pfKActive(a))}`, k: pfKActive(a) });
  ix.push({ sec: 'agents', id: 'agents', t: 'Навык takoctl для агентов', s: 'агенты навык skill claude codex antigravity qwen muse gemini takoctl path' });
  ix.push({ sec: 'perms', id: 'perms', t: 'Доступы macOS и уведомления', s: 'уведомления доступ папки микрофон диск сеть запись экрана звук универсальный' });
  return ix;
}
function pfSearchHtml() {
  const q = PSET.q.trim().toLowerCase(), hits = pfIndex().filter(x => x.s.toLowerCase().includes(q) || x.t.toLowerCase().includes(q));
  if (!hits.length) return `<p class="pf-empty">Ничего не нашлось по «${pfEsc(PSET.q)}». Попробуйте по-английски — ищется и по ключам конфига.</p>`;
  return PF_SECS.map(([sec, l]) => { const h = hits.filter(x => x.sec === sec).slice(0, 8);
    return h.length ? `<div class="pf-res"><h5>${pfIcon(sec)}${l}</h5>${h.map(x => `<button data-go="${sec}" data-hl="${pfEsc(x.id)}"${sec === 'keys' ? ` data-kfind="${pfEsc(x.t)}"` : ''}><b>${pfEsc(x.t)}</b>${x.k ? pfKHtml(x.k) : `<code>${pfEsc(x.id)}</code>`}</button>`).join('')}</div>` : ''; }).join('');
}

// ---------- the window ----------
function pfCrumbs() {
  const tip = SET.tip, ch = pfChain(tip.kind === 'all' ? SET.scope : tip);
  return '<span class="pf-for">Для</span>' + ch.map(sc => {
    const ext = sc.kind === 'ses', dot = sc.kind === 'ws' ? `<i class="dot" style="background:${(S.ws.find(x => x.id === sc.id) || {}).color}"></i>` : '';
    const ctx = sc.kind === 'w' && !IDEAS.on ? `<small>в сессии ${pfEsc(findWin(sc.id)[0].title)}</small>` : '';
    return `<button class="pf-cr ${pfSame(sc, SET.scope) ? 'on' : ''} ${ext ? 'ext' : ''}" data-sc="${sc.kind}:${sc.id || ''}" title="${ext ? 'Уровень «сессия» — запрошенное расширение, в Tako 526 его нет' : ''}">${dot}<small>${pfKindName(sc)}</small>${sc.kind === 'all' ? '' : `<b>${pfEsc(pfScName(sc))}</b>`}${ctx}${pfHasOwn(sc) ? '<span class="od">своё</span>' : ''}${ext ? '<span class="xt">расширение</span>' : ''}</button>`;
  }).join('<span class="sep">›</span>');
}
function pfFootHtml() {
  const pg = SET.page, search = !!PSET.q.trim();
  const lvl = pfKindName(SET.scope);
  return PED ? `<span class="pf-msg">${pfEdErrors().length ? '<b class="pf-err">Есть ошибки — тема не сохранится</b>' : `Живой предпросмотр на терминалах «${pfEsc(pfScName(PED.sc))}»${pfDirty() ? ` · изменено ${pfDirty()}` : ''}`}</span><button class="pf-btn" data-edcancel>Отменить</button><button class="pf-btn pri" data-edsave ${pfEdErrors().length ? 'disabled' : ''}>Сохранить тему</button>`
    : `<span class="pf-msg">${PSET.msg ? pfEsc(PSET.msg) : `Tako 0.1.10 · сохраняется сразу · Esc — закрыть`}</span>${pg === 'look' && !search && SET.scope.kind !== 'all' && pfHasOwn(SET.scope) ? `<button class="pf-btn" data-lresetall title="Удаляет переопределения только этого уровня; соседние и вложенные остаются">Сбросить оформление: ${lvl} «${pfEsc(pfScName(SET.scope))}»</button>` : ''}`;
}
function pfWinHtml() {
  const pg = SET.page, search = !!PSET.q.trim();
  const nav = PF_SECS.map(([id, l]) => { const note = id === 'look' ? (pfHasOwn(SET.scope) ? 'есть свои' : '') : id === 'keys' ? (PF_KA.filter(([a]) => pfKChanged(a)).length || '') : '';
    return `<button class="pf-nv ${!search && pg === id ? 'on' : ''}" data-pg="${id}" ${PED ? 'disabled' : ''}>${pfIcon(id)}<span>${l}</span>${note ? `<small>${note}</small>` : ''}</button>`; }).join('');
  const top = !search && pg === 'look' && !PED ? `<div class="pf-scope">${pfCrumbs()}</div>` : !search && ['agents', 'perms'].includes(pg) ? '' : !search && pg !== 'look' ? '<div class="pf-scope glob">Общие настройки приложения — для всех workspace и терминалов</div>' : '';
  const title = search ? `Поиск: «${pfEsc(PSET.q)}»` : PF_SECS.find(s => s[0] === pg)[1];
  return `<div class="pf-side"><div class="pf-hd"><h5>Настройки</h5></div><label class="pf-q"><svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.2"/><path d="m10.2 10.2 3.2 3.2"/></svg><input data-pq placeholder="Поиск" value="${pfEsc(PSET.q)}" spellcheck="false" ${PED ? 'disabled' : ''}></label><nav>${nav}</nav></div>
    <div class="pf-main"><div class="pf-top"><h4>${title}</h4><button class="sw-x" data-close title="Закрыть · Esc">✕</button></div>${top}
      <div class="pf-pg">${search ? pfSearchHtml() : PF_PAGES[pg]()}</div><div class="pf-ft">${pfFootHtml()}</div></div>`;
}
redraw = el => {
  const pg = el.querySelector('.pf-pg'), y = pg ? pg.scrollTop : 0, f = document.activeElement, fk = f && el.contains(f) && f.matches('input,textarea') ? [...f.attributes].find(a => a.name.startsWith('data-')) : null;
  el.innerHTML = pfWinHtml();
  const np = el.querySelector('.pf-pg'); np.scrollTop = y;
  if (fk) { const n = el.querySelector(`[${fk.name}${fk.value ? `="${fk.value}"` : ''}]`); if (n) { n.focus(); if (n.setSelectionRange && n.type !== 'color' && n.type !== 'range') n.setSelectionRange(n.value.length, n.value.length); } }
  if (SET.page === 'keys') pfKFilter(el);
  if (PSET.hl) { const r = el.querySelector(`[data-row="${CSS.escape(PSET.hl)}"],[data-ka="${CSS.escape(PSET.hl)}"]`); if (r) { r.scrollIntoView({ block: 'center' }); r.classList.add('hl'); } PSET.hl = null; }
  placeSet(el); markEditing();
};
placeSet = p => {
  const a = $('#app').getBoundingClientRect(), w = Math.min(820, a.width - 24), h = Math.min(700, Math.max(380, a.height - 24));
  Object.assign(p.style, { width: w + 'px', height: h + 'px', left: Math.round(a.left + (a.width - w) / 2) + 'px', top: Math.round(a.top + (a.height - h) / 2) + 'px' });
};
markEditing = () => {
  const open = !!document.querySelector('.pop.pf'), sc = SET.scope;
  for (const [id, el] of els) { const s = findWin(id)[0];
    el.classList.toggle('editing', open && SET.page === 'look' && !PSET.q && sc.kind !== 'all' && ((sc.kind === 'w' && sc.id === id) || (sc.kind === 'ws' && s && s.ws === sc.id) || (sc.kind === 'ses' && s && s.id === sc.id))); }
};
function pfShow(sc) {                             // bring the edited terminals on screen
  if (sc.kind === 'w') { const [s, w] = findWin(sc.id); if (s && s.id !== S.active && w.mode !== 'float') switchSession(s.id); }
  if (sc.kind === 'ses' && S.active !== sc.id) switchSession(sc.id);
  if (sc.kind === 'ws' && cur() && cur().ws !== sc.id) { const s = S.sessions.find(x => x.ws === sc.id); if (s) switchSession(s.id); }
}
const pfScParse = k => { const [kind, id] = k.split(':'); return kind === 'all' ? PF_ALL : { kind, id }; };
openSettings = (sc, page, opt = {}) => {
  if (sc) { SET.tip = sc; SET.scope = sc; SET.page = page || 'look'; pfShow(sc); }
  else { SET.tip = S.focus && findWin(S.focus)[1] ? { kind: 'w', id: S.focus } : PF_ALL; SET.scope = PF_ALL; if (page) SET.page = page; if (!PF_PAGES[SET.page]) SET.page = 'general'; }
  PSET.q = ''; PSET.msg = ''; PL.tq = opt.tq || ''; PL.ren = PL.del = null; PK.rec = null; PK.conf = null;
  const el = openPop('set setwin pf', '', placeSet, true);
  scrimEl.classList.add('light'); $('#setBtn').classList.add('on');
  redraw(el); pfWire(el);
  if (opt.focus) { const i = el.querySelector(opt.focus); if (i) i.focus(); }
  if (SET.page === 'perms') readStatuses('статусы прочитаны при открытии раздела');
  return el;
};
settingsPop = () => openSettings();
const _closePopPf = closePop;
closePop = () => { if (PED) pfCancelEditor(); PK.rec = null; PK.conf = null; _closePopPf(); markEditing(); };
// Esc inside the editor cancels the draft first; inside the recorder the recorder owns it
addEventListener('keydown', e => {
  if (e.key !== 'Escape' || !document.querySelector('.pop.pf') || PK.rec || PK.conf) return;
  if (PED && !e.target.closest('textarea')) { e.preventDefault(); e.stopImmediatePropagation(); pfCancelEditor(); redraw(document.querySelector('.pop.pf')); }
}, true);
