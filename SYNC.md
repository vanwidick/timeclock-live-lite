# TimeClock cloud sync (phone v1.2.1, PC companion TimeClockSync v1.1.0, needs TimeClock Live v1.0.2+)

```
TimeClockLive.ps1 ──writes──> timeclock-data.json ──read──> TimeClockSync.ps1 (PC companion, scheduled task)
      (reloads on change, 1 s)       ^                           │  GET (ETag) / PUT punches only
                                     └── merged punches written  ▼
                                         live, atomically        private GitHub repo  vanwidick/timeclock-sync
                                                                 file timeclock-sync.json
                                                                 ▲
                         phone app (TimeClock Live Lite) ────────┘  GET/PUT via api.github.com (token stored only on the phone)
```

* Cloud store: a **private** GitHub repo, one file `timeclock-sync.json` = `{app, version, saved, by, punches}`. Only punches leave the PC
  (no profile, PTO, alerts.topic or sync topic). Every write is a commit, so history doubles as an audit log / backup.
* Merge: per date, 3-way against the last synced state (`src/merge.js` = `Merge-Punches3` in `pc/TimeClockSync.ps1`, shared vectors in
  `sync-test/vectors.json`). A day changed on one side wins verbatim; changed on both → union of new punches, removals (undo/edits) win, sorted by time.
  Optimistic concurrency with the file `sha` (409/422 → re-read and re-merge).
* Phone: syncs on open, on every punch/undo/import (0.8 s debounce), every 30 s while visible, and when back online.
* PC (every 10 s, default `-FileWrite Always`): reads timeclock-data.json only when its LastWriteTime/size changes (FileShare
  Read|Write|Delete, never held open), conditional GET of the cloud copy (304s are free), 3-way merge, push if different.
  Writes merged punches back live: re-reads the file right before writing (a desktop save in between is merged first),
  replaces only the `"punches"` value (all other keys byte-for-byte; `days` is left for the app to re-derive), writes UTF-8
  to `timeclock-data.json.lite.tmp` and swaps it in with `File.Replace` (previous file -> `timeclock-data.json.bak`, the same
  backup name/content style the app uses; harmless). Its own write's LastWriteTime is remembered, so it is not pushed back,
  and a desktop re-save with identical punches is not pushed either (no ping-pong).
* Rules (from the TimeClock Live owner): Central `yyyy-MM-dd` keys, seconds 0-86399, kinds in/out/bs/be/lo/li, max 2 breaks
  a day (`tcLimitBreaks` / `Limit-Breaks`: a 3rd+ `bs` is dropped, with its `be` unless a break was still open). The app
  ignores a PC click within 3 s of that day's newest punch (double-tap guard).
* `-FileWrite WhenClosed` remains for TimeClock Live < 1.0.2.

Tests: `node sync-test/merge_test.js` (+ `limit_vectors.json`), `pwsh pc/merge_test.ps1`, `sync-test/pc_e2e.sh`, `python sync-test/phone_sync_test.py` (mock GitHub API).
