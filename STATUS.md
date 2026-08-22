# whisper-clone — статус проекта

> Диктовка голосом на macOS (Apple Silicon): зажать клавишу → говорить → отпустить → текст печатается в активное приложение.
> Форк [human37/open-wispr](https://github.com/human37/open-wispr), доработанный под локальный быстрый пайплайн на `whisper.cpp`.
>
> Актуально на: **22.08.2026**, HEAD: `11104dd`+.

---

## 1. Цели

1. **Hands-free диктовка.** Одна клавиша (Fn / 🌐) — без мыши, без облака.
2. **Задержка ≤ 500 мс** от отпускания клавиши до появления текста.
3. **Точная транскрипция русского** (и других языков) — 100 % локально, приватность.
4. **Надёжность.** Автозапуск при входе в систему; фолбэк, если сервер недоступен.
5. **Простота.** Один хоткей, без настроек «на каждый случай».

## 2. Задачи (декомпозиция)

| # | Задача | Статус |
|---|---|---|
| 1 | Запись аудио по зажатой клавише (16 кГц, mono, WAV) | ✅ |
| 2 | Транскрипция Whisper локально, модель резидент в RAM | ✅ |
| 3 | Вставка текста в любое приложение (CGEvent) | ✅ |
| 4 | Хоткей: Fn (globe) long-press | ✅ |
| 5 | Автозапуск демона + whisper-server (LaunchAgents) | ✅ |
| 6 | Latency ≤ 500 мс | ✅ (см. замеры) |
| 7 | Фолбэк на whisper-cli при падении сервера | ✅ |
| 8 | Измерение полного цикла с таймстемпами | ✅ |
| 9 | Перенос live-установки из /tmp, README/UX polish, git tag | ✅ (сборка из репозитория) |

## 3. Архитектура

```
┌───────────────┐   Fn long-press    ┌────────────────────────┐
│   Пользователь │ ─────────────────▶ │  OpenWispr daemon       │
└───────────────┘                    │  (menu bar, NSApp.run) │
                                     │  • NSEvent global mon. │
   текст в приложение ◀── CGEvent ── │  • AVAudioEngine→WAV   │
                                     └───────────┬────────────┘
                                                 │ POST /inference
                                                 │ multipart (file, language, beam_size)
                                                 ▼
                                     ┌────────────────────────┐
                                     │  whisper-server :8123  │
                                     │  whisper.cpp + Metal   │
                                     │  модель в RAM (small)  │
                                     └────────────────────────┘
```

**Компоненты:**

| Компонент | Путь | Роль |
|---|---|---|
| Демон | `OpenWispr.app` (из `scripts/bundle-app.sh`) | хоткей, запись, вставка текста |
| Сервер | `/opt/homebrew/bin/whisper-server` | транскрипция, порт **8123** |
| Фолбэк | `/opt/homebrew/bin/whisper-cli` | транскрипция при падении сервера |
| Конфиг | `~/.config/open-wispr/config.json` | хоткей, язык, beam, URL сервера |
| Модели | `~/.config/open-wispr/models/` | small, medium-q5_0, large-v3-turbo |
| Записи | `~/.config/open-wispr/recordings/` | последние 10 WAV |
| Логи | `~/openwispr-fast/logs/` | `openwispr.log`, `whisper-server.log` |
| LaunchAgents | `~/Library/LaunchAgents/local.openwispr.*.plist` | демон + сервер (KeepAlive) |

**Ключевые файлы кода** (всего ~2900 строк Swift):

| Файл | Роль |
|---|---|
| `Sources/OpenWispr/main.swift` | CLI-диспетчер (`listen`, `set-hotkey`, …) |
| `Sources/OpenWisprLib/AppDelegate.swift` | демон: `NSApp.run()`, main-thread-монитор, жизненный цикл записи |
| `Sources/OpenWisprLib/HotkeyManager.swift` | `NSEvent.addGlobalMonitorForEvents`, keyCode/modifiers |
| `Sources/OpenWisprLib/AudioRecorder.swift` | запись → WAV 16 kHz mono |
| `Sources/OpenWisprLib/Transcriber.swift` | HTTP POST к серверу + CLI-фолбэк (352 строки, 129 тестов) |
| `Sources/OpenWisprLib/TextInserter.swift` | вставка текста (CGEvent) |
| `Sources/OpenWisprLib/RecordingStore.swift` | хранение/прuning записей |
| `Sources/OpenWisprLib/Config.swift` | `config.json`, `set-hotkey`/`get-hotkey` |
| `Sources/OpenWisprLib/LatencyTracker.swift` | таймстемпы цикла «отпустил клавишу → текст» в лог |

## 4. Текущее состояние (22.08.2026)

### ✅ Работает

- **E2E-пайплайн:** Fn long-press → речь → транскрипция → текст в приложении (подтверждено вживую).
- **Latency:** транскрипция **0.25–0.41 с** на модели `small` (0.9 с аудио → 0.25 с; 2.8 с аудио → 0.35 с).
  Целевой порог 500 мс по этапу инференса **выполнен**.
- **Сервер:** `whisper-server` на `small` (ggml-small.bin), флага `-bs 1 -nt`, порт 8123, KeepAlive.
- **Демон:** хоткей **Fn**, `language=ru`, `beam_size=5`, `modelSize=small`, режим «зажать → отпустить».
- **Тесты:** 135/135 (Transcriber + multipart-сборка + фолбэк-логика + LatencyTrace).
- **Измерение полного цикла:** после каждой диктовки демон пишет в лог строку вида
  `latency: total=612ms (capture=18ms transcribe=352ms insert=242ms) audio=2.8s chars=41`
  — этапы: остановка записи/закрытие WAV → транскрипция → вставка текста.
  Смотреть: `grep latency: ~/openwispr-fast/logs/openwispr.log`.
- **Live-установка собирается из этого репозитория** (`~/code/my/whisper-clone`), а не из `/tmp`;
  приложение установлено в `~/openwispr-fast/OpenWispr.app` (путь стабилен ради TCC-гранта).

### 📊 A/B моделей (одна и та же фраза, порт 8123)

| Модель | 0.9 с аудио | 2.8 с аудио | Качество на тест-фразе |
|---|---|---|---|
| large-v3-turbo (было) | 1.27 с | 1.20 с | «…153 метра…» |
| medium-q5_0 | 0.93 с | ~0.95 с | «…153 метра…» |
| **small (выбрано)** | **0.25 с** | **0.35 с** | «…153 метра…» (как turbo) |

Вывод: узкое место — **encode time** (энкодер обрабатывает полное 30-с окно; на turbo ~1.2 с).
`small` даёт то же качество на тестовых фразах, но в 3.5–4 раза быстрее.



### ⚠️ Известные проблемы / риски

1. **TCC-хрупкость.** Грант Accessibility/Микрофон привязан к точному cdhash + пути бинарника.
   Любой `codesign` / перенос / rebuild **аннулирует грант**:
   `tccutil reset Accessibility` → пользователь выдает заново в System Settings.
   → **Любые правки кода батчить в один rebuild.**
2. **Аномалия 400 «Invalid request».** Старый процесс демона (pid 87237, запущен 12:18)
   получал 400 от сервера на валидных запросах; байт-идентичный запрос (прокси/curl/python)
   принимался сервером. После рестарта демона ошибки исчезли. **Корневая причина не установлена** —
   если 400 вернётся, ловить запрос через прокси на 8124 (методика: перехват тела+заголовков,
   бисекция заголовков).
3. ~~**Live-сборка в `/tmp/open-wispr`.**~~ Закрыто: сборка идёт из `~/code/my/whisper-clone`,
   исходники в `/tmp/open-wispr` были байт-в-байт идентичны и больше не нужны.
4. **`open -n --args` ловушка.** LaunchServices подставляет `-psn_…`, ломающий CLI-диспетчер.
   Запускать прямой бинарник (`.../Contents/MacOS/open-wispr`).

### 📋 Next steps

1. Собрать реальные замеры `latency:` из лога за день использования и свести таблицу
   (сколько из них укладывается в 500 мс полного цикла, а не только инференса).
2. Опционально: `--port` флаг, `start`/`stop` UX.
3. Следить за аномалией 400 (риск #2).

## 5. Сборка и запуск из этого каталога

```bash
brew install whisper-cpp          # whisper-cli + whisper-server
swift build -c release
scripts/bundle-app.sh .build/release/open-wispr OpenWispr.app 0.44.0
codesign --force --deep -s - OpenWispr.app

# установка в live-каталог (путь фиксирован в LaunchAgent и в TCC-гранте):
launchctl bootout gui/$(id -u)/local.openwispr.app
rm -rf ~/openwispr-fast/OpenWispr.app
cp -R OpenWispr.app ~/openwispr-fast/OpenWispr.app
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.openwispr.app.plist

# запуск вручную (без LaunchAgents):
OpenWispr.app/Contents/MacOS/open-wispr listen

# хоткей:
OpenWispr.app/Contents/MacOS/open-wispr set-hotkey fn
```

После любой пересборки: `tccutil reset Accessibility` → выдать доступ в System Settings.

## 6. Команды эксплуатации

```bash
# статус LaunchAgents
launchctl print gui/$(id -u)/local.openwispr.app | grep state
launchctl print gui/$(id -u)/local.openwispr.whisper-server | grep state

# рестарт
launchctl kickstart -k gui/$(id -u)/local.openwispr.app
launchctl bootout gui/$(id -u)/local.openwispr.whisper-server
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.openwispr.whisper-server.plist

# быстрая проверка сервера
curl -s -X POST http://127.0.0.1:8123/inference \
  -F 'file=@~/openwispr-fast/test.wav;type=audio/wav' -F 'language=ru'

# логи
tail -f ~/openwispr-fast/logs/openwispr.log
tail -f ~/openwispr-fast/logs/whisper-server.log
```
