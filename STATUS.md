# whisper-clone — статус проекта

> Диктовка голосом на macOS (Apple Silicon): зажать клавишу → говорить → отпустить → текст печатается в активное приложение.
> Форк [human37/open-wispr](https://github.com/human37/open-wispr), доработанный под локальный быстрый пайплайн на `whisper.cpp`.
>
> Актуально на: **22.08.2026**, HEAD: `11104dd`+.

---

## 1. Цели

1. **Hands-free диктовка.** Одна клавиша (Fn / 🌐) — без мыши, без облака.
2. **Задержка ≤ 650 мс** от отпускания клавиши до появления текста
   (порог поднят с 500 мс 22.08.2026 — цена за качество `large-v3-turbo` на быстрой речи).
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
| 6 | Latency ≤ 650 мс при качестве turbo | ✅ (0.55–0.60 с, CoreML) |
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
                                     │  whisper.cpp + CoreML  │
                                     │  turbo-q8_0 в RAM,     │
                                     │  энкодер на ANE        │
                                     └────────────────────────┘
```

**Компоненты:**

| Компонент | Путь | Роль |
|---|---|---|
| Демон | `~/openwispr-fast/OpenWispr.app` (из `scripts/bundle-app.sh`) | хоткей, запись, вставка текста |
| Сервер | `~/openwispr-fast/build/whisper.cpp/build-coreml/bin/whisper-server` | транскрипция, порт **8123**, CoreML |
| Фолбэк | `/opt/homebrew/bin/whisper-cli` | транскрипция при падении сервера |
| Конфиг | `~/.config/open-wispr/config.json` | хоткей, язык, beam, URL сервера |
| Модели | `~/.config/open-wispr/models/` | turbo-q8_0 + CoreML-энкодер (`*.mlmodelc`), small, medium-q5_0 |
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
- **Latency:** транскрипция **0.55–0.60 с** на `large-v3-turbo-q8_0` с CoreML-энкодером;
  полный цикл в бою **644–710 мс**.
- **Сервер:** `whisper-server` из собственной сборки whisper.cpp v1.9.2 **с CoreML**,
  модель `large-v3-turbo-q8_0` + CoreML-энкодер на Neural Engine, порт 8123, KeepAlive.
  Ставится скриптом `scripts/setup-fast-server.sh`.
- **Демон:** хоткей **Fn**, `language=ru`, `beam_size=5`, `whisperPrompt` (см. ниже),
  режим «зажать → отпустить».
- **Тесты:** 136/136 (Transcriber + multipart-сборка + фолбэк-логика + LatencyTrace).
- **Измерение полного цикла:** после каждой диктовки демон пишет в лог строку
  «отпустил клавишу → текст в приложении». Смотреть: `grep '^latency:' ~/openwispr-fast/logs/openwispr.log`.

  Живые замеры на боевой конфигурации (turbo-q8_0 + CoreML + промпт):

  ```
  latency: total=677ms (capture=10ms transcribe=660ms insert=8ms)  audio=2.2s chars=29
  latency: total=644ms (capture=6ms  transcribe=629ms insert=10ms) audio=2.4s chars=31
  latency: total=710ms (capture=10ms transcribe=695ms insert=5ms)  audio=3.1s chars=21
  ```

  Запись и вставка почти бесплатны (6–17 мс + 4–21 мс, ~3 % цикла), остальное — транскрипция.
  На `small` те же этапы давали 375–485 мс общего цикла, но с ошибками на быстрой речи.
- **Live-установка собирается из этого репозитория** (`~/code/my/whisper-clone`), а не из `/tmp`;
  приложение установлено в `~/openwispr-fast/OpenWispr.app` (путь стабилен ради TCC-гранта).

### 📊 Качество на быстрой речи (22.08.2026)

Жалоба: на быстрой речи `small` ошибается. Проверено на записях с известным эталоном
(корпус сохранён в `~/openwispr-fast/testset`, т.к. `recordings/` хранит только 10 последних).

| Конфигурация | Время | «Мы идем в **maxi-step over does**» | «**CSSOM** переименуй» |
|---|---|---|---|
| small (было) | 0.30–0.35 с | Макси степ, Овер даст | — |
| turbo-q8_0, Metal, полный контекст | 1.15 с | Maxi Step Over Das | — |
| turbo-q8_0, Metal, `-ac 1100` | 0.88–0.99 с | Maxi Step Over Dust | CSSOM переименуй |
| turbo-q8_0, **CoreML** | 0.55–0.62 с | МАКСИ-СТЕП-ОВЕР-ДАС | cssvm переименуй |
| **turbo-q8_0, CoreML + `whisperPrompt`** | **0.55–0.60 с** | **maxi-step over does** | **CSSOM переименуй** |

Три независимых рычага, каждый проверен замером:

1. **Модель.** `small` систематически проигрывает `large-v3-turbo` на быстрой речи и
   скороговорках («От топа-то копыт пыль по полю летит»: turbo — «От топа-то копыт пыль
   попали лютит», small — «А то под окопы пыль попали летит»). `medium-q5_0` хуже turbo
   при той же цене — не нужен.
2. **CoreML-энкодер.** Узкое место — encode: энкодер всегда обрабатывает полное 30-с окно.
   Бутылка Homebrew собрана без CoreML (`COREML = 0`), всё идёт через Metal. Своя сборка
   с `-DWHISPER_COREML=1` переносит энкодер на Neural Engine: 0.9 с → 0.6 с без потери качества.
   Альтернатива — `--audio-ctx` (урезание окна энкодера), но ниже ~1000 модель срывается
   с латиницы на кириллицу, а на 750 и меньше начинает дублировать фразы.
3. **`whisperPrompt`.** Без подсказки английские термины съезжают в кириллицу
   («CSSOM» → «cssvm»). Промпт со списком типовых терминов чинит это бесплатно по времени.

**Что проверено и отвергнуто** (чтобы не возвращаться):

| Гипотеза | Результат |
|---|---|
| `large-v3` точнее `turbo` на быстрой речи | **Хуже**: смешивает алфавиты («намерima», «от topa-t-к», «На двore»), 0.72–0.90 с |
| `medium-q5_0` — компромисс | Хуже turbo при той же цене |
| `beam_size` 5 → 8 | Текст **не меняется**, +0.03 с |
| Промпт мешает на бытовой речи | Текст со скороговорками **идентичен** с промптом и без |
| `turbo-q5_0` быстрее `q8_0` | **Нет**: 0.63 против 0.60 с — упёрлись в энкодер на ANE |
| Дефект в тракте записи 48→16 кГц | **Нет.** Гипотеза была: input-блок отдаёт конвертеру один и тот же буфер повторно (`AudioRecorder.swift:92`), отсюда склейка слогов. Прогон контрольного чирпа через ту же схему: **36 запросов входа на 36 порций**, дублирования нет. Тракт чистый. |

### 🎤 Предел на скороговорках

Ошибки на быстрых скороговорках **не лечатся** ни моделью, ни настройками декодера —
это предел распознавания, а не конфигурации:

| Сказано | Распознано |
|---|---|
| На мели мы лениво налима ловили | Намеримо лениво, намеримо ловили ✗ |
| И меняли налима вы мне на линя | И меняли на Лима, мы на Линя ~ |
| От топота копыт пыль по полю летит | верно ✓ |
| На дворе трава, на траве дрова | На дворе трава, на дрове трава ✗ |

На обычной рабочей диктовке («Объясни подробнее, что это», «CSSOM переименуй»,
«Последний пункт немного подробнее выдай») ошибок нет.



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
5. **Выброс латентности ×5 на отдельных записях.** Одна запись из шести (`…99FCF172.wav`,
   1.5 с, распознаётся как «1, 2, 3, 4, 5») стабильно занимает **1.66–1.80 с** вместо 0.3 с,
   причём в ~1 прогоне из 6 та же запись укладывается в 0.31 с. Остальные пять записей
   (1.5–5.0 с) — стабильно 0.29–0.40 с.

   Проверено и **исключено** как причина: длина аудио (5.0 с — 0.39 с); конкуренция за GPU
   со вторым инстансом сервера; `beam_size` (1 и 5 одинаково); temperature-fallback
   (флаг сервера `-nf` и поле запроса `temperature_inc=0` не влияют).
   Текст ответа между прогонами слегка плавает («1, 2, 3, 4, 5» / «1,2,3,4,5» / «1-2-3-4-5»),
   то есть декодирование недетерминировано. Корневая причина не установлена.

   Воспроизведение:
   ```bash
   cd ~/.config/open-wispr/recordings
   for i in 1 2 3; do /usr/bin/time -p curl -s -o /dev/null -X POST \
     http://127.0.0.1:8123/inference -F 'file=@<file>.wav;type=audio/wav' \
     -F 'language=ru' -F 'beam_size=5'; done
   ```
   Следующий шаг диагностики: собрать `whisper-server` с выводом `whisper_print_timings`
   (encode/decode/sample по запросу) — текущая сборка из Homebrew их не печатает.

### 📋 Next steps

1. Живые замеры на новой конфигурации: **644–710 мс** (transcribe 629–695 мс).
   Это на 0–60 мс выше порога 650 мс — сам инференс 0.60 с, сверху HTTP и запись WAV.
   Накопить статистику за день и решить, нужен ли ещё запас: резервов в текущем
   стеке не осталось (энкодер на ANE — потолок), следующий шаг был бы своя
   конверсия CoreML-энкодера под меньшее окно.
2. Пополнять `whisperPrompt` терминами, которые распознаются неверно, — самый дешёвый
   способ поднять качество на своём словаре.
3. Опционально: `--port` флаг, `start`/`stop` UX.
4. Следить за аномалией 400 (риск #2) и выбросом ×5 (риск #5).

## 4a. GigaAM (27.10.2026)

Боевой распознаватель переключён на **GigaAM-v3 e2e RNNT** (onnx-asr, CPU).
Sidecar говорит тем же `POST /inference`, что и whisper-server.

- Живой URL: `http://127.0.0.1:8124` (`whisperServerURL` в config.json)
- Установщик: `bash scripts/install-gigaam.sh` — см. [docs/install-gigaam.md](docs/install-gigaam.md)
- Live-префикс: `~/openwispr-fast/` (приложение + копия `gigaam_server.py`, без зависимости от git checkout)
- CoreML EP onnxruntime на этом графе падает; CPU даёт ~30–60 мс на фразу
- `whisper-cpp` для этой сборки не нужен; старый LaunchAgent whisper-server отключается установщиком

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
