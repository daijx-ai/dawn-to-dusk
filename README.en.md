# Dawn to Dusk

[简体中文](README.md) · [English](README.en.md)

**Dawn to Dusk** (朝夕) is a native macOS schedule and to-do app. Dated events appear in Schedule; undated items stay in To-dos. A desktop panel, local reminders, and on-device storage help you see and plan your day.

Switch between Simplified Chinese and English in **Settings → Appearance → Language / 语言**. Your event names and notes stay exactly as you wrote them.

## Features

- Edit, add, and remove events together from **Edit Schedule**. **Save Changes** applies the whole edit; **Cancel** discards it. Completed one-off events are hidden from the editor while their history is kept.
- Daily, weekday, and weekly repeats. Give one event different times by weekday: for example, Monday at 09:00 and Tuesday–Friday at 10:00.
- For a temporary change, select the preview date and choose **Change only YYYY-MM-DD**. Other dates retain the usual pattern. Individual events also offer **Only this one** editing.
- Type hours and minutes directly, or open the two-column wheel picker using the button beside the numbers. Hours run from 00–23 and minutes from 00–59. A cleared field means 00. Rows stay in place while typing and sort after **Done** or Return.
- Optional intervals between events, including overnight gaps. Toggle normal display in **Settings → Appearance → Schedule Display**; the editor has an independent preview switch.
- Separate actions for snoozing a reminder and postponing an occurrence.
- Local notifications, menu bar access, a compact panel, pinning, and several appearance options. Compact view can follow the next event or a pinned item.
- Local JSON data, backup export, and restore.
- Local command-line capture and read-only queries.
- Optional read-only Feishu primary calendar sync. The app does not write to Feishu.

## Requirements

- macOS 15 or later
- Apple Silicon
- Xcode Command Line Tools

## Build and Run

```sh
./scripts/build.sh
open build/朝夕.app
```

Run the checks:

```sh
./scripts/test.sh
```

Data is stored in `~/Library/Application Support/Chaoxi/agenda.json`. Core schedule features use local data. Feishu sync additionally requires an installed and signed-in `lark-cli`, currently located at `~/bin/lark-cli`. Sync reads the primary calendar and refreshes periodically when enabled.

The Hermes capture helper at `Integrations/Hermes/chaoxi-capture/scripts/capture.py` accepts JSON on standard input and invokes the local command-line interface in `~/Applications/朝夕.app`. The Clawd desktop pet bridge is a local customization and is not included in this public repository.

## Version

**1.2.0 (build 13)** · Git tag `v1.2.0`.

This version adds Chinese/English interfaces, a wheel time picker, unified schedule editing with add/remove, weekday-specific times, and one-day overrides. It also fixes premature sorting while typing and accidental time changes while scrolling, and moves normal interval visibility into Settings.

## License

An overall code license has not yet been specified. `Resources/Maccy-LICENSE.txt` applies only to native material code adapted from Maccy, not to the rest of Dawn to Dusk.
