# TimeClock cloud sync (v1.2.0, branch `sync`, NOT deployed yet)

```
TimeClockLive.ps1 ──writes──> timeclock-data.json ──read──> TimeClockSync.ps1 (PC companion, scheduled task)
                                     ^                           │  GET/PUT punches only
                                     └── phone punches written   ▼
                                         only while TimeClock    private GitHub repo  vanwidick/timeclock-sync
                                         Live is CLOSED          file timeclock-sync.json
                                                                 ▲
                         phone app (TimeClock Live Lite) ────────┘  GET/PUT via api.github.com (token stored only on the phone)
```

* Cloud store: a **private** GitHub repo, one file `timeclock-sync.json` = `{app, version, saved, by, punches}`. Only punches leave the PC
  (no profile, PTO, alerts.topic or sync topic). Every write is a commit, so history doubles as an audit log / backup.
* Merge: per date, 3-way against the last synced state (`src/merge.js` = `Merge-Punches3` in `pc/TimeClockSync.ps1`, shared vectors in
  `sync-test/vectors.json`). A day changed on one side wins verbatim; changed on both → union of new punches, removals (undo/edits) win, sorted by time.
  Optimistic concurrency with the file `sha` (409/422 → re-read and re-merge).
* Phone: syncs on open, on every punch/undo/import (0.8 s debounce), every 30 s while visible, and when back online.
* PC: every 20 s. TimeClockLive.ps1 reads timeclock-data.json **only at start-up** and rewrites it from memory on every punch, so phone punches are
  queued in the cloud and written into the file only when TimeClock Live is not running (`-FileWrite WhenClosed`, default). `-FileWrite Always`
  is only safe once TimeClockLive.ps1 re-reads the file when it changes on disk.

Tests: `node sync-test/merge_test.js`, `pwsh pc/merge_test.ps1`, `sync-test/pc_e2e.sh`, `python sync-test/phone_sync_test.py` (mock GitHub API).
