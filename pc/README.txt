TimeClock Sync v1.1.0 - PC companion for TimeClock Live (live two-way punch sync with the phone app)
====================================================================================================
Requires TimeClock Live v1.0.2 or newer (it reloads timeclock-data.json when the file changes).
Does NOT modify TimeClockLive.ps1. Only "punches" go to the cloud (private repo vanwidick/timeclock-sync);
profile, PTO, alerts.topic and the sync topic never leave this PC. Uses built-in Windows PowerShell 5.1, no admin.

1. Create a token (in a browser, signed in as vanwidick):
   https://github.com/settings/personal-access-tokens/new
   - Token name: TimeClock Sync PC      - Expiration: your choice (e.g. 1 year)
   - Repository access: Only select repositories -> vanwidick/timeclock-sync
   - Permissions -> Repository permissions -> Contents: Read and write   (Metadata: Read is added automatically)
   Make a SECOND token the same way for the phone ("TimeClock Sync Phone") so each can be revoked on its own.

2. Unzip this folder anywhere (e.g. Downloads\TimeClockSync), open PowerShell in it and run:
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TimeClockSync.ps1
   Paste the PC token when asked (input hidden). It is stored encrypted with Windows DPAPI in
   %LOCALAPPDATA%\TimeClockSync\token.dat (only your Windows user can decrypt it).
   The installer runs one test sync, then registers the Scheduled Task "TimeClock Sync" (starts hidden at logon,
   checks every 10 s) and starts it. Log: %LOCALAPPDATA%\TimeClockSync\sync-log.txt
   (Already installed v1.0.0? Just run the installer again - it replaces the script and the task.)

3. Phone: open https://vanwidick.github.io/timeclock-live-lite/ (from the Home Screen icon), scroll to
   "Cloud sync with PC", keep repo vanwidick/timeclock-sync, paste the PHONE token, tap "Connect & sync".

How it behaves
- Desktop punch -> cloud/phone within ~10 s (pushed when timeclock-data.json's LastWriteTime changes).
- Phone punch -> cloud right away -> written into timeclock-data.json within ~10 s, even while TimeClock Live is
  running; TimeClock Live reloads it within ~1 s.
- Only the "punches" value is changed; every other key is written back unchanged. The write is atomic
  (timeclock-data.json.lite.tmp in the same folder, then File.Replace); the previous file is kept as
  timeclock-data.json.bak, like TimeClock Live itself does. The file is re-read right before each write and any
  desktop change is merged first; only punches that were really deleted (undo/edit) are removed.
- At most 2 breaks a day are kept (a break started on both devices counts once).
- FYI: TimeClock Live ignores a PC click within 3 s of the day's newest punch (double-tap guard), which can include a
  punch that just arrived from the phone.
- Older TimeClock Live (< 1.0.2)? Reinstall with  -FileWrite WhenClosed  (phone punches then wait until it is closed).

Uninstall:  powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TimeClockSync.ps1 -Uninstall
Revoke a token any time at https://github.com/settings/personal-access-tokens
