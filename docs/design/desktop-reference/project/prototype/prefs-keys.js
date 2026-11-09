'use strict';
// Tako desktop prototype — Settings › Клавиши: the real action list (KeybindRegistry.allActions), the real defaults
// (Tako.Config.defaultKeyboardShortcuts) and the recorder's rules (TerminalSettingsDialog+Recording):
// click a row → press a shortcut; Esc cancels, ⌫ returns the default; a modifier or F1–F12 is required;
// a taken shortcut names its owner and asks «Переназначить» / «Отмена». Overrides are «keybind = trigger=action» lines.
const PF_KCATS = [['tabs', 'Вкладки и окна', 'в сайдбаре вкладка — это сессия'], ['splits', 'Терминалы в сессии', 'сплиты'], ['workspaces', 'Workspace', ''], ['terminal', 'Терминал и приложение', ''], ['edit', 'Правка и поиск', '']];
const PF_KA = [
  ['new_tab', 'Новая вкладка', 'tabs'], ['close_surface', 'Закрыть терминал или вкладку', 'tabs'], ['close_tab', 'Закрыть вкладку целиком', 'tabs'],
  ['goto_tab:next', 'Следующая вкладка', 'tabs'], ['goto_tab:previous', 'Предыдущая вкладка', 'tabs'], ['move_tab:1', 'Сдвинуть вкладку вниз', 'tabs'], ['move_tab:-1', 'Сдвинуть вкладку вверх', 'tabs'],
  ['new_window', 'Новое окно', 'tabs'], ['close_window', 'Закрыть окно', 'tabs'], ['close_all_windows', 'Закрыть все окна', 'tabs'],
  ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map(n => [`goto_tab:${n}`, `Вкладка ${n}`, 'tabs']),
  ['new_split:right', 'Разделить вправо', 'splits'], ['new_split:down', 'Разделить вниз', 'splits'], ['goto_split:next', 'Следующий терминал', 'splits'], ['goto_split:previous', 'Предыдущий терминал', 'splits'],
  ['goto_split:left', 'Терминал слева', 'splits'], ['goto_split:right', 'Терминал справа', 'splits'], ['goto_split:up', 'Терминал выше', 'splits'], ['goto_split:down', 'Терминал ниже', 'splits'],
  ['toggle_split_zoom', 'Развернуть терминал', 'splits'], ['equalize_splits', 'Выровнять терминалы', 'splits'],
  ['resize_split:left,10', 'Сдвинуть границу влево', 'splits'], ['resize_split:right,10', 'Сдвинуть границу вправо', 'splits'], ['resize_split:up,10', 'Сдвинуть границу вверх', 'splits'], ['resize_split:down,10', 'Сдвинуть границу вниз', 'splits'],
  ['next_workspace', 'Следующий workspace', 'workspaces'], ['previous_workspace', 'Предыдущий workspace', 'workspaces'], ['new_workspace', 'Новый workspace', 'workspaces'],
  ['quit', 'Выйти из Tako', 'terminal'], ['increase_font_size:1', 'Крупнее шрифт', 'terminal'], ['decrease_font_size:1', 'Мельче шрифт', 'terminal'], ['reset_font_size', 'Обычный размер шрифта', 'terminal'],
  ['jump_to_prompt:previous', 'К предыдущей команде', 'terminal'], ['jump_to_prompt:next', 'К следующей команде', 'terminal'], ['toggle_quick_terminal', 'Quick Terminal', 'terminal'],
  ['reload_config', 'Перечитать конфиг', 'terminal'], ['open_config', 'Настройки', 'terminal'], ['toggle_command_palette', 'Палитра команд', 'terminal'],
  ['copy_to_clipboard', 'Копировать', 'edit'], ['paste_from_clipboard', 'Вставить', 'edit'], ['paste_from_selection', 'Вставить выделенное', 'edit'], ['undo', 'Отменить', 'edit'], ['redo', 'Повторить', 'edit'],
  ['select_all', 'Выделить всё', 'edit'], ['select_command_output', 'Выделить вывод команды', 'edit'], ['start_search', 'Найти в терминале', 'edit'], ['find_all', 'Найти во всех', 'edit'],
  ['navigate_search:next', 'Найти далее', 'edit'], ['navigate_search:previous', 'Найти назад', 'edit'],
];
// actions with a default but outside the list: they still own their shortcut and show up as conflicts
const PF_KEXTRA = [['search_selection', 'Искать выделенное'], ['scroll_to_selection', 'Прокрутить к выделению'], ['toggle_output_filter', 'Фильтр вывода'], ['focus_mode', 'Режим фокуса']];
const PF_KDEF = {
  'goto_tab:previous': 'ctrl+shift+tab', 'goto_tab:next': 'ctrl+tab', 'move_tab:-1': 'shift+cmd+bracket_left', 'move_tab:1': 'shift+cmd+bracket_right',
  new_tab: 'cmd+t', new_window: 'cmd+n', 'new_split:right': 'cmd+d', 'new_split:down': 'shift+cmd+d', close_surface: 'cmd+w',
  toggle_quick_terminal: 'shift+cmd+grave_accent', toggle_command_palette: 'shift+cmd+p', reload_config: 'shift+cmd+comma', open_config: 'cmd+comma',
  'goto_split:previous': 'cmd+bracket_left', 'goto_split:next': 'cmd+bracket_right', 'goto_split:up': 'opt+cmd+up', 'goto_split:down': 'opt+cmd+down', 'goto_split:left': 'opt+cmd+left', 'goto_split:right': 'opt+cmd+right',
  toggle_split_zoom: 'shift+cmd+return', 'resize_split:up,10': 'ctrl+opt+cmd+up', 'resize_split:down,10': 'ctrl+opt+cmd+down', 'resize_split:left,10': 'ctrl+opt+cmd+left', 'resize_split:right,10': 'ctrl+opt+cmd+right',
  equalize_splits: 'opt+cmd+equal', next_workspace: 'ctrl+opt+bracket_right', previous_workspace: 'ctrl+opt+bracket_left', new_workspace: 'ctrl+opt+n',
  quit: 'cmd+q', close_tab: 'opt+cmd+w', close_window: 'shift+cmd+w', close_all_windows: 'opt+shift+cmd+w', undo: 'cmd+z', redo: 'shift+cmd+z',
  copy_to_clipboard: 'cmd+c', paste_from_clipboard: 'cmd+v', paste_from_selection: 'shift+cmd+v', select_all: 'cmd+a',
  'increase_font_size:1': 'cmd+equal', 'decrease_font_size:1': 'cmd+minus', reset_font_size: 'cmd+0', start_search: 'cmd+f', find_all: 'shift+cmd+f',
  search_selection: 'cmd+e', scroll_to_selection: 'cmd+j', 'navigate_search:next': 'cmd+g', 'navigate_search:previous': 'shift+cmd+g',
  'jump_to_prompt:previous': 'cmd+up', 'jump_to_prompt:next': 'cmd+down', select_command_output: 'shift+cmd+a', toggle_output_filter: 'opt+cmd+f', focus_mode: 'opt+cmd+f',
};
for (let n = 1; n <= 9; n++) PF_KDEF[`goto_tab:${n}`] = `cmd+${n}`;
const PF_KALL = [...PF_KA.map(a => a[0]), ...PF_KEXTRA.map(a => a[0])];
const pfKTitle = a => (PF_KA.find(x => x[0] === a) || PF_KEXTRA.find(x => x[0] === a) || [a, a])[1];
const PF_KSYM = { return: '↩', tab: '⇥', space: 'Space', escape: '⎋', backspace: '⌫', delete: '⌦', up: '↑', down: '↓', left: '←', right: '→', page_up: '⇞', page_down: '⇟', home: '↖', end: '↘',
  bracket_left: '[', bracket_right: ']', minus: '-', equal: '=', grave_accent: '`', backslash: '\\', semicolon: ';', quote: "'", comma: ',', period: '.', slash: '/' };
const pfKCaps = tr => { const p = tr.split('+'), key = p.pop(), m = { ctrl: '⌃', opt: '⌥', shift: '⇧', cmd: '⌘' };
  return [...['ctrl', 'opt', 'shift', 'cmd'].filter(x => p.includes(x)).map(x => m[x]), PF_KSYM[key] || key.toUpperCase()]; };
const pfKStr = tr => tr ? pfKCaps(tr).join('') : '';
const pfKHtml = tr => tr ? pfKCaps(tr).map(c => `<kbd>${pfEsc(c)}</kbd>`).join('') : '<span class="pf-none">не назначено</span>';
function pfKNorm(q) {                             // «cmd+shift+d» / «⇧⌘D» → canonical trigger, for search
  const sym = { '⌃': 'ctrl', '⌥': 'opt', '⇧': 'shift', '⌘': 'cmd' }, mods = new Set(); let key = '';
  if (/[⌃⌥⇧⌘]/.test(q)) { for (const ch of q.replace(/\s/g, '')) { if (sym[ch]) mods.add(sym[ch]); else key += ch; } }
  else { const p = q.toLowerCase().split('+').map(x => x.trim()); key = p.pop(); p.forEach(x => mods.add({ control: 'ctrl', alt: 'opt', option: 'opt', command: 'cmd', super: 'cmd' }[x] || x)); }
  key = key.toLowerCase(); const back = Object.entries(PF_KSYM).find(([, v]) => v.toLowerCase() === key); if (back) key = back[0];
  return [...['ctrl', 'opt', 'shift', 'cmd'].filter(x => mods.has(x)), key].join('+');
}
function pfKActive(a) {                           // an override, else the default unless another action claimed it
  const ov = PREFS.keys[a]; if (ov === 'unbound') return null; if (ov) return ov;
  const d = PF_KDEF[a]; if (!d) return null;
  return Object.entries(PREFS.keys).some(([x, t]) => x !== a && t === d) ? null : d;
}
const pfKConflict = (tr, target) => PF_KALL.find(a => a !== target && pfKActive(a) === tr) || null;
const pfKChanged = a => PREFS.keys[a] !== undefined || (PF_KDEF[a] && !pfKActive(a));
const PF_CODE = { Minus: 'minus', Equal: 'equal', BracketLeft: 'bracket_left', BracketRight: 'bracket_right', Backslash: 'backslash', Semicolon: 'semicolon', Quote: 'quote', Comma: 'comma', Period: 'period', Slash: 'slash', Backquote: 'grave_accent',
  Enter: 'return', NumpadEnter: 'return', Tab: 'tab', Space: 'space', Backspace: 'backspace', Delete: 'delete', Escape: 'escape', ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', PageUp: 'page_up', PageDown: 'page_down', Home: 'home', End: 'end' };
const pfKeyName = code => /^Key[A-Z]$/.test(code) ? code.slice(3).toLowerCase() : /^Digit\d$/.test(code) ? code.slice(5) : /^F([1-9]|1[0-2])$/.test(code) ? code.toLowerCase() : PF_CODE[code] || null;
const pfMods = e => ['ctrl', 'opt', 'shift', 'cmd'].filter((m, i) => [e.ctrlKey, e.altKey, e.shiftKey, e.metaKey][i]);

const PK = { rec: null, held: [], conf: null, q: '', only: 'all', msg: '' };
function pfKRow(a, title) {
  const rec = PK.rec === a, tr = pfKActive(a), own = PREFS.keys[a] !== undefined, lost = !own && PF_KDEF[a] && !tr;
  const caps = rec ? `<span class="pf-recing">${PK.held.length ? PK.held.map(m => `<kbd>${({ ctrl: '⌃', opt: '⌥', shift: '⇧', cmd: '⌘' })[m]}</kbd>`).join('') : ''}<em>${PK.held.length ? '…' : 'Нажмите сочетание'}</em></span>` : pfKHtml(tr);
  const conf = PK.conf && PK.conf.target === a ? `<div class="pf-kconf"><span><b>${pfKStr(PK.conf.tr)}</b> уже у «${pfEsc(pfKTitle(PK.conf.holder))}». Переназначить — у «${pfEsc(pfKTitle(PK.conf.holder))}» сочетания не останется.</span><button class="pf-btn" data-kno>Отмена</button><button class="pf-btn pri" data-kyes>Переназначить</button></div>` : '';
  return `<div class="pf-kr ${rec ? 'rec' : ''} ${own || lost ? 'chg' : ''}" data-ka="${a}" data-name="${pfEsc((title + ' ' + a).toLowerCase())}" data-tr="${tr || ''}" data-def="${PF_KDEF[a] || ''}" tabindex="0">
    <div class="pf-kt"><b>${pfEsc(title)}</b><code>${a}</code>${own ? `<span class="pf-mark">изменено${PF_KDEF[a] ? ` · было ${pfKStr(PF_KDEF[a])}` : ''}</span>` : lost ? '<span class="pf-mark warn">сочетание отдано другому действию</span>' : ''}</div>
    <div class="pf-kk">${caps}</div>
    <div class="pf-ka">${rec ? '<button class="pf-btn" data-kcancel>Esc</button>' : own || lost ? `<button class="pf-rst" data-kreset="${a}" title="Вернуть стандартное${PF_KDEF[a] ? ' ' + pfKStr(PF_KDEF[a]) : ''}">↺</button>` : ''}</div>${conf}</div>`;
}
function pfKList() {
  const changed = PF_KA.filter(([a]) => pfKChanged(a)).length;
  return PF_KCATS.map(([c, l, n]) => { const rows = PF_KA.filter(x => x[2] === c && (PK.only === 'all' || pfKChanged(x[0])));
    return rows.length ? `<div class="pf-kg"><h5>${l}${n ? `<small>${n}</small>` : ''}</h5>${rows.map(([a, t]) => pfKRow(a, t)).join('')}</div>` : ''; }).join('')
    || `<p class="pf-hint">${changed ? '' : 'Ничего не изменено — все сочетания стандартные.'}</p>`;
}
function pfPageKeys() {
  const changed = PF_KA.filter(([a]) => pfKChanged(a)).length;
  return `<div class="pf-khd"><input class="pf-in" data-kq placeholder="Действие или сочетание: «вниз», «⇧⌘D», «cmd+d»" value="${pfEsc(PK.q)}" spellcheck="false">
      <span class="pf-seg"><button data-konly="all" class="${PK.only === 'all' ? 'on' : ''}">Все</button><button data-konly="chg" class="${PK.only === 'chg' ? 'on' : ''}">Изменённые${changed ? ` · ${changed}` : ''}</button></span></div>
    <p class="pf-hint">Щёлкните строку и нажмите сочетание: нужен ⌘ ⌃ ⌥ ⇧ или F1–F12. Esc — отмена, ⌫ — вернуть стандартное. Это сочетания внутри Tako, а не глобальные системные. Браузер может не отдать часть системных сочетаний (⌘Q, ⌘W, ⌘Tab) — в Tako запись идёт в окне настроек.</p>
    <div class="pf-klist">${pfKList()}</div><div class="pf-kmsg" aria-live="polite">${pfEsc(PK.msg)}</div>`;
}
function pfKFilter(root) {                        // in place, so typing keeps focus
  const q = PK.q.trim().toLowerCase(), tr = /[+⌃⌥⇧⌘]/.test(q) ? pfKNorm(PK.q.trim()) : '';
  root.querySelectorAll('.pf-kr').forEach(r => { const hit = !q || r.dataset.name.includes(q) || (tr && (r.dataset.tr === tr || r.dataset.def === tr)); r.hidden = !hit; });
  root.querySelectorAll('.pf-kg').forEach(g => { g.hidden = ![...g.querySelectorAll('.pf-kr')].some(r => !r.hidden); });
}
function pfKRefresh() {
  const el = document.querySelector('.pop.pf'); if (!el) return;
  const l = el.querySelector('.pf-klist'), m = el.querySelector('.pf-kmsg'), s = el.querySelector('[data-konly="chg"]');
  if (l) { l.innerHTML = pfKList(); pfKFilter(el); }
  if (m) m.textContent = PK.msg;
  if (s) { const n = PF_KA.filter(([a]) => pfKChanged(a)).length; s.textContent = 'Изменённые' + (n ? ` · ${n}` : ''); }
  const r = el.querySelector('.pf-kr.rec,.pf-kr .pf-kconf'); if (r) r.closest('.pf-kr').scrollIntoView({ block: 'center' });
}
function pfKApply(a, tr, from) {
  PREFS.keys[a] = tr; pfSave();
  PK.msg = from ? `${pfKStr(tr)} теперь у «${pfKTitle(a)}»; у «${pfKTitle(from)}» ${pfKActive(from) ? 'вернулось ' + pfKStr(pfKActive(from)) : 'сочетания нет'}` : `«${pfKTitle(a)}» — ${pfKStr(tr)}`;
}
function pfKReset(a) {
  const was = PREFS.keys[a] !== undefined; delete PREFS.keys[a]; pfSave();
  PK.msg = was ? `«${pfKTitle(a)}» — снова стандартное${pfKActive(a) ? ' ' + pfKStr(pfKActive(a)) : ''}` : `«${pfKTitle(a)}» уже стандартное`;
}
function pfKStart(a) { PK.rec = a; PK.held = []; PK.conf = null; PK.msg = 'Нажмите сочетание. Esc — отмена, ⌫ — вернуть стандартное.'; pfKRefresh(); }
// while recording, the press goes to the recorder only: it does not run the command and never reaches a terminal
addEventListener('keydown', e => {
  if (PK.conf && !PK.rec && document.querySelector('.pop.pf')) {
    if (e.key === 'Enter') { e.preventDefault(); e.stopImmediatePropagation(); const c = PK.conf; PK.conf = null; if (PREFS.keys[c.holder] !== undefined) delete PREFS.keys[c.holder]; pfKApply(c.target, c.tr, c.holder); return pfKRefresh(); }
    if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); PK.conf = null; PK.msg = 'Переназначение отменено'; return pfKRefresh(); }
  }
  if (!PK.rec) return;
  e.preventDefault(); e.stopImmediatePropagation();
  const mods = pfMods(e), key = pfKeyName(e.code);
  if (!key) { PK.held = mods; return pfKRefresh(); }
  if (!mods.length && key === 'escape') { PK.rec = null; PK.msg = 'Запись отменена'; return pfKRefresh(); }
  if (!mods.length && (key === 'backspace' || key === 'delete')) { const a = PK.rec; PK.rec = null; pfKReset(a); return pfKRefresh(); }
  if (!mods.length && !/^f\d+$/.test(key)) { PK.msg = 'Нужен модификатор (⌘ ⌃ ⌥ ⇧) или F1–F12. Esc — отмена.'; return pfKRefresh(); }
  const tr = [...mods, key].join('+'), a = PK.rec, holder = pfKConflict(tr, a);
  PK.rec = null; PK.held = [];
  if (holder) { PK.conf = { target: a, holder, tr }; PK.msg = `${pfKStr(tr)} занято «${pfKTitle(holder)}». Enter — переназначить, Esc — отмена.`; return pfKRefresh(); }
  if (tr === pfKActive(a)) { PK.msg = `«${pfKTitle(a)}» уже ${pfKStr(tr)}`; return pfKRefresh(); }
  pfKApply(a, tr); pfKRefresh();
}, true);
addEventListener('keyup', e => { if (!PK.rec) return; e.preventDefault(); e.stopImmediatePropagation(); PK.held = pfMods(e); pfKRefresh(); }, true);
