# Dawn to Dusk

[简体中文](README.md) · [English](README.en.md)

**Dawn to Dusk** (朝夕) is a native macOS schedule and to-do app. Dated events appear in Schedule; undated items stay in To-dos. A desktop panel, local reminders, and on-device storage help you see and plan your day.

Switch between Simplified Chinese and English in **Settings → Appearance → Language / 语言**. Your event names and notes stay exactly as you wrote them.

## Features

- Edit, add, and remove events together from **Edit Schedule**. **Save Changes** applies the whole edit; **Cancel** discards it. Completed one-off events are hidden from the editor while their history is kept.
- Daily, weekday, and weekly repeats. Give one event different times by weekday: for example, Monday at 09:00 and Tuesday–Friday at 10:00.
- For a temporary change, select the preview date and choose **Change only YYYY-MM-DD**. Other dates retain the usual pattern. Individual events also offer **Only this one** editing.
- Type hours and minutes directly, or open the two-column wheel picker using the clock icon beside the numbers. Hours run from 00–23 and minutes from 00–59. A cleared field means 00. Rows stay in place while typing and sort after **Done** or Return.
- Enter an exact duration from 0–1440 minutes, or choose **None, 15 min, 30 min, or 1 hr** in one click. A blank field or 0 means no duration. Each editor card shows its duration at the bottom right, even when its details are collapsed.
- Optional intervals between events, including overnight gaps. Toggle normal display in **Settings → Appearance → Schedule Display**; the editor has an independent preview switch.
- Separate actions for snoozing a reminder and postponing an occurrence.
- Local notifications, menu bar access, a compact panel, pinning, and several appearance options. Compact view can follow the next event or a pinned item.
- Local JSON data, backup export, and restore.
- Local command-line capture, changes and read-only queries; external changes can be undone in the window.
- Skip one day of a repeating item or pause it for a date range; skipped days show as "Skipped" with one-click restore.
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

The repository contains source code, documentation, and synthetic test data only. It does not contain personal schedules, to-dos, completion records, backups, or account credentials. Keep local data, exported backups, and screenshots outside the repository.

## Local command-line interface

Every entry point reads JSON from standard input; add `--qa --data-dir <absolute path>` for isolated testing. See `朝夕.app/Contents/MacOS/Chaoxi --help` for all fields.

- `--capture` adds an item.
- `--query` is read-only and never opens the window: `{}` for today, `{"date":"YYYY-MM-DD"}`, or `{"from":"YYYY-MM-DD","to":"YYYY-MM-DD"}` for up to 31 days. Rows include `revision`, `note`, `source` (`ui/hermes/cli/feishu`), `capture_request_id` and `feishu_readonly`, plus skipped repeating items.
- `--change` changes one existing item: `update` (only the given fields), `reschedule_once`, `complete` / `reopen`, `skip_once`, `pause_range` / `resume`, `delete` and `restore`. `target` is one of `item_id`, `occurrence_id` or the original `capture_request_id`.

`--change` uses the same local inbox as `--capture`; only the app process writes `agenda.json`, and it is launched if needed. A repeated `request_id` returns `already_processed`; a stale `if_match` or an unsaved draft of the same item in the window returns `conflict`; Feishu items return `forbidden`. Deletions store a full snapshot so `restore` brings back the same id, completion records and repeat rule. Every external change is logged with before, after, source and time: the window's Undo reverts the latest one, and Settings → Other → Recent external changes can undo each record. Reminders are rescheduled or removed after time changes, skips and deletions. `--change --dry-run` reads the saved data only and returns the expected `before` / `after` without saving. Receipts contain `ok`, `status`, `item_exists`, `saved`, `before`, `after` and `request_id`; rely on the receipt, not the exit code.

The Hermes capture helper at `Integrations/Hermes/chaoxi-capture/scripts/capture.py` accepts JSON on standard input and invokes the local command-line interface in `~/Applications/朝夕.app`. The Clawd desktop pet bridge is a local customization and is not included in this public repository.

## Version

**1.3.0 (build 18)**

This version adds the local `--change` interface (edit, delete and restore, one-time reschedule, complete/reopen, skip and pause) and up to 31-day range queries with the fields needed for safe changes. Skipped repeating items stay visible with one-click restore, and Settings lists recent external changes for undo.

### 1.2.1 (build 15) · Git tag `v1.2.1`

1.2.1 replaces the small duration arrows with exact-minute input and common presets, keeps duration visible at the bottom right of each editor card, and uses a clock icon to open the time wheel. It retains the Chinese/English interfaces, weekday-specific times, and one-day overrides introduced in 1.2.0.

## License

An overall code license has not yet been specified. `Resources/Maccy-LICENSE.txt` applies only to native material code adapted from Maccy, not to the rest of Dawn to Dusk.
