# mytower-sync — notes for Claude

Minimal, shareable uploader: copies The Tower's `tool_export.json` out of the game's private
folder on an Android tablet (Termux + Shizuku/rish) every 30 minutes and POSTs it to
`https://mytower.app/api/tower/ingest` when it changed. `install.sh` runs on the Mac over adb.
README.md is the user-facing doc and is kept accurate for people who are not the author.

## Layout

- `install.sh` — Mac side. Four questions, answers cached in `.install.conf` (gitignored, mode 600,
  holds the API key). `--check`, `--once`, `--yes`.
- `device/mytower_sync.sh` — the tablet loop (`--once`, `--stop`, `--status`). Logs to
  `/sdcard/Download/mytower_sync.log`.
- `device/boot_hook.sh` — Termux:Boot restart. `device/probe.sh` — runs inside Termux, reports to
  `/sdcard/Download/mytower_probe.txt`.
- `releases/<ver>/` — frozen unzipped copies made by `release.sh`. Any `releases/*.zip` is hand-made
  for sharing.

## Conventions

- Version bump = `./release.sh <ver> "one line"`. It copies files, writes VERSION, commits, tags
  `v<ver>`. Add a CHANGELOG.md entry first. Never edit files under `releases/`.
- Never commit secrets. The only place the mytower key may live is `.install.conf`.
- Tablet-side filenames are deliberately distinct from the full tower-monitor project
  (`~/mytower_sync.sh`, `~/.mytower_sync_env`) so both can coexist on one tablet. Keep that.
- Quota is 5 uploads/hour/account shared with the browser. The loop must stay at <= 2/hour
  (MD5 dedup, 10-minute spacing guard, 4xx never retried). Do not loosen those.
- Nothing is ever typed on the tablet by hand; every tablet action goes through adb or the installer.

## Related

- The author's full personal system (Drive archive, status Sheet, watchdog) lives in a separate
  private repo, `tower-monitor`. Fixes proven there are ported here by hand. Nothing from it
  (keys, addresses, device names, real log lines) may appear in this repo.
