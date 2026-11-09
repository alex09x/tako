'use strict';
// Tako desktop prototype — settings window. A terminal's look cascades like the native app:
// Общие → workspace → терминал (pane). A level either picks a preset (palette + font + size)
// or overrides single fields; the deepest value wins. The session is only context, not a level.
const FONTS = {
  jb: ['JetBrains', "'JetBrains Mono'"], sf: ['SF Mono', "'SF Mono',ui-monospace"], menlo: ['Menlo', 'Menlo'],
  fira: ['Fira Code', "'Fira Code'"], plex: ['Plex Mono', "'IBM Plex Mono'"],
};
(() => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=Fira+Code:wght@400;500&family=IBM+Plex+Mono:wght@400;500&display=swap'; document.head.appendChild(l); })();
// a preset is the whole look, not just colours
const PRESET_TYPE = { ember: ['jb', '12.5'], midnight: ['sf', '12.5'], gruvbox: ['fira', '12.5'], mocha: ['jb', '12.5'], paper: ['plex', '12.5'], latte: ['sf', '12.5'] };
const presetVal = (p, k) => ({ family: PRESET_TYPE[p][0], font: PRESET_TYPE[p][1], bg: THEMES[p].term, fg: THEMES[p].fg, cursor: '#F4581C' })[k];
// Appearance document, separate from layout (like the native Appearance.json): only overrides are stored,
// a missing field means "inherit"; reset deletes the field.
const APPEARANCE_KEY = 'tako.prototype.appearance.v1';
const APP = { version: 1, global: {}, workspaces: { inf: { preset: 'gruvbox' } }, panes: {} };   // demo: Infra on Gruvbox
try {
  const saved = JSON.parse(localStorage.getItem(APPEARANCE_KEY) || 'null');
  if (saved && saved.version === 1) { Object.assign(APP, saved); for (const k of ['theme', 'auto', 'dark', 'light']) if (saved.cfg && saved.cfg[k] !== undefined) CFG[k] = saved.cfg[k]; }
} catch (e) { /* storage unavailable: start from defaults */ }
function saveAppearance() {
  try { localStorage.setItem(APPEARANCE_KEY, JSON.stringify({ ...APP, cfg: { theme: CFG.theme, auto: CFG.auto, dark: CFG.dark, light: CFG.light } })); } catch (e) { /* ignore */ }
}
CFG.look = APP.global;               // fields overridden at the «Общие» level

// ---------- cascade ----------
const FIELDS = ['family', 'font', 'bg', 'fg', 'cursor'];
const ALL = { kind: 'all' };
const nodeOf = sc => sc.kind === 'ws' ? S.ws.find(x => x.id === sc.id) : sc.kind === 'w' ? findWin(sc.id)[1] : null;
const same = (a, b) => a.kind === b.kind && a.id === b.id;
const chainOf = sc => sc.kind === 'all' ? [ALL] : sc.kind === 'ws' ? [ALL, sc] : [ALL, { kind: 'ws', id: findWin(sc.id)[0].ws }, sc];
const mapOf = sc => sc.kind === 'ws' ? APP.workspaces : APP.panes;
const lookAt = sc => sc.kind === 'all' ? { ...CFG.look, preset: activeTheme() } : mapOf(sc)[sc.id] || {};
function resolveField(sc, k) {                    // → { v, from, how: 'own' | 'preset' }
  const ch = chainOf(sc);
  for (let i = ch.length - 1; i >= 0; i--) {
    const lk = lookAt(ch[i]);
    if (lk[k] !== undefined) return { v: lk[k], from: ch[i], how: 'own' };
    if (lk.preset) return { v: presetVal(lk.preset, k), from: ch[i], how: 'preset', preset: lk.preset };
  }
}
function resolvePreset(sc) {
  const ch = chainOf(sc);
  for (let i = ch.length - 1; i >= 0; i--) { const p = lookAt(ch[i]).preset; if (p) return { v: p, from: ch[i] }; }
}
const lookOf = sc => ({ preset: resolvePreset(sc).v, ...Object.fromEntries(FIELDS.map(k => [k, resolveField(sc, k).v])) });
const hasOwn = sc => sc.kind !== 'all' && Object.keys(lookAt(sc)).length > 0;
function setOwn(sc, k, v) {
  if (sc.kind === 'all') {
    if (k === 'preset') { CFG[CFG.auto ? (sysDark() ? 'dark' : 'light') : 'theme'] = v; for (const f in CFG.look) delete CFG.look[f]; }
    else if (v === undefined) delete CFG.look[k]; else CFG.look[k] = v;
    return saveAppearance();
  }
  const m = mapOf(sc), lk = m[sc.id] || {};
  if (k === 'preset') m[sc.id] = v === undefined ? Object.fromEntries(Object.entries(lk).filter(([x]) => x !== 'preset')) : { preset: v }; // picking a preset clears this level's own fields
  else { m[sc.id] = lk; if (v === undefined) delete lk[k]; else lk[k] = v; }
  if (!Object.keys(m[sc.id]).length) delete m[sc.id];
  saveAppearance();
}
const resetLevel = sc => { delete mapOf(sc)[sc.id]; saveAppearance(); };
const scopeName = sc => sc.kind === 'all' ? 'Общие' : sc.kind === 'ws' ? nodeOf(sc).name : nodeOf(sc).title;

// moving a session to another workspace: windows that inherited the old workspace keep looking the same
function carryLooks() {
  for (const s of S.sessions) {
    if (s._ws && s._ws !== s.ws) {
      const old = S.ws.find(w => w.id === s._ws);
      const oldLook = APP.workspaces[s._ws];
      if (old && oldLook) for (const w of s.windows) { const own = APP.panes[w.id] || {}; if (!own.preset) APP.panes[w.id] = { ...oldLook, ...own }; }
      saveAppearance();
    }
    s._ws = s.ws;
  }
}

// ---------- windows wear their resolved look ----------
const WIN_VARS = ['--term', '--text', '--sub', '--dim', '--mute', '--deep', '--line2', '--card', '--ok', '--err', '--yellow', '--blue', '--purple'];
function themeVars(t, bg, fg) {
  const d = t.tone === 'dark';
  return {
    '--term': bg, '--text': fg, '--sub': mix(fg, bg, .27), '--dim': mix(fg, bg, .45), '--mute': mix(fg, bg, .6),
    '--deep': mix(fg, bg, .72), '--line2': mix(bg, fg, d ? .15 : .17), '--card': mix(bg, fg, d ? .07 : .06),
    '--ok': t.green, '--err': t.red, '--yellow': t.yellow, '--blue': t.blue, '--purple': t.magenta,
  };
}
function applyLooks() {
  carryLooks();
  const g = THEMES[activeTheme()];
  for (const [id, el] of els) {
    if (!findWin(id)[1]) continue;
    const lk = lookOf({ kind: 'w', id }), t = THEMES[lk.preset];
    if (t === g && lk.bg === g.term && lk.fg === g.fg) WIN_VARS.forEach(k => el.style.removeProperty(k));
    else { const v = themeVars(t, lk.bg, lk.fg); for (const k in v) el.style.setProperty(k, v[k]); }
    el.style.setProperty('--fs', lk.font + 'px');
    el.style.setProperty('--tf', FONTS[lk.family][1]);
    el.style.setProperty('--cursor', lk.cursor);
  }
  markEditing();
}
const _renderLook = render;
render = a => { _renderLook(a); applyLooks(); };

// ---------- the window ----------
const SET = { scope: ALL, tip: ALL, page: 'look', adv: false };
const PAGES = [['look', 'Оформление'], ['win', 'Терминалы', 'общие'], ['side', 'Сайдбар', 'общие'], ['keys', 'Клавиши', 'общие']];
const lookNote = () => SET.scope.kind === 'all' ? 'базовое' : hasOwn(SET.scope) ? 'есть свои настройки' : 'всё наследуется';
const scKey = sc => sc.kind + ':' + (sc.id || '');
const scParse = k => { const [kind, id] = k.split(':'); return kind === 'all' ? ALL : { kind, id }; };

function crumbs() {
  return '<span class="lbl">Для</span>' + chainOf(SET.tip).map(sc => {
    const dot = sc.kind === 'ws' ? `<i class="dot" style="background:${nodeOf(sc).color}"></i>` : '';
    const ctx = sc.kind === 'w' ? `<small>терминал</small>` : sc.kind === 'ws' ? '<small>workspace</small>' : '';
    const sess = sc.kind === 'w' ? `<small class="in">в сессии ${esc(findWin(sc.id)[0].title)}</small>` : '';
    const own = hasOwn(sc) ? '<span class="od" title="У этого уровня есть свои настройки оформления">своё</span>' : '';
    return `<button class="cr ${same(sc, SET.scope) ? 'on' : ''}" data-sc="${scKey(sc)}" title="${esc(scopeName(sc))}">${dot}${ctx}<b>${esc(scopeName(sc))}</b>${sess}${own}</button>`;
  }).join('<span class="sep">›</span>');
}
function caption(k) {
  const sc = SET.scope;
  if (k === 'preset') {
    if (sc.kind === 'all') return '';
    const r = resolvePreset(sc);
    return same(r.from, sc) ? `<em class="own">● Свой</em><em><a data-reset="preset">↺ сбросить</a></em>` : `<em>Наследуется от «${esc(scopeName(r.from))}»</em>`;
  }
  const r = resolveField(sc, k);
  if (same(r.from, sc) && r.how === 'own') return `<em class="own">● Своё</em><em><a data-reset="${k}">↺ сбросить</a></em>`;
  if (r.how === 'preset') return `<em>из пресета ${THEMES[r.preset].name}${same(r.from, sc) ? '' : ` · от «${esc(scopeName(r.from))}»`}</em>`;
  return `<em>Наследуется от «${esc(scopeName(r.from))}»</em>`;
}
const lseg = (k, opts) => { const v = resolveField(SET.scope, k).v;
  return `<div class="sg" data-k="${k}">${opts.map(([x, l]) => `<button data-v="${x}" class="${v === x ? 'on' : ''}">${l}</button>`).join('')}</div>`; };
const lfont = () => { const v = resolveField(SET.scope, 'family').v;
  return `<select class="fsel" data-sel="family">${Object.entries(FONTS).map(([k, [n]]) => `<option value="${k}" ${v === k ? 'selected' : ''}>${n}</option>`).join('')}</select><span class="sub">моноширинные шрифты, установленные в системе</span>`; };
const lcolor = k => { const v = resolveField(SET.scope, k).v; return `<label class="cp"><input type="color" data-c="${k}" value="${v}"><span>${v.toUpperCase()}</span></label>`; };
const lgrid = (k, filter, cur) => `<div class="thg" data-k="${k}">${Object.keys(THEMES).filter(x => !filter || THEMES[x].tone === filter)
  .map(x => `<button class="th ${cur === x ? 'on' : ''}" data-v="${x}">${swatch(x)}<span>${THEMES[x].name}<em>${FONTS[PRESET_TYPE[x][0]][0]}</em></span></button>`).join('')}</div>`;
const fr = (label, ctl, cap = '') => `<div class="fr"><div class="lb">${label}${cap}</div><div class="ct">${ctl}</div></div>`;

function preview(lk) {
  const t = THEMES[lk.preset], bg = lk.bg, fg = lk.fg, dim = mix(fg, bg, .45);
  return `<div class="pv" style="background:${bg};color:${fg};font-family:${FONTS[lk.family][1]},monospace;font-size:${lk.font}px"><b style="color:${dim}">${t.name} · ${FONTS[lk.family][0]} ${lk.font}</b>\n`
    + `<span style="color:${t.cyan}">~/tako</span> <span style="color:${t.magenta}">main ±2</span> <span style="color:${t.green}">❯</span> mitts test -p auth\n`
    + `<span style="color:${dim}">⚡ Mitts Build  test [dev]</span>\n`
    + `test jwt::verify ... <span style="color:${t.green}">ok</span>\n`
    + `test jwt::refresh ... <span style="color:${t.red}">FAILED</span>\n`
    + `<span style="color:${t.yellow}">warning</span>: unused import <span style="color:${t.blue}">std::fmt</span>  <i style="background:${lk.cursor}"></i></div>`;
}
function pageLook() {
  const sc = SET.scope, lk = sc.kind === 'all' ? lookOf({ kind: 'all' }) : lookOf(sc);
  let presets;
  if (sc.kind === 'all') {
    presets = `<div class="rw"><span>Как в системе</span>${tog('auto')}</div>` + (CFG.auto
      ? `<span class="sub">Тёмный</span>${lgrid('dark', 'dark', CFG.dark)}<span class="sub">Светлый</span>${lgrid('light', 'light', CFG.light)}
         <span class="sub">система сейчас: ${sysDark() ? 'тёмная' : 'светлая'} · <a data-sys>переключить</a></span>`
      : lgrid('preset', null, CFG.theme));
  } else presets = lgrid('preset', null, lk.preset);
  presets += '<span class="sub">Пресет — цвета, шрифт и размер целиком. Выбор пресета сбрасывает свои поля этого уровня.</span>';
  const adv = `<button class="adv ${SET.adv ? 'open' : ''}" data-adv><span>▸</span>Настроить…<small>${FIELDS.filter(k => same(resolveField(sc, k).from, sc) && resolveField(sc, k).how === 'own').length || ''}</small></button>`
    + (SET.adv ? '<div class="advb">'
      + fr('Шрифт', lfont(), caption('family'))
      + fr('Размер', lseg('font', [['11', '11'], ['12.5', '12.5'], ['14', '14']]), caption('font'))
      + fr('Фон', lcolor('bg'), caption('bg'))
      + fr('Текст', lcolor('fg'), caption('fg'))
      + fr('Курсор', lcolor('cursor'), caption('cursor'))
      + '</div>' : '');
  return preview(lk) + fr('Пресет', presets, caption('preset')) + adv;
}
const pageWin = () => fr('Неактивные терминалы', seg('dim', [['1', 'как есть'], ['.72', 'тусклее'], ['.5', 'сильно']]), '<em>тот, в котором печатаешь, всегда яркий</em>')
  + fr('Новый терминал', seg('split', [['auto', 'авто'], ['h', 'справа'], ['v', 'снизу']]), '<em>куда делить текущий</em>')
  + fr('Анимации', seg('motion', [['full', 'все'], ['off', 'без']]))
  + fr('Уведомления', tog('toasts'), '<em>только для того, что сейчас не видно</em>');
const pageSide = () => fr('Строки', seg('density', [['normal', 'две'], ['compact', 'одна']]))
  + fr('Терминалы сессий', seg('kids', [['all', 'у всех'], ['active', 'у открытой']]))
  + fr('Ветка git', tog('git')) + fr('Порты', tog('ports'));
const pageKeys = () => `<dl class="kl">${KEYS.map(([k, d]) => `<dt>${k.map(x => `<kbd>${x}</kbd>`).join('')}</dt><dd>${d}</dd>`).join('')}</dl>`;

const PAGE_BODY = { look: pageLook, win: pageWin, side: pageSide, keys: pageKeys };
function settingsWinHtml() {
  const look = SET.page === 'look';
  const nav = PAGES.map(([id, label, note]) => `<button class="nv ${SET.page === id ? 'on' : ''}" data-pg="${id}">${label}<small class="${id === 'look' && hasOwn(SET.scope) ? 'ownn' : ''}">${note || lookNote()}</small></button>`).join('');
  const body = PAGE_BODY[SET.page]();
  const top = look ? `<div class="crumbs">${crumbs()}</div>` : '<div class="crumbs glob"><span>Общие настройки приложения — действуют на все workspace и терминалы.</span></div>';
  const lvl = SET.scope.kind === 'ws' ? 'workspace' : 'терминала';
  const reset = look && SET.scope.kind !== 'all' && hasOwn(SET.scope)
    ? `<a data-resetall title="Удаляет только переопределения этого уровня. Соседние терминалы и собственные настройки терминалов внутри остаются.">Сбросить оформление ${lvl} «${esc(scopeName(SET.scope))}»</a>`
    : '<span>сохраняется сразу · Esc — закрыть</span>';
  return `<div class="sw-hd"><h5>Настройки</h5><button class="sw-x" data-close title="Закрыть · Esc">✕</button></div>${top}
    <div class="sw-main"><nav>${nav}</nav><section class="sw-pg">${body}</section></div>
    <div class="ft"><span>Tako 0.1.10</span>${reset}</div>`;
}
// the terminals being edited get a Claw outline, so the change is seen on the real thing
function markEditing() {
  const pe = typeof popEl !== 'undefined' && popEl && popEl.classList.contains('setwin');
  for (const [id, el] of els) {
    const sc = SET.scope, [s] = findWin(id);
    el.classList.toggle('editing', !!pe && SET.page === 'look' && ((sc.kind === 'w' && sc.id === id) || (sc.kind === 'ws' && s && s.ws === sc.id)));
  }
}
function redraw(el) {
  const pg = el.querySelector('.sw-pg'), sc = pg ? pg.scrollTop : 0;
  el.innerHTML = settingsWinHtml();
  el.querySelector('.sw-pg').scrollTop = sc;
  placeSet(el); markEditing();
}
function showScope(sc) {                           // bring the edited terminals on screen
  if (sc.kind === 'w') { const [s, w] = findWin(sc.id); if (s && s.id !== S.active && w.mode !== 'float') switchSession(s.id); }
  if (sc.kind === 'ws' && cur() && cur().ws !== sc.id) { const s = S.sessions.find(x => x.ws === sc.id); if (s) switchSession(s.id); }
}
// stand clear of the terminal being edited: it sits on the right → settings go left, and back
function placeSet(p) {
  const b = p.getBoundingClientRect(), cv = $('#canvas').getBoundingClientRect();
  const t = SET.page === 'look' && SET.scope.kind === 'w' && els.get(SET.scope.id);
  const r = t && t.getBoundingClientRect();
  const left = r && r.left + r.width / 2 > cv.left + cv.width / 2 ? 16 : Math.min(innerWidth - b.width - 16, cv.right - b.width - 20);
  p.style.left = Math.round(left) + 'px';
  p.style.top = Math.round(Math.max(16, (innerHeight - b.height) / 2)) + 'px';
}
function openSettings(sc) {
  if (sc) { SET.tip = sc; SET.scope = sc; SET.page = 'look'; showScope(sc); }
  else { SET.tip = S.focus && findWin(S.focus)[1] ? { kind: 'w', id: S.focus } : ALL; SET.scope = ALL; }
  const el = openPop('set setwin', settingsWinHtml(), placeSet, true);
  scrimEl.classList.add('light');
  $('#setBtn').classList.add('on');
  markEditing();
  el.addEventListener('input', e => {             // colour pickers: live on the terminals, no redraw while dragging
    const c = e.target.closest('[data-c]'); if (!c) return;
    setOwn(SET.scope, c.dataset.c, c.value); c.nextElementSibling.textContent = c.value.toUpperCase(); applyCfg();
  });
  el.addEventListener('change', e => {
    const sel = e.target.closest('[data-sel]');
    if (sel) { setOwn(SET.scope, sel.dataset.sel, sel.value); redraw(el); return applyCfg(); }
    if (e.target.closest('[data-c]')) redraw(el);
  });
  el.addEventListener('click', e => {
    const t = e.target;
    if (t.closest('[data-close]')) return closePop();
    if (t.closest('[data-c]') || t.closest('.cp') || t.closest('[data-sel]')) return;
    const cr = t.closest('[data-sc]'), nv = t.closest('[data-pg]'), rs = t.closest('[data-reset]');
    const v = t.closest('[data-v]'), tg = t.closest('[data-t]');
    if (cr) { SET.scope = scParse(cr.dataset.sc); showScope(SET.scope); redraw(el); return applyCfg(); }
    if (nv) { SET.page = nv.dataset.pg; return redraw(el); }
    if (t.closest('[data-adv]')) { SET.adv = !SET.adv; return redraw(el); }
    if (rs) setOwn(SET.scope, rs.dataset.reset, undefined);
    else if (t.closest('[data-resetall]')) resetLevel(SET.scope);
    else if (t.closest('[data-sys]')) SYS.dark = !SYS.dark;
    else if (v) {
      const k = v.closest('[data-k]').dataset.k;
      if (k === 'preset' || FIELDS.includes(k)) setOwn(SET.scope, k, v.dataset.v);
      else { CFG[k] = v.dataset.v; if (k === 'kids') S.sessions.forEach(x => x.open = undefined); if (k === 'dark' || k === 'light') for (const f in CFG.look) delete CFG.look[f]; }
    } else if (tg) {
      const k = tg.dataset.t; CFG[k] = !CFG[k];
      if (k === 'auto' && CFG.auto) { CFG.dark = THEMES[CFG.theme].tone === 'dark' ? CFG.theme : CFG.dark; CFG.light = THEMES[CFG.theme].tone === 'light' ? CFG.theme : CFG.light; }
    } else return;
    saveAppearance(); redraw(el); applyCfg();
  });
  return el;
}
settingsPop = () => openSettings();
// the demo «сброс» reloads the page: forget the stored appearance first
addEventListener('click', e => { if (e.target.closest('[data-act=reset]')) try { localStorage.removeItem(APPEARANCE_KEY); } catch (err) { /* ignore */ } }, true);
const _closePopLook = closePop;
closePop = () => { _closePopLook(); markEditing(); };

// ---------- "Оформление…" in the workspace and window menus ----------
let ctxExtra = null;
const _openCtxLook = openCtx;
openCtx = (items, x, y) => {
  if (ctxExtra) { items = [...items]; const i = items.lastIndexOf('-'); items.splice(i < 0 ? items.length : i, 0, '-', ctxExtra); ctxExtra = null; }
  _openCtxLook(items, x, y);
};
const lookItem = sc => ({ label: 'Оформление…', kbd: hasOwn(sc) ? 'своё' : '', run: () => openSettings(sc) });
const _wsMenuLook = wsMenu;
wsMenu = (ws, x, y) => { ctxExtra = lookItem({ kind: 'ws', id: ws.id }); _wsMenuLook(ws, x, y); };
const _winMenuLook = winMenu;
winMenu = (id, x, y) => { ctxExtra = lookItem({ kind: 'w', id }); _winMenuLook(id, x, y); };

applyCfg();
