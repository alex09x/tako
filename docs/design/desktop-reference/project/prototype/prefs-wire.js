'use strict';
// Tako desktop prototype — settings window input, and quick assignment from context menus:
// right-click a workspace, a terminal header or a terminal body → «Оформление ▸» with a few presets, «Наследовать», «Все темы…».
function pfEdRefresh(el) {                        // live editor bits without re-rendering the field being typed in
  const pv = el.querySelector('.pf-ed .pf-pv');
  if (pv) pv.outerHTML = pfPreview(pfLook(PED.sc, { sc: PED.sc, look: { theme: '__draft__' } }), pfThemeObj(PED.name, PED.cfg, false), PED.tab === 'type', PED.cfg);
  const ft = el.querySelector('.pf-ft'); if (ft) ft.innerHTML = pfFootHtml();
  applyCfg();
}
function pfSetEd(k, v) { if (k.startsWith('palette:')) PED.cfg.palette[+k.slice(8)] = v; else if (v === '' && k === 'adjust-cell-height') delete PED.cfg[k]; else PED.cfg[k] = v; }
const pfClamp = (v, min, max) => Math.min(max, Math.max(min, v));
function pfStep(btn) {
  const a = [...btn.attributes].find(x => x.name.endsWith('-step')), key = a.name.slice(5, -5), inp = btn.parentNode.querySelector('.pf-num');
  const n = pfClamp(Math.round((parseFloat(inp.value) || 0) + parseFloat(a.value)), +inp.dataset.min, +inp.dataset.max);
  pfStepSet(key, n);
}
function pfStepSet(key, n) {
  if (key === 'lsize') { PL.sizeErr = ''; pfSetField(SET.scope, 'font-size', String(n)); }
  else if (key === 'esize') { PED.cfg['font-size'] = String(n); applyCfg(); }
  else if (key.startsWith('pn-')) pfSetVal(key.slice(3), n);
}
function pfWire(el) {
  const R = () => redraw(el);
  el.addEventListener('click', e => {
    const t = e.target, g = s => t.closest(s);
    if (g('[data-close]')) return closePop();
    if (g('[data-wizard]')) return openOnboarding();
    // agents and access: the same actions as the wizard
    const pm = g('[data-perm]'), pa = g('[data-pane]'), un = g('[data-unskill]'), pd = g('[data-pdet]');
    if (pm) return runPerm(pm.dataset.perm, R);
    if (pa) return openPane(pa.dataset.pane, R);
    if (pd) { SETUP.det = SETUP.det === pd.dataset.pdet ? null : pd.dataset.pdet; return R(); }
    if (g('[data-test]')) return sendTest(R);
    if (g('[data-skill]')) { addSkill(); return R(); }
    if (g('[data-det]')) { OB.det = !OB.det; return R(); }
    if (g('[data-extra]')) { SETUP.extra = !SETUP.extra; saveSetup(); return R(); }
    if (un) { delete SETUP.skill[un.dataset.unskill]; OB.added = null; saveSetup(); return R(); }
    if (g('[data-hotkey]')) { SETUP.hotkey = !SETUP.hotkey; readStatuses('статусы прочитаны'); saveSetup(); R(); return SETUP.hotkey && !READ.ax ? openPane('ax', R) : null; }
    // navigation and search results
    const nv = g('[data-pg]'), go = g('[data-go]');
    if (nv) { SET.page = nv.dataset.pg; PSET.q = ''; PSET.msg = ''; if (SET.page === 'perms') readStatuses('статусы прочитаны при открытии раздела'); return R(); }
    if (go) { SET.page = go.dataset.go; PSET.q = ''; PSET.hl = go.dataset.hl || null; if (go.dataset.kfind) PK.q = go.dataset.kfind; if (SET.page === 'look' && PSET.hl === 'colors') PL.colors = true; return R(); }
    const cr = g('[data-sc]'); if (cr) { SET.scope = pfScParse(cr.dataset.sc); pfShow(SET.scope); PL.ren = PL.del = null; PSET.msg = ''; return R(); }
    // themes: choose = applies at once; anything that edits a preset goes through the draft
    const more = g('[data-thmore]'); if (more) { e.stopPropagation(); const r = more.getBoundingClientRect(); return pfThemeMenu(more.dataset.thmore, r.left, r.bottom + 4, el); }
    const th = g('[data-th]'); if (th) { const n = th.dataset.th; pfSetTheme(SET.scope, n || undefined); PSET.msg = n ? `«${pfScName(SET.scope)}» — тема ${n}` : `«${pfScName(SET.scope)}» снова наследует тему`; return R(); }
    if (g('[data-tnew]')) { pfOpenEditor('new', pfResolve(SET.scope, 'theme').v); R(); return pfFocusName(el); }
    const dup = g('[data-tdup]'); if (dup) { pfOpenEditor('dup', dup.dataset.tdup); R(); return pfFocusName(el); }
    const ed = g('[data-tedit]'); if (ed) { pfOpenEditor('edit', ed.dataset.tedit); return R(); }
    if (g('[data-renok]')) { if (pfNameError(PL.ren.value, PL.ren.name)) return; pfRename(PL.ren.name, PL.ren.value); PSET.msg = `Тема переименована: ${PL.ren.name} → ${PL.ren.value}`; PL.ren = null; return R(); }
    if (g('[data-rencancel]')) { PL.ren = null; return R(); }
    if (g('[data-delok]')) { const n = PL.del; pfDelete(n); PL.del = null; PSET.msg = `Тема «${n}» удалена (themes/.deleted)`; return R(); }
    if (g('[data-delcancel]')) { PL.del = null; return R(); }
    const lr = g('[data-lreset]'); if (lr) { const k = lr.dataset.lreset; if (k === 'theme') pfSetTheme(SET.scope, undefined); else pfSetField(SET.scope, k, undefined); return R(); }
    if (g('[data-lresetall]')) { pfResetLevel(SET.scope); PSET.msg = `Оформление «${pfScName(SET.scope)}» сброшено — снова наследует`; return R(); }
    if (g('[data-fonts]')) { PL.fonts = !PL.fonts; PL.fq = ''; return R(); }
    const lf = g('[data-lfont]'); if (lf) { pfSetField(SET.scope, 'font-family', lf.dataset.lfont || undefined); PL.fonts = false; return R(); }
    const ef = g('[data-efont]'); if (ef) { PED.cfg['font-family'] = ef.dataset.efont || 'Menlo'; PL.fonts = false; applyCfg(); return R(); }
    if (g('[data-lcolors]')) { PL.colors = !PL.colors; return R(); }
    const st = g('.pf-step button'); if (st) { pfStep(st); return R(); }
    // app settings
    const ps = g('[data-ps]'); if (ps) { const it = PF_SET.find(x => x.id === ps.dataset.ps); pfSetVal(it.id, it.type === 'bool' ? !pfGet(it.id) : ps.dataset.v); return R(); }
    const sr = g('[data-sreset]'); if (sr) { pfSetVal(sr.dataset.sreset, undefined); return R(); }
    const os = g('.sg[data-k] button[data-v]'); if (os) { CFG[os.closest('.sg').dataset.k] = os.dataset.v; applyCfg(); return R(); }
    const ot = g('[data-t]'); if (ot) { CFG[ot.dataset.t] = !CFG[ot.dataset.t]; applyCfg(); return R(); }
    // the editor
    if (g('[data-edcancel]')) { pfCancelEditor(); return R(); }
    if (g('[data-edsave]')) { pfSaveEditor(); return R(); }
    const et = g('[data-etab]'); if (et) { PED.tab = et.dataset.etab; if (!PED.terr.length) PED.text = null; PL.fonts = false; return R(); }
    const rs = g('[data-erst]'); if (rs) { const k = rs.dataset.erst; if (PED.init[k] === undefined) delete PED.cfg[k]; else PED.cfg[k] = PED.init[k]; applyCfg(); return R(); }
    const es = g('[data-eseg]'); if (es) { PED.cfg[es.dataset.eseg] = es.dataset.v; applyCfg(); return R(); }
    if (g('[data-faces]')) { PED.faces = !PED.faces; return R(); }
    // keys
    if (g('[data-kcancel]')) { PK.rec = null; PK.msg = 'Запись отменена'; return pfKRefresh(); }
    const kr = g('[data-kreset]'); if (kr) { e.stopPropagation(); pfKReset(kr.dataset.kreset); return pfKRefresh(); }
    if (g('[data-kyes]')) { const c = PK.conf; PK.conf = null; if (PREFS.keys[c.holder] !== undefined) delete PREFS.keys[c.holder]; pfKApply(c.target, c.tr, c.holder); return pfKRefresh(); }
    if (g('[data-kno]')) { PK.conf = null; PK.msg = 'Переназначение отменено'; return pfKRefresh(); }
    const ko = g('[data-konly]'); if (ko) { PK.only = ko.dataset.konly; return R(); }
    const row = g('.pf-kr[data-ka]'); if (row && !g('.pf-kconf')) return pfKStart(row.dataset.ka);
  });
  el.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || PK.rec || PK.conf) return;
    const c = e.target.closest('.pf-tc,.pf-kr'); if (c && e.target === c) { e.preventDefault(); c.click(); }
  });
  el.addEventListener('input', e => {
    const t = e.target, d = t.dataset;
    if ('pq' in d) { PSET.q = t.value; return R(); }
    if ('tq' in d) { PL.tq = t.value.toLowerCase(); el.querySelectorAll('.pf-tc:not(.inh)').forEach(c => { c.hidden = !c.dataset.name.includes(PL.tq); }); return; }
    if ('fq' in d) { PL.fq = t.value.toLowerCase(); el.querySelectorAll('.pf-fr').forEach(c => { c.hidden = !c.dataset.name.includes(PL.fq); }); return; }
    if ('kq' in d) { PK.q = t.value; return pfKFilter(el); }
    if ('lc' in d) { pfSetField(SET.scope, d.lc, t.value); t.nextElementSibling.textContent = t.value.toUpperCase(); return; }
    if ('pcol' in d) { pfSetVal(d.pcol, t.value); t.nextElementSibling.textContent = t.value.toUpperCase(); return; }
    if ('renname' in d) { PL.ren.value = t.value; const err = pfNameError(t.value, PL.ren.name); el.querySelector('.pf-strip .pf-err').textContent = err; el.querySelector('[data-renok]').disabled = !!err; return; }
    if (!PED) return;
    if ('edname' in d) { PED.name = t.value; const err = pfNameError(t.value, PED.orig); t.classList.toggle('bad', !!err); t.parentNode.querySelector('.pf-err').textContent = err; return pfEdRefresh(el); }
    if ('ec' in d) { pfSetEd(d.ec, t.value); const h = el.querySelector(`[data-eh="${d.ec}"]`); if (h) { h.value = t.value; h.classList.remove('bad'); } return pfEdRefresh(el); }
    if ('er' in d) { pfSetEd(d.er, t.value); const h = el.querySelector(`[data-eh="${d.er}"]`); if (h) h.value = t.value; return pfEdRefresh(el); }
    if ('eh' in d) {
      pfSetEd(d.eh, t.value.trim()); const err = pfFieldError(d.eh, t.value.trim());
      t.classList.toggle('bad', !!err); const s = t.parentNode.querySelector('.pf-err'); if (s) s.textContent = err;
      const c = el.querySelector(`[data-ec="${d.eh}"],[data-er="${d.eh}"]`); if (c && !err) c.value = t.value.trim();
      return pfEdRefresh(el);
    }
    if ('ecfg' in d) {
      PED.text = t.value; const r = pfParseConfig(t.value); PED.terr = r.errs;
      if (!r.errs.length) { const pal = PED.cfg.palette.slice(); r.cfg.palette.forEach((c, i) => { if (c) pal[i] = c; }); PED.cfg = { ...r.cfg, palette: pal }; }
      el.querySelector('.pf-cfgst').innerHTML = r.errs.length ? r.errs.map(([l, m]) => `<p class="pf-err">строка ${l}: ${pfEsc(m)}</p>`).join('') : '<p class="pf-ok">Конфиг корректен · применяется к черновику</p>';
      return pfEdRefresh(el);
    }
  });
  el.addEventListener('change', e => {
    const t = e.target, d = t.dataset;
    if ('lc' in d || 'pcol' in d) return R();
    if ('eface' in d) { if (t.value) PED.cfg[d.eface] = t.value; else delete PED.cfg[d.eface]; applyCfg(); return R(); }
    const num = [...t.attributes].find(a => a.name.startsWith('data-') && t.classList.contains('pf-num'));
    if (num) {
      const key = num.name.slice(5), v = parseFloat(t.value.replace(',', '.')), min = +t.dataset.min, max = +t.dataset.max;
      if (!isFinite(v) || v < min || v > max) { if (key === 'lsize') PL.sizeErr = `Размер от ${min} до ${max} pt`; else if (key === 'esize') PED.cfg['font-size'] = t.value; return R(); }
      pfStepSet(key, v); return R();
    }
  });
}
const pfFocusName = el => { const i = el.querySelector('[data-edname]'); if (i && !i.readOnly) { i.focus(); i.select(); } };
function pfThemeMenu(n, x, y, el) {
  const t = THEMES[n], R = () => redraw(el);
  openCtx([
    { label: `Выбрать для «${pfScName(SET.scope)}»`, run: () => { pfSetTheme(SET.scope, n); R(); } }, '-',
    { label: 'Дублировать…', run: () => { pfOpenEditor('dup', n); R(); pfFocusName(el); } },
    { label: t.builtin ? 'Изменить — через копию' : 'Изменить…', off: t.builtin, run: () => { pfOpenEditor('edit', n); R(); } },
    { label: 'Переименовать…', off: t.builtin, run: () => { PL.ren = { name: n, value: n }; PL.del = null; R(); const i = el.querySelector('[data-renname]'); if (i) { i.focus(); i.select(); } } },
    '-', { label: 'Удалить…', dang: true, off: t.builtin, run: () => { PL.del = n; PL.ren = null; R(); } },
  ], x, y);
}

// ---------- «Оформление ▸» in context menus ----------
function pfLookMenu(sc, label) {
  const own = sc.kind === 'all' ? CFG.theme : (pfMap(sc)[sc.id] || {}).theme;
  const parent = sc.kind === 'all' ? '' : pfResolve(pfChain(sc).slice(-2)[0], 'theme').v;
  const names = [...new Set([own, ...PREFS.recent, ...PF_BUILTIN].filter(n => n && THEMES[n]))].slice(0, 6);
  const sw = n => `linear-gradient(135deg,${THEMES[n].term} 55%,${THEMES[n].cfg['cursor-color']} 55%)`;
  const say = m => { if (typeof toast2 === 'function') toast2('', m); };
  return { label: label || 'Оформление', sub: [
    ...(sc.kind === 'all' ? [] : [{ label: `Наследовать · ${parent}`, chk: !own, run: () => { pfSetTheme(sc, undefined); say(`«${pfScName(sc)}» снова наследует ${parent}`); } }, '-']),
    ...names.map(n => ({ label: n, sw: sw(n), chk: own === n, run: () => { pfSetTheme(sc, n); say(`«${pfScName(sc)}» — ${n}`); } })),
    '-', { label: 'Все темы…', run: () => openSettings(sc, 'look', { focus: '[data-tq]' }) },
    { label: 'Настроить…', run: () => openSettings(sc, 'look') },
  ] };
}
winMenu = (id, x, y) => {
  const [s, w] = findWin(id); if (!w) return;
  const go = f => () => { if (s.id !== S.active && w.mode !== 'float') switchSession(s.id); f(); };
  ctxExtra = null;
  openCtx([
    { label: 'Переименовать', off: w.mode === 'min', run: go(() => renameWindow(id)) }, '-',
    { label: 'Разделить вправо', kbd: '⌘D', off: w.mode !== 'tile', run: go(() => splitFrom(id, 'h')) },
    { label: 'Разделить вниз', kbd: '⇧⌘D', off: w.mode !== 'tile', run: go(() => splitFrom(id, 'v')) }, '-',
    { label: w.mode === 'float' ? 'Вернуть в сетку' : 'Плавающее окно', off: w.mode === 'min', run: go(() => toggleFloat(id)) },
    { label: w.max ? 'Вернуть в ячейку' : 'На всё поле', kbd: '⇧⌘↩', off: w.mode === 'min', run: go(() => toggleMax(id)) },
    { label: w.mode === 'min' ? 'Вернуть с полки' : 'Свернуть на полку', run: go(() => w.mode === 'min' ? restore(id) : minimize(id)) }, '-',
    pfLookMenu({ kind: 'w', id }), '-',
    { label: 'Закрыть терминал', kbd: '⌘W', dang: true, run: go(() => askClose(id)) },
  ], x, y);
};
wsMenu = (ws, x, y) => { ctxExtra = pfLookMenu({ kind: 'ws', id: ws.id }); _wsMenuLook(ws, x, y); };
const _sesMenuPf = sessionMenu;
sessionMenu = (s, x, y) => { if (IDEAS.on) ctxExtra = pfLookMenu({ kind: 'ses', id: s.id }, 'Оформление сессии · расширение'); _sesMenuPf(s, x, y); };
const _openCtxPf = openCtx;
openCtx = (items, x, y) => { _openCtxPf(items, x, y); if (ctxEl && ctxEl.getBoundingClientRect().right + 230 > innerWidth) ctxEl.classList.add('flip'); };
// the terminal body keeps its own menu (copy, paste…); appearance sits there too, never instead of it
function pfBodyMenu(el, id) {
  const b = el.querySelector('.fw-body'); if (!b || b._pf) return; b._pf = 1;
  b.addEventListener('contextmenu', e => {
    e.preventDefault(); const sel = String(getSelection()).trim();
    openCtx([
      { label: 'Копировать', kbd: '⌘C', off: !sel, run: () => { try { navigator.clipboard.writeText(sel); } catch (x) { /* no clipboard */ } } },
      { label: 'Вставить', kbd: '⌘V', run: () => {} },
      { label: 'Выделить всё', kbd: '⌘A', run: () => { const r = document.createRange(); r.selectNodeContents(b); getSelection().removeAllRanges(); getSelection().addRange(r); } }, '-',
      pfLookMenu({ kind: 'w', id }), '-',
      { label: 'Разделить вправо', kbd: '⌘D', run: () => splitFrom(id, 'h') },
      { label: 'Разделить вниз', kbd: '⇧⌘D', run: () => splitFrom(id, 'v') },
    ], e.clientX, e.clientY);
  });
}
const _mountPf = mount;
mount = function (w, opening) { const el = _mountPf(w, opening); pfBodyMenu(el, w.id); return el; };
for (const [id, el] of els) pfBodyMenu(el, id);
render();
