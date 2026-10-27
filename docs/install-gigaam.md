# open-wispr + GigaAM

Локальная диктовка на русском: зажать Fn / 🌐 → говорить → отпустить → текст в активном приложении. Распознавание — **GigaAM-v3 e2e RNNT** (SaluteDevices, MIT), 100% on-device.

## Поставить на эту машину

Нужны macOS 13+, сеть для первой загрузки модели (~300 MB), Homebrew (`uv`) и Swift / Xcode CLT.

```bash
git clone <url-этого-репозитория>
cd <каталог>
bash scripts/install-gigaam.sh
```

Скрипт:

1. Ставит Python-venv и `onnx-asr`, копирует sidecar в `~/openwispr-fast/gigaam/` (не зависит от каталога исходников).
2. Поднимает `local.openwispr.gigaam-server` на `127.0.0.1:8124`.
3. Собирает `OpenWispr.app` в `~/openwispr-fast/` (путь фиксирован из‑за TCC), если приложения ещё нет.
4. Пишет `whisperServerURL` в `~/.config/open-wispr/config.json`.
5. Включает автозапуск демона, отключает старый `whisper-server`.

Выдай **Microphone** и **Accessibility** для `~/openwispr-fast/OpenWispr.app`, если система спросит.

Флаги: `--rebuild` (пересборка приложения, сбросит Accessibility), `--no-build`, `--sidecar`, `--bench`.

Снять:

```bash
bash scripts/uninstall-gigaam.sh          # агенты + ~/openwispr-fast
bash scripts/uninstall-gigaam.sh --purge  # плюс конфиг и кэш модели
```

## Поделиться и поставить на другой Mac

Репозиторий — единица поставки. На второй машине тот же `git clone` и `bash scripts/install-gigaam.sh`.

Без git:

```bash
# на этой машине
cd /path/to/repo
git archive --format=tar.gz HEAD > /tmp/open-wispr-gigaam.tar.gz

# на другой
tar -xzf open-wispr-gigaam.tar.gz
cd <распакованный-каталог>
bash scripts/install-gigaam.sh
```

Первый запуск на новой машине качает веса GigaAM с Hugging Face. Дальше всё офлайн.

## Что куда кладётся

| Путь | Роль |
|---|---|
| `~/openwispr-fast/OpenWispr.app` | демон, хоткей, запись, вставка текста |
| `~/openwispr-fast/gigaam/` | venv, `gigaam_server.py`, логи sidecar |
| `~/.config/open-wispr/config.json` | хоткей, язык, URL сервера |
| `~/Library/LaunchAgents/local.openwispr.*.plist` | автозапуск |
| `~/.cache/huggingface/` | веса GigaAM |

Демон ходит на `POST http://127.0.0.1:8124/inference` (тот же контракт, что у whisper-server). `whisper-cpp` для этой сборки не нужен.
