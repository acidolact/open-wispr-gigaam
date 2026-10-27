#!/bin/bash
# Снимает GigaAM-сборку open-wispr с этой машины (LaunchAgents + live-каталог).
# Конфиг ~/.config/open-wispr и кэш моделей Hugging Face не трогает, если нет --purge.
set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

ROOT="${OPENWISPR_ROOT:-$HOME/openwispr-fast}"
UID_NUM="$(id -u)"

bootout() {
  launchctl bootout "gui/$UID_NUM/$1" 2>/dev/null || true
}

echo "==> останавливаю агенты"
bootout local.openwispr.app
bootout local.openwispr.gigaam-server
bootout local.openwispr.whisper-server
pkill -f "OpenWispr.app/Contents/MacOS/open-wispr" 2>/dev/null || true
pkill -f "gigaam_server.py" 2>/dev/null || true

echo "==> удаляю LaunchAgents"
rm -f "$HOME/Library/LaunchAgents/local.openwispr.app.plist"
rm -f "$HOME/Library/LaunchAgents/local.openwispr.gigaam-server.plist"
rm -f "$HOME/Library/LaunchAgents/local.openwispr.whisper-server.plist"
rm -f "$HOME/Library/LaunchAgents/local.openwispr.whisper-server.plist.disabled"

echo "==> удаляю $ROOT"
rm -rf "$ROOT"

if [ "$PURGE" = 1 ]; then
  echo "==> --purge: конфиг и кэш моделей"
  rm -rf "$HOME/.config/open-wispr"
  rm -rf "$HOME/.cache/huggingface/hub/models--istupakov--gigaam-v3-onnx"
fi

echo "снято. Поставить снова: bash scripts/install-gigaam.sh"
