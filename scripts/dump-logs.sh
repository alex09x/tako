#!/usr/bin/env bash
# dump-logs.sh — собирает диагностику TakoCore для анализа
#
# Запусти после того как что-то глюкнуло, скинь вывод Claude:
#   ./scripts/dump-logs.sh | pbcopy          # в буфер
#   ./scripts/dump-logs.sh > /tmp/tako.log   # в файл
#   ./scripts/dump-logs.sh --minutes 10      # расширить окно (по умолч. 5)

set -euo pipefail

MINUTES=${1:-5}
if [[ "${1:-}" == "--minutes" ]]; then
    MINUTES="${2:-5}"
fi

sep() { printf '\n%s\n' "═══ $* ═══"; }

# ── Контекст ────────────────────────────────────────────────────────────────
sep "CONTEXT"
echo "date     : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "host     : $(hostname)"
echo "os       : $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "arch     : $(uname -m)"
echo "git      : $(git -C "$(dirname "$0")/.." log -1 --format='%h %s' 2>/dev/null || echo 'unknown')"
echo "branch   : $(git -C "$(dirname "$0")/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
echo "window   : last ${MINUTES}m"

# ── Session log file (всегда пишется, каждый запуск свой файл) ───────────────
sep "SESSION LOG"
LOG_DIR="$HOME/Library/Logs/TakoCore"
latest_session=$(ls -t "$LOG_DIR"/session-*.log 2>/dev/null | head -1)
if [[ -z "$latest_session" ]]; then
    echo "(нет файлов сессии — приложение ещё не запускалось)"
else
    echo "file: $latest_session"
    echo "size: $(wc -l < "$latest_session") lines"
    echo ""
    # Последние N минут из файла (по временной метке HH:MM:SS)
    cutoff=$(date -v -"${MINUTES}"M '+%H:%M:%S' 2>/dev/null \
          || date -d "${MINUTES} minutes ago" '+%H:%M:%S' 2>/dev/null \
          || echo "00:00:00")
    awk -v cut="$cutoff" '$1 >= cut' "$latest_session" | tail -500
fi

# ── Список всех сессий ────────────────────────────────────────────────────────
sep "ALL SESSIONS"
ls -lht "$LOG_DIR"/session-*.log 2>/dev/null | head -10 || echo "(нет)"

# ── OSLog — ошибки процесса (AppKit / Metal / CoreText) ───────────────────────
sep "PROCESS ERRORS (last ${MINUTES}m)"
log show \
    --predicate 'process == "TakoCore" AND messageType == "error"' \
    --last "${MINUTES}m" \
    --style compact \
    2>/dev/null \
    | grep -v "^Timestamp\|^---\|^$" \
    | tail -200 \
    || true

# ── Краш-репорты (последние 3) ───────────────────────────────────────────────
sep "CRASH REPORTS"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
crashes=$(ls -t "$CRASH_DIR"/*.ips 2>/dev/null \
    | grep -iE "tako|tako" \
    | head -3)

if [[ -z "$crashes" ]]; then
    echo "(no recent crash reports)"
else
    for ips in $crashes; do
        echo ""
        echo "── $(basename "$ips") ──"
        python3 - "$ips" <<'PY'
import json, sys
lines = open(sys.argv[1]).readlines()
try:
    data = json.loads(''.join(lines[1:]))
except Exception as e:
    print(f"  (parse error: {e})")
    sys.exit(0)
exc  = data.get('exception', {})
term = data.get('termination', {})
print(f"  signal : {exc.get('signal','?')} ({exc.get('type','?')})")
print(f"  reason : {term.get('indicator','?')}")
images = data.get('usedImages', [])
for t in data.get('threads', []):
    if not t.get('triggered'): continue
    print(f"  thread : {t.get('id')} {t.get('name') or ''}")
    for i, fr in enumerate(t.get('frames', [])[:20]):
        idx = fr.get('imageIndex', 0)
        img = images[idx].get('name','?') if idx < len(images) else '?'
        sym = fr.get('symbol', '?')
        print(f"    {i:2d}: [{img}] {sym}")
    break
PY
    done
fi

# ── Живые процессы ───────────────────────────────────────────────────────────
sep "RUNNING PROCS"
pgrep -la "TakoCore\|TakoPort" 2>/dev/null || echo "(not running)"

# ── Metal / GPU ──────────────────────────────────────────────────────────────
sep "GPU"
system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -E "Chipset Model|Metal|VRAM|Resolution" \
    | sed 's/^[[:space:]]*/  /' \
    || true

# ── Память ──────────────────────────────────────────────────────────────────
sep "MEMORY"
vm_stat | awk '
    /Pages free/      { free=$3 }
    /Pages wired/     { wired=$4 }
    /Pages active/    { active=$3 }
    /Pages inactive/  { inactive=$3 }
    END {
        page=4096
        printf "  free     : %.0f MB\n", free*page/1048576
        printf "  active   : %.0f MB\n", active*page/1048576
        printf "  wired    : %.0f MB\n", wired*page/1048576
        printf "  inactive : %.0f MB\n", inactive*page/1048576
    }
' 2>/dev/null || true
