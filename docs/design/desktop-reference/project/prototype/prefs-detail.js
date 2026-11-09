'use strict';
// Tako desktop prototype — details before implementation (Alex, m15236):
// 1) the app chrome and the terminal are two separate looks; 2) the font picker comes from the real inventory of
// the installed Tako 526 (takoctl theme fonts) and never fakes a sample; 3) exact decimal size, separate from the
// temporary ⌘+/⌘− zoom; 4) activity indicators: show / animate / colours, apart from focus; 5) explicit counters.

// ---------- 2. fonts: snapshot of `takoctl --bundle-id com.tako-core.terminal --json theme fonts` (Tako 526, this Mac) ----------
const PD_INV = [
  { family: 'Andale Mono', styles: ['Regular'], from: 'macOS' },
  { family: 'Courier New', styles: ['Regular', 'Italic', 'Bold', 'Bold Italic'], from: 'macOS' },
  { family: 'Fira Code', styles: ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold'], variable: [300, 700], from: 'ставит Tako' },
  { family: 'JetBrains Mono', styles: ['Medium', 'SemiBold'], from: 'ставит Tako' },
  { family: 'Menlo', styles: ['Regular', 'Italic', 'Bold', 'Bold Italic'], from: 'macOS' },
  { family: 'Monaco', styles: ['Regular'], from: 'macOS' },
  { family: 'PT Mono', styles: ['Regular', 'Bold'], from: 'macOS' },
  { family: 'Symbols Nerd Font Mono', styles: ['Regular'], from: 'ставит Tako', symbols: true },
  { family: 'Victor Mono', styles: ['Thin', 'ExtraLight', 'Light', 'Regular', 'Medium', 'SemiBold', 'Bold', 'Italic', 'Oblique', '…'], count: 21, from: 'установлен' },
];
PF_FONTS.splice(0, PF_FONTS.length, ...PD_INV.filter(f => !f.symbols).map(f => [f.family, `'${f.family}', monospace`, f.from]));
(() => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'https://fonts.googleapis.com/css2?family=Victor+Mono:ital,wght@0,400;0,700;1,400&display=swap'; document.head.appendChild(l); })();
const PD_AV = {};                                 // drawn by this browser? measured, never assumed
function pdMeasure(f) {
  const c = pdMeasure.c || (pdMeasure.c = document.createElement('canvas').getContext('2d')), s = 'mmmmmmmmmlli0O1IW@#ёЖ';
  return ['serif', 'sans-serif'].some(b => { c.font = `40px ${b}`; const w0 = c.measureText(s).width; c.font = `40px "${f}", ${b}`; return Math.abs(c.measureText(s).width - w0) > .5; });
}
async function pdDetect() {
  await Promise.all(PD_INV.map(f => document.fonts.load(`16px "${f.family}"`).catch(() => null)));
  for (const f of PD_INV) PD_AV[f.family] = pdMeasure(f.family);
  applyCfg(); const el = document.querySelector('.pop.pf'); if (el) redraw(el);
}
const PD_W = { Thin: 100, ExtraLight: 200, Light: 300, Regular: 400, Medium: 500, SemiBold: 600, Bold: 700 };
function pdFace(fam, w) {                         // which face regular text really gets
  const f = PD_INV.find(x => x.family === fam); if (!f) return '';
  if (f.variable) return `переменный вес ${f.variable[0]}–${f.variable[1]} · обычный текст ${Math.min(Math.max(w, f.variable[0]), f.variable[1])}`;
  const up = f.styles.filter(s => PD_W[s]).sort((a, b) => Math.abs(PD_W[a] - w) - Math.abs(PD_W[b] - w));
  const best = up[0] || 'Regular';
  return best === 'Regular' && w === 400 ? `обычный текст — Regular${f.styles.includes('Bold') ? ', жирный — Bold' : ', жирного начертания нет — Tako сделает синтетический'}` : `обычный текст — ${best}: у ${fam} нет начертания с весом ${w}, берётся ближайшее`;
}
const pdStyles = f => { const n = f.count || f.styles.length; return n === 1 ? 'одно начертание' : n === 2 ? f.styles.join(', ') : `${n} ${plural(n, 'начертание', 'начертания', 'начертаний')}${f.variable ? ', переменный вес' : ''}`; };
pfFontList = (cur, attr) => {
  const rows = PD_INV.filter(f => !f.symbols);
  const inherit = attr === 'data-lfont' ? `<button class="pf-fr ${cur === '' ? 'on' : ''}" data-lfont="" data-name="как в теме"><b>Как в теме</b><span class="pd-ui">шрифт выбранной темы</span><small></small></button>` : '';
  return `<div class="pf-fl"><input class="pf-in" data-fq placeholder="Найти шрифт" value="${pfEsc(PL.fq)}" spellcheck="false">
    <div class="pf-flr">${inherit}${rows.map(f => { const av = PD_AV[f.family];
      return `<button class="pf-fr pd-fr ${cur === f.family ? 'on' : ''} ${av === false ? 'na' : ''}" ${attr}="${pfEsc(f.family)}" data-name="${pfEsc(f.family.toLowerCase())}">
        <b>${pfEsc(f.family)}</b>${av === false ? '<span class="pd-na">образец недоступен в браузере</span>' : `<span style="font-family:'${f.family}',serif">0O 1lI {}[];: Ёжик → mitts</span>`}<small title="${pfEsc(f.styles.join(', '))}">${pdStyles(f)} · ${f.from}</small></button>`; }).join('')}</div>
    <p class="pf-hint">Symbols Nerd Font Mono — только значки (Nerd Font): Tako подставляет их сам, для текста не выбирается.</p>
    <p class="pf-hint">Список — снимок <code>takoctl theme fonts</code> установленного Tako 526 на этом Mac (2026-11-08), а не живой доступ браузера к системе. Образец рисуется, только если браузер реально отрисовал этот шрифт.</p></div>`;
};
const _pvPd = pfPreview;
pfPreview = (lk, t, faces, cfg) => PD_AV[lk['font-family']] === false
  ? `<div class="pf-pv pd-pvna" style="background:${lk.background};color:${lk.foreground}"><div class="pf-pvh">${pfEsc(t.name)} · ${pfEsc(lk['font-family'])} ${+lk['font-size']}</div><b>«${pfEsc(lk['font-family'])}» этот браузер не отрисовал</b><span>В Tako на этом Mac шрифт есть (снимок inventory). Образец не подменяем запасным моноширинным.</span></div>`
  : _pvPd(lk, t, faces, cfg);

// ---------- 3. size: decimals, effective value, and the temporary zoom kept apart ----------
const _stepSetPd = pfStepSet;
pfStepSet = (key, n) => _stepSetPd(key, Math.round(n * 10) / 10);
pfStep = btn => {
  const a = [...btn.attributes].find(x => x.name.endsWith('-step')), key = a.name.slice(5, -5), inp = btn.parentNode.querySelector('.pf-num');
  pfStepSet(key, pfClamp((parseFloat(inp.value) || 0) + parseFloat(a.value), +inp.dataset.min, +inp.dataset.max));
};
const PD_ZOOM = {};                               // pane id → pt; runtime only, never saved (native increase/decrease/reset_font_size)
function pdZoom(id, d) {
  const base = +pfResolve({ kind: 'w', id }, 'font-size').v, z = d === 0 ? 0 : Math.min(72 - base, Math.max(6 - base, (PD_ZOOM[id] || 0) + d));
  if (z) PD_ZOOM[id] = z; else delete PD_ZOOM[id];
  render(); const el = document.querySelector('.pop.pf'); if (el) redraw(el);
  if (typeof toast2 === 'function') toast2('', `${(findWin(id)[1] || {}).title}: ${base + z} pt${z ? ` (масштаб ${z > 0 ? '+' : ''}${z}, временно · ⌘0 — сбросить)` : ' — масштаб сброшен'}`);
}
const _looksPd = applyLooks;
applyLooks = function () {
  _looksPd();
  for (const [id, el] of els) {
    if (!findWin(id)[1]) continue;
    const z = PD_ZOOM[id]; if (z) el.style.setProperty('--fs', (parseFloat(el.style.getPropertyValue('--fs')) + z) + 'px');
    const fam = pfResolve({ kind: 'w', id }, 'font-family').v;
    if (PD_AV[fam] === false) el.dataset.nofont = fam; else delete el.dataset.nofont;
  }
};
addEventListener('keydown', e => {                // ⌘+ / ⌘− / ⌘0: the focused terminal only
  if (!(e.metaKey || e.ctrlKey) || e.altKey || PK.rec || !S.focus || (e.target.closest && e.target.closest('input,textarea'))) return;
  const d = e.key === '=' || e.key === '+' ? 1 : e.key === '-' ? -1 : e.key === '0' ? 0 : null; if (d === null) return;
  e.preventDefault(); e.stopImmediatePropagation(); pdZoom(S.focus, d);
}, true);
let pdCtxWin = null;
addEventListener('contextmenu', e => { const f = e.target.closest && e.target.closest('.fw-body') && e.target.closest('.fw'); pdCtxWin = f ? f.dataset.id : null; }, true);
const _ctxPd = openCtx;
openCtx = (items, x, y) => {
  const i = items.findIndex(it => it && it.label === 'Выделить всё');
  if (i >= 0 && pdCtxWin) { const id = pdCtxWin; items = [...items]; items.splice(i + 1, 0, '-', { label: 'Крупнее', kbd: '⌘+', run: () => pdZoom(id, 1) }, { label: 'Мельче', kbd: '⌘−', run: () => pdZoom(id, -1) }, { label: 'Сбросить масштаб', kbd: '⌘0', off: !PD_ZOOM[id], run: () => pdZoom(id, 0) }); }
  _ctxPd(items, x, y);
};
function pdZoomRow(sc) {
  if (sc.kind !== 'w') return '<p class="pf-hint">⌘+ / ⌘− / ⌘0 меняют масштаб одного терминала и не сохраняются. Сохранённый размер — поле выше; он наследуется.</p>';
  const z = PD_ZOOM[sc.id] || 0, base = +pfResolve(sc, 'font-size').v;
  return `<div class="pf-row"><div class="pf-rl"><b>Масштаб сейчас</b><span>${z ? `${z > 0 ? '+' : ''}${z} pt — на экране <b class="pd-eff">${base + z} pt</b>. Временно, только этот терминал, не сохраняется.` : 'Нет. ⌘+ / ⌘− / ⌘0 — только этот терминал, временно.'}</span><code>increase_font_size · decrease_font_size · reset_font_size</code></div>
    <div class="pf-rc"><button class="pf-btn" data-zoom="-1" aria-label="Мельче">−</button><button class="pf-btn" data-zoom="1" aria-label="Крупнее">+</button><button class="pf-btn" data-zoom="0" ${z ? '' : 'disabled'}>Сбросить масштаб</button></div></div>`;
}
const _lookPd = pfPageLook;
pfPageLook = () => {
  let h = _lookPd(); if (PED) return h;
  const sc = SET.scope, fam = pfResolve(sc, 'font-family').v, w = +pfCfgVal(pfResolve(sc, 'theme').v, 'font-weight');
  h = h.replace('<div class="pf-tools">', '<p class="pf-hint pd-lead">Тема — полный пресет: цвета, ANSI, шрифт и размер. Выбор темы заменяет всё это на уровне; свои поля уровня сбрасываются.</p><div class="pf-tools">');
  h = h.replace('<div class="pf-row"><div class="pf-rl"><b>Размер</b>', `<p class="pf-hint pd-face">${PD_AV[fam] === false ? `«${pfEsc(fam)}» этот браузер не отрисовал — в Tako он есть. ` : ''}${pdFace(fam, w)}</p><div class="pf-row"><div class="pf-rl"><b>Размер</b>`);
  return h.replace('<p class="pf-hint">Шрифт и размер окна настроек', pdZoomRow(sc) + '<p class="pf-hint">Шрифт и размер окна настроек');
};
PF_PAGES.look = pfPageLook;
const _cardPd = pfThemeCard;
pfThemeCard = (n, on) => { const c = THEMES[n].cfg; return _cardPd(n, on).replace('<small>', `<small>${pfEsc(c['font-family'] || 'Menlo')} ${c['font-size'] || 13} · `); };

// ---------- 1. the app chrome has its own look; terminal themes never repaint it ----------
// ---------- 4/5. activity: show, animate, colours, counters ----------
PF_SET.push(
  { id: 'app-appearance', t: 'Оформление интерфейса', sec: 'ui', type: 'opt', def: 'system', opts: [['system', 'Как в macOS'], ['light', 'Светлое'], ['dark', 'Тёмное']], d: 'Сайдбар, поле под терминалами, меню, настройки. Тема терминала его не перекрашивает.', when: 'сразу', ext: 1 },
  { id: 'status-show', t: 'Показывать статусы', sec: 'activity', type: 'bool', def: true, d: 'Кольца, цветные рамки, линия ошибки. Выключено — всё спокойное, но статусы и история продолжают отслеживаться.', when: 'сразу', ext: 1 },
  { id: 'status-animate', t: 'Анимировать рамки', sec: 'activity', type: 'bool', def: true, d: 'Бегущая рамка «работает», дыхание «ждёт». Выключено — те же цвета, статично. С «Уменьшить движение» в macOS рамки статичны всегда.', when: 'сразу', ext: 1 },
  { id: 'sidebar-count-waiting', t: 'Сколько ждут ответа', sec: 'activity', type: 'bool', def: true, d: 'Терминалы, где агент ждёт ответа или разрешения.', when: 'сразу', ext: 1 },
  { id: 'sidebar-count-error', t: 'Сколько с ошибкой', sec: 'activity', type: 'bool', def: true, d: 'Терминалы, где команда завершилась с ненулевым кодом.', when: 'сразу', ext: 1 },
  { id: 'sidebar-count-done', t: 'Сколько готово и не просмотрено', sec: 'activity', type: 'bool', def: true, d: 'Сессии с завершением, которое вы ещё не открывали.', when: 'сразу', ext: 1 },
);
for (const it of PF_SET) if (it.id.startsWith('tab-status-color-')) it.sec = 'activity';
PF_SET.find(x => x.id === 'tab-status-color-waiting').t = 'Ждёт ответа или разрешения';
PF_SET.find(x => x.id === 'tab-status-color-working').t = 'Работает';
PF_SET.find(x => x.id === 'tab-status-color-done').t = 'Готово';
PF_SET.find(x => x.id === 'tab-status-color-error').t = 'Ошибка';
PF_SET.find(x => x.id === 'tab-status-color-idle').t = 'Покой или без связи';
const _rowPd = pfRow;
pfRow = it => { const h = _rowPd(it); return it.ext ? h.replace(`<code>${it.id}`, `<code class="pd-ext" title="В Tako 526 такого ключа нет — предлагаемое расширение">новое · ${it.id}`) : h; };
applyTheme = function () {                        // chrome: its own scheme (TakoCore dark / Tako Paper light), not the terminal theme
  const m = pfGet('app-appearance'), light = m === 'light' || (m === 'system' && !sysDark()), t = THEMES[light ? 'Tako Paper' : 'TakoCore'], d = !light;
  const root = document.documentElement.style, v = {
    '--bg': t.bg, '--term': t.term, '--text': t.fg,
    '--card': mix(t.term, t.fg, d ? .07 : .06), '--hover': mix(t.bg, t.fg, d ? .045 : .05), '--hover2': mix(t.term, t.fg, d ? .12 : .1),
    '--field': d ? mix(t.bg, t.term, .5) : t.term, '--pillbg': mix(t.term, t.fg, d ? .07 : .04),
    '--line': mix(t.bg, t.fg, d ? .09 : .11), '--line2': mix(t.bg, t.fg, d ? .15 : .17),
    '--sub': mix(t.fg, t.bg, .27), '--dim': mix(t.fg, t.bg, .45), '--mute': mix(t.fg, t.bg, .6), '--deep': mix(t.fg, t.bg, .72),
    '--ok': t.green, '--err': t.red, '--yellow': t.yellow, '--blue': t.blue, '--purple': t.magenta,
    '--pop': d ? '#241C16' : '#FFFFFF', '--pophover': d ? '#30261E' : mix('#FFFFFF', t.fg, .08),
  };
  for (const k in v) root.setProperty(k, v[k]);
  document.documentElement.dataset.tone = t.tone; document.documentElement.dataset.shell = light ? 'light' : 'dark';
  for (const [k, s] of [['--st-work', 'working'], ['--st-wait', 'waiting'], ['--st-done', 'done'], ['--st-err', 'error'], ['--st-idle', 'idle']]) root.setProperty(k, pfGet('tab-status-color-' + s));
  document.body.classList.toggle('st-off', !pfGet('status-show'));
  document.body.classList.toggle('st-static', !pfGet('status-animate'));
};
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (pfGet('app-appearance') === 'system') applyCfg(); });
const _sbPd = renderSidebar;
renderSidebar = () => {                           // the counters say what they count; nothing is merged into one number
  _sbPd();
  const ws = S.sessions.flatMap(s => s.windows), n = { w: ws.filter(x => x.status === 'waiting').length, e: ws.filter(x => x.status === 'error').length, d: S.sessions.filter(s => s.unread).length };
  const parts = [['waiting', 'w', 'ждут', 'Терминалов ждут ответа или разрешения'], ['error', 'e', 'ошибка', 'Терминалов с ошибкой'], ['done', 'd', 'готово', 'Сессий с непросмотренным завершением']]
    .filter(([k, c]) => pfGet('sidebar-count-' + k) && n[c]).map(([k, c, l, t]) => `<b class="pd-c pd-${k}" title="${t}">${l} ${n[c]}</b>`);
  const lbl = $('#needsLbl'); if (lbl) lbl.innerHTML = parts.length ? parts.join(' ') : 'Нужно внимание';
};

// ---------- the pages ----------
PF_IC.ui = '<rect x="1.8" y="2.8" width="12.4" height="10.4" rx="2"/><path d="M5.6 2.8v10.4"/><path d="M2.8 5.4h1.6M2.8 7.4h1.6" opacity=".7"/>';
PF_IC.activity = '<circle cx="8" cy="8" r="5.6"/><path d="M8 2.4a5.6 5.6 0 0 1 5.6 5.6"/><circle cx="8" cy="8" r="1.2"/>';
PF_SECS.splice(0, PF_SECS.length, ['general', 'Общее'], ['ui', 'Интерфейс Tako'], ['look', 'Терминал: вид'], ['term', 'Ввод и курсор'], ['win', 'Окна и workspace'], ['quick', 'Quick Terminal'],
  ['activity', 'Статусы и активность'], ['keys', 'Клавиши'], ['agents', 'Агенты'], ['perms', 'Уведомления и доступы'], ['adv', 'Дополнительно']);
PF_PAGES.ui = () => pfGroup('Схема', pfRows(0, ['app-appearance']) + `<p class="pf-hint">Демо: macOS сейчас ${sysDark() ? 'тёмная' : 'светлая'} · <a class="pd-a" data-sysflip>переключить</a></p>`, 'сайдбар, поле, меню, настройки')
  + pfGroup('Текст интерфейса', '<div class="pf-row"><div class="pf-rl"><b>Шрифт и размер интерфейса</b><span>Системные: SF Pro и размер из macOS. Шрифт терминала задаётся в «Терминал: вид» и подписи сайдбара и настроек не меняет; ⌘+ / ⌘− масштабируют только терминал.</span><code>системные · отдельного ключа нет</code></div></div>')
  + pfGroup('Что красит тема терминала', '<p class="pf-hint">Только сам терминал: фон, текст, ANSI, курсор, выделение, шрифт. Оболочка, рамка фокуса и цвета статусов от неё не меняются — тёмный терминал в светлой оболочке и наоборот выглядят как два слоя.</p>');
function pdSample() {
  const tile = (cls, ring, label, note) => `<div class="pd-sp ${cls}" style="--sbg:var(--card)"><span class="ring ${ring}"></span><b>${label}</b><small>${note}</small></div>`;
  return `<div class="pd-samples">${tile('pd-focus', 'r-idle', 'В фокусе', 'тонкая нейтральная рамка, не статус')}${tile('sweep', 'r-work', 'Работает', 'рамка бежит')}${tile('glow', 'r-attn', 'Ждёт ответа', 'рамка дышит')}${tile('', 'r-done', 'Готово', 'одна вспышка')}${tile('errline', 'r-err', 'Ошибка', 'линия снизу, exit N')}${tile('', 'r-idle', 'Покой', '')}</div>`;
}
PF_PAGES.activity = () => pfGroup('Индикаторы', pdSample() + pfRows(0, ['status-show', 'status-animate']), 'фокус и статус — разные вещи')
  + pfGroup('Цвета', pfRows(0, ['tab-status-color-working', 'tab-status-color-waiting', 'tab-status-color-done', 'tab-status-color-error', 'tab-status-color-idle'])
    + '<p class="pf-hint">Одинаковы во всех темах. «Ждёт ответа» и «нужно разрешение» в Tako 526 — один статус и один цвет; отдельный цвет разрешения потребует отдельного статуса от агента.</p>', 'tab-status-color-*')
  + pfGroup('Счётчики в сайдбаре', pfRows(0, ['sidebar-count-waiting', 'sidebar-count-error', 'sidebar-count-done']) + '<p class="pf-hint">Только то, что Tako знает: статусы терминалов и непрочитанные завершения. Ни процентов, ни таймеров, ни токенов — в OSC 7501 таких данных нет.</p>')
  + pfGroup('Уведомления', `<div class="pf-row"><div class="pf-rl"><b>События из невидимых терминалов</b><span>Ждёт ответа или упало там, где вы сейчас не смотрите.</span><code>в макете — тосты; в Tako — уведомления macOS</code></div><div class="pf-rc">${tog('toasts')}</div></div>
    <div class="pf-row"><div class="pf-rl"><b>Разрешение и звук</b><span>Задаются в macOS: баннеры, звук, наклейки.</span></div><div class="pf-rc"><button class="pf-btn" data-go="perms">Уведомления и доступы…</button></div></div>`, 'отдельно от вида');
PF_PAGES.adv = () => pfGroup('Где это хранится', `<div class="pf-store"><p><code>~/.config/tako/config</code> общие настройки, тема Общих, keybind</p><p><code>~/.config/tako/themes/</code> свои темы, по файлу на тему</p><p><code>Appearance.json</code> оформление workspace и терминалов, по UUID</p></div>`)
  + pfGroup('Конфиг', `<pre class="pf-conf">${pfEsc(pfConfigPreview())}</pre>`, 'то, что этот макет записал бы; отсутствующий ключ = стандартное значение');
const _wirePd = pfWire;
pfWire = el => {
  _wirePd(el);
  el.addEventListener('click', e => {
    const z = e.target.closest('[data-zoom]'); if (z && SET.scope.kind === 'w') return pdZoom(SET.scope.id, +z.dataset.zoom);
    if (e.target.closest('[data-sysflip]')) { SYS.dark = !SYS.dark; applyCfg(); redraw(el); }
  });
};

// small windows: the settings stay centred in what is visible, never past the edge
placeSet = p => {
  const a = $('#app').getBoundingClientRect(), L = Math.max(a.left, 0), T = Math.max(a.top, 0), R = Math.min(a.right, innerWidth), B = Math.min(a.bottom, innerHeight);
  const w = Math.min(820, R - L - 24), h = Math.min(700, Math.max(320, B - T - 24));
  Object.assign(p.style, { width: w + 'px', height: h + 'px', left: Math.round(L + (R - L - w) / 2) + 'px', top: Math.round(T + Math.max(12, (B - T - h) / 2)) + 'px' });
};
pdDetect();
applyCfg();

// ---------- spec: what is shown, what native already has, what still has to be added ----------
{
  const R = [
    ['Интерфейс Tako: Как в macOS / Светлое / Тёмное', 'отдельного ключа в 526 не нашли; оболочка в макете отделена от темы терминала', 'нужно: ключ app-appearance и чтобы sidebar, overview, settings, меню брали его, а не тему терминала', 'idea'],
    ['Шрифт терминала', 'font-family · TerminalAppearanceCatalog.fontFamilies / takoctl theme fonts', 'есть; в макете — снимок inventory 526, служебный Symbols Nerd Font Mono отдельно', 'ok'],
    ['Начертания', 'font-weight* 100–900, font-family-bold/italic, styles из font_details', 'есть; показ «какое начертание реально берётся» — новое в UI', 'part'],
    ['Размер', 'font-size: валидатор 6–72, дробные; реестр 9–28 шаг 1', 'есть; какой диапазон показывать в Общих — вопрос', 'part'],
    ['Масштаб ⌘+ / ⌘− / ⌘0', 'increase_font_size · decrease_font_size · reset_font_size, window-inherit-font-size', 'есть; показ текущего масштаба и «Сбросить масштаб» в настройках — новое в UI', 'part'],
    ['Цвета статусов', 'tab-status-color-working|waiting|done|error|idle', 'есть', 'ok'],
    ['Показывать статусы, анимировать рамки', 'ключей нет; движение уважает Reduce Motion', 'нужно: status-show, status-animate; отключение не трогает трекинг', 'idea'],
    ['Счётчики в сайдбаре', 'данные есть: waiting/attention, error, unread', 'нужно: ключи показа sidebar-count-*', 'idea'],
    ['Отдельный цвет «нужно разрешение»', 'отдельного статуса нет — входит в waiting', 'нужно: отдельный статус от агента, иначе не показывать', 'ask'],
    ['Уведомления и звук', 'Notifications permission, PromptManager, звук — macOS', 'есть, отдельно от вида', 'ok'],
  ];
  $('#notes dl').insertAdjacentHTML('afterend', `<h4>Детали перед реализацией</h4><p class="rt-n">Что в макете → что есть в Tako 526 → что ещё нужно.</p>
    <table class="rt">${R.map(r => `<tr><td>${r[0]}</td><td>${r[1]}</td><td class="${r[3]}">${r[2]}</td></tr>`).join('')}</table>`);
}
