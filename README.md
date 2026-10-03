# TimeClock Live Lite

Phone-friendly PWA time clock for Van (Central time). Single self-contained `index.html` (Oswald Bold subset embedded), `manifest.webmanifest`, `sw.js` (offline).

* Punches stored in `localStorage["punches"]` as `{"yyyy-MM-dd":[["in"|"out"|"bs"|"be"|"lo"|"li", secondsAfterMidnight], ...]}` — same as TimeClock Live.
* Export/Import `timeclock-data.json` (`app`, `version`, `saved`, `punches`, `days`).
* Worked time = clock in → clock out minus unpaid lunch / off-the-clock gaps (15-min breaks paid), same rules as the desktop app.
* Pay periods: biweekly from 2026-09-26.

Edit `src/index.src.html`, then run `./build.sh` to regenerate `index.html`. Tests: `test/test.py` (Playwright + Chrome).
