// Tako desktop prototype — icons. Access tiles follow macOS System Settings: a coloured rounded square with a real
// SF Symbol glyph (exported via NSImage.imageWithSystemSymbolName, white on transparent, prototype/icons/*.png).
const SYM = { bell: 'bell.fill', folder: 'folder.fill', drive: 'internaldrive.fill', net: 'network', mic: 'mic.fill', screen: 'rectangle.on.rectangle',
  sound: 'speaker.wave.2.fill', gear: 'applescript.fill', access: 'keyboard', term: 'terminal.fill' };
const TILE = { bell: 'linear-gradient(#FF6259,#E8352B)', folder: 'linear-gradient(#4AA8FF,#1C7EEA)', drive: 'linear-gradient(#A1A1A6,#7C7C82)', net: 'linear-gradient(#3B9BFF,#0A6CDF)',
  mic: 'linear-gradient(#FF9F2E,#F57C00)', screen: 'linear-gradient(#B57BF5,#8E4FE0)', sound: 'linear-gradient(#FF5E8A,#E5326A)', gear: 'linear-gradient(#9D9DA3,#6E6E74)',
  access: 'linear-gradient(#3B9BFF,#0A6CDF)', term: 'linear-gradient(#3A332E,#1A1512)' };
const sfTile = (k, size) => `<span class="mtile z-${size || 'n'}" style="background:${TILE[k]}"><img src="prototype/icons/${SYM[k]}.png" alt=""></span>`;
// the Tako.app icon: the pixel crab on ink, same as the brand macOS icon
const takoIcon = size => `<span class="mtile tako z-${size || 'n'}"><svg viewBox="-8 -10 136 112">${$('#empty svg g').innerHTML}</svg></span>`;
// agent images. claude/codex/antigravity/gemini: the Agent*.pdf images Tako ships, rendered through AppKit
// (tako-native-symbols-20261108/native-icons.json). Qwen Code: the product's own logo from github.com/QwenLM/qwen-code
// (packages/desktop/bootstrap/qwen-code-logo.svg @ 82d9ac31). Muse Code: no official mark found — neutral terminal symbol.
const AGENT_IMG = { claude: 'agent-claude.png', codex: 'agent-codex.png', antigravity: 'agent-antigravity.png', gemini: 'agent-gemini.png', qwen: 'qwen-code.svg' };
const agentIcon = id => AGENT_IMG[id] ? `<span class="mtile ag-i pic ${id}"><img src="prototype/icons/${AGENT_IMG[id]}" alt=""></span>`
  : `<span class="mtile ag-i" style="background:${TILE.term}" title="официального знака не нашли — нейтральный символ"><img src="prototype/icons/${SYM.term}.png" alt=""></span>`;
