// Tako desktop prototype — the main path is real Tako (tako-agent-integrations 9785be25, build 526).
// What Tako does not have (SSH form, Overview ⌘⇧O → command blocks → result beside, global-hotkey toggle) is an idea:
// it shows only with «показать идеи» in the demo panel. The mode lives in localStorage; switching reloads the page.
const IDEAS = { on: (() => { try { return localStorage.getItem('tako.prototype.ideas') === '1'; } catch (e) { return false; } })() };
document.body.classList.toggle('ideas', IDEAS.on);

// ---------- spec: the «Сверка с Tako 526» table and a separate «Идеи» list (the page itself stays as published) ----------
{
  const notes = $('#notes'), dl = notes.querySelector('dl');
  const dd = name => [...dl.querySelectorAll('dt')].find(d => d.textContent === name);
  const ag = dd('агенты'); if (ag) ag.nextElementSibling.innerHTML = "«Найдены на этом Mac»: иконка, имя, «CLI найден · статус по OSC 7501, хуки не нужны» — это свойство агента, а не проверка: живой статус появится, только когда агент сам пришлёт OSC 7501; найденный бинарник — не подтверждение. «Навык добавлен» — только после «Добавить навык». Ненайденные поддерживаемые — одной строкой ниже. Блок «Агент может управлять Tako» (открыть терминал, окна, вывод через takoctl) с одним действием «Добавить навык найденным агентам»: без повторного подтверждения, уже добавленным не ставим, после — «Добавлено: …». «Что меняется» раскрывает детали: takoctl skills install, CODEX_HOME, adapter gemini для Antigravity, удаление только наших старых хуков, Gemini CLI на хуках. Изображения Claude Code, Codex, Antigravity и Gemini CLI — те, что Tako уже показывает (Agent*.pdf, выгружены через AppKit); Qwen Code — логотип из репозитория QwenLM/qwen-code; у Muse Code официального знака не нашли — нейтральный символ терминала и название.";
  const ideas = document.createElement('dl');
  for (const [name, as] of [['ssh', 'форма SSH'], ['путь к результату', 'путь к результату'], ['глобальная клавиша', 'переключатель глобальной клавиши']]) {
    const d = dd(name); if (!d) continue;
    const v = d.nextElementSibling;
    if (name === 'глобальная клавиша') {
      const nd = document.createElement('dt'), nv = document.createElement('dd');
      nd.textContent = 'универсальный доступ'; nv.innerHTML = "В Настройки › Доступы — только статус AXIsProcessTrusted и «Открыть настройки». В Tako доступ нужен лишь глобальным сочетаниям: macOS спрашивает, когда Tako включает глобальный перехват клавиш (GlobalEventTap). Первому терминалу и ⌘⇧` внутри Tako не нужен."; d.before(nd, nv);
    }
    d.textContent = as; ideas.append(d, v);
  }
  dl.insertAdjacentHTML('afterend', "<h4>Сверка с Tako 526</h4>\n  <p class=\"rt-n\">Эталон — tako-agent-integrations 9785be25 (сборка 526). Что не подтверждено, в основной путь не входит.</p>\n  <table class=\"rt\"><tr><th>в макете</th><th>реальный механизм</th><th>статус</th></tr>\n    <tr><td>Мастер: Привет → Тема → Агенты → Доступы → Готово</td><td>SetupCoordinator.offerAtLaunch, SetupProgress (7 шагов)</td><td class=\"part\">есть · перегруппировка: Command line → блок навыка, Notifications → карточка Доступов</td></tr>\n    <tr><td>Тема в мастере</td><td>applySetupColorPreset — только цвета, шрифт и layout сохраняются</td><td class=\"part\">есть · каталог из 24 тем — пример, нужен реальный список пресетов</td></tr>\n    <tr><td>Агенты: «CLI найден»</td><td>обнаружение CLI; статус — OSC 7501 от самого агента</td><td class=\"part\">есть · найденный CLI ≠ живой статус</td></tr>\n    <tr><td>«Добавить навык»</td><td>SetupAgentService.connect: takoctl skills install &lt;adapter&gt; --yes --json, чистит только legacy-хуки Tako</td><td class=\"ok\">есть</td></tr>\n    <tr><td>takoctl в PATH</td><td>Install takoctl Command… → CommandLineTool (symlink, без sudo)</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Уведомления · Тест</td><td>requestAuthorization; SetupNotificationTestSender (accepted / delivered)</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Папки · Проверить</td><td>SetupFolderAccess: opendir Desktop / Documents / Downloads по кнопке</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Микрофон</td><td>AVCaptureDevice status + requestAccess без записи</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Запись экрана</td><td>CGPreflight / CGRequestScreenCaptureAccess; takoctl screenshot её не требует</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Полный доступ к диску</td><td>Privacy_AllFiles + перетаскиваемая иконка .app (SetupDiskAccessGuide)</td><td class=\"part\">есть · иконки в макете пока нет</td></tr>\n    <tr><td>Локальная сеть</td><td>по клику best-effort UDP к link-local, потом Настройки; macOS 15 — managedInSettings</td><td class=\"part\">есть · в макете только «Открыть настройки»</td></tr>\n    <tr><td>Системный звук, Управление приложениями</td><td>открывают Privacy_AudioCapture / Privacy_Automation; запрос — при первом использовании</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Перечитать после Системных настроек</td><td>.onReceive(didBecomeActive)</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Универсальный доступ</td><td>AXIsProcessTrusted; запрос при включении GlobalEventTap</td><td class=\"part\">есть · переключатель в Настройках — идея</td></tr>\n    <tr><td>Готово · «Начать работу»</td><td>шаг Ready; закрывает sheet, терминал уже открыт</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Настройки ⌘, по центру</td><td>TerminalSettingsDialog; ⌘, › Setup… возвращает мастер</td><td class=\"part\">есть · центр и высота — улучшение UX</td></tr>\n    <tr><td>Оформление Общие → workspace → терминал</td><td>ScopedAppearanceStore global / workspace / pane, Appearance.json</td><td class=\"ok\">есть</td></tr>\n    <tr><td>Плавающее окно, resize, развернуть, полка</td><td>существующие режимы панелей</td><td class=\"part\">есть · подписанная кнопка — улучшение UX</td></tr>\n    <tr><td>Сайдбар сессий, статусы 1b / 5a</td><td>sidebar 4a; OSC 133 / 7501; quiet-commands</td><td class=\"ok\">есть</td></tr>\n    <tr><td>ssh</td><td>обычная команда ssh в терминале, host key и auth там же</td><td class=\"part\">есть · отдельная форма — идея</td></tr>\n    <tr><td>Обзор ⌘⇧O, ⌘F по командам, результат рядом</td><td>есть Pane Overview, ⌘F / ⌘⇧F, OSC 133 marks</td><td class=\"idea\">идея · нужны binding, извлечение блоков, pane-просмотрщик</td></tr>\n    <tr><td>⌘N делит текущий, ⌘T новая сессия</td><td>?</td><td class=\"ask\">нужна сверка</td></tr>\n    <tr><td>Настройки › Терминалы: притушивание, куда делить, строки сайдбара, ветка и порты</td><td>?</td><td class=\"ask\">нужна сверка</td></tr>\n  </table>" + '<h4>Идеи — в Tako этого нет</h4><p class="rt-n">Видны только с «показать идеи» в демо-панели.</p>');
  notes.append(ideas);
}
// ---------- demo panel: the ideas group ----------
{
  const c = document.querySelector('.dbtn[data-act="cx-C"]'), g = c && c.closest('.grp');
  if (g) {
    g.querySelector('.lbl').textContent = 'идеи · нет в Tako';
    g.querySelectorAll('[data-act^="cx-"]').forEach(b => b.classList.add('idea'));
    g.querySelector('.lbl').insertAdjacentHTML('afterend', `<button class="dbtn" data-act="ideas">${IDEAS.on ? 'скрыть идеи' : 'показать идеи'}</button>`);
  }
}
addEventListener('click', e => {
  if (!e.target.closest('[data-act="ideas"]')) return;
  e.stopImmediatePropagation();
  try { localStorage.setItem('tako.prototype.ideas', IDEAS.on ? '0' : '1'); } catch (err) { /* no storage: the switch cannot persist */ }
  location.reload();
}, true);

if (!IDEAS.on) {
  // «tako-core tests» is an ordinary terminal again: no command blocks, no ⌘F block search, no result pane
  const h = histWin();
  if (h) { h.hist = false; FL.hist = null; const el = els.get(h.id); if (el) { el.remove(); els.delete(h.id); } render(); }
  const _openCxR = openCx, _openFindR = openFind, _openBesideR = openBeside;
  openCx = v => IDEAS.on && _openCxR(v);
  openFind = () => IDEAS.on && _openFindR();
  openBeside = id => IDEAS.on && _openBesideR(id);
  for (let i = FLOWS.length - 1; i >= 0; i--) if (/результат/.test(FLOWS[i][0])) FLOWS.splice(i, 1);
  // «+»: what Tako has; ssh is a command in a terminal
  $('#addBtn').addEventListener('click', e => {
    e.stopImmediatePropagation();
    const r = e.currentTarget.getBoundingClientRect();
    openCtx([
      { label: 'Новая сессия', kbd: '⌘T', run: () => newSession() },
      { label: 'Новый терминал здесь', kbd: '⌘N', run: () => newWindow() },
      '-',
      { label: 'Новый workspace', run: () => newWorkspace() },
    ], r.right - 210, r.bottom + 6);
  }, true);
}

// agents: a found CLI is not a live status; «навык добавлен» only after the explicit action
const _agentsViewR = agentsView;
agentsView = inSettings => _agentsViewR(inSettings)
  .replace(/<small class="ok">● Статусы встроены/g, '<small title="Найден CLI. Живой статус появится, когда агент сам пришлёт OSC 7501 — сейчас это не проверено">CLI найден · статус по OSC 7501, хуки не нужны')
  .replace(/<small class="">● Статусы через хуки/g, '<small>CLI найден · статус через хуки')
  .replace(/ · навык добавлен<\/small>/g, ' · <b class="ok">навык добавлен</b></small>');

// Settings › Доступы: Accessibility is a read-only AXIsProcessTrusted status; the toggle is an idea
const _permsBodyR = PAGE_BODY.perms;
PAGE_BODY.perms = () => IDEAS.on ? _permsBodyR().replace('<em>новый UX макета</em>', '<em>идея: в Tako такого переключателя нет</em>')
  : permsView(true)
    + fr('Универсальный доступ', `<div class="rw"><span>${READ.ax ? '<b class="ok">Доступ выдан</b>' : 'Нет доступа'}</span><a data-pane="ax">Открыть настройки</a></div>`
      + '<span class="sub">Нужен только глобальным сочетаниям клавиш: macOS спросит, когда Tako включает глобальный перехват. Первому терминалу и ⌘⇧` внутри Tako не нужен.</span>', 'AXIsProcessTrusted');

// flow map wording follows the same rule
for (const f of FLOWS) {
  if (f[0] === 'Темы') { f[0] = 'Оформление'; f[1][0][0] = 'Настройки › Оформление — пресеты по цепочке Общие → workspace → терминал'; }
  for (const r of f[1]) r[0] = r[0].replace('+ — сессия ⌘T, терминал ⌘N, SSH, workspace', '+ — сессия ⌘T, терминал ⌘N, workspace; ssh — командой в терминале')
    .replace('карточки, дополнительные, глобальная клавиша', 'карточки, дополнительные, Универсальный доступ');
}
