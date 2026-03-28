
#!/usr/bin/env bash
# install_t2med_tempwatch.sh
#
# T2med Tempwatch Installer
# Version: 1.0.0
#
# Vollständiger Changelog:
# - Installation der benötigten Pakete:
#   inotify-tools, xdotool, x11-utils, yad
# - Entfernt alte systemd --user Service-Reste von t2med-tempwatch
# - Installiert den Watcher als normales Benutzerprogramm unter ~/.local/bin
# - Installiert die Konfigurationsdatei unter ~/.config/t2med-tempwatch/config
# - Unterstützt getrennte Geometrie-Konfiguration für:
#   - Atril-Fenster
#   - T2med-Fenster
# - Geometrie erfolgt über:
#   - EDGE = left/right
#   - WIDTH_FACTOR
#   - OFFSET_FACTOR
#   - HEIGHT_FACTOR
#   - Y_POS
# - Öffnet neue PDFs aus /tmp/T2med-tmp-*/... automatisch in Atril
# - Deduplizierung gegen Mehrfachöffnungen
# - Globales Debouncing gegen Event-Stürme
# - Singleton-Sperre via flock
# - Fokus-Rücksprung zu T2med
# - Optionales automatisches Escape an T2med nach Rücksprung
# - Robuste Atril-Fensterbehandlung:
#   - neues Fenster erkennen via Vorher/Nachher-Differenz
#   - Fallback auf letztes Atril-Fenster
#   - Minimieren -> Positionieren -> Wiederherstellen
#   - zweiter Snap-Versuch
# - Installiert ein Tray-Icon mit yad
# - Tray-Icon:
#   - Linksklick: killall atril
#   - Rechtsklick-Menü:
#     - Atril schließen
#     - Watcher neu starten
#     - Konfiguration öffnen
#     - Tray beenden
# - Legt XFCE-Autostart-Launcher an für:
#   - Watcher
#   - Tray-Icon
# - Startet Watcher und Tray direkt nach der Installation
#
set -euo pipefail

echo "[1/9] Pakete installieren…"
sudo apt update
sudo apt install -y inotify-tools xdotool x11-utils yad

echo "[2/9] Alte systemd --user Reste entfernen…"
systemctl --user disable --now t2med-tempwatch.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/t2med-tempwatch.service"
systemctl --user daemon-reload 2>/dev/null || true

echo "[3/9] Verzeichnisse anlegen…"
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.config/t2med-tempwatch"
mkdir -p "$HOME/.config/autostart"
mkdir -p "$HOME/.cache"

echo "[4/9] Konfigurationsdatei schreiben…"
cat > "$HOME/.config/t2med-tempwatch/config" <<'EOF'
# Öffner
OPENER="atril"

# ===== Atril-Fenster =====
ATRIL_EDGE="right"
ATRIL_WIDTH_FACTOR="0.33"
ATRIL_OFFSET_FACTOR="0.00"
ATRIL_HEIGHT_FACTOR="1.00"
ATRIL_Y_POS="0"

# ===== T2med-Fenster =====
T2MED_EDGE="left"
T2MED_WIDTH_FACTOR="0.66"
T2MED_OFFSET_FACTOR="0.00"
T2MED_HEIGHT_FACTOR="1.00"
T2MED_Y_POS="0"

# Mindestabstand zwischen zwei Öffnungen in Sekunden
MIN_OPEN_INTERVAL="1.5"

# Nach Rücksprung zu T2med automatisch Escape senden
AUTO_ESCAPE_AFTER_OPEN="yes"

# T2med-Temp-Präfix
TMP_PREFIX="T2med-tmp-"
EOF

echo "[5/9] Watcher installieren…"
cat > "$HOME/.local/bin/t2med-tempwatch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$HOME/.config/t2med-tempwatch"
CONFIG_FILE="$CONFIG_DIR/config"
PID_FILE="$HOME/.cache/t2med-tempwatch.pid"
LOG_FILE="$HOME/.cache/t2med-tempwatch.log"
SEEN_FILE="${XDG_RUNTIME_DIR:-/tmp}/t2med-tempwatch.seen"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/t2med-tempwatch.lock"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/t2med-tempwatch.state"

mkdir -p "$CONFIG_DIR" "$HOME/.cache"
touch "$SEEN_FILE"

load_config() {
  OPENER="atril"

  ATRIL_EDGE="right"
  ATRIL_WIDTH_FACTOR="0.33"
  ATRIL_OFFSET_FACTOR="0.00"
  ATRIL_HEIGHT_FACTOR="1.00"
  ATRIL_Y_POS="0"

  T2MED_EDGE="left"
  T2MED_WIDTH_FACTOR="0.66"
  T2MED_OFFSET_FACTOR="0.00"
  T2MED_HEIGHT_FACTOR="1.00"
  T2MED_Y_POS="0"

  MIN_OPEN_INTERVAL="1.5"
  TMP_PREFIX="T2med-tmp-"
  AUTO_ESCAPE_AFTER_OPEN="yes"

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -Fq "t2med-tempwatch run"
}

is_seen() {
  grep -Fxq "$1" "$SEEN_FILE" 2>/dev/null
}

mark_seen() {
  echo "$1" >> "$SEEN_FILE"
}

now_epoch_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

may_open_now() {
  load_config
  local now last min_ms
  now="$(now_epoch_ms)"
  last=0
  [[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
  min_ms=$(python3 - <<PY
print(int(float("$MIN_OPEN_INTERVAL") * 1000))
PY
)
  (( now - last >= min_ms ))
}

mark_open_now() {
  now_epoch_ms > "$STATE_FILE"
}

get_screen_wh() {
  xdpyinfo | awk '/dimensions/{split($2,a,"x"); print a[1],a[2]; exit}'
}

calc_geometry_for() {
  local edge="$1" width_factor="$2" offset_factor="$3" height_factor="$4" y_pos="$5"
  local sw sh ww wh x

  read -r sw sh <<<"$(get_screen_wh)"

  ww=$(python3 - <<PY
sw = $sw
wf = float("$width_factor")
print(max(100, int(sw * wf)))
PY
)

  wh=$(python3 - <<PY
sh = $sh
hf = float("$height_factor")
print(max(100, int(sh * hf)))
PY
)

  x=$(python3 - <<PY
sw = $sw
ww = $ww
off = float("$offset_factor")
edge = "$edge"
offset_px = int(sw * off)
if edge == "left":
    x = offset_px
else:
    x = sw - offset_px - ww
if x < 0:
    x = 0
print(x)
PY
)

  echo "$x $y_pos $ww $wh"
}

wait_until_stable() {
  local f="$1" s1 s2
  s1=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
  sleep 0.20
  s2=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
  [[ "$s1" -ne 0 && "$s1" -eq "$s2" ]]
}

restore_focus() {
  local wid="${1:-}"
  [[ -n "$wid" ]] || return 0
  xdotool windowfocus "$wid" >/dev/null 2>&1 || true
}

send_escape_to_t2med() {
  local wid="${1:-}"
  [[ -n "$wid" ]] || return 0
  [[ "${AUTO_ESCAPE_AFTER_OPEN:-no}" == "yes" ]] || return 0
  sleep 0.08
  xdotool key --window "$wid" --clearmodifiers Escape >/dev/null 2>&1 || true
}

snap_window_geometry() {
  local xid="$1" x="$2" y="$3" w="$4" h="$5"
  xdotool windowmove "$xid" "$x" "$y" >/dev/null 2>&1 || true
  xdotool windowsize "$xid" "$w" "$h" >/dev/null 2>&1 || true
}

snap_atril_window() {
  local xid="$1"
  local x y w h
  read -r x y w h <<<"$(calc_geometry_for "$ATRIL_EDGE" "$ATRIL_WIDTH_FACTOR" "$ATRIL_OFFSET_FACTOR" "$ATRIL_HEIGHT_FACTOR" "$ATRIL_Y_POS")"
  snap_window_geometry "$xid" "$x" "$y" "$w" "$h"
}

snap_t2med_window() {
  local xid="$1"
  local x y w h
  read -r x y w h <<<"$(calc_geometry_for "$T2MED_EDGE" "$T2MED_WIDTH_FACTOR" "$T2MED_OFFSET_FACTOR" "$T2MED_HEIGHT_FACTOR" "$T2MED_Y_POS")"
  snap_window_geometry "$xid" "$x" "$y" "$w" "$h"
}

get_atril_windows() {
  xdotool search --onlyvisible --class atril 2>/dev/null || true
}

get_last_atril_window() {
  get_atril_windows | tail -n 1 || true
}

find_new_window_by_diff() {
  local before_file="$1"
  local after_file="$2"

  python3 - "$before_file" "$after_file" <<'PY'
import sys
before = set()
after = []
with open(sys.argv[1], 'r', encoding='utf-8', errors='ignore') as f:
    before = {line.strip() for line in f if line.strip()}
with open(sys.argv[2], 'r', encoding='utf-8', errors='ignore') as f:
    after = [line.strip() for line in f if line.strip()]
for wid in after:
    if wid not in before:
        print(wid)
        break
PY
}

hide_window_best_effort() {
  local xid="$1"
  xdotool windowminimize "$xid" >/dev/null 2>&1 || true
}

show_window_best_effort() {
  local xid="$1"
  xdotool windowmap "$xid" >/dev/null 2>&1 || true
}

position_atril_robust() {
  local xid="$1"
  hide_window_best_effort "$xid"
  sleep 0.05
  snap_atril_window "$xid"
  sleep 0.10
  show_window_best_effort "$xid"
  sleep 0.08
  snap_atril_window "$xid"
}

open_pdf() {
  local pdf="$1"
  [[ -r "$pdf" ]] || return 0

  if is_seen "$pdf"; then
    echo "[SKIP] bereits gesehen: $pdf" >>"$LOG_FILE"
    return 0
  fi

  if ! may_open_now; then
    echo "[SKIP] global debounce aktiv: $pdf" >>"$LOG_FILE"
    mark_seen "$pdf"
    return 0
  fi

  if ! wait_until_stable "$pdf"; then
    echo "[WARN] Datei nicht stabil: $pdf" >>"$LOG_FILE"
    return 0
  fi

  mark_seen "$pdf"
  mark_open_now

  local active_wid=""
  active_wid="$(xdotool getactivewindow 2>/dev/null || true)"

  local before after newwin fallback
  before="$(mktemp)"
  after="$(mktemp)"

  get_atril_windows > "$before"

  "$OPENER" "$pdf" >/dev/null 2>&1 &

  newwin=""
  for _ in {1..20}; do
    get_atril_windows > "$after"
    newwin="$(find_new_window_by_diff "$before" "$after")"
    [[ -n "$newwin" ]] && break
    sleep 0.10
  done

  if [[ -n "$newwin" ]]; then
    position_atril_robust "$newwin"
  else
    fallback="$(get_last_atril_window)"
    if [[ -n "$fallback" ]]; then
      position_atril_robust "$fallback"
    else
      echo "[WARN] kein Atril-Fenster gefunden: $pdf" >>"$LOG_FILE"
    fi
  fi

  if [[ -n "$active_wid" ]]; then
    snap_t2med_window "$active_wid"
  fi

  rm -f "$before" "$after"

  restore_focus "$active_wid"
  send_escape_to_t2med "$active_wid"
}

run_loop() {
  load_config

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "[INFO] andere Instanz läuft bereits, beende." >>"$LOG_FILE"
    exit 0
  fi

  echo $$ > "$PID_FILE"
  trap 'rm -f "$PID_FILE"' EXIT

  echo "[INFO] gestartet PID=$$" >>"$LOG_FILE"

  inotifywait -m -r -e close_write --format '%w%f' /tmp 2>/dev/null | while read -r path; do
    [[ "$path" == /tmp/${TMP_PREFIX}* ]] || continue
    [[ "$path" == *.pdf ]] || continue
    echo "[EVENT] $path" >>"$LOG_FILE"
    open_pdf "$path"
  done
}

cmd_start() {
  if is_running; then
    echo "t2med-tempwatch läuft bereits (PID $(cat "$PID_FILE"))."
    exit 0
  fi
  nohup "$0" run >>"$LOG_FILE" 2>&1 &
  disown || true
  sleep 0.5
  if is_running; then
    echo "t2med-tempwatch gestartet (PID $(cat "$PID_FILE"))."
  else
    echo "t2med-tempwatch konnte nicht gestartet werden."
    exit 1
  fi
}

cmd_stop() {
  if ! is_running; then
    echo "t2med-tempwatch läuft nicht."
    rm -f "$PID_FILE"
    exit 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null || true
  sleep 0.5
  if ps -p "$pid" >/dev/null 2>&1; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  rm -f "$LOCK_FILE"
  echo "t2med-tempwatch gestoppt."
}

cmd_status() {
  load_config
  if is_running; then
    echo "t2med-tempwatch läuft (PID $(cat "$PID_FILE"))."
  else
    echo "t2med-tempwatch läuft nicht."
  fi
  echo
  echo "Konfiguration:"
  echo "  OPENER=$OPENER"
  echo "  ATRIL_EDGE=$ATRIL_EDGE"
  echo "  ATRIL_WIDTH_FACTOR=$ATRIL_WIDTH_FACTOR"
  echo "  ATRIL_OFFSET_FACTOR=$ATRIL_OFFSET_FACTOR"
  echo "  T2MED_EDGE=$T2MED_EDGE"
  echo "  T2MED_WIDTH_FACTOR=$T2MED_WIDTH_FACTOR"
  echo "  T2MED_OFFSET_FACTOR=$T2MED_OFFSET_FACTOR"
  echo "  MIN_OPEN_INTERVAL=$MIN_OPEN_INTERVAL"
  echo "  AUTO_ESCAPE_AFTER_OPEN=$AUTO_ESCAPE_AFTER_OPEN"
}

cmd_edit_config() {
  "${EDITOR:-mousepad}" "$CONFIG_FILE" &
}

case "${1:-start}" in
  run)      run_loop ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_stop || true; cmd_start ;;
  status)   cmd_status ;;
  edit-config) cmd_edit_config ;;
  *)
    echo "Verwendung: $0 {start|stop|restart|status|run|edit-config}"
    exit 1
    ;;
esac
EOF

chmod +x "$HOME/.local/bin/t2med-tempwatch"

echo "[6/9] Tray-Helferskripte installieren…"
cat > "$HOME/.local/bin/t2med-atril-kill" <<'EOF'
#!/usr/bin/env bash
killall atril 2>/dev/null || true
EOF

cat > "$HOME/.local/bin/t2med-atril-tray-quit" <<'EOF'
#!/usr/bin/env bash
pkill -f "$HOME/.local/bin/t2med-atril-tray" 2>/dev/null || true
EOF

cat > "$HOME/.local/bin/t2med-atril-tray" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WATCHER="$HOME/.local/bin/t2med-tempwatch"
KILLER="$HOME/.local/bin/t2med-atril-kill"
QUITTER="$HOME/.local/bin/t2med-atril-tray-quit"

exec yad --notification \
  --image="application-pdf" \
  --text="T2med / Atril" \
  --command="$KILLER" \
  --menu="Atril schließen!$KILLER|Watcher neu starten!$WATCHER restart|Konfiguration öffnen!$WATCHER edit-config|Tray beenden!$QUITTER"
EOF

chmod +x \
  "$HOME/.local/bin/t2med-atril-kill" \
  "$HOME/.local/bin/t2med-atril-tray-quit" \
  "$HOME/.local/bin/t2med-atril-tray"

echo "[7/9] XFCE-Autostart-Launcher anlegen…"
cat > "$HOME/.config/autostart/t2med-tempwatch.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=T2med Tempwatch
Comment=Öffnet neue T2med-PDFs automatisch in Atril und positioniert die Fenster
Exec=$HOME/.local/bin/t2med-tempwatch start
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
EOF

cat > "$HOME/.config/autostart/t2med-atril-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=T2med Atril Tray
Comment=Tray-Symbol für Atril/T2med
Exec=$HOME/.local/bin/t2med-atril-tray
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
OnlyShowIn=XFCE;
EOF

echo "[8/9] Alte Prozesse beenden…"
pkill -f "$HOME/.local/bin/t2med-atril-tray" 2>/dev/null || true
pkill -f "$HOME/.local/bin/t2med-tempwatch run" 2>/dev/null || true
rm -f "${XDG_RUNTIME_DIR:-/tmp}/t2med-tempwatch.seen"
rm -f "${XDG_RUNTIME_DIR:-/tmp}/t2med-tempwatch.lock"
rm -f "${XDG_RUNTIME_DIR:-/tmp}/t2med-tempwatch.state"

echo "[9/9] Watcher und Tray starten…"
nohup "$HOME/.local/bin/t2med-tempwatch" run >>"$HOME/.cache/t2med-tempwatch.log" 2>&1 &
nohup "$HOME/.local/bin/t2med-atril-tray" >/dev/null 2>&1 &

echo
echo "✅ Installation abgeschlossen."
echo
echo "Wichtige Dateien:"
echo "  Konfiguration:   $HOME/.config/t2med-tempwatch/config"
echo "  Watcher:         $HOME/.local/bin/t2med-tempwatch"
echo "  Tray:            $HOME/.local/bin/t2med-atril-tray"
echo "  Log:             $HOME/.cache/t2med-tempwatch.log"
echo
echo "Nützliche Befehle:"
echo "  $HOME/.local/bin/t2med-tempwatch status"
echo "  $HOME/.local/bin/t2med-tempwatch restart"
echo "  $HOME/.local/bin/t2med-tempwatch edit-config"
echo
echo "Tray:"
echo "  Linksklick: killall atril"
echo "  Rechtsklick: Menü"
