# Tako Desktop Prototype — эталон для native delivery (2026-11-08)

Зафиксированное опубликованное состояние Claude Design проекта «Nuzen логотип и дизайн»
(853d837e-5098-426a-8080-cbf72cfe3772), файл `Desktop Prototype.html`. После фиксации дизайн меняется только явными
записями поверх: CHANGELOG.md после «2026-11-08 (8)». Этот каталог не правится.

## Состав
- `project/` — полный исходник страницы, скачан с сервера проекта:
  - HTML без инъекции редактора;
  - prototype/*.js и *.css;
  - prototype/icons/*: SF Symbols, agent PNG, qwen-code.svg;
  - CHANGELOG.md и соседние dc-страницы для контекста.
  JS/CSS/HTML побайтно совпадают с исходниками, которые я заливал. В PNG/SVG сервер вписывает C2PA-метаданные, пиксели те же.
- `shots/` — эталонные кадры, без демо-панели (`.demo{display:none}`):
  - чистый localStorage, «идеи» выключены, `prefers-color-scheme: dark`;
  - кадры без отключения анимаций: момент анимации рамок/колец произвольный.
- `tokens-dark.json`, `tokens-light.json` — фактические CSS-токены и размеры из отрисованной страницы (getComputedStyle и getBoundingClientRect).
- `MANIFEST.sha256` — sha256 всех файлов; `manifest.json` — путь, размер, sha256, etag сервера.

## Запуск локально
`cd project && python3 -m http.server 8800` → http://localhost:8800/Desktop%20Prototype.html (шрифты JetBrains Mono, Fira Code, PT Mono, Victor Mono грузятся с Google Fonts).

## Серии
Серия A — CSS viewport 1440×900, deviceScaleFactor 2 → PNG 2880×1800. Окно Tako (#app) — x=20 y=0, 1400×880 CSS px.

| кадр | состояние |
|---|---|
| A01-desktop | основное поле: сайдбар 248, fish (workspace Default → Tako Night), claude · auth (свой Tako Paper), полка «mitts build», тёмная оболочка |
| A02-settings-general | Настройки по центру (820×700), раздел Общее |
| A03-themes-catalog | Терминал: вид, уровень Общие, каталог 10 встроенных тем |
| A04-theme-editor-colors | Дублировать Tako Night → редактор, вкладка Цвета, черновик |
| A05-theme-editor-type | редактор › Шрифт, начертания открыты |
| A06-font-picker | уровень «терминал fish», список шрифтов из inventory 526 |
| A07-size-zoom | размер 13.5 (своё) и масштаб +2 → 15.5 pt, «Сбросить масштаб» |
| A08-keys | Клавиши, список |
| A09-keys-recording | запись: удержаны ⇧⌘ на «Quick Terminal» |
| A10-keys-conflict | ⇧⌘D на «Разделить вправо» → конфликт с «Разделить вниз» |
| A11-activity | Статусы и активность |
| A12-app-theme-light | Интерфейс Tako = Светлое, раздел «Интерфейс Tako» |
| A13-desktop-light-shell | светлая оболочка, тёмные терминалы |
| A14-welcome | мастер: Привет |
| A15-permissions | мастер: Доступы (новый Mac, дополнительные раскрыты) |
| A16-ready | мастер: Готово |
| A17-floating-shelf | fish плавающий (rect 420,200 560×320), иконка нажата, полка |
| A18-context-appearance | правый клик workspace › Оформление ▸ |

Серия B — CSS viewport 1000×640, deviceScaleFactor 2 → PNG 2000×1280 (маленькое окно).

| кадр | состояние |
|---|---|
| B01-small-desktop | основное поле |
| B02-small-settings | Настройки ограничены видимой областью |

## Ключевые размеры (CSS px = pt на 1×)
- Сайдбар: 248 (200–380). Строка сессии: 2 строки. Кольцо статуса: 14, малое 11.
- Терминал: скругление 10, зазор 8, шапка 28 (без линии), кнопки шапки 24×22, r 5. Символ плавающего режима — 16. Тело: Menlo 13 / line-height 1.55, padding 6 12 10.
- Полка: капсула 30.
- Настройки: окно 820×700 (не больше видимой области − 24), r 12. Левая колонка 232. Пункт навигации 32, r 7. Заголовок 17/600. Строка: padding 10 0.
- Страница: padding 16 24 24. Футер ≥ 52. Кнопка 28, r 7. Поле ввода 28, r 7. Сегмент 24.
- Карточка темы: r 10, мини-терминал 72, r 7. Превью: r 10, padding 12 14.
- Шрифт интерфейса: системный (SF Pro) 13/1.4. Моноширинный — только для образцов, ключей и клавиш.
- Цвета статусов (tab-status-color-*): working #f4581c, waiting #ff7a3d, done #7bd88f, error #d54e53, idle #8a7f76.
- Оболочка: тёмная — производная TakoCore, светлая — производная Tako Paper. Полные значения — в tokens-*.json.
