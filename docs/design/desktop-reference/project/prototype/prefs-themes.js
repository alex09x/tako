'use strict';
// Tako desktop prototype — Settings › Оформление: pick a preset for a level (applies at once),
// typography and colour overrides with a visible source, and the preset editor (draft → Save / Cancel).
// The two workflows never mix: choosing applies immediately, editing a named preset is a draft with live preview.
const PL = { tq: '', fq: '', fonts: false, colors: false, ren: null, del: null };
const pfEsc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const PF_COLOR_KEYS = ['background', 'foreground', 'cursor-color', 'selection-background', 'selection-foreground'];
const PF_ANSI = ['Black', 'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White', 'Bright black', 'Bright red', 'Bright green', 'Bright yellow', 'Bright blue', 'Bright magenta', 'Bright cyan', 'Bright white'];
const PF_EKEYS = ['font-family', 'font-size', 'font-family-bold', 'font-family-italic', 'font-family-bold-italic', 'font-weight', 'font-weight-bold', 'font-weight-italic', 'font-weight-bold-italic',
  'background', 'foreground', 'cursor-color', 'selection-background', 'selection-foreground', 'cursor-style', 'cursor-style-blink', 'cursor-opacity', 'background-opacity', 'selection-invert-fg-bg', 'adjust-cell-height'];

// ---------- validation: the same rules as ThemePresetStore / ThemePresetConfig+Validation ----------
function pfNameError(name, orig) {
  if (!name.trim()) return 'Имя не может быть пустым';
  if (name !== name.trim()) return 'Без пробелов в начале и в конце';
  if (name.startsWith('.')) return 'Имя не может начинаться с точки';
  if (/[/\\]/.test(name)) return 'Без «/» и «\\»';
  if (name.includes('..')) return 'Без «..»';
  if (/[\x00-\x1f\x7f]/.test(name)) return 'Без управляющих символов';
  if (name.toLowerCase() === 'tako') return '«tako» — зарезервированное имя TakoCore';
  if (/^(["']).*\1$/.test(name)) return 'Без кавычек вокруг имени';
  const clash = Object.keys(THEMES).find(k => k.toLowerCase() === name.toLowerCase() && k !== orig);
  return clash ? (THEMES[clash].builtin ? `Встроенная тема «${clash}» уже есть, её имя занято` : `Тема «${clash}» уже есть`) : '';
}
function pfFieldError(k, v) {
  if (v === undefined || v === '') return '';
  if (PF_COLOR_KEYS.includes(k) || k.startsWith('palette')) return /^#[0-9a-f]{6}$/i.test(v) ? '' : 'Цвет в виде #RRGGBB';
  const n = Number(v);
  if (k === 'font-size') return isFinite(n) && n >= 6 && n <= 72 ? '' : 'Размер от 6 до 72 pt';
  if (k.startsWith('font-weight')) return Number.isInteger(n) && n >= 100 && n <= 900 ? '' : 'Вес — целое от 100 до 900';
  if (k === 'cursor-opacity' || k === 'background-opacity') return isFinite(n) && n >= 0 && n <= 1 ? '' : 'Значение от 0 до 1';
  if (k === 'adjust-cell-height') return /^-?\d+(\.\d+)?%?$/.test(v) ? '' : 'Число или процент, например 10%';
  if (k.startsWith('font-family')) return v.trim() ? '' : 'Укажите шрифт';
  if (k === 'cursor-style') return ['block', 'bar', 'underline', 'block_hollow'].includes(v) ? '' : 'block, bar или underline';
  if (['cursor-style-blink', 'selection-invert-fg-bg'].includes(k)) return ['true', 'false'].includes(v) ? '' : 'true или false';
  return '';
}
const pfUnique = base => { let n = base, i = 2; while (Object.keys(THEMES).some(k => k.toLowerCase() === n.toLowerCase())) n = `${base} ${i++}`; return n; };
const pfClone = o => JSON.parse(JSON.stringify(o));

// ---------- the preview: a small real terminal with the Mitts demo ----------
function pfPreview(lk, t, faces, cfg) {
  const bg = lk.background, fg = lk.foreground, dim = mix(fg, bg, .45), c = cfg || t.cfg;
  const w = k => c[k] || PF_TDEF[k], ff = k => c[k] ? pfFontCss(c[k]) : pfFontCss(lk['font-family']);
  return `<div class="pf-pv" style="background:${bg};color:${fg};font-family:${pfFontCss(lk['font-family'])};font-size:${+lk['font-size']}px;font-weight:${w('font-weight')}">`
    + `<div class="pf-pvh" style="color:${dim}">${pfEsc(t.name)} · ${pfEsc(lk['font-family'])} ${+lk['font-size']}</div>`
    + `<div><span style="color:${t.cyan}">~/tako</span> <span style="color:${t.magenta}">main ±2</span> <span style="color:${t.green}">❯</span> mitts test -p auth</div>`
    + `<div style="color:${dim}">⚡ Mitts Build  test [dev]</div>`
    + `<div>test jwt::verify ... <span style="color:${t.green}">ok</span></div>`
    + `<div>test jwt::refresh ... <span style="color:${t.red}">FAILED</span></div>`
    + `<div><span style="color:${t.yellow}">warning</span>: unused import <span style="background:${lk['selection-background']}">std::fmt</span> <i class="pf-cur" style="background:${lk['cursor-color']}"></i></div>`
    + (faces ? `<div class="pf-faces"><span>Regular ${w('font-weight')}</span> <b style="font-weight:${w('font-weight-bold')};font-family:${ff('font-family-bold')}">Bold ${w('font-weight-bold')}</b> <i style="font-weight:${w('font-weight-italic')};font-family:${ff('font-family-italic')}">Italic ${w('font-weight-italic')}</i> <b><i style="font-weight:${w('font-weight-bold-italic')};font-family:${ff('font-family-bold-italic')}">Bold Italic ${w('font-weight-bold-italic')}</i></b></div>` : '')
    + `<div class="pf-pal">${(c.palette || t.cfg.palette || []).slice(0, 16).map(x => `<u style="background:${x}"></u>`).join('')}</div></div>`;
}
const pfMini = n => { const t = THEMES[n], d = mix(t.fg, t.term, .45);
  return `<i class="pf-mini" style="background:${t.term};color:${t.fg};font-family:${pfFontCss(t.cfg['font-family'] || 'Menlo')}"><span><b style="color:${t.cyan}">~/tako</b> <b style="color:${t.green}">❯</b> mitts test</span><span style="color:${d}">47 passed</span><span><b style="color:${t.red}">1 failed</b> <b class="c" style="background:${t.cfg['cursor-color']}"></b></span>`
    + `<span class="pal">${(t.cfg.palette || []).slice(1, 7).map(c => `<u style="background:${c}"></u>`).join('')}</span></i>`; };

// ---------- where a value comes from, in words ----------
function pfCaption(sc, k) {
  if (k === 'theme') {
    if (sc.kind === 'all') return '<span class="pf-src">Основная тема приложения</span>';
    const r = pfResolve(sc, 'theme');
    return pfSame(r.from, sc) ? `<span class="pf-src own">● Своя <a data-lreset="theme" title="Удалить выбор этого уровня: снова наследовать">↺ наследовать</a></span>`
      : `<span class="pf-src">Наследуется от «${pfEsc(pfScName(r.from))}»</span>`;
  }
  const r = pfResolve(sc, k);
  if (pfSame(r.from, sc) && r.how === 'own') return `<span class="pf-src own">● Своё <a data-lreset="${k}" title="Удалить переопределение: значение снова приходит сверху">↺ сбросить</a></span>`;
  if (r.how === 'theme') return `<span class="pf-src">из темы ${pfEsc(r.theme)}${pfSame(r.from, sc) ? '' : ` · «${pfEsc(pfScName(r.from))}»`}</span>`;
  return `<span class="pf-src">Наследуется от «${pfEsc(pfScName(r.from))}»</span>`;
}

// ---------- the page ----------
function pfThemeCard(n, on) {
  const t = THEMES[n];
  return `<div class="pf-tc ${on ? 'on' : ''}" data-th="${pfEsc(n)}" data-name="${pfEsc(n.toLowerCase())}" role="button" tabindex="0">${pfMini(n)}
    <span class="pf-tn"><b>${pfEsc(n)}</b><small>${t.builtin ? 'встроенная' : 'своя'}${pfRefs(n).length ? ` · ${pfRefs(n).length} ${plural(pfRefs(n).length, 'место', 'места', 'мест')}` : ''}</small></span>
    <button class="pf-more" data-thmore="${pfEsc(n)}" title="Действия с темой">⋯</button></div>`;
}
function pfFontList(cur, attr) {
  const rows = [...(attr === 'data-lfont' ? [['', 'Как в теме', 'шрифт выбранной темы']] : []), ...PF_FONTS.map(([f, , o]) => [f, f, o])];
  return `<div class="pf-fl"><input class="pf-in" data-fq placeholder="Найти шрифт" value="${pfEsc(PL.fq)}" spellcheck="false">
    <div class="pf-flr">${rows.map(([f, l, o]) => `<button class="pf-fr ${cur === f ? 'on' : ''}" ${attr}="${pfEsc(f)}" data-name="${pfEsc(l.toLowerCase())}">
      <b style="font-family:${f ? pfFontCss(f) : 'inherit'}">${pfEsc(l)}</b><span style="font-family:${pfFontCss(f || 'Menlo')}">mitts test -p auth  0O 1lI {}</span><small>${o}</small></button>`).join('')}</div>
    <p class="pf-hint">В Tako список строится из моноширинных шрифтов этого Mac (fontInventory); здесь — типичный Mac и шрифты, которые Tako ставит сам.</p></div>`;
}
const pfStepper = (attr, v, min, max, step, unit, err) => `<span class="pf-step"><button data-${attr}-step="-${step}" aria-label="меньше">−</button><input class="pf-num" data-${attr} value="${pfEsc(v)}" inputmode="decimal" data-min="${min}" data-max="${max}"><button data-${attr}-step="${step}" aria-label="больше">+</button>${unit ? `<em>${unit}</em>` : ''}</span>${err ? `<small class="pf-err">${err}</small>` : ''}`;
function pfLevelColor(sc, k, label) {
  const r = pfResolve(sc, k);
  return `<div class="pf-row"><div class="pf-rl"><b>${label}</b>${pfCaption(sc, k)}</div><div class="pf-rc"><label class="pf-color"><input type="color" data-lc="${k}" value="${r.v}"><code>${String(r.v).toUpperCase()}</code></label></div></div>`;
}
function pfPageLook() {
  if (PED) return pfEditorHtml();
  const sc = SET.scope, lk = pfLook(sc), t = pfThemeOf(lk.theme), own = sc.kind === 'all' ? null : (pfMap(sc)[sc.id] || {}).theme;
  const user = Object.keys(THEMES).filter(n => !THEMES[n].builtin);
  const inh = sc.kind === 'all' ? '' : `<div class="pf-tc inh ${own ? '' : 'on'}" data-th="" data-name="наследовать" role="button" tabindex="0"><i class="pf-mini inh">↑</i><span class="pf-tn"><b>Наследовать</b><small>сейчас ${pfEsc(pfResolve(pfChain(sc).slice(-2)[0], 'theme').v)}</small></span></div>`;
  const cur = lk.theme, curT = THEMES[cur];
  const strip = PL.ren ? `<div class="pf-strip"><label>Новое имя для «${pfEsc(PL.ren.name)}»</label><input class="pf-in" data-renname value="${pfEsc(PL.ren.value)}" spellcheck="false"><button class="pf-btn" data-rencancel>Отмена</button><button class="pf-btn pri" data-renok ${pfNameError(PL.ren.value, PL.ren.name) ? 'disabled' : ''}>Переименовать</button><small class="pf-err">${pfNameError(PL.ren.value, PL.ren.name)}</small><small class="pf-hint">Ссылки на тему в Общих, workspace и терминалах переедут на новое имя.</small></div>`
    : PL.del ? `<div class="pf-strip warn"><b>Удалить тему «${pfEsc(PL.del)}»?</b><span>${pfRefs(PL.del).length ? `Используется: ${pfRefs(PL.del).map(r => `${pfKindName(r)}${r.kind === 'all' ? '' : ' «' + pfEsc(pfScName(r)) + '»'}`).join(', ')}. После удаления они вернутся к наследованию (Общие — к TakoCore).` : 'Нигде не выбрана.'} Файл уйдёт в themes/.deleted.</span><button class="pf-btn" data-delcancel>Отмена</button><button class="pf-btn danger" data-delok>Удалить</button></div>` : '';
  const fam = pfResolve(sc, 'font-family'), ownFam = pfSame(fam.from, sc) && fam.how === 'own';
  const sizeErr = PL.sizeErr || '';
  return pfPreview(lk, t)
    + `<section class="pf-blk"><header><h4>Тема</h4>${pfCaption(sc, 'theme')}</header>
      <div class="pf-tools"><input class="pf-in" data-tq placeholder="Найти тему" value="${pfEsc(PL.tq)}" spellcheck="false"><button class="pf-btn" data-tnew>Новая тема…</button></div>
      <div class="pf-tg">${inh}${PF_BUILTIN.map(n => pfThemeCard(n, own === n || (sc.kind === 'all' && cur === n))).join('')}</div>
      ${user.length ? `<div class="pf-sub">Свои темы</div><div class="pf-tg">${user.map(n => pfThemeCard(n, own === n || (sc.kind === 'all' && cur === n))).join('')}</div>` : ''}
      <div class="pf-tact"><span>Сейчас: <b>${pfEsc(cur)}</b>${curT.builtin ? ' · встроенная, меняется через копию' : ''}</span>
        <button class="pf-btn" data-tdup="${pfEsc(cur)}">Дублировать…</button>${curT.builtin ? '' : `<button class="pf-btn" data-tedit="${pfEsc(cur)}">Изменить</button>`}</div>${strip}</section>
    <section class="pf-blk"><header><h4>Шрифт и размер</h4></header>
      <div class="pf-row"><div class="pf-rl"><b>Шрифт</b>${pfCaption(sc, 'font-family')}</div><div class="pf-rc"><button class="pf-fbtn ${PL.fonts ? 'open' : ''}" data-fonts style="font-family:${pfFontCss(fam.v)}">${pfEsc(fam.v)}<span>▾</span></button></div></div>
      ${PL.fonts ? pfFontList(ownFam ? fam.v : '', 'data-lfont') : ''}
      <div class="pf-row"><div class="pf-rl"><b>Размер</b>${pfCaption(sc, 'font-size')}</div><div class="pf-rc">${pfStepper('lsize', pfResolve(sc, 'font-size').v, 6, 72, 1, 'pt', sizeErr)}</div></div>
      <p class="pf-hint">Шрифт и размер окна настроек — системные и от терминала не зависят. Отступы терминала — 0.</p></section>
    <section class="pf-blk"><button class="pf-disc ${PL.colors ? 'open' : ''}" data-lcolors><span>▸</span>Цвета поверх темы<small>${['background', 'foreground', 'cursor-color', 'selection-background'].filter(k => { const r = pfResolve(sc, k); return pfSame(r.from, sc) && r.how === 'own'; }).length || ''}</small></button>
      ${PL.colors ? pfLevelColor(sc, 'background', 'Фон') + pfLevelColor(sc, 'foreground', 'Текст') + pfLevelColor(sc, 'cursor-color', 'Курсор') + pfLevelColor(sc, 'selection-background', 'Выделение')
        + '<p class="pf-hint">Своё значение этого уровня. Выбор темы на этом уровне сбрасывает его поля.</p>' : ''}</section>`;
}

// ---------- the preset editor ----------
function pfOpenEditor(mode, name) {
  const src = THEMES[name] || THEMES.TakoCore, cfg = pfClone(src.cfg);
  for (const k of ['font-family', 'font-size']) if (cfg[k] === undefined) cfg[k] = PF_TDEF[k];
  const nm = mode === 'edit' ? name : pfUnique(mode === 'new' ? 'New Theme' : `${name} Copy`);
  PED = { mode, orig: mode === 'edit' ? name : null, base: name, name: nm, initName: nm, cfg, init: pfClone(cfg), tab: 'colors', sc: SET.scope, faces: false, text: null, terr: [] };
  PL.ren = PL.del = null; applyCfg();
}
const pfDirty = () => (PED.name !== PED.initName ? 1 : 0) + PF_EKEYS.filter(k => PED.cfg[k] !== PED.init[k]).length + (JSON.stringify(PED.cfg.palette) !== JSON.stringify(PED.init.palette) ? 1 : 0);
const pfEdErrors = () => [pfNameError(PED.name, PED.orig), ...PF_EKEYS.map(k => pfFieldError(k, PED.cfg[k])), ...(PED.cfg.palette || []).map(c => pfFieldError('palette', c)), ...(PED.terr.length ? ['config'] : [])].filter(Boolean);
const pfEv = k => PED.cfg[k] !== undefined ? PED.cfg[k] : PF_TDEF[k] || '';
function pfECol(k, label, note) {
  const v = pfEv(k), err = pfFieldError(k, v);
  return `<div class="pf-row"><div class="pf-rl"><b>${label}</b>${note ? `<span class="pf-src">${note}</span>` : ''}</div><div class="pf-rc"><label class="pf-color"><input type="color" data-ec="${k}" value="${/^#[0-9a-f]{6}$/i.test(v) ? v : '#000000'}"></label><input class="pf-in hex ${err ? 'bad' : ''}" data-eh="${k}" value="${pfEsc(v)}" spellcheck="false">${PED.cfg[k] !== PED.init[k] ? `<a class="pf-rst" data-erst="${k}" title="Вернуть исходное">↺</a>` : ''}<small class="pf-err">${err}</small></div></div>`;
}
function pfESeg(k, opts, label, note) { const v = pfEv(k) || opts[0][0];
  return `<div class="pf-row"><div class="pf-rl"><b>${label}</b>${note ? `<span class="pf-src">${note}</span>` : ''}</div><div class="pf-rc"><span class="pf-seg">${opts.map(([x, l]) => `<button data-eseg="${k}" data-v="${x}" class="${v === x ? 'on' : ''}">${l}</button>`).join('')}</span></div></div>`; }
function pfERange(k, label, min, max, step, note) { const v = pfEv(k) || (k.includes('opacity') ? '1' : '400');
  return `<div class="pf-row"><div class="pf-rl"><b>${label}</b>${note ? `<span class="pf-src">${note}</span>` : ''}</div><div class="pf-rc"><input type="range" data-er="${k}" min="${min}" max="${max}" step="${step}" value="${v}"><input class="pf-in num" data-eh="${k}" value="${pfEsc(v)}"><small class="pf-err">${pfFieldError(k, v)}</small></div></div>`; }
function pfFaceSel(k, label) { const v = PED.cfg[k] || '';
  return `<div class="pf-row"><div class="pf-rl"><b>${label}</b></div><div class="pf-rc"><select class="pf-in" data-eface="${k}"><option value="">как основной</option>${PF_FONTS.map(([f]) => `<option ${v === f ? 'selected' : ''}>${f}</option>`).join('')}</select></div></div>`; }
function pfConfigText(cfg) {
  const lines = ['# tako-preset-version: 1'];
  for (const k of PF_EKEYS) if (cfg[k] !== undefined) lines.push(`${k} = ${cfg[k]}`);
  (cfg.palette || []).forEach((c, i) => lines.push(`palette = ${i}=${c}`));
  return lines.join('\n');
}
function pfParseConfig(text) {                    // the editor's «Конфиг» view: same keys and checks as the preset file
  const cfg = { palette: [] }, errs = [], seen = new Set();
  text.split('\n').forEach((raw, i) => {
    const s = raw.trim(); if (!s || s.startsWith('#')) return;
    const eq = s.indexOf('='); if (eq < 0) return errs.push([i + 1, 'нет «=»']);
    const k = s.slice(0, eq).trim(), v = s.slice(eq + 1).trim();
    if (!k) return errs.push([i + 1, 'пустой ключ']);
    if (k === 'theme') return errs.push([i + 1, 'ссылка на другую тему внутри темы не допускается']);
    if (k === 'palette') {
      const m = v.match(/^(\d+)\s*=\s*(.+)$/); if (!m || +m[1] > 255) return errs.push([i + 1, 'palette = ИНДЕКС=#RRGGBB, индекс 0–255']);
      if (pfFieldError('palette', m[2])) return errs.push([i + 1, `palette ${m[1]}: цвет в виде #RRGGBB`]);
      if (seen.has('p' + m[1])) return errs.push([i + 1, `palette ${m[1]} указан дважды`]); seen.add('p' + m[1]);
      if (+m[1] < 16) cfg.palette[+m[1]] = m[2]; return;
    }
    if (!PF_EKEYS.includes(k)) return errs.push([i + 1, `неизвестный ключ оформления «${k}»`]);
    if (seen.has(k)) return errs.push([i + 1, `«${k}» указан дважды`]); seen.add(k);
    const e = pfFieldError(k, v); if (e) return errs.push([i + 1, `${k}: ${e}`]);
    cfg[k] = v;
  });
  return { cfg, errs };
}
function pfEditorHtml() {
  const E = PED, t = pfThemeObj(E.name, E.cfg, false), lk = { ...pfLook(E.sc, { sc: E.sc, look: { theme: '__draft__' } }) };
  const nerr = pfNameError(E.name, E.orig), tabs = [['colors', 'Цвета'], ['ansi', 'ANSI'], ['type', 'Шрифт'], ['cursor', 'Курсор и выделение'], ['config', 'Конфиг']];
  let body = '';
  if (E.tab === 'colors') body = pfECol('background', 'Фон') + pfECol('foreground', 'Текст') + pfERange('background-opacity', 'Непрозрачность фона', 0, 1, .05, '1 — без прозрачности');
  else if (E.tab === 'ansi') body = `<div class="pf-ansi">${E.cfg.palette.slice(0, 16).map((c, i) => `<label class="pf-ac ${c !== E.init.palette[i] ? 'chg' : ''}" title="${PF_ANSI[i]}"><input type="color" data-ec="palette:${i}" value="${c}"><b>${i}</b><small>${PF_ANSI[i]}</small></label>`).join('')}</div><p class="pf-hint">0–7 — обычные, 8–15 — яркие. Программы в терминале берут цвета отсюда.</p>`;
  else if (E.tab === 'type') body = `<div class="pf-row"><div class="pf-rl"><b>Шрифт</b><span class="pf-src">основной для темы</span></div><div class="pf-rc"><button class="pf-fbtn ${PL.fonts ? 'open' : ''}" data-fonts style="font-family:${pfFontCss(pfEv('font-family'))}">${pfEsc(pfEv('font-family'))}<span>▾</span></button></div></div>`
    + (PL.fonts ? pfFontList(E.cfg['font-family'], 'data-efont') : '')
    + `<div class="pf-row"><div class="pf-rl"><b>Размер</b></div><div class="pf-rc">${pfStepper('esize', pfEv('font-size'), 6, 72, 1, 'pt', pfFieldError('font-size', pfEv('font-size')))}</div></div>`
    + `<button class="pf-disc ${E.faces ? 'open' : ''}" data-faces><span>▸</span>Начертания и метрики<small>regular · bold · italic · bold italic</small></button>`
    + (E.faces ? pfERange('font-weight', 'Вес обычного', 100, 900, 50) + pfERange('font-weight-bold', 'Вес жирного', 100, 900, 50) + pfERange('font-weight-italic', 'Вес курсива', 100, 900, 50) + pfERange('font-weight-bold-italic', 'Вес жирного курсива', 100, 900, 50)
      + pfFaceSel('font-family-bold', 'Шрифт жирного') + pfFaceSel('font-family-italic', 'Шрифт курсива') + pfFaceSel('font-family-bold-italic', 'Шрифт жирного курсива')
      + `<div class="pf-row"><div class="pf-rl"><b>Высота строки</b><span class="pf-src">adjust-cell-height · число или %</span></div><div class="pf-rc"><input class="pf-in num" data-eh="adjust-cell-height" value="${pfEsc(E.cfg['adjust-cell-height'] || '')}" placeholder="0"><small class="pf-err">${pfFieldError('adjust-cell-height', E.cfg['adjust-cell-height'])}</small></div></div>`
      + '<p class="pf-hint">100–900, стрелки меняют на 50; в конфиге — любое целое. Переменный шрифт берёт вес с оси, остальные — ближайшее начертание.</p>' : '');
  else if (E.tab === 'cursor') body = pfECol('cursor-color', 'Курсор') + pfESeg('cursor-style', [['block', 'блок'], ['bar', 'черта'], ['underline', 'подчёркивание']], 'Форма курсора', 'в теме побеждает общую настройку')
    + pfESeg('cursor-style-blink', [['false', 'не мигает'], ['true', 'мигает']], 'Мигание') + pfERange('cursor-opacity', 'Непрозрачность курсора', 0, 1, .05)
    + pfECol('selection-background', 'Фон выделения') + pfECol('selection-foreground', 'Текст выделения') + pfESeg('selection-invert-fg-bg', [['false', 'цвета выше'], ['true', 'инвертировать']], 'Выделение');
  else body = `<textarea class="pf-cfg" data-ecfg spellcheck="false">${pfEsc(E.text !== null ? E.text : pfConfigText(E.cfg))}</textarea>
    <div class="pf-cfgst">${E.terr.length ? E.terr.map(([l, m]) => `<p class="pf-err">строка ${l}: ${pfEsc(m)}</p>`).join('') : '<p class="pf-ok">Конфиг корректен · применяется к черновику</p>'}</div>`;
  return `<div class="pf-ed"><div class="pf-edhd"><button class="pf-back" data-edcancel>‹ Темы</button>
      <label class="pf-name"><span>Имя темы</span><input class="pf-in ${nerr ? 'bad' : ''}" data-edname value="${pfEsc(E.name)}" ${E.orig ? 'readonly title="Переименование — отдельным действием в каталоге"' : ''} spellcheck="false"><small class="pf-err">${nerr}</small></label>
      <span class="pf-src">${E.orig ? 'своя тема' : `копия «${pfEsc(E.base)}» — исходная тема не меняется`}</span></div>
    ${pfPreview(lk, t, E.tab === 'type', E.cfg)}
    <nav class="pf-tabs">${tabs.map(([k, l]) => `<button data-etab="${k}" class="${E.tab === k ? 'on' : ''}">${l}</button>`).join('')}</nav>
    <div class="pf-edb">${body}</div></div>`;
}
function pfSaveEditor() {
  if (pfEdErrors().length) return;
  const E = PED, cfg = pfClone(E.cfg);
  PREFS.themes[E.name] = cfg; pfRebuildThemes();
  const sc = E.sc, users = E.orig ? pfRefs(E.name).length : 0;
  PED = null; PL.fonts = false;
  if (!E.orig) pfSetTheme(sc, E.name); else { pfSave(); applyCfg(); }
  PSET.msg = E.orig ? `Тема «${E.name}» сохранена${users ? ` · видно везде, где она выбрана (${users})` : ''}` : `Тема «${E.name}» создана и выбрана для «${pfScName(sc)}»`;
}
function pfCancelEditor() { PED = null; PL.fonts = false; PSET.msg = 'Изменения темы отменены — терминалы вернулись к прежнему виду'; applyCfg(); }
function pfRename(oldN, newN) {
  PREFS.themes[newN] = PREFS.themes[oldN]; delete PREFS.themes[oldN];
  for (const k of ['theme', 'dark', 'light']) if (CFG[k] === oldN) CFG[k] = newN;
  for (const m of [PREFS.look.workspaces, PREFS.look.sessions, PREFS.look.panes]) for (const l of Object.values(m)) if (l.theme === oldN) l.theme = newN;
  PREFS.recent = PREFS.recent.map(x => x === oldN ? newN : x);
  pfRebuildThemes(); pfSave(); applyCfg();
}
function pfDelete(n) {
  for (const k of ['theme', 'dark', 'light']) if (CFG[k] === n) CFG[k] = k === 'light' ? 'Tako Paper' : 'TakoCore';
  for (const m of [PREFS.look.workspaces, PREFS.look.sessions, PREFS.look.panes]) for (const [id, l] of Object.entries(m)) if (l.theme === n) { delete l.theme; if (!Object.keys(l).length) delete m[id]; }
  delete PREFS.themes[n]; PREFS.recent = PREFS.recent.filter(x => x !== n);
  pfRebuildThemes(); pfSave(); applyCfg();
}
