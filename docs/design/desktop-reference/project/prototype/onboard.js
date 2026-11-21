// Tako desktop prototype — «Set up Tako»: first run, agents and skill, macOS access self-check, flow map.
// Native facts (tako-agent-integrations 9785be25): compatible agents report status by themselves over OSC 7501;
// SKILL.md is an optional extra that lets an agent drive Tako via takoctl; macOS access is asked only on a click.
// Proposal vs native 526: 5 steps instead of 7 — Command line moves to «Агенты», Notifications into «Доступы».

const SETUP_KEY = 'tako.prototype.setup.v3';
// [id, name, how it reports status, found on this Mac, Tako-owned legacy hooks present]
const AGENTS = [
  ['claude', 'Claude Code', 'native', true, true],
  ['codex', 'Codex', 'native', true, false],
  ['antigravity', 'Antigravity', 'native', true, false],
  ['qwen', 'Qwen Code', 'native', false, false],
  ['muse', 'Muse Code', 'native', false, false],
  ['gemini', 'Gemini CLI', 'hooks', false, false],
];
// Access cards simulate the native contract: what each public macOS API can actually read.
// [id, icon, title, one useful line, how Tako can know it]
const PERMS = [
  ['notif', 'bell', 'Уведомления', 'Когда работа готова или агент ждёт вас', 'exact'],
  ['folders', 'folder', 'Папки', 'Рабочий стол, Документы и Загрузки', 'check'],
  ['mic', 'mic', 'Микрофон', 'Голосовой ввод в агентах', 'exact'],
  ['fda', 'drive', 'Полный доступ к диску', 'Защищённые файлы, например ~/Library', 'macos'],
  ['net', 'net', 'Локальная сеть', 'ssh и dev-серверы в вашей сети (не интернет)', 'macos'],
];
const EXTRA = [
  ['screen', 'screen', 'Запись экрана', 'Снимать другие окна. Свой takoctl screenshot работает без этого', 'preflight'],
  ['audio', 'sound', 'Запись системного звука', 'macOS спросит, когда инструмент начнёт запись', 'macos'],
  ['auto', 'gear', 'Управление приложениями', 'macOS спросит отдельно для каждого приложения', 'macos'],
];
// the public API behind each card — shown only under «Подробнее»
const API = {
  notif: 'UNUserNotificationCenter.getNotificationSettings: authorizationStatus и настройки баннеров, звука, наклеек',
  folders: 'Проверка — явное чтение каждой папки; само чтение может вызвать вопрос macOS, поэтому только по кнопке',
  mic: 'AVCaptureDevice.authorizationStatus(for: .audio)',
  fda: 'Публичного API для проверки нет. Доступ к одной папке — ещё не полный доступ к диску',
  net: 'Публичного API нет; удачное соединение не доказывает разрешение. Интернет ≠ локальная сеть',
  screen: 'CGPreflightScreenCaptureAccess: да / нет; «нет» не отличает отказ от «ещё не спрашивали»',
  audio: 'Публичного API для проверки нет — macOS спросит при первой записи',
  auto: 'Разрешение даётся на пару «Tako → приложение» при первом обращении скрипта',
  ax: 'AXIsProcessTrusted: да / нет',
};
const ASK = {
  notif: '«Tako» хочет отправлять уведомления. Уведомления могут включать предупреждения, звуки и наклейки на значках.',
  mic: '«Tako» запрашивает доступ к микрофону.',
  desktop: '«Tako» хочет получить доступ к файлам в папке «Рабочий стол».',
  documents: '«Tako» хочет получить доступ к файлам в папке «Документы».',
  downloads: '«Tako» хочет получить доступ к файлам в папке «Загрузки».',
};
const FOLDERS = [['desktop', 'Рабочий стол'], ['documents', 'Документы'], ['downloads', 'Загрузки']];
// what macOS really holds in this demo (never read by the browser — a stand-in for TCC)
const SIM0 = () => ({ notif: 'notDetermined', notifSet: { alert: 'баннеры', sound: true, badge: false }, mic: 'notDetermined', screen: false, ax: false, folders: { desktop: 'notDetermined', documents: 'notDetermined', downloads: 'notDetermined' } });
const SETUP = { done: false, step: 0, cli: null, hotkey: false, skill: {}, extra: false, det: null, sim: null };
try { Object.assign(SETUP, JSON.parse(localStorage.getItem(SETUP_KEY) || '{}')); } catch (e) { /* private window */ }
if (!SETUP.sim) SETUP.sim = SIM0();
const saveSetup = () => { try { localStorage.setItem(SETUP_KEY, JSON.stringify(SETUP)); } catch (e) { /* ignore */ } };
const OB = { el: null, all: false, det: false, added: null };
const found = () => AGENTS.filter(a => a[3]);
const skillPending = () => found().filter(a => a[2] === 'native' && !SETUP.skill[a[0]]);
const plural = (n, a, b, c) => n % 10 === 1 && n % 100 !== 11 ? a : n % 10 >= 2 && n % 10 <= 4 && (n % 100 < 10 || n % 100 >= 20) ? b : c;

// ---------- macOS stand-ins (labelled as such; the prototype does not touch real permissions) ----------
function sysAlert(text, yes, no, cb) {
  document.querySelectorAll('.sysalert').forEach(x => x.remove());
  const d = document.createElement('div'); d.className = 'sysalert';
  d.innerHTML = `${takoIcon('lg')}<b>${text}</b><div class="bt"><button data-n="1" class="def">${yes}</button><button data-n="0">${no}</button></div><small class="cap">запрос macOS · в макете</small>`;
  d.onclick = e => { const b = e.target.closest('[data-n]'); if (!b) return; d.remove(); cb(b.dataset.n === '1'); };
  document.body.appendChild(d);
}
function sysPane(title, icon, body, cb) {
  document.querySelectorAll('.sysset').forEach(x => x.remove());
  const w = document.createElement('div'); w.className = 'sysset';
  w.innerHTML = `<div class="tb"><i></i><i></i><i></i><span>${sfTile(icon, 'xs')}${title}</span></div>${body}
    <div class="ln">${takoIcon('sm')}Tako<button class="tg" data-ax></button></div><div class="ft"><small class="cap">Системные настройки · в макете</small><button data-x>Вернуться в Tako</button></div>`;
  w.onclick = e => { const t = e.target; if (t.closest('[data-ax]')) { t.classList.add('on'); setTimeout(() => { w.remove(); cb && cb(true); }, 450); } else if (t.closest('[data-x]')) { w.remove(); cb && cb(false); } };
  document.body.appendChild(w);
}
function notifBanner(title, text) {
  const b = document.createElement('div'); b.className = 'sysban';
  b.innerHTML = `${takoIcon('md')}<div class="tx"><b>${title}</b><span>${text}</span></div>`;
  document.body.appendChild(b); setTimeout(() => b.remove(), 3200);
}

// ---------- access self-check: read what the public APIs report, on open and on return from System Settings ----------
const READ = { at: null, notif: null, mic: null, screen: null, ax: null, folders: {} };
function readStatuses(why) {            // only readable, prompt-free APIs; folders are read only by the explicit «Проверить»
  const m = SETUP.sim;
  Object.assign(READ, { notif: m.notif, notifSet: m.notifSet, mic: m.mic, screen: m.screen, ax: m.ax, at: why });
}
const allPerms = () => PERMS.concat(EXTRA);
const det = id => SETUP.det === id;
const btn = (cls, attr, label) => `<button class="${cls}" ${attr}>${label}</button>`;
function cardState(p) {                   // → [status label, class, action]
  const id = p[0], open = btn('pb sm alt', `data-pane="${id}"`, 'Открыть настройки'), tune = btn('lnk', `data-pane="${id}"`, 'Настроить');
  if (id === 'notif' || id === 'mic') {
    const v = READ[id];
    if (v === 'authorized') return ['Доступ выдан', 'ok', id === 'notif' ? btn('lnk', 'data-test', 'Тест') + tune : tune];
    if (v === 'denied') return ['Выключено в macOS', 'off', open];
    return ['', '', btn('pb sm', `data-perm="${id}"`, id === 'notif' ? 'Включить' : 'Разрешить')];
  }
  if (id === 'screen') return READ.screen ? ['Доступ выдан', 'ok', tune] : ['Нет доступа или ещё не спрашивали', 'mute', btn('pb sm alt', 'data-perm="screen"', 'Запросить')];
  if (id === 'folders') {
    const f = READ.folders, done = FOLDERS.filter(([k]) => f[k] !== undefined);
    if (!done.length) return ['Не проверено', 'mute', btn('pb sm alt', 'data-perm="folders"', 'Проверить')];
    const no = FOLDERS.filter(([k]) => f[k] === 'denied');
    return no.length ? [`Нет доступа: ${no.map(x => x[1]).join(', ')}`, 'off', open] : ['Доступ выдан', 'ok', btn('lnk', 'data-perm="folders"', 'Проверить снова')];
  }
  return ['Проверяется в macOS', 'mute', btn('lnk', `data-pane="${id}"`, 'Открыть настройки')];
}
function permCard(p) {
  const [lbl, cls, act] = cardState(p), id = p[0];
  let line = p[3];
  if (id === 'notif' && READ.notif === 'authorized') { const n = READ.notifSet; line = `${n.alert} · ${n.sound ? 'со звуком' : 'без звука'} · ${n.badge ? 'с наклейкой' : 'без наклейки'}`; }
  if (id === 'folders' && FOLDERS.some(([k]) => READ.folders[k] !== undefined)) line = FOLDERS.map(([k, n]) => `${n} ${READ.folders[k] === 'authorized' ? '✓' : READ.folders[k] === 'denied' ? '—' : '·'}`).join('  ');
  return `<div class="pc">${sfTile(p[1])}<div class="pt"><b>${p[2]}</b><span>${line}</span>${det(id) ? `<span class="api">${API[id]}</span>` : ''}</div>
    <div class="pa">${lbl ? `<small class="${cls}">${lbl}</small>` : ''}${act}<button class="lnk q" data-pdet="${id}" title="Подробнее">${det(id) ? '×' : '?'}</button></div></div>`;
}
const permsView = open => `<p class="readat">${READ.at || 'статусы прочитаны при открытии'} · права Tako не равны правам других процессов и удалённых хостов</p>
  <div class="pcs">${PERMS.map(permCard).join('')}</div>
  <button class="grp-t ${open ? 'open' : ''}" data-extra><span>▸</span>Дополнительные доступы<small>запись экрана, системный звук, управление приложениями</small></button>
  ${open ? `<div class="pcs">${EXTRA.map(permCard).join('')}</div>` : ''}`;
function setSim(fn, after) { fn(SETUP.sim); saveSetup(); after(); }
function checkFolders(after, i = 0) {       // explicit: each protected folder may raise its own macOS prompt
  if (i >= FOLDERS.length) { saveSetup(); return after(); }
  const [k] = FOLDERS[i], cur = SETUP.sim.folders[k];
  const next = v => { SETUP.sim.folders[k] = v; READ.folders[k] = v; checkFolders(after, i + 1); };
  if (cur === 'notDetermined') return sysAlert(ASK[k], 'Разрешить', 'Не разрешать', ok => next(ok ? 'authorized' : 'denied'));
  next(cur);
}
function runPerm(id, after) {
  const back = () => { readStatuses('обновлено после ответа macOS'); after(); };
  if (id === 'notif' || id === 'mic') return sysAlert(ASK[id], 'Разрешить', 'Не разрешать', ok => setSim(m => { m[id] = ok ? 'authorized' : 'denied'; }, back));
  if (id === 'folders') return checkFolders(() => { READ.at = 'папки проверены по кнопке'; after(); });
  if (id === 'screen') return openPane('screen', after);   // CGRequestScreenCaptureAccess opens System Settings
}
const PANE_TXT = { fda: 'Перетащите Tako в список или включите его. Перезапуск — только если macOS попросит.', net: 'Tako появится здесь после первого обращения к устройству в локальной сети.', audio: 'Tako появится в списке, когда инструмент начнёт запись.', auto: 'Здесь появятся пары «Tako → приложение», когда скрипт впервые обратится к нему.' };
function openPane(id, after) {
  const p = allPerms().find(x => x[0] === id) || ['ax', 'access', 'Универсальный доступ'];
  const body = `<p>${PANE_TXT[id] || 'Включите Tako. Когда вернётесь, Tako перечитает состояние.'}</p>${id === 'fda' ? `<div class="drag" draggable="true">${takoIcon('md')}<span>Tako.app<small>перетащите в список</small></span></div>` : ''}`;
  sysPane(p[2], p[1], body, on => {
    if (on && id === 'notif') SETUP.sim.notif = 'authorized';
    if (on && id === 'mic') SETUP.sim.mic = 'authorized';
    if (on && id === 'screen') SETUP.sim.screen = true;
    if (on && id === 'ax') SETUP.sim.ax = true;
    if (on && id === 'folders') FOLDERS.forEach(([k]) => { if (SETUP.sim.folders[k] === 'denied') SETUP.sim.folders[k] = 'authorized'; });
    saveSetup(); readStatuses('обновлено после Системных настроек');   // macOS-only cards stay «Проверяется в macOS»
    (after || rerender)();
  });
}
function sendTest(after) {
  setTimeout(() => { notifBanner('Tako', 'Так будет выглядеть «агент ждёт вас».'); after(); }, 400);
}
function rerender() { if (OB.el && OB.el.isConnected) obRe(); const s = document.querySelector('.pop.setwin'); if (s) redraw(s); }
const PRESETS = [['новый Mac', SIM0], ['часть выдана', () => ({ notif: 'authorized', notifSet: { alert: 'баннеры', sound: true, badge: false }, mic: 'denied', screen: true, ax: false, folders: { desktop: 'authorized', documents: 'authorized', downloads: 'denied' } })]];

// ---------- agents: found first, statuses already work; the skill is one optional action ----------
function agentsView(inSettings) {
  const f = found(), nf = AGENTS.filter(a => !a[3]), pend = skillPending();
  const row = a => `<div class="agr">${agentIcon(a[0])}<b>${a[1]}</b><small class="${a[2] === 'native' ? 'ok' : ''}">${a[2] === 'native' ? '● Статусы встроены' : '● Статусы через хуки'}${SETUP.skill[a[0]] ? ' · навык добавлен' : ''}</small>${inSettings && SETUP.skill[a[0]] ? `<button class="lnk" data-unskill="${a[0]}">убрать навык</button>` : ''}</div>`;
  const plan = f.map(a => `<span class="h">${a[1]}</span>\n` + (a[2] === 'native'
    ? `статус: встроенные статусы терминала (OSC 7501), установка не нужна\n<i>+</i> навык: takoctl skills install ${a[0] === 'antigravity' ? 'gemini' : a[0]} --yes${a[0] === 'codex' ? '  (учитывает CODEX_HOME)' : ''}\n${a[4] ? '<s>−</s> старые хуки статуса Tako — только наши, чужие не трогаем\n' : ''}`
    : 'статус через хуки в ~/.gemini/settings.json\n')).join('\n');
  return `<div class="sec-h">Найдены на этом Mac</div><div class="ag">${f.map(row).join('')}</div>
    ${nf.length ? `<p class="nf">Поддерживаются, но не найдены: ${nf.map(a => `<span>${agentIcon(a[0])}${a[1]}</span>`).join('')}</p>` : ''}
    <div class="skill"><div class="sk-h">${takoIcon('md')}<div><b>Агент может управлять Tako</b><span>Открыть терминал, создать или переключить окно, прочитать вывод — через takoctl.</span></div></div>
      <div class="sk-a">${pend.length ? `<button class="pb" data-skill>Добавить навык ${pend.length === f.length ? 'найденным агентам' : `ещё ${pend.length} ${plural(pend.length, 'агенту', 'агентам', 'агентам')}`}</button>`
        : '<small class="ok">✓ Навык есть у всех найденных агентов</small>'}
        ${OB.added ? `<small class="ok">Добавлено: ${OB.added}</small>` : ''}<button class="lnk" data-det>${OB.det ? 'Скрыть детали' : 'Что меняется'}</button></div>
      ${OB.det ? `<pre class="diff">${plan}</pre>` : ''}
      <div class="cli">${sfTile('term', 'sm')}<span class="cl-t"><b>takoctl в PATH</b><small>${SETUP.cli ? `✓ ${SETUP.cli}/takoctl` : 'Ссылка в папку из PATH, без sudo — чтобы навык и другие терминалы видели takoctl'}</small></span>${SETUP.cli ? '' : '<button class="lnk" data-cli>Добавить</button>'}</div>
      <span class="fine">Необязательно: терминал и статусы работают и без навыка. Агентов не перезапускаем.</span></div>`;
}
function addSkill() { const p = skillPending(); p.forEach(a => { SETUP.skill[a[0]] = true; }); OB.added = p.map(a => a[1]).join(', '); saveSetup(); }

// ---------- the wizard: a calm sheet over the working terminal ----------
const STEPS = ['Привет', 'Тема', 'Агенты', 'Доступы', 'Готово'];
function termPreview() {
  const t = THEMES[activeTheme()], d = mix(t.fg, t.term, .45), claw = '#FF7A3D';
  return `<div class="tprev" style="background:${t.term};color:${t.fg}"><div class="tp-h" style="color:${d}"><i style="border-color:${claw}"></i>claude · tako</div>
    <span><b style="color:${t.cyan}">~/tako</b> <b style="color:${t.magenta}">main</b> <b style="color:${t.green}">❯</b> claude "fix auth tests"</span>
    <span style="color:${d}">● Reading src/auth/jwt.rs</span><span style="color:${d}">● Edit src/auth/jwt.rs <b style="color:${t.green}">+12</b> <b style="color:${t.red}">−3</b></span>
    <span style="color:${claw}">? Allow: mitts test -p auth</span><span>  <b style="color:${claw}">❯ Yes</b>   No</span></div>`;
}
function obBody() {
  const st = SETUP.step;
  if (st === 0) return `<div class="hello"><div class="hl">${takoIcon('xl')}<h2>Tako</h2><p>Терминал, который видит, что делают ваши агенты: кто работает, кто ждёт вас, у кого упало.</p>
    <button class="pb big" data-next>Начать</button></div>${termPreview()}</div>`;
  if (st === 1) {
    if (OB.all) return `<div class="h-row"><h3>Все темы</h3><button class="lnk" data-picks>← Подборка</button></div>${themeFilterBar()}
      <style id="thide">${themeHideCss('.ob .tgrid')}</style><div class="tgrid all">${Object.keys(THEMES).map(k => themeCard(k, !CFG.auto && CFG.theme === k)).join('')}</div>`;
    return `<div class="h-row"><h3>Тема</h3><label class="sys-t">Как в системе <button class="tg ${CFG.auto ? 'on' : ''}" data-auto></button></label></div>
      <div class="tgrid">${PICKS.map(k => themeCard(k, !CFG.auto && CFG.theme === k)).join('')}</div>
      <button class="lnk more" data-all>Все темы · ${Object.keys(THEMES).length} →</button>`;
  }
  if (st === 2) return `<h3>Агенты</h3>${agentsView(false)}`;
  if (st === 3) return `<h3>Доступы macOS</h3><p class="lead">Выберите доступ, который нужен для вашей работы.</p>${permsView(SETUP.extra)}`;
  // Ready: only facts Tako can state; optional access that was not granted is not an error
  const sk = found().filter(a => SETUP.skill[a[0]]).map(a => a[1]);
  const got = [READ.notif === 'authorized' && 'уведомления', READ.mic === 'authorized' && 'микрофон', READ.screen && 'запись экрана', FOLDERS.every(([k]) => READ.folders[k] === 'authorized') && 'папки'].filter(Boolean);
  const facts = [`Тема ${THEMES[activeTheme()].name}`, sk.length ? `навык у ${sk.join(', ')}` : 'навык не добавлен — можно позже', got.length ? `выдано: ${got.join(', ')}` : ''].filter(Boolean);
  return `<div class="ready"><span class="rk"><svg viewBox="0 0 24 24"><path d="M6 12.5l4 4 8-9"/></svg></span><h2>Tako готов</h2>
      <p>${facts.join(' · ')}.</p><p class="later">Остальные доступы — по мере надобности, в Настройки › Доступы.</p>
      <button class="pb big" data-next>Начать работу</button></div>`;
}
function obHtml() {
  const st = SETUP.step, edge = st === 0 || st === STEPS.length - 1;
  return `${st ? `<div class="ob-top">${STEPS.map((s, i) => `<span class="${i === st ? 'on' : i < st ? 'past' : ''}" data-go="${i}">${s}</span>`).join('')}</div>` : ''}
    <div class="ob-body">${obBody()}</div>
    <div class="ob-ft"><button class="lnk" data-later>${st === STEPS.length - 1 ? 'Закрыть' : 'Закончить позже'}</button><span class="sp"></span>
      ${st ? '<button class="lnk" data-back>Назад</button>' : ''}${edge ? '' : '<button class="pb" data-next>Дальше</button>'}</div>`;
}
function obRe() { const b = OB.el.querySelector('.ob-body'), y = b ? b.scrollTop : 0; OB.el.innerHTML = obHtml(); OB.el.querySelector('.ob-body').scrollTop = y; }
function openOnboarding() {
  OB.all = false; OB.det = false; OB.added = null; if (SETUP.step >= STEPS.length - 1) SETUP.step = 0;
  if (!cur() || !cur().windows.length) newWindow();
  const app = $('#app').getBoundingClientRect();
  const el = OB.el = openPop('ob', obHtml(), p => { p.style.left = Math.round(app.left + (app.width - 680) / 2 + 124) + 'px'; p.style.top = Math.round(app.top + 4) + 'px'; }, true);
  scrimEl.onclick = null; scrimEl.classList.add('sheet');
  SETUP.done = true; saveSetup();                                   // like native hasPresented: shown once, reopened by hand
  const finish = () => { closePop(); OB.el = null; document.querySelectorAll('.sysalert,.sysset').forEach(x => x.remove()); };
  el.addEventListener('input', e => { if (!e.target.matches('[data-tq]')) return; TQ.q = e.target.value; const s = el.querySelector('#thide'); if (s) s.textContent = themeHideCss('.ob .tgrid'); });
  el.addEventListener('click', e => {
    const t = e.target, lk = t.closest('[data-look]'), pm = t.closest('[data-perm]'), pa = t.closest('[data-pane]'), go = t.closest('[data-go]'), tf = t.closest('[data-tf]');
    if (lk) { CFG.auto = false; CFG.theme = lk.dataset.look; saveAppearance(); applyCfg(); return obRe(); }
    if (t.closest('[data-auto]')) { CFG.auto = !CFG.auto; saveAppearance(); applyCfg(); return obRe(); }
    if (t.closest('[data-all]')) { OB.all = true; return obRe(); }
    if (t.closest('[data-picks]')) { OB.all = false; return obRe(); }
    if (tf) { TQ.f = tf.dataset.tf; return obRe(); }
    if (t.closest('[data-skill]')) { addSkill(); return obRe(); }
    if (t.closest('[data-det]')) { OB.det = !OB.det; return obRe(); }
    if (t.closest('[data-extra]')) { SETUP.extra = !SETUP.extra; saveSetup(); return obRe(); }
    if (t.closest('[data-pdet]')) { const d = t.closest('[data-pdet]').dataset.pdet; SETUP.det = SETUP.det === d ? null : d; return obRe(); }
    if (pm) return runPerm(pm.dataset.perm, obRe);
    if (pa) return openPane(pa.dataset.pane, obRe);
    if (t.closest('[data-test]')) return sendTest(obRe);
    if (t.closest('[data-cli]')) { SETUP.cli = '/opt/homebrew/bin'; saveSetup(); return obRe(); }
    if (t.closest('[data-later]')) return finish();
    if (go) { SETUP.step = +go.dataset.go; OB.all = false; if (SETUP.step === 3) readStatuses('статусы прочитаны при открытии'); saveSetup(); return obRe(); }
    if (t.closest('[data-back]')) { SETUP.step--; OB.all = false; saveSetup(); return obRe(); }
    if (t.closest('[data-next]')) {
      if (SETUP.step === STEPS.length - 1) {          // «Начать работу»: close and focus the terminal that already exists — no new shell
        SETUP.step = 0; saveSetup(); finish();
        const f = (S.focus && findWin(S.focus)[1]) || cur().windows.find(w => w.mode !== 'min');
        if (f) focusWin(f.id); return;
      }
      SETUP.step++; OB.all = false; if (SETUP.step === 3) readStatuses('статусы прочитаны при открытии'); saveSetup(); obRe();
    }
  });
  return el;
}

// ---------- Settings: the same agents and access views, plus the way back to the wizard ----------
PAGES.push(['agents', 'Агенты', 'навык'], ['perms', 'Доступы', 'macOS']);
PAGE_BODY.agents = () => agentsView(true) + '<p class="sub">Меню: Tako › Connect AI Agents…</p>';
PAGE_BODY.perms = () => permsView(true)
  + fr('Глобальная клавиша', `<div class="rw"><span>Quick Terminal из любого приложения</span><button class="tg ${SETUP.hotkey ? 'on' : ''}" data-hotkey></button></div>`
    + `<span class="sub">${!SETUP.hotkey ? '⌘⇧` внутри Tako работает и без этого' : READ.ax ? '<b class="ok">Универсальный доступ выдан</b>' : 'Нужен Универсальный доступ (AXIsProcessTrusted: нет) · <a data-pane="ax">Открыть настройки</a>'}</span>`, '<em>новый UX макета</em>');
const _settingsWinHtmlOb = settingsWinHtml;
settingsWinHtml = () => _settingsWinHtmlOb().replace('<span>Tako 0.1.10</span>', '<span>Tako 0.1.10 · <a data-wizard>Мастер настройки…</a></span>');
const _openSettingsOb = openSettings;
openSettings = sc => {
  const el = _openSettingsOb(sc);
  el.addEventListener('click', e => {
    const t = e.target, pm = t.closest('[data-perm]'), pa = t.closest('[data-pane]'), un = t.closest('[data-unskill]'), pd = t.closest('[data-pdet]'), pg = t.closest('[data-pg]');
    const stop = () => e.stopImmediatePropagation();
    if (t.closest('[data-wizard]')) { stop(); return openOnboarding(); }
    if (pm) { stop(); return runPerm(pm.dataset.perm, () => redraw(el)); }
    if (pa) { stop(); return openPane(pa.dataset.pane, () => redraw(el)); }
    if (pg && pg.dataset.pg === 'perms') readStatuses('статусы прочитаны при открытии раздела');   // self-check on open; falls through to the page switch
    if (pd) { stop(); SETUP.det = SETUP.det === pd.dataset.pdet ? null : pd.dataset.pdet; return redraw(el); }
    if (t.closest('[data-test]')) { stop(); return sendTest(() => redraw(el)); }
    if (t.closest('[data-skill]')) addSkill();
    else if (t.closest('[data-det]')) OB.det = !OB.det;
    else if (t.closest('[data-extra]')) SETUP.extra = !SETUP.extra;
    else if (un) { delete SETUP.skill[un.dataset.unskill]; OB.added = null; }
    else if (t.closest('[data-hotkey]')) {
      SETUP.hotkey = !SETUP.hotkey;
      readStatuses('статусы прочитаны'); if (SETUP.hotkey && !READ.ax) { stop(); saveSetup(); redraw(el); return openPane('ax', () => redraw(el)); }
    } else return;
    stop(); saveSetup(); redraw(el);
  }, true);
  return el;
};
settingsPop = () => openSettings();

// ---------- flow map: where everything is opened from ----------
const pageOf = pg => () => { const el = openSettings(); SET.page = pg; redraw(el); };
const FLOWS = [
  ['Первый запуск', [['Мастер поверх первого терминала: Привет → Тема → Агенты → Доступы → Готово', () => { SETUP.step = 0; openOnboarding(); }], ['Вернуться к мастеру: ⌘, › «Мастер настройки…»', () => openSettings()]]],
  ['Темы', [['Настройки › Оформление — 24 темы, поиск и фильтры', () => openSettings()]]],
  ['Шапка сайдбара', [['⌨︎ / ? — все клавиши', () => $('#keyBtn').click()], ['+ — сессия ⌘T, терминал ⌘N, SSH, workspace', () => $('#addBtn').click()]]],
  ['Правый клик', [['workspace → «Оформление…»', () => openSettings({ kind: 'ws', id: cur().ws })], ['терминал → «Оформление…»', () => S.focus && openSettings({ kind: 'w', id: S.focus })]]],
  ['Агенты и доступы', [['Настройки › Агенты — найденные агенты и навык', pageOf('agents')], ['Настройки › Доступы — карточки, дополнительные, глобальная клавиша', pageOf('perms')]]],
  ['Внимание', [['⌥⏎ — к следующему, кто ждёт', () => nextWaiting()], ['⌘K — найти сессию', () => qEl.focus()]]],
];
const NOT_YET = ['Quick Terminal ⌘⇧` — выпадает сверху, без сайдбара', 'Палитра команд ⌘⇧P, поиск ⌘F и по всем терминалам ⌘⇧F', 'takoctl ask и overlay-формы: вопрос агента внутри терминала', 'Secure Input — индикатор, когда вводишь пароль', 'Восстановление сессий после перезапуска', 'Подтверждение вставки и внешних ссылок'];
function openFlows() {
  const el = openPop('flows', `<div class="sw-hd"><h5>Откуда что открывается</h5><button class="sw-x" data-close>✕</button></div><div class="flm">${FLOWS.map(([g, rows], gi) => `<div class="fg"><span>${g}</span>${rows.map(([l], ri) => `<button data-fl="${gi}.${ri}">${l}<em>показать →</em></button>`).join('')}</div>`).join('')}
    <div class="fg todo"><span>Есть в Tako, ещё не в макете</span>${NOT_YET.map(l => `<p>${l}</p>`).join('')}</div></div>`,
    p => { p.style.right = '16px'; p.style.top = '96px'; }, false);
  el.onclick = e => { if (e.target.closest('[data-close]')) return closePop(); const f = e.target.closest('[data-fl]'); if (!f) return; const [g, r] = f.dataset.fl.split('.'); closePop(); setTimeout(FLOWS[g][1][r][1], 30); };
}

document.addEventListener('click', e => {
  const b = e.target.closest('[data-act]'); if (!b) return;
  const a = b.dataset.act;
  if (a === 'firstrun') { SETUP.step = 0; openOnboarding(); }
  else if (a === 'permsim') { const i = (SETUP.simI = ((SETUP.simI || 0) + 1) % PRESETS.length); SETUP.sim = PRESETS[i][1](); readStatuses('статусы прочитаны · макет: ' + PRESETS[i][0]); saveSetup(); rerender(); b.textContent = 'доступы: ' + PRESETS[i][0]; }
  else if (a === 'flows') openFlows();
  else if (a === 'reset') try { localStorage.setItem(SETUP_KEY, JSON.stringify({ done: true })); } catch (err) { /* ignore */ }
}, true);
readStatuses('статусы прочитаны при открытии');
if (!SETUP.done) setTimeout(openOnboarding, 250);
