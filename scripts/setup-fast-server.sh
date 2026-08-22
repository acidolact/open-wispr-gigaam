#!/bin/bash
# Ставит быстрый локальный whisper-server: large-v3-turbo + CoreML-энкодер (Neural Engine).
#
# Зачем не Homebrew: бутылка whisper-cpp собрана без CoreML (COREML = 0), энкодер идёт
# через Metal и стоит ~0.9 с на фразу. CoreML переносит энкодер на ANE — те же фразы
# укладываются в ~0.6 с при том же качестве.
#
# Использование: scripts/setup-fast-server.sh [--port 8123]
set -euo pipefail

PORT=8123
[ "${1:-}" = "--port" ] && PORT="$2"

ROOT="$HOME/openwispr-fast"
BUILD="$ROOT/build/whisper.cpp"
MODELS="$HOME/.config/open-wispr/models"
MODEL="ggml-large-v3-turbo-q8_0.bin"
ENCODER="ggml-large-v3-turbo-encoder.mlmodelc"
WHISPER_TAG="v1.9.2"
PLIST="$HOME/Library/LaunchAgents/local.openwispr.whisper-server.plist"

mkdir -p "$ROOT/logs" "$MODELS" "$(dirname "$BUILD")"

echo "==> whisper.cpp $WHISPER_TAG с CoreML"
if [ ! -d "$BUILD" ]; then
  git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$BUILD"
fi
cmake -S "$BUILD" -B "$BUILD/build-coreml" \
  -DWHISPER_COREML=1 -DWHISPER_COREML_ALLOW_FALLBACK=1 -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD/build-coreml" -j"$(sysctl -n hw.ncpu)" --target whisper-server >/dev/null
BIN="$BUILD/build-coreml/bin"

echo "==> модель $MODEL"
if [ ! -f "$MODELS/$MODEL" ]; then
  curl -L --progress-bar -o "$MODELS/$MODEL" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
fi

echo "==> CoreML-энкодер"
if [ ! -d "$MODELS/$ENCODER" ]; then
  curl -L --progress-bar -o /tmp/turbo-encoder.zip \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$ENCODER.zip"
  unzip -oq /tmp/turbo-encoder.zip -d "$MODELS/"
  rm -f /tmp/turbo-encoder.zip
fi
# whisper.cpp ищет энкодер по имени весов: <модель>-encoder.mlmodelc.
# Энкодер один и тот же для fp16 и квантованных весов — квантование трогает только декодер.
ln -sfn "$ENCODER" "$MODELS/${MODEL%.bin}-encoder.mlmodelc"

echo "==> LaunchAgent (порт $PORT)"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.openwispr.whisper-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN/whisper-server</string>
        <string>-m</string>
        <string>$MODELS/$MODEL</string>
        <string>-l</string>
        <string>ru</string>
        <string>--port</string>
        <string>$PORT</string>
        <string>-nt</string>
        <string>-t</string>
        <string>8</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DYLD_LIBRARY_PATH</key>
        <string>$BIN</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$ROOT/logs/whisper-server.log</string>
    <key>StandardErrorPath</key>
    <string>$ROOT/logs/whisper-server.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/local.openwispr.whisper-server" 2>/dev/null || true
sleep 2
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo -n "==> ждём сервер"
for _ in $(seq 1 180); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/"; then echo " — готов"; break; fi
  echo -n .
  sleep 1
done

if grep -q "Core ML model loaded" "$ROOT/logs/whisper-server.log"; then
  echo "==> CoreML активен"
else
  echo "!! CoreML не подхватился — энкодер идёт через Metal, будет медленнее" >&2
fi

cat <<'HINT'

Осталось задать в ~/.config/open-wispr/config.json:
  "whisperServerURL": "http://127.0.0.1:8123",
  "whisperBeamSize": 5,
  "whisperPrompt": "Разработка и код: CSSOM, JavaScript, TypeScript, React, git rebase, API, Docker, Swift, Xcode."

whisperPrompt — подсказка распознавателю: без неё английские термины
съезжают в кириллицу («CSSOM» → «cssvm»). Затем:
  launchctl kickstart -k gui/$(id -u)/local.openwispr.app
HINT
