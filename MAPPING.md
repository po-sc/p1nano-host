# Привязки кнопок и энкодеров

Хост читает **стандартные MCU-ноты/CC**, которые шлёт P1-Nano. Привязки задаются файлом
**`~/.config/p1nano/mapping.conf`** — БЕЗ пересборки. Поменял → перезапусти:
```bash
launchctl kickstart -k gui/$(id -u)/com.poscripty.p1nano-host
```
(Дефолты на случай отсутствия файла — в таблицах `NOTE_ACTIONS`/`ENC_TARGETS` в `host.swift`.)

> Хост печатает в лог КАЖДОЕ нажатие с номером ноты (`кнопка нота 94`) и кручение энкодера
> (`энкодер CC16 +3`). Так легко узнать, что шлёт конкретная кнопка (в т.ч. кнопки сенсорного
> экрана), и привязать. Лог: `tail -f /tmp/p1nano-host.log`.

## Формат `mapping.conf`
```
note <N> playpause | nexttrack | prevtrack | mute | micmute
note <N> launch <ИмяПриложения>     # точное имя из /Applications
note <N> run <shell-команда>        # URL, Shortcut, AppleScript — что угодно
enc  <CC> brightness | volume | none
unmap note <N>   |   unmap enc <CC>
```

## Сенсорный экран (4″) → запуск приложений
Кнопки тачскрина в MCU-режиме шлют свои ноты. Чтобы повесить на них приложения:
1. `tail -f /tmp/p1nano-host.log`
2. Нажми кнопку на экране → увидишь `кнопка нота <N> (не назначена)`.
3. Допиши в `mapping.conf`:  `note <N> launch Spotify`  (или `run open https://...`).
4. Перезапусти хост (команда выше).

## Кнопки (note → действие) — по умолчанию

| Нота | Кнопка (MCU) | Действие |
|---|---|---|
| 94 | Play | Play/Pause |
| 93 | Stop | Play/Pause |
| 91 | Rewind | Предыдущий трек |
| 92 | Fast-Fwd | Следующий трек |
| 95 | Record | Mute вкл/выкл |
| 74 | Read/Off | Открыть **Safari** |
| 75 | Write | Открыть **Music** |
| 76 | Trim | Открыть **Finder** |
| 77 | Touch | Открыть **Notes** |
| 78 | Latch | Открыть **Calendar** |
| 79 | Group | Открыть **System Settings** |

Приложения 74–79 — **заглушки из стоковых программ**, поменяй на свои в `NOTE_ACTIONS`
(точное имя приложения из `/Applications`, напр. `.launch("Telegram")`).

## Энкодеры (V-Pot, относительный CC ch1) — по умолчанию

| CC | Энкодер | Действие |
|---|---|---|
| 16 | 1 | Яркость экрана (медиа-клавиши, только встроенный дисплей) |
| 23 | 8 | Громкость (±2% за щелчок) |
| 17–22 | 2–7 | Не назначены (видны в логе) |

## Фейдер

- Ведёшь → системная громкость (CoreAudio, плавно, до 100%); на экране HUD-плашка.
- Внешнее изменение громкости → моторный фейдер сам едет (обратная связь).
- LCD устройства показывает громкость числом + полоской.

## Доступные действия

- `playpause`, `nexttrack`, `prevtrack` — медиа (через MediaRemote, без прав)
- `mute` — системный звук вкл/выкл
- `micmute` — мьют МИКРОФОНА (для созвонов)
- `launch <Приложение>` — открыть приложение
- `run <команда>` — **универсальный макрос**: любая shell-команда. Примеры:
  - `run("open https://youtube.com")` — открыть сайт
  - `run("shortcuts run 'Название ярлыка'")` — запустить macOS Shortcut
  - `run("osascript -e 'tell app \"Music\" to playpause'")` — AppleScript
  - `run open -a 'Mission Control'`

Энкодеры: `brightness`, `volume`, `none`.

## Как поменять привязку (без пересборки)

1. `tail -f /tmp/p1nano-host.log`, нажми нужную кнопку → увидишь её ноту.
2. Открой `~/.config/p1nano/mapping.conf`, добавь/поменяй строку: `note <N> launch Spotify`
3. Перезапусти: `launchctl kickstart -k gui/$(id -u)/com.poscripty.p1nano-host`
