// Tako desktop prototype — theme catalog: 24 presets, terminal-sample cards, search and filters.
// A proposal for the design, not the preset set shipped in native build 526.
Object.assign(THEMES, {
  tokyo:     { name: 'Tokyo Night', tone: 'dark', term: '#1A1B26', bg: '#16161E', fg: '#C0CAF5', red: '#F7768E', green: '#9ECE6A', yellow: '#E0AF68', blue: '#7AA2F7', magenta: '#BB9AF7', cyan: '#7DCFFF' },
  nord:      { name: 'Nord', tone: 'dark', term: '#2E3440', bg: '#272C36', fg: '#D8DEE9', red: '#BF616A', green: '#A3BE8C', yellow: '#EBCB8B', blue: '#81A1C1', magenta: '#B48EAD', cyan: '#88C0D0' },
  dracula:   { name: 'Dracula', tone: 'dark', term: '#282A36', bg: '#21222C', fg: '#F8F8F2', red: '#FF5555', green: '#50FA7B', yellow: '#F1FA8C', blue: '#BD93F9', magenta: '#FF79C6', cyan: '#8BE9FD' },
  frappe:    { name: 'Frappé', tone: 'dark', term: '#303446', bg: '#292C3C', fg: '#C6D0F5', red: '#E78284', green: '#A6D189', yellow: '#E5C890', blue: '#8CAAEE', magenta: '#CA9EE6', cyan: '#81C8BE' },
  rosepine:  { name: 'Rosé Pine', tone: 'dark', term: '#191724', bg: '#13111E', fg: '#E0DEF4', red: '#EB6F92', green: '#9CCFD8', yellow: '#F6C177', blue: '#3E8FB0', magenta: '#C4A7E7', cyan: '#EBBCBA' },
  kanagawa:  { name: 'Kanagawa', tone: 'dark', term: '#1F1F28', bg: '#16161D', fg: '#DCD7BA', red: '#C34043', green: '#76946A', yellow: '#C0A36E', blue: '#7E9CD8', magenta: '#957FB8', cyan: '#6A9589' },
  everdark:  { name: 'Everforest', tone: 'dark', term: '#2D353B', bg: '#272E33', fg: '#D3C6AA', red: '#E67E80', green: '#A7C080', yellow: '#DBBC7F', blue: '#7FBBB3', magenta: '#D699B6', cyan: '#83C092' },
  soldark:   { name: 'Solarized', tone: 'dark', term: '#002B36', bg: '#00212B', fg: '#93A1A1', red: '#DC322F', green: '#859900', yellow: '#B58900', blue: '#268BD2', magenta: '#D33682', cyan: '#2AA198' },
  ayu:       { name: 'Ayu Mirage', tone: 'dark', term: '#1F2430', bg: '#1A1F29', fg: '#CCCAC2', red: '#F28779', green: '#D5FF80', yellow: '#FFD173', blue: '#73D0FF', magenta: '#DFBFFF', cyan: '#95E6CB' },
  monokai:   { name: 'Monokai', tone: 'dark', term: '#2D2A2E', bg: '#221F22', fg: '#FCFCFA', red: '#FF6188', green: '#A9DC76', yellow: '#FFD866', blue: '#78DCE8', magenta: '#AB9DF2', cyan: '#78DCE8' },
  ghdark:    { name: 'GitHub Dark', tone: 'dark', term: '#0D1117', bg: '#010409', fg: '#E6EDF3', red: '#FF7B72', green: '#7EE787', yellow: '#D29922', blue: '#79C0FF', magenta: '#D2A8FF', cyan: '#A5D6FF' },
  hcdark:    { name: 'Контраст', tone: 'dark', term: '#000000', bg: '#0A0A0A', fg: '#FFFFFF', red: '#FF5F5F', green: '#5FFF87', yellow: '#FFFF5F', blue: '#5FAFFF', magenta: '#FF87FF', cyan: '#5FFFFF' },
  sollight:  { name: 'Solarized Light', tone: 'light', term: '#FDF6E3', bg: '#EEE8D5', fg: '#586E75', red: '#DC322F', green: '#859900', yellow: '#B58900', blue: '#268BD2', magenta: '#D33682', cyan: '#2AA198' },
  rosedawn:  { name: 'Rosé Pine Dawn', tone: 'light', term: '#FAF4ED', bg: '#F2E9E1', fg: '#575279', red: '#B4637A', green: '#56949F', yellow: '#EA9D34', blue: '#286983', magenta: '#907AA9', cyan: '#D7827E' },
  everlight: { name: 'Everforest Light', tone: 'light', term: '#FFFBEF', bg: '#F4F0D9', fg: '#5C6A72', red: '#F85552', green: '#8DA101', yellow: '#DFA000', blue: '#3A94C5', magenta: '#DF69BA', cyan: '#35A77C' },
  gruvlight: { name: 'Gruvbox Light', tone: 'light', term: '#FBF1C7', bg: '#F2E5BC', fg: '#3C3836', red: '#CC241D', green: '#98971A', yellow: '#D79921', blue: '#458588', magenta: '#B16286', cyan: '#689D6A' },
  ghlight:   { name: 'GitHub Light', tone: 'light', term: '#FFFFFF', bg: '#F6F8FA', fg: '#1F2328', red: '#CF222E', green: '#116329', yellow: '#9A6700', blue: '#0969DA', magenta: '#8250DF', cyan: '#1B7C83' },
  hclight:   { name: 'Контраст светлая', tone: 'light', term: '#FFFFFF', bg: '#F0F0F0', fg: '#000000', red: '#C00000', green: '#006B00', yellow: '#7A5A00', blue: '#0040C0', magenta: '#8A00A8', cyan: '#006A7A' },
});
const MOOD = { mocha: 'soft', latte: 'soft', nord: 'soft', frappe: 'soft', rosepine: 'soft', kanagawa: 'soft', everdark: 'soft', soldark: 'soft', sollight: 'soft', rosedawn: 'soft', everlight: 'soft',
  dracula: 'contrast', monokai: 'contrast', ghdark: 'contrast', hcdark: 'contrast', ghlight: 'contrast', hclight: 'contrast' };
Object.keys(THEMES).forEach(k => { if (!PRESET_TYPE[k]) PRESET_TYPE[k] = ['jb', '12.5']; });   // a preset is still the whole look
const PICKS = ['ember', 'midnight', 'tokyo', 'nord', 'gruvbox', 'mocha', 'paper', 'ghlight'];
const TQ = { q: '', f: 'all' };
const TFILTERS = [['all', 'Все'], ['dark', 'Тёмные'], ['light', 'Светлые'], ['soft', 'Мягкие'], ['contrast', 'Контрастные']];
const themeMatch = k => { const t = THEMES[k]; return (!TQ.q || t.name.toLowerCase().includes(TQ.q.toLowerCase())) && (TQ.f === 'all' || t.tone === TQ.f || MOOD[k] === TQ.f); };

// a card is a tiny real terminal in that theme, plus its palette
function themeSample(k) {
  const t = THEMES[k], d = mix(t.fg, t.term, .45);
  return `<i class="tsam" style="background:${t.term};color:${t.fg}"><span><b style="color:${t.cyan}">~/tako</b> <b style="color:${t.magenta}">main</b> <b style="color:${t.green}">❯</b> mitts test</span>`
    + `<span style="color:${d}">running 48 tests</span><span><b style="color:${t.green}">47 ok</b> · <b style="color:${t.red}">1 failed</b></span>`
    + `<span class="pal">${[t.red, t.green, t.yellow, t.blue, t.magenta, t.cyan].map(c => `<u style="background:${c}"></u>`).join('')}</span></i>`;
}
const themeCard = (k, on) => `<button class="tcard ${on ? 'on' : ''}" data-look="${k}">${themeSample(k)}<span class="tn">${THEMES[k].name}</span></button>`;
const themeFilterBar = () => `<div class="tfil"><input class="tq" data-tq placeholder="Найти тему" value="${esc(TQ.q)}" spellcheck="false">${TFILTERS.map(([v, l]) => `<button class="${TQ.f === v ? 'on' : ''}" data-tf="${v}">${l}</button>`).join('')}</div>`;
const themeHideCss = scope => { const h = Object.keys(THEMES).filter(k => !themeMatch(k)); return h.length ? h.map(k => `${scope} [data-v="${k}"],${scope} [data-look="${k}"]`).join(',') + '{display:none}' : ''; };

// Settings › Оформление: the preset grid gets the same search and filters, filtered in place so typing keeps focus
const _lookPage = PAGE_BODY.look;
PAGE_BODY.look = () => _lookPage().replace(/(<div class="lb">Пресет[\s\S]*?<div class="ct">)/, `$1${themeFilterBar()}<style id="thide">${themeHideCss('.setwin .thg')}</style>`);
const _openSettingsTh = openSettings;
openSettings = sc => {
  const el = _openSettingsTh(sc);
  el.addEventListener('input', e => { if (!e.target.matches('[data-tq]')) return; TQ.q = e.target.value; const s = el.querySelector('#thide'); if (s) s.textContent = themeHideCss('.setwin .thg'); });
  el.addEventListener('click', e => { const f = e.target.closest('[data-tf]'); if (!f) return; e.stopImmediatePropagation(); TQ.f = f.dataset.tf; redraw(el); }, true);
  return el;
};
settingsPop = () => openSettings();
applyCfg();                                  // a saved theme from this catalog is known only now
