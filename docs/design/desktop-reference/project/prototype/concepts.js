// Tako desktop prototype — one connected path (design proposal, native not implemented yet):
// Обзор ⌘⇧O → терминал → ⌘F по командам → выбранный блок → «… рядом» ⇧⌘↩ → Esc обратно к вводу.
// Commands, output and results share one identity: «#N команда». Navigation never re-runs anything.
// Nothing here runs on a timer: views render on open and on input only.

const FL = { hist: null, find: false, q: '', mode: 'cmd', only: 'all', sel: null, pins: [], view: null, errOnly: false, raw: false, hk: 0 };
const HB = [
  { id: 1, cmd: 'mitts bench -p tako-grid', code: 0, res: 'chart', out: ['<c>⚡ Mitts Build</c> <d>bench [release] ───────────</d>', 'reflow/wide_char_80x24   time: [318 µs]', 'reflow/ascii_80x24       time: [186 µs]', 'reflow/mixed_200x60      time: [1.41 ms]'] },
  { id: 2, cmd: 'takoctl screenshot --pane 2', code: 0, res: 'img', out: ['<d>~/Pictures/tako-pane-2.png · 1440×900</d>'] },
  { id: 3, cmd: 'git diff', code: 0, res: 'diff', out: ['<d>diff --git a/src/grid/reflow.rs b/src/grid/reflow.rs</d>', '<d>@@ -204,11 +204,13 @@ impl Grid {</d>', '<r>-        let spill = self.width_at(cols);</r>', '<g>+        let spill = self.width_at(cols).min(2);</g>', '<d>… ещё 19 строк</d>'] },
  { id: 4, cmd: 'mitts test --workspace', code: 101, res: 'report', out: ['<c>⚡ Mitts Build</c> <d>test [dev] ────────────────</d>', 'running 48 tests', 'test parser::osc133 ... <g>ok</g>', 'test grid::reflow_wide_char ... <r>FAILED</r>', '', '---- grid::reflow_wide_char stdout ----', "thread 'grid::reflow_wide_char' panicked at src/grid/reflow.rs:212:9:", 'assertion `left == right` failed', '  left: 3', ' right: 2', '', 'test result: <r>FAILED</r>. 47 passed; 1 failed; 0 ignored', '<b>└─</b> ❌ <r>dev profile failed</r> <d>(Test harness failed)</d>'], err: [3, 6, 7, 8, 9, 11] },
];
const RES = { report: ['Отчёт', 'отчёт теста'], diff: ['Diff', 'diff'], chart: ['График', 'график'], img: ['Снимок', 'снимок'] };
const tag = s => s.replace(/<(\/?)([cdgrybp])>/g, (m, sl, k) => sl ? '</span>' : `<span class="${k}">`);
const plain = s => s.replace(/<\/?[cdgrybp]>/g, '');
const cxEsc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const markQ = (html, q) => !q ? html : html.replace(/(>|^)([^<]*)/g, (m, a, t) => a + t.replace(new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), x => `<mark>${x}</mark>`));
const SVGI = {
  pin: '<svg viewBox="0 0 16 16"><path d="M6 2h4l-.6 4 2.6 2.4H4L6.6 6zM8 8.4V14"/></svg>',
  copy: '<svg viewBox="0 0 16 16"><rect x="5" y="5" width="8.5" height="8.5" rx="1.6"/><path d="M3 10.5V3.6A1.1 1.1 0 0 1 4.1 2.5H11"/></svg>',
  side: '<svg viewBox="0 0 16 16"><rect x="1.8" y="2.8" width="12.4" height="10.4" rx="1.8"/><path d="M9 2.8v10.4"/></svg>',
  err: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6"/><path d="M8 4.8v3.8M8 11h.01"/></svg>',
  find: '<svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2 13.5 13.5"/></svg>',
};
CONTENT.view = '';
const PROP = '<span class="prop" title="Дизайн-предложение: в нативном Tako ещё нет">предложение</span>';
const histWin = () => FL.hist && findWin(FL.hist)[1];
const viewWin = () => FL.view && findWin(FL.view)[1];
const blk = id => HB.find(b => b.id === id);
const hits = () => HB.filter(b => (FL.only === 'all' || b.code) && (!FL.q || b.cmd.toLowerCase().includes(FL.q.toLowerCase()) || (FL.mode === 'all' && b.out.some(l => plain(l).toLowerCase().includes(FL.q.toLowerCase())))));
const bid = b => `<span class="bid">#${b.id}</span>`;

// ---------- the terminal: its scrollback as command blocks ----------
function blockHtml(b) {
  const sel = b.id === FL.sel, q = FL.mode === 'all' ? FL.q : '', v = viewWin(), shown = v && v.view === b.id;
  const lines = b.out.map((l, i) => `<div class="ln${b.err && b.err.includes(i) && sel && FL.errOnly ? ' eo' : ''}">${markQ(tag(l), q) || ' '}</div>`).join('');
  const act = sel ? `<div class="hx-act"><button data-cp="cmd">${SVGI.copy}Команда <kbd>⌘C</kbd></button><button data-cp="out">Вывод <kbd>⇧⌘C</kbd></button>${b.err ? `<button data-cp="err">${SVGI.err}Только ошибка</button>` : ''}<button data-pin="${b.id}" class="${FL.pins.includes(b.id) ? 'on' : ''}">${SVGI.pin}${FL.pins.includes(b.id) ? 'Закреплено' : 'Закрепить'}</button><button class="pri" data-beside="${b.id}">${SVGI.side}${RES[b.res][0]} рядом <kbd>⇧⌘↩</kbd></button></div>` : '';
  return `<div class="hx-b${sel ? ' sel' : ''}${shown ? ' shown' : ''}" data-b="${b.id}"><div class="hx-p"><i class="st ${b.code ? 'bad' : 'ok'}"></i>${bid(b)}<span class="d">~/tako-core</span> <span class="g">❯</span> <span class="cm">${markQ(cxEsc(b.cmd), FL.q)}</span>${b.code ? `<span class="ex">exit ${b.code}</span>` : ''}${shown ? '<span class="side-on">открыто рядом</span>' : ''}</div>${act}<div class="hx-o">${lines}</div></div>`;
}
function histHtml() {
  const h = hits();
  const pins = FL.pins.map(blk).map(b => `<button class="pin" data-go="${b.id}">${SVGI.pin}${bid(b)}<b>${cxEsc(b.cmd)}</b><span>${plain(b.out[b.out.length - 2] || b.out[0])}</span></button>`).join('');
  const find = FL.find ? `<div class="hx-find"><span class="ic">${SVGI.find}</span><input data-hxq placeholder="Команда или текст вывода" value="${cxEsc(FL.q)}" spellcheck="false">
      <span class="seg"><button data-mode="cmd" class="${FL.mode === 'cmd' ? 'on' : ''}">Команды</button><button data-mode="all" class="${FL.mode === 'all' ? 'on' : ''}">Весь текст</button></span>
      <span class="seg"><button data-only="all" class="${FL.only === 'all' ? 'on' : ''}">Все</button><button data-only="err" class="${FL.only === 'err' ? 'on' : ''}">С ошибкой</button></span></div>
    <div class="hx-hits">${h.length ? h.map(b => `<button class="hit${b.id === FL.sel ? ' on' : ''}" data-go="${b.id}"><i class="st ${b.code ? 'bad' : 'ok'}"></i>${bid(b)}<b>${markQ(cxEsc(b.cmd), FL.q)}</b>${b.code ? `<span class="ex">exit ${b.code}</span>` : ''}<small>${RES[b.res][1]}</small></button>`).join('') : `<p class="none">Ни одной команды по «${cxEsc(FL.q)}»</p>`}</div>` : '';
  return `<div class="hx">${pins || !FL.find ? `<div class="hx-top">${pins}<span class="sp"></span>${FL.find ? '' : `<button class="hx-f" data-hxfind>${SVGI.find}Команды <kbd>⌘F</kbd></button>`}</div>` : ''}${find}
    <div class="hx-sb" data-hxsb>${HB.map(blockHtml).join('')}<div class="hx-p last"><span class="d">~/tako-core</span> <span class="g">❯</span> <span class="cur"></span></div></div></div>`;
}

// ---------- the result beside: a real pane of the same session, linked to its block ----------
const RAW = {
  diff: `diff --git a/src/grid/reflow.rs b/src/grid/reflow.rs
@@ -204,11 +204,13 @@ impl Grid {
     fn reflow_wide_char(&mut self, cols: u16) {
-        let spill = self.width_at(cols);
-        if spill > 1 { self.wrap(cols - 1) }
+        // a wide glyph never splits across rows
+        let spill = self.width_at(cols).min(2);
+        if spill == 2 && self.col == cols - 1 {
+            self.wrap(cols - 1);
+        }
         assert_eq!(self.spill(), 2);
     }
diff --git a/src/grid/tests/reflow.rs b/src/grid/tests/reflow.rs
@@ -88,0 +89,6 @@
+#[test]
+fn wide_char_at_last_column_wraps_whole() {
+    let mut g = Grid::new(4, 2);
+    g.print("ab漢");
+    assert_eq!(g.row(1), "漢");
+}`,
  chart: `bench                     main      branch
reflow/wide_char_80x24    412 µs    318 µs
reflow/ascii_80x24        188 µs    186 µs
reflow/mixed_200x60      1.92 ms   1.41 ms`,
  img: '(PNG 1440×900 — takoctl screenshot --pane 2)',
};
RAW.report = HB[3].out.map(plain).join('\n');
function reportView() {
  return `<div class="rp"><div class="rp-sum"><span class="ex big">exit 101</span><b>1 упал</b><span>· 47 прошли · 0 пропущено</span></div>
    <div class="rp-card"><div class="rp-h"><i class="st bad"></i><b>grid::reflow_wide_char</b><code>src/grid/reflow.rs:212:9</code></div>
      <div class="rp-cmp"><span>ожидалось</span><code class="g">2</code><span>получено</span><code class="r">3</code><span class="d">assert_eq!(self.spill(), 2)</span></div>
      <div class="rp-links"><button data-tob="4">→ строки ошибки в выводе #4</button><button data-swap="3">${SVGI.side}правка этого файла · git diff #3</button></div></div>
    <details class="rp-ok"><summary>47 прошли</summary><p>parser::osc133, grid::reflow_ascii, grid::resize_keeps_cursor, … — список целиком в выводе #4</p></details></div>`;
}
function diffView() {
  return RAW.diff.split('\n').map(l => {
    if (l.startsWith('diff --git')) return `<div class="df-f">${SVGI.side}${cxEsc(l.split(' b/')[1])}</div>`;
    if (l.startsWith('@@')) return `<div class="df-h">${cxEsc(l)}</div>`;
    const k = l[0] === '+' ? 'add' : l[0] === '-' ? 'del' : '';
    return `<div class="df-l ${k}"><i>${l[0] === '+' || l[0] === '-' ? l[0] : ''}</i><code>${cxEsc(l.slice(1)) || ' '}</code></div>`;
  }).join('');
}
function chartView() {
  const rows = [['reflow/wide_char_80x24', 412, 318], ['reflow/ascii_80x24', 188, 186], ['reflow/mixed_200x60', 1920, 1410]], f = v => v >= 1000 ? (v / 1000).toFixed(2) + ' ms' : v + ' µs';
  return `<div class="ch"><div class="lg"><span><i class="bm"></i>main</span><span><i class="bb"></i>эта ветка</span><small>меньше — лучше</small></div>
    ${rows.map(([n, a, b]) => `<div class="cr"><code>${n}</code><div class="bars"><div class="bar bm" style="width:${a / 19.2}%"><span>${f(a)}</span></div><div class="bar bb" style="width:${b / 19.2}%"><span>${f(b)}</span></div></div><small class="${b < a * .95 ? 'okc' : ''}">${b < a * .95 ? 'быстрее' : 'как было'}</small></div>`).join('')}</div>`;
}
function imgView() {
  return `<figure class="im"><svg viewBox="0 0 360 225"><rect width="360" height="225" rx="10" fill="#14100E"/><rect x="8" y="8" width="70" height="209" rx="6" fill="#1C1714"/>
    ${[0, 1, 2, 3, 4].map(i => `<rect x="16" y="${22 + i * 22}" width="${40 + (i % 3) * 8}" height="6" rx="3" fill="${i === 1 ? '#FF7A3D' : '#4A3A2E'}"/>`).join('')}
    <rect x="86" y="8" width="266" height="209" rx="6" fill="#1C1714" stroke="#FF7A3D" stroke-width="1.5"/>
    ${[0, 1, 2, 3, 4, 5, 6].map(i => `<rect x="98" y="${26 + i * 16}" width="${[150, 210, 120, 180, 90, 200, 140][i]}" height="5" rx="2" fill="${i === 4 ? '#D54E53' : i === 2 ? '#7BD88F' : '#8A7F76'}"/>`).join('')}
    <rect x="98" y="150" width="116" height="40" rx="4" fill="#3A2A20"/><text x="106" y="174" font-family="monospace" font-size="11" fill="#EDE6DF">ab漢</text><text x="150" y="174" font-family="monospace" font-size="11" fill="#7BD88F">✓ wraps</text></svg>
    <figcaption>снимок своего окна, без записи экрана</figcaption></figure>`;
}
function viewHtml(w) {
  const b = blk(w.view), k = b.res, h = histWin();
  const body = FL.raw ? `<pre class="raw">${cxEsc(RAW[k])}</pre>` : { report: reportView, diff: diffView, chart: chartView, img: imgView }[k]();
  return `<div class="vx"><div class="vx-hd"><span class="kind">${RES[k][0]}</span>${PROP}<span class="src" title="${cxEsc(h ? findWin(h.id)[0].title : '')}">из ${bid(b)} <code>${cxEsc(b.cmd)}</code></span>
      <button data-raw class="${FL.raw ? 'on' : ''}">Текст</button><button data-cpsrc>${SVGI.copy}Исходник</button></div>
    <div class="vx-bd">${body}</div>
    <div class="vx-ft"><kbd>Esc</kbd> закрыть и вернуться к #${b.id} <kbd>⌘C</kbd> исходник${k === 'diff' ? ' <kbd>j k</kbd> по изменениям' : ''} · команда не перезапускается</div></div>`;
}

// ---------- the panes wear it: the history terminal and the result pane ----------
function fill(w, keepInput) {
  const el = els.get(w.id); if (!el) return;
  const bd = el.querySelector('.fw-body'), sb = bd.querySelector('[data-hxsb]'), y = sb ? sb.scrollTop : null;
  const inp = keepInput && bd.querySelector('[data-hxq]'), pos = inp && document.activeElement === inp ? inp.selectionStart : -1;
  bd.classList.add('hx-on');
  bd.innerHTML = w.view ? viewHtml(w) : histHtml();
  const nb = bd.querySelector('[data-hxsb]'); if (nb) nb.scrollTop = y === null ? nb.scrollHeight : y;
  if (pos >= 0) { const n = bd.querySelector('[data-hxq]'); n.focus(); n.setSelectionRange(pos, pos); }
}
const _paintFL = paint;
paint = w => {
  _paintFL(w);
  if (!w.hist && !w.view) return;
  const el = els.get(w.id), bd = el && el.querySelector('.fw-body');
  if (bd && !bd.querySelector('.hx,.vx')) fill(w);
};
const refresh = keep => { const h = histWin(), v = viewWin(); if (h) fill(h, keep); if (v) fill(v); };
function scrollToBlock(id, smooth) {
  const h = histWin(), el = h && els.get(h.id), b = el && el.querySelector(`[data-hxsb] [data-b="${id}"]`); if (!b) return;
  const sb = b.parentElement;
  sb.scrollTo({ top: b.offsetTop - sb.offsetTop - 4, behavior: smooth && !reduce && !document.body.classList.contains('rm') ? 'smooth' : 'auto' });
}
function selectBlock(id, smooth) { FL.sel = id; FL.errOnly = false; refresh(true); scrollToBlock(id, smooth); }
function openFind() {
  FL.find = true; if (FL.sel === null) FL.sel = HB[HB.length - 1].id; refresh();
  const el = els.get(FL.hist), i = el && el.querySelector('[data-hxq]'); if (i) { i.focus(); i.select(); }
  scrollToBlock(FL.sel);
}
function backToInput() {                       // Esc ladder ends here: prompt visible, focus on this terminal
  FL.find = false; FL.sel = null; FL.errOnly = false; refresh();
  if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  focusWin(FL.hist);
}
function openBeside(id) {
  const h = histWin(); if (!h) return;
  const [s] = findWin(h.id), b = blk(id); let v = viewWin();
  FL.sel = id; FL.raw = false; FL.find = false;
  const title = `${RES[b.res][1]} · #${b.id}`;
  if (v) { v.view = id; v.title = title; }
  else {
    v = W(title, h.cwd, 'view', 'idle'); v.view = id; v.src = h.id; FL.view = v.id;
    s.windows.push(v);
    if (h.mode === 'tile') insertNear(s, v.id, h.id, 'h', true, .5); else { v.mode = 'float'; const r = h.rect; v.rect = { x: r.x + r.w + 8, y: r.y, w: Math.max(MINW, r.w), h: r.h }; }
    mount(v, true);
  }
  S.focus = v.id; S.z[v.id] = ++zTop; render(true); refresh();
}
function closeView() {
  const v = viewWin(); if (!v) return;
  FL.view = null; FL.raw = false; closeWin(v.id);
  setTimeout(() => { if (histWin()) { focusWin(FL.hist); refresh(); scrollToBlock(FL.sel); } }, 170);
}
function copyText(t, what) { try { navigator.clipboard.writeText(t); } catch (e) { /* the page may lack clipboard access */ } toast2('', what); }
const blockText = (b, p) => p === 'cmd' ? b.cmd : p === 'err' ? b.err.map(i => plain(b.out[i])).join('\n') : b.out.map(plain).join('\n');
function copyPart(p) {
  const b = blk(FL.sel); if (!b) return; const t = blockText(b, p);
  if (p === 'err') { FL.errOnly = true; refresh(true); }
  copyText(t, p === 'cmd' ? `Скопирована команда #${b.id}` : `Скопировано строк из #${b.id}: ${t.split('\n').length}`);
}

// the scenario's terminal: «mitts test» in session «tako-core tests» keeps its scrollback as blocks
(() => { const s = S.sessions.find(x => x.id === 's2'); if (s) { const w = s.windows[0]; w.hist = true; w.code = 101; FL.hist = w.id; } })();
render();

// ---------- Обзор ⌘⇧O: every pane at a glance; a snapshot, nothing re-renders in the background ----------
const CX = { on: null, ovSel: 0, peek: false };
const ST_WORD = { waiting: 'ждёт тебя', error: 'ошибка', done: 'готово', working: 'работает', live: 'идёт вывод', idle: 'покой', progress: 'работает' };
function ovItems() {
  const all = [];
  for (const s of S.sessions) for (const w of s.windows) {
    if (w.view) continue;
    const remote = /@/.test(w.cwd || ''), ssh = w.kind === 'ssh' && /^(ssh|psql)/.test(w.title), proj = remote ? w.cwd.split('@')[1] : (w.cwd || s.cwd || '~').split('/').slice(0, 2).join('/');
    const where = remote ? 'ssh · ' + proj : ssh ? 'ssh prod-db · из ' + w.cwd : 'локально · ' + (w.cwd || '');
    const st = s.offline ? 'offline' : w.status, attn = st === 'waiting' || st === 'error' || st === 'offline';
    all.push({ s, w, ssh: ssh || remote, remote, proj, where, st, attn });
  }
  const rank = x => ({ waiting: 0, error: 1, offline: 2, done: 3 })[x.st] ?? 4;
  return all.sort((a, b) => rank(a) - rank(b));
}
const miniOf = w => { if (w.hist) return HB[HB.length - 1].out.slice(1).map(tag).join('\n'); const c = CONTENT[w.kind] || ''; return w.ask ? c.split('\n').filter(l => !/\?|❯ 1\.|^\s+\d\./.test(l.replace(/<[^>]+>/g, ''))).join('\n') : c; };
function ovTile(x, i) {
  const { s, w } = x, word = x.st === 'offline' ? 'нет связи' : x.st === 'error' ? `exit ${w.code || 101}` : x.st === 'live' && w.quiet ? 'тихо' : ST_WORD[x.st] || x.st;
  const last = w.hist ? `<div class="ov-ask err">#4 mitts test --workspace · 1 упал</div>` : w.ask && x.st === 'waiting' ? `<div class="ov-ask">${cxEsc(w.ask)}</div>` : '';
  return `<button class="ov-t${i === CX.ovSel ? ' on' : ''} st-${x.st}" data-ov="${i}">
    <div class="ov-h"><span class="ring sm ${x.st === 'offline' ? 'r-ghost' : ringOf(w)}"></span><b>${cxEsc(w.title)}</b><span class="ses">${cxEsc(s.title)}</span></div>
    <div class="ov-mini">${miniOf(w)}</div>${last}
    <div class="ov-f"><span class="where ${x.ssh ? 'ssh' : ''}">${cxEsc(x.where)}</span><span class="w ${x.st}">${word}</span></div></button>`;
}
function viewC() {
  const it = ovItems(); CX._ov = it;
  const att = it.filter(x => x.attn), rest = it.filter(x => !x.attn);
  const groups = {}; rest.forEach(x => { const g = (x.remote ? 'ssh · ' : '') + x.proj; (groups[g] = groups[g] || []).push(x); });
  const sel = it[CX.ovSel];
  return `<div class="cx-ov">
    <div class="ov-top"><b>Обзор</b>${PROP}<span class="d">все терминалы всех сессий · снимок на момент открытия</span><span class="sp"></span><span class="hint"><kbd>←↑↓→</kbd> выбрать <kbd>Пробел</kbd> заглянуть <kbd>⏎</kbd> перейти <kbd>Esc</kbd> назад</span></div>
    ${att.length ? `<div class="ov-g"><h6>Нужно твоё внимание</h6><div class="ov-grid big">${att.map(x => ovTile(x, it.indexOf(x))).join('')}</div></div>` : ''}
    ${Object.entries(groups).map(([g, xs]) => `<div class="ov-g"><h6>${cxEsc(g)}</h6><div class="ov-grid">${xs.map(x => ovTile(x, it.indexOf(x))).join('')}</div></div>`).join('')}
    ${CX.peek && sel ? `<div class="ov-peek"><div class="pk"><div class="ov-h"><span class="ring sm ${ringOf(sel.w)}"></span><b>${cxEsc(sel.w.title)}</b><span class="ses">${cxEsc(sel.s.title)} · ${cxEsc(sel.where)}</span><span class="sp"></span><span class="hint">Пробел — закрыть · ⏎ — перейти сюда</span></div><div class="pk-bd">${miniOf(sel.w)}</div></div></div>` : ''}</div>`;
}

// ---------- research note: why the path looks like this ----------
const NOTE_ROWS = [
  ['ghostty#10078 — «Feature request: CMD+F search/highlight what is on current screen», 2025-12', 'Хотят подсветить найденное прямо на экране, как в iTerm. Единичный запрос (1 голос, 4 ответа).', '⌘F в терминале ищет по командам или по всему тексту и подсвечивает совпадения на месте.', 'Список по командам требует OSC 133 от шелла; без него — обычный поиск по строкам.'],
  ['ghostty#11339 — «context for a tab», 2026-03', 'С агентами держат 3–4 задачи во вкладках и забывают, что где делали.', 'Команды пронумерованы (#N), есть exit-код и закреплённые результаты; в Обзоре видно последнюю команду.', 'Только то, что реально было в терминале, без придуманных «сводок».'],
  ['ghostty#13334 «Ability to restore sessions», 2026-07; kitty#8911; kitty docs/sessions.rst', 'Ждут, что после перезапуска вернутся те же окна и вкладки.', 'Обзор различает живое и восстановленное.', 'Раскладка и scrollback восстанавливаются, процесс — нет (кроме ssh/mosh или tmux).'],
  ['warp#5640 «Full Offline Support», 2024-12, открыт', 'Терминал не должен зависеть от сети и аккаунта.', 'Отчёт, diff, график и снимок строятся локально.', 'Это не проверка нынешнего Warp, а сигнал.'],
  ['Wave — docs.waveterm.dev/widgets', 'Рядом с терминалом — виджеты превью Markdown, картинок, файлов; ⌘W закрывает.', 'Результат рядом — по одному явному вызову и обычной панелью сессии, не постоянной полосой виджетов.', 'Постоянные виджеты тянут место и CPU.'],
  ['Kitty graphics protocol', 'Картинки в самом терминале.', 'Изображение — в панели рядом, а не в scrollback.', 'Картинка в scrollback мешает выделению и копированию.'],
];
const PATH = [['Обзор ⌘⇧O', 'видно, кто ждёт и где упало; ⏎ — ровно в эту панель, фокус туда же'], ['⌘F в терминале', 'команды этого терминала с #N и exit-кодом; «С ошибкой»; ⏎ выбирает'], ['Выбранная команда', 'копировать команду / вывод / только ошибку, закрепить'], ['«… рядом» ⇧⌘↩', 'отчёт, diff, график или снимок — обычной панелью в той же сессии, подпись «из #N»'], ['Esc, Esc', 'закрыть результат → обратно к #N; ещё Esc — к приглашению, фокус в том же терминале']];
function viewNote() {
  return `<div class="cx-note"><h3>Один путь вместо трёх направлений</h3>
    <p class="lead">Приёмы A (команда и результат), B (результат рядом) и C (обзор) сложены в одну последовательность. Всё новое — дизайн-предложение: в нативном Tako этого пока нет. Сигналы — отдельные запросы и документация продуктов, не опрос.</p>
    <dl class="hg">${PATH.map(([a, b]) => `<dt>${a}</dt><dd>${b}</dd>`).join('')}</dl>
    <h4>Правила пути</h4><dl class="hg">
      <dt>Одна идентичность</dt><dd>«#N команда» одинаково в терминале, в поиске, в закрепе, в заголовке панели результата и в Обзоре. Переход по ним никогда не перезапускает команду.</dd>
      <dt>По вызову</dt><dd>Обзор и результат появляются только по явному действию и закрываются Esc; постоянных панелей нет, в простое ничего не рендерится.</dd>
      <dt>Esc — лестница назад</dt><dd>результат → выбранная команда → поиск → приглашение. Фокус всегда возвращается в тот терминал, откуда пришли.</dd>
      <dt>Не вместо, а поверх</dt><dd>Сайдбар, свободные окна, полка, настройки с наследованием и первый запуск не меняются; панель результата — обычная панель сессии, её можно отлепить, свернуть, закрыть ✕.</dd></dl>
    <h4>Источники</h4>
    <table class="nt"><tr><th>Источник</th><th>Наблюдение</th><th>Как учтено</th><th>Компромисс</th></tr>${NOTE_ROWS.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</table>
    <p class="fine">Свободные перекрывающиеся панели — решение Alex и рабочее поле приложения, а не системные окна HIG; из HIG и NN/g взяты принципы: устойчивая геометрия, явный выбранный объект, привычные клавиши, Escape, сложное по мере надобности.</p></div>`;
}

// ---------- overlay shell for Обзор and the note ----------
let cxEl = null;
function cxHtml() {
  return `<div class="cx-bar"><button class="now" data-cxclose>← К терминалам</button><button class="${CX.on === 'C' ? 'on' : ''}" data-cxv="C">Обзор <kbd>⌘⇧O</kbd></button><button class="${CX.on === 'note' ? 'on' : ''}" data-cxv="note">Почему так</button><span class="sp"></span></div>
    <div class="cx-body">${CX.on === 'note' ? viewNote() : viewC()}</div>`;
}
function openCx(v) {
  if (!cxEl) { cxEl = document.createElement('div'); cxEl.className = 'cx'; canvas.appendChild(cxEl); }
  if (v === 'C') { CX.ovSel = 0; CX.peek = false; }
  CX.on = v; cxEl.innerHTML = cxHtml();
  document.querySelectorAll('[data-act^="cx-"]').forEach(b => b.classList.toggle('on', b.dataset.act === 'cx-' + v));
}
function closeCx() { if (cxEl) cxEl.remove(); cxEl = null; CX.on = null; document.querySelectorAll('[data-act^="cx-"]').forEach(b => b.classList.remove('on')); }
function ovGo() { const x = CX._ov[CX.ovSel]; closeCx(); if (x) goTo(x.w.id); }

addEventListener('click', e => {
  const t = e.target, g = s => t.closest(s), act = g('[data-act]');
  if (act && act.dataset.act.startsWith('cx-')) { const v = act.dataset.act.slice(3); return CX.on === v ? closeCx() : openCx(v); }
  if (cxEl && cxEl.contains(t)) {
    if (g('[data-cxclose]')) return closeCx();
    if (g('[data-cxv]')) return openCx(g('[data-cxv]').dataset.cxv);
    const o = g('[data-ov]'); if (o) { const i = +o.dataset.ov; if (CX.ovSel === i) return ovGo(); CX.ovSel = i; cxEl.innerHTML = cxHtml(); }
    return;
  }
  const inHx = g('.hx'), inVx = g('.vx');
  if (!inHx && !inVx) return;
  if (inHx) {
    if (g('[data-hxfind]')) return openFind();
    if (g('[data-mode]')) { FL.mode = g('[data-mode]').dataset.mode; return refresh(); }
    if (g('[data-only]')) { FL.only = g('[data-only]').dataset.only; const h = hits(); if (h.length && !h.find(b => b.id === FL.sel)) FL.sel = h[h.length - 1].id; refresh(); return scrollToBlock(FL.sel); }
    if (g('[data-go]')) return selectBlock(+g('[data-go]').dataset.go, true);
    if (g('[data-cp]')) return copyPart(g('[data-cp]').dataset.cp);
    if (g('[data-pin]')) { const id = +g('[data-pin]').dataset.pin, i = FL.pins.indexOf(id); i < 0 ? FL.pins.push(id) : FL.pins.splice(i, 1); return refresh(); }
    if (g('[data-beside]')) return openBeside(+g('[data-beside]').dataset.beside);
    const b = g('[data-b]'); if (b && !getSelection().toString()) return selectBlock(+b.dataset.b, false);
  } else {
    if (g('[data-raw]')) { FL.raw = !FL.raw; return refresh(); }
    if (g('[data-cpsrc]')) { const v = viewWin(); return copyText(RAW[blk(v.view).res], `Исходник #${v.view} скопирован`); }
    if (g('[data-swap]')) return openBeside(+g('[data-swap]').dataset.swap);
    if (g('[data-tob]')) { const id = +g('[data-tob]').dataset.tob; focusWin(FL.hist); FL.sel = id; FL.errOnly = true; refresh(); return scrollToBlock(id, true); }
  }
});
addEventListener('input', e => {
  if (!e.target.matches('[data-hxq]')) return;
  FL.q = e.target.value; const h = hits(); if (h.length && !h.find(b => b.id === FL.sel)) FL.sel = h[h.length - 1].id;
  refresh(true); scrollToBlock(FL.sel);
});
addEventListener('keydown', e => {
  const k = e.key, stop = () => { e.preventDefault(); e.stopImmediatePropagation(); }, cmd = e.metaKey || e.ctrlKey;
  if (cmd && e.shiftKey && k.toLowerCase() === 'o') { stop(); return CX.on === 'C' ? closeCx() : openCx('C'); }
  if (cxEl) {
    if (CX.on === 'C') {
      const n = (CX._ov || []).length, mv = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 4, ArrowUp: -4 }[k];
      if (mv) { stop(); CX.ovSel = Math.max(0, Math.min(n - 1, CX.ovSel + mv)); cxEl.innerHTML = cxHtml(); return; }
      if (k === ' ') { stop(); CX.peek = !CX.peek; cxEl.innerHTML = cxHtml(); return; }
      if (k === 'Enter') { stop(); return ovGo(); }
    }
    if (k === 'Escape') { stop(); if (CX.peek) { CX.peek = false; cxEl.innerHTML = cxHtml(); return; } return closeCx(); }
    return;
  }
  const f = S.focus && findWin(S.focus)[1]; if (!f) return;
  if (f.view) {
    if (k === 'Escape') { stop(); return closeView(); }
    if (blk(f.view).res === 'diff' && (k === 'j' || k === 'k')) { stop(); const el = els.get(f.id), hs = [...el.querySelectorAll('.df-h')], bd = el.querySelector('.vx-bd'); FL.hk = Math.max(0, Math.min(hs.length - 1, FL.hk + (k === 'j' ? 1 : -1))); if (hs[FL.hk]) bd.scrollTo({ top: hs[FL.hk].offsetTop - bd.offsetTop - 6 }); return; }
    if (cmd && k.toLowerCase() === 'c' && !getSelection().toString()) { stop(); return copyText(RAW[blk(f.view).res], `Исходник #${f.view} скопирован`); }
    return;
  }
  if (!f.hist) return;
  const h = hits(), i = h.findIndex(b => b.id === FL.sel);
  if (cmd && !e.shiftKey && k.toLowerCase() === 'f') { stop(); return openFind(); }
  if (cmd && e.shiftKey && k === 'Enter' && FL.sel) { stop(); return openBeside(FL.sel); }
  if (cmd && k.toLowerCase() === 'c' && FL.sel && !getSelection().toString()) { stop(); return copyPart(e.shiftKey ? 'out' : 'cmd'); }
  if ((k === 'ArrowDown' || k === 'ArrowUp') && (FL.find || FL.sel)) { stop(); if (h.length) selectBlock(h[Math.max(0, Math.min(h.length - 1, (i < 0 ? h.length : i) + (k === 'ArrowDown' ? 1 : -1)))].id, true); return; }
  if (k === 'Enter' && FL.find) { stop(); FL.find = false; refresh(); return scrollToBlock(FL.sel); }
  if (k === 'Escape' && (FL.find || FL.sel)) { stop(); if (FL.find) { FL.find = false; refresh(); return scrollToBlock(FL.sel); } return backToInput(); }
}, true);

// the flow map knows the path too
FLOWS.splice(FLOWS.length - 1, 0, ['Команда → результат (предложение)', [['⌘⇧O Обзор → «mitts test» с exit 101', () => openCx('C')], ['⌘F по командам терминала → #4 → «Отчёт рядом»', () => { goTo(FL.hist); openFind(); }]]]);
