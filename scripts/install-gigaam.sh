#!/bin/bash
# Ставит open-wispr с GigaAM v3 на эту машину: демон + sidecar + автозапуск.
#
# Из клона репозитория:
#   bash scripts/install-gigaam.sh
#
# На другой Mac:
#   git clone <этот-репозиторий>
#   cd <каталог> && bash scripts/install-gigaam.sh
#
# Флаги:
#   --rebuild     пересобрать OpenWispr.app (сбросит Accessibility TCC)
#   --no-build    не трогать приложение, только sidecar/агенты/конфиг
#   --sidecar     только GigaAM-сервер
#   --bench       прогнать тестовые WAV и выйти
#   --port N      порт sidecar (по умолчанию 8124)
#   --model NAME  модель onnx-asr (по умолчанию gigaam-v3-e2e-rnnt)
set -euo pipefail

PORT=8124
MODEL="gigaam-v3-e2e-rnnt"
SIDECAR_ONLY=0
BENCH=0
REBUILD=0
NO_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --sidecar) SIDECAR_ONLY=1; shift ;;
    --bench) BENCH=1; shift ;;
    --rebuild) REBUILD=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "неизвестный флаг: $1" >&2
      exit 1
      ;;
  esac
done

ROOT="${OPENWISPR_ROOT:-$HOME/openwispr-fast}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_SRC="$REPO/scripts/gigaam_server.py"
REQ="$REPO/scripts/gigaam-requirements.txt"
GIGA_DIR="$ROOT/gigaam"
VENV="$GIGA_DIR/.venv"
SERVER_DST="$GIGA_DIR/gigaam_server.py"
TESTSET="$ROOT/testset"
UID_NUM="$(id -u)"
APP_PLIST="$HOME/Library/LaunchAgents/local.openwispr.app.plist"
GIGA_PLIST="$HOME/Library/LaunchAgents/local.openwispr.gigaam-server.plist"
WHISPER_PLIST="$HOME/Library/LaunchAgents/local.openwispr.whisper-server.plist"
CONFIG="$HOME/.config/open-wispr/config.json"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_uv() {
  if need_cmd uv; then
    return
  fi
  if need_cmd brew; then
    echo "==> brew install uv"
    brew install uv
  else
    echo "нужен uv (https://docs.astral.sh/uv/) или Homebrew" >&2
    exit 1
  fi
}

install_sidecar() {
  mkdir -p "$GIGA_DIR/logs" "$TESTSET"
  ensure_uv
  echo "==> GigaAM venv $VENV"
  if [ ! -x "$VENV/bin/python" ]; then
    uv venv "$VENV"
  fi
  uv pip install --python "$VENV/bin/python" -r "$REQ"
  cp "$SERVER_SRC" "$SERVER_DST"
  chmod +x "$SERVER_DST"
}

write_giga_plist() {
  cat > "$GIGA_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.openwispr.gigaam-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV/bin/python</string>
        <string>$SERVER_DST</string>
        <string>--port</string>
        <string>$PORT</string>
        <string>--model</string>
        <string>$MODEL</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$GIGA_DIR/logs/gigaam-server.log</string>
    <key>StandardErrorPath</key>
    <string>$GIGA_DIR/logs/gigaam-server.log</string>
</dict>
</plist>
PLIST
}

write_app_plist() {
  cat > "$APP_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.openwispr.app</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ROOT/OpenWispr.app/Contents/MacOS/open-wispr</string>
        <string>start</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$ROOT</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OPEN_WISPR_APP</key>
        <string>$ROOT/OpenWispr.app</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$ROOT/logs/openwispr.log</string>
    <key>StandardErrorPath</key>
    <string>$ROOT/logs/openwispr.log</string>
</dict>
</plist>
PLIST
}

reload_agent() {
  local label="$1"
  local plist="$2"
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$UID_NUM" "$plist"
}

wait_health() {
  echo -n "==> ждём GigaAM на :$PORT"
  local i
  for i in $(seq 1 180); do
    if curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null; then
      echo " — готов"
      curl -s "http://127.0.0.1:$PORT/health"
      echo
      return 0
    fi
    echo -n .
    sleep 1
  done
  echo
  echo "сервер не поднялся, лог: $GIGA_DIR/logs/gigaam-server.log" >&2
  tail -40 "$GIGA_DIR/logs/gigaam-server.log" >&2 || true
  return 1
}

merge_config() {
  mkdir -p "$(dirname "$CONFIG")"
  python3 - "$CONFIG" "$PORT" <<'PY'
import json, sys
path, port = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
cfg.setdefault("hotkey", {"keyCode": 63, "modifiers": []})
cfg.setdefault("hotkeys", [cfg["hotkey"]])
cfg.setdefault("language", "ru")
cfg.setdefault("modelSize", "small")
cfg.setdefault("spokenPunctuation", False)
cfg.setdefault("maxRecordings", 10)
cfg.setdefault(
    "whisperPrompt",
    "Разработка и код: CSSOM, JavaScript, TypeScript, React, git rebase, API, Docker, Swift, Xcode.",
)
cfg["whisperServerURL"] = f"http://127.0.0.1:{port}"
with open(path, "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"config: {path} -> {cfg['whisperServerURL']}")
PY
}

build_app() {
  echo "==> swift build -c release"
  if ! need_cmd swift; then
    echo "нужен Swift / Xcode Command Line Tools: xcode-select --install" >&2
    exit 1
  fi
  (cd "$REPO" && swift build -c release)
  local ver
  ver="$(python3 - "$REPO" <<'PY'
import re, pathlib, sys
text = (pathlib.Path(sys.argv[1]) / "Sources/OpenWisprLib/Version.swift").read_text()
print(re.search(r'version = "([^"]+)"', text).group(1))
PY
)"
  (cd "$REPO" && bash scripts/bundle-app.sh .build/release/open-wispr OpenWispr.app "$ver")
  mkdir -p "$ROOT/logs"
  launchctl bootout "gui/$UID_NUM/local.openwispr.app" 2>/dev/null || true
  rm -rf "$ROOT/OpenWispr.app"
  cp -R "$REPO/OpenWispr.app" "$ROOT/OpenWispr.app"
}

make_wav() {
  local name="$1" text="$2"
  local aiff="$TESTSET/$name.aiff"
  local wav="$TESTSET/$name.wav"
  [ -f "$wav" ] && return
  say -v Milena -o "$aiff" "$text" 2>/dev/null || say -o "$aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
  rm -f "$aiff"
}

if [ ! -f "$SERVER_SRC" ]; then
  echo "запускай из клона репозитория: bash scripts/install-gigaam.sh" >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "только macOS" >&2
  exit 1
fi

install_sidecar

if [ "$BENCH" = 1 ]; then
  echo "==> тестовый корпус"
  make_wav cssom "CSSOM переименуй"
  make_wav explain "Объясни подробнее, что это"
  make_wav last "Последний пункт немного подробнее выдай"
  make_wav tongue "От топота копыт пыль по полю летит"
  make_wav maxi "Мы идем в maxi-step over does"
  echo "==> GigaAM $MODEL"
  "$VENV/bin/python" "$SERVER_DST" --model "$MODEL" --bench "$TESTSET"
  exit 0
fi

write_giga_plist
reload_agent local.openwispr.gigaam-server "$GIGA_PLIST"
wait_health

if [ "$SIDECAR_ONLY" = 1 ]; then
  echo "sidecar готов: http://127.0.0.1:$PORT/inference"
  exit 0
fi

APP_BIN="$ROOT/OpenWispr.app/Contents/MacOS/open-wispr"
if [ "$NO_BUILD" = 1 ]; then
  if [ ! -x "$APP_BIN" ]; then
    echo "нет $APP_BIN — убери --no-build или собери с --rebuild" >&2
    exit 1
  fi
  echo "==> приложение уже на месте, сборку пропускаю"
elif [ "$REBUILD" = 1 ] || [ ! -x "$APP_BIN" ]; then
  build_app
else
  echo "==> $APP_BIN есть; сборку пропускаю (нужна пересборка — --rebuild)"
fi

mkdir -p "$ROOT/logs"
merge_config
write_app_plist

if [ -f "$WHISPER_PLIST" ]; then
  echo "==> отключаю старый whisper-server"
  launchctl bootout "gui/$UID_NUM/local.openwispr.whisper-server" 2>/dev/null || true
  mv "$WHISPER_PLIST" "$WHISPER_PLIST.disabled"
fi

reload_agent local.openwispr.app "$APP_PLIST"
sleep 2
launchctl kickstart -k "gui/$UID_NUM/local.openwispr.app" 2>/dev/null || true
sleep 1

echo
echo "GigaAM sidecar: http://127.0.0.1:$PORT/inference"
echo "демон:          $ROOT/OpenWispr.app"
echo "конфиг:         $CONFIG"
echo
echo "Выдай Микрофон и Универсальный доступ, если macOS спросит:"
echo "  System Settings → Privacy & Security → Accessibility / Microphone"
echo "  приложение: $ROOT/OpenWispr.app"
echo
echo "Снять: bash scripts/uninstall-gigaam.sh"
