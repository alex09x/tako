'use strict';
// Tako desktop prototype — settings model, mirrored from native 526 (tako-agent-integrations 9785be25):
// • built-in theme presets = swift/Resources/themes (10 files); user presets live in «themes» next to the config;
// • a terminal's look cascades Общие → workspace → терминал (Appearance.json: workspaces/panes by UUID);
//   «сессия» between them is an explicitly requested extension, visible only with «показать идеи»;
// • app settings = TerminalSettingRegistry keys, keybind overrides = «keybind = trigger=action» lines.
const PF_NT = {
  'TakoCore': ['#14100e', '#ede6df', '#f4581c', '#352b23', '#faf7f2', '#14100e #d54e53 #b5bd68 #f0c674 #81a2be #b294bb #8abeb7 #ede6df #6b6259 #ff7a3d #7bd88f #f4c96b #9bb8d3 #c9a8d0 #a3d3cd #faf7f2'],
  'Tako Dawn': ['#f4f3f7', '#222436', '#e05666', '#dad5ea', '#181928', '#222436 #b63d58 #367b57 #98681b #2e64a8 #774996 #1e7885 #aca7bc #676277 #cf4a69 #48946e #b27d28 #417ec8 #905eb0 #2c91a0 #f9f8fc'],
  'Tako Ember': ['#1c1210', '#f2e5d5', '#ff5925', '#42231b', '#fff3eb', '#1c1210 #e05349 #9bb362 #e59a3c #7898ba #c6749d #6eb8b0 #dfd2c4 #7a665d #f26d5c #b0cc74 #fab852 #94b5db #da8fb5 #8ad4ca #fdf6ee'],
  'Tako Forest': ['#111a16', '#e0e9db', '#eab080', '#34483a', '#f5faf0', '#111a16 #d67d77 #9bc58a #d2bd7e #8da9c1 #b9a1bd #83bdb0 #d1dfcd #728476 #ed9790 #b4dda2 #ead79d #a9c2d8 #d2b8d3 #9fd7c8 #f5faf0'],
  'Tako Ink': ['#0d0e12', '#eaedf2', '#ff4d5a', '#202534', '#fafbfe', '#0d0e12 #e35252 #5ab074 #df9d41 #588de4 #ae6ce0 #48b2b5 #d3d8e0 #5c6374 #f26868 #74cca0 #f0b55d #75a4f0 #c387ec #66cecf #fafbfe'],
  'Tako Night': ['#11151e', '#e3e8f0', '#e9a46d', '#303d50', '#f6f8fb', '#11151e #d9787b #9ac88b #d7bd78 #8baed3 #b99bcf #82bfc2 #d5dce8 #667487 #f28b89 #b1dda0 #f0d596 #a6c7ec #d2b4e6 #9bd8d9 #f6f8fb'],
  'Tako Ocean': ['#0e1820', '#dce9ea', '#e8ad79', '#29434c', '#f4faf9', '#0e1820 #d77876 #8fc29e #d4bc7a #83b3d0 #b69fc9 #7cc5c0 #cadcdd #617d83 #ec9290 #a9d9b5 #ead49a #9fcce5 #ceb6df #99dfd6 #f4faf9'],
  'Tako Paper': ['#f6f4ee', '#262320', '#b83a24', '#dfd7c6', '#1a1816', '#262320 #b9382f #3d7a44 #996814 #2a639b #83477d #247875 #b0a898 #686259 #cf493e #51944e #b57d19 #3d7ec2 #9b5a94 #359491 #fbfaf7'],
  'Tako Slate': ['#17191c', '#e7e7e4', '#e4a376', '#3b3e43', '#f8f8f5', '#17191c #d17e7b #a6c18d #d1bd85 #91aec6 #bba2c2 #8abfb8 #d9dad7 #7b8084 #e8958f #bed8a4 #e8d5a4 #acc8dd #d4bad8 #a4d8ce #f8f8f5'],
  'Tako Violet': ['#160f21', '#efe7f6', '#d24ff0', '#3c2858', '#f9f5ff', '#160f21 #e45b7e #70bf94 #dbaf54 #7685e8 #b768e8 #4ebdbe #dcd3eb #6b5c7d #f57095 #8ddcb0 #f2c76e #96a2f6 #cf82f8 #6edbd6 #f9f5ff'],
};
const PF_BUILTIN = Object.keys(PF_NT);
const pfBuiltinCfg = n => { const [bg, fg, cur, sb, sf, pal] = PF_NT[n];
  return { 'font-family': 'Menlo', 'font-size': '13', background: bg, foreground: fg, 'cursor-color': cur, 'selection-background': sb, 'selection-foreground': sf, palette: pal.split(' ') }; };
const pfLum = h => { const [r, g, b] = hex(h); return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255; };
function pfThemeObj(name, cfg, builtin) {
  const p = cfg.palette || [], term = cfg.background || '#14100e', dark = pfLum(term) < .5;
  return { name, builtin, cfg, tone: dark ? 'dark' : 'light', term, bg: mix(term, dark ? '#000000' : '#6a6058', dark ? .2 : .05), fg: cfg.foreground,
    red: p[1], green: p[2], yellow: p[3], blue: p[4], magenta: p[5], cyan: p[6] };
}

// ---------- fonts: in Tako the list is fontInventory() of this Mac; here a typical Mac plus the fonts Tako bundles ----------
(() => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=PT+Mono&display=swap'; document.head.appendChild(l); })();
const PF_FONTS = [
  ['Menlo', 'Menlo, Monaco, monospace', 'macOS'], ['SF Mono', "'SF Mono', ui-monospace, Menlo, monospace", 'macOS'],
  ['JetBrains Mono', "'JetBrains Mono', monospace", 'в Tako'], ['JetBrainsMono Nerd Font', "'JetBrains Mono', monospace", 'в Tako'],
  ['Fira Code', "'Fira Code', monospace", 'в Tako'], ['Monaco', 'Monaco, Menlo, monospace', 'macOS'], ['PT Mono', "'PT Mono', monospace", 'macOS'],
  ['IBM Plex Mono', "'IBM Plex Mono', monospace", 'установлен'], ['Courier New', "'Courier New', monospace", 'macOS'], ['Andale Mono', "'Andale Mono', monospace", 'macOS'],
];
const pfFontCss = f => (PF_FONTS.find(x => x[0] === f) || [0, `'${f}', Menlo, monospace`])[1];

// ---------- one stored document (the native app splits it: config, themes/, Appearance.json) ----------
const PF_KEY = 'tako.prototype.prefs.v2';
const PREFS = { v: 2, theme: 'TakoCore', themes: {}, look: { global: {}, workspaces: {}, sessions: {}, panes: {} }, set: {}, keys: {}, recent: [] };
let pfFresh = true;
try { const s = JSON.parse(localStorage.getItem(PF_KEY) || 'null'); if (s && s.v === 2) { Object.assign(PREFS, s); pfFresh = false; } } catch (e) { /* no storage: defaults */ }
const pfSave = () => { PREFS.theme = CFG.theme; try { localStorage.setItem(PF_KEY, JSON.stringify(PREFS)); } catch (e) { /* ignore */ } };
addEventListener('click', e => { if (e.target.closest('[data-act=reset]')) try { localStorage.removeItem(PF_KEY); } catch (err) { /* ignore */ } }, true);

function pfRebuildThemes() {
  for (const k of Object.keys(THEMES)) delete THEMES[k];
  for (const n of PF_BUILTIN) THEMES[n] = pfThemeObj(n, pfBuiltinCfg(n), true);
  for (const [n, cfg] of Object.entries(PREFS.themes)) THEMES[n] = pfThemeObj(n, cfg, false);
}
pfRebuildThemes();
// the wizard and its «все темы» now show the real presets
PICKS.splice(0, PICKS.length, 'TakoCore', 'Tako Night', 'Tako Ember', 'Tako Forest', 'Tako Ocean', 'Tako Slate', 'Tako Paper', 'Tako Dawn');
TFILTERS.splice(3);
CFG.theme = THEMES[PREFS.theme] ? PREFS.theme : 'TakoCore';
if (!THEMES[CFG.dark]) CFG.dark = 'TakoCore';
if (!THEMES[CFG.light]) CFG.light = 'Tako Paper';
if (pfFresh) {                                                      // demo: workspace Default = Night, claude · auth = Paper
  PREFS.look.workspaces = { def: { theme: 'Tako Night' }, inf: { theme: 'Tako Slate' } };
  const cl = S.sessions.flatMap(s => s.windows).find(w => /^claude/.test(w.title));
  if (cl) PREFS.look.panes[cl.id] = { theme: 'Tako Paper' };
}

// ---------- scopes and the cascade ----------
const PF_ALL = { kind: 'all' };
const pfSame = (a, b) => a.kind === b.kind && a.id === b.id;
const pfSes = id => S.sessions.find(x => x.id === id);
function pfChain(sc) {
  if (sc.kind === 'all') return [PF_ALL];
  if (sc.kind === 'ws') return [PF_ALL, sc];
  if (sc.kind === 'ses') return [PF_ALL, { kind: 'ws', id: pfSes(sc.id).ws }, sc];
  const s = findWin(sc.id)[0], c = [PF_ALL, { kind: 'ws', id: s.ws }];
  if (IDEAS.on) c.push({ kind: 'ses', id: s.id });
  return [...c, sc];
}
const pfMap = sc => sc.kind === 'ws' ? PREFS.look.workspaces : sc.kind === 'ses' ? PREFS.look.sessions : PREFS.look.panes;
const pfLevel = (sc, virt) => virt && pfSame(virt.sc, sc) ? virt.look : sc.kind === 'all' ? { theme: activeTheme(), ...PREFS.look.global } : pfMap(sc)[sc.id] || {};
const pfOwnFields = sc => { const l = sc.kind === 'all' ? PREFS.look.global : pfMap(sc)[sc.id] || {}; return Object.keys(l).filter(k => k !== 'theme'); };
const pfHasOwn = sc => sc.kind === 'all' ? pfOwnFields(sc).length > 0 : Object.keys(pfMap(sc)[sc.id] || {}).length > 0;
const PF_LKEYS = ['font-family', 'font-size', 'background', 'foreground', 'cursor-color', 'selection-background'];
const PF_TDEF = { 'font-family': 'Menlo', 'font-size': '13', 'font-weight': '400', 'font-weight-bold': '700', 'font-weight-italic': '400', 'font-weight-bold-italic': '700' };
const pfThemeOf = name => name === '__draft__' && PED ? pfThemeObj(PED.name, PED.cfg, false) : THEMES[name] || THEMES.TakoCore;
const pfCfgVal = (name, k) => { const c = pfThemeOf(name).cfg; return c[k] !== undefined ? c[k] : PF_TDEF[k]; };
function pfResolve(sc, k, virt) {                 // → { v, from, how: 'own' | 'theme', theme }
  const ch = pfChain(sc);
  for (let i = ch.length - 1; i >= 0; i--) {
    const lk = pfLevel(ch[i], virt);
    if (k === 'theme') { if (lk.theme) return { v: lk.theme, from: ch[i], how: 'own' }; continue; }
    if (lk[k] !== undefined) return { v: lk[k], from: ch[i], how: 'own' };
    if (lk.theme) return { v: pfCfgVal(lk.theme, k), from: ch[i], how: 'theme', theme: lk.theme };
  }
}
const pfLook = (sc, virt) => Object.fromEntries(['theme', ...PF_LKEYS].map(k => [k, pfResolve(sc, k, virt).v]));
const pfScName = sc => sc.kind === 'all' ? 'Общие' : sc.kind === 'ws' ? (S.ws.find(x => x.id === sc.id) || {}).name : sc.kind === 'ses' ? (pfSes(sc.id) || {}).title : (findWin(sc.id)[1] || {}).title;
const pfKindName = sc => ({ all: 'Общие', ws: 'workspace', ses: 'сессия', w: 'терминал' })[sc.kind];

function pfSetTheme(sc, name) {                   // picking a preset clears this level's own fields (native applyPreset)
  if (sc.kind === 'all') { CFG[CFG.auto ? (sysDark() ? 'dark' : 'light') : 'theme'] = name; PREFS.look.global = {}; }
  else { const m = pfMap(sc); if (name) m[sc.id] = { theme: name }; else { const l = m[sc.id] || {}; delete l.theme; if (Object.keys(l).length) m[sc.id] = l; else delete m[sc.id]; } }
  if (name) PREFS.recent = [name, ...PREFS.recent.filter(x => x !== name)].slice(0, 4);
  pfSave(); applyCfg();
}
function pfSetField(sc, k, v) {                   // undefined removes the override: the parent shows through again
  const l = sc.kind === 'all' ? PREFS.look.global : (pfMap(sc)[sc.id] = pfMap(sc)[sc.id] || {});
  if (v === undefined) delete l[k]; else l[k] = v;
  if (sc.kind !== 'all' && !Object.keys(l).length) delete pfMap(sc)[sc.id];
  pfSave(); applyCfg();
}
function pfResetLevel(sc) { if (sc.kind === 'all') PREFS.look.global = {}; else delete pfMap(sc)[sc.id]; pfSave(); applyCfg(); }
function pfRefs(name) {                           // every level that names this preset
  const r = [];
  if (CFG.theme === name || (CFG.auto && (CFG.dark === name || CFG.light === name))) r.push(PF_ALL);
  for (const [kind, m] of [['ws', PREFS.look.workspaces], ['ses', PREFS.look.sessions], ['w', PREFS.look.panes]])
    for (const [id, l] of Object.entries(m)) if (l.theme === name) r.push({ kind, id });
  return r;
}

// ---------- app settings (TerminalSettingRegistry) ----------
const PF_SET = [
  { id: 'confirm-close-surface', t: 'Спрашивать перед закрытием', sec: 'general', type: 'opt', def: 'true', opts: [['true', 'если идёт команда'], ['always', 'всегда'], ['false', 'никогда']], d: 'Закрываешь терминал или вкладку, где что-то работает, — сначала вопрос.', when: 'сразу' },
  { id: 'window-inherit-working-directory', t: 'Новый терминал в той же папке', sec: 'general', type: 'bool', def: true, d: 'Новая вкладка или сплит начинает там, где стоит текущий терминал.', when: 'для новых терминалов' },
  { id: 'window-inherit-font-size', t: 'Новые окна берут размер шрифта', sec: 'general', type: 'bool', def: true, d: 'Увеличил ⌘= — новое окно откроется с тем же размером.', when: 'для новых окон' },
  { id: 'cursor-style', t: 'Форма курсора', sec: 'term', type: 'opt', def: 'block', opts: [['block', 'блок'], ['bar', 'черта'], ['underline', 'подчёркивание']], d: 'Тема может задать свою форму — тогда побеждает тема.', when: 'сразу' },
  { id: 'cursor-style-blink', t: 'Мигающий курсор', sec: 'term', type: 'bool', def: false, d: '', when: 'сразу' },
  { id: 'mouse-hide-while-typing', t: 'Прятать указатель, пока печатаешь', sec: 'term', type: 'bool', def: false, d: '', when: 'сразу' },
  { id: 'copy-on-select', t: 'Копировать выделенное', sec: 'term', type: 'opt', def: 'true', opts: [['true', 'в буфер выделения'], ['clipboard', 'в буфер обмена'], ['false', 'нет']], d: 'Буфер выделения вставляется ⇧⌘V, буфер обмена — ⌘V.', when: 'сразу' },
  { id: 'safe-paste', t: 'Подтверждать вставку нескольких строк', sec: 'term', type: 'bool', def: true, d: 'Вставка нескольких строк в приглашение шелла сначала спрашивает.', when: 'сразу' },
  { id: 'shell-integration', t: 'Интеграция с шеллом', sec: 'term', type: 'opt', def: 'detect', opts: [['detect', 'авто'], ['zsh', 'zsh'], ['fish', 'fish'], ['bash', 'bash'], ['none', 'выкл']], d: 'Метки команд, переход к приглашению, время команды. Явная команда запуска не переписывается; на удалённый хост не ставится.', when: 'для новых терминалов' },
  { id: 'workspace-sync-window-frame', t: 'Окно сохраняет место при смене workspace', sec: 'win', type: 'bool', def: false, d: 'Позиция и размер окна берутся из предыдущего workspace.', when: 'при следующем переключении', alias: 'workspace-inherit-window-frame' },
  { id: 'background-blur', t: 'Размытие фона', sec: 'win', type: 'num', def: 0, min: 0, max: 60, step: 5, unit: 'px', d: '0 — выключено. Заметно, когда у темы прозрачный фон.', when: 'сразу' },
  { id: 'quick-terminal-position', t: 'Где выезжает', sec: 'quick', type: 'pos', def: 'top', opts: [['top', 'сверху'], ['bottom', 'снизу'], ['left', 'слева'], ['right', 'справа'], ['center', 'по центру']], d: '', when: 'при следующем показе' },
  { id: 'quick-terminal-autohide', t: 'Прятать, когда уходишь в другое окно', sec: 'quick', type: 'bool', def: true, d: '', when: 'сразу' },
  ...[['working', 'работает', '#f4581c'], ['waiting', 'ждёт или просит подтверждения', '#ff7a3d'], ['done', 'готово, есть непрочитанное', '#7bd88f'], ['error', 'ошибка', '#d54e53'], ['idle', 'покой или без связи', '#8a7f76']]
    .map(([s, t, c]) => ({ id: 'tab-status-color-' + s, t: 'Статус: ' + t, sec: 'adv', type: 'color', def: c, d: '', when: 'сразу' })),
];
const pfGet = id => { const it = PF_SET.find(x => x.id === id); return PREFS.set[id] !== undefined ? PREFS.set[id] : it.def; };
function pfSetVal(id, v) { const it = PF_SET.find(x => x.id === id); if (v === undefined || v === it.def) delete PREFS.set[id]; else PREFS.set[id] = v; pfSave(); applyCfg(); }

// ---------- terminals wear the resolved look ----------
let PED = null;                                   // the theme editor's draft (prefs-themes.js)
function pfVars(t, lk) {
  const bg = lk.background, fg = lk.foreground, d = pfLum(bg) < .5;
  return { '--term': bg, '--text': fg, '--sub': mix(fg, bg, .27), '--dim': mix(fg, bg, .45), '--mute': mix(fg, bg, .6), '--deep': mix(fg, bg, .72),
    '--line2': mix(bg, fg, d ? .15 : .17), '--card': mix(bg, fg, d ? .07 : .06), '--ok': t.green, '--err': t.red, '--yellow': t.yellow, '--blue': t.blue, '--purple': t.magenta,
    '--fs': (+lk['font-size']) + 'px', '--tf': pfFontCss(lk['font-family']), '--cursor': lk['cursor-color'], '--sel': lk['selection-background'] };
}
function pfCarry() {                              // a session moved to another workspace keeps the look its terminals inherited
  for (const s of S.sessions) {
    if (s._pfws && s._pfws !== s.ws) {
      const old = PREFS.look.workspaces[s._pfws];
      if (old) for (const w of s.windows) { const own = PREFS.look.panes[w.id] || {}; if (!own.theme) PREFS.look.panes[w.id] = { ...old, ...own }; }
      pfSave();
    }
    s._pfws = s.ws;
  }
}
applyLooks = function () {
  pfCarry();
  const virt = PED ? { sc: PED.sc, look: { theme: '__draft__' } } : null;
  for (const [id, el] of els) {
    if (!findWin(id)[1]) continue;
    const lk = pfLook({ kind: 'w', id }, virt), t = pfThemeOf(lk.theme), v = pfVars(t, lk);
    for (const k in v) el.style.setProperty(k, v[k]);
    const tc = t.cfg, cs = tc['cursor-style'] || pfGet('cursor-style');
    el.style.setProperty('--tfw', tc['font-weight'] || 400);
    el.classList.toggle('cs-bar', cs === 'bar'); el.classList.toggle('cs-underline', cs === 'underline');
    el.classList.toggle('cs-blink', (tc['cursor-style-blink'] || String(pfGet('cursor-style-blink'))) === 'true');
  }
  markEditing();
};
applyCfg();
