# Changelog

## 0.1.0 (2026-10-30)

First version. Automatic upload of `tool_export.json` to mytower.app only.

- `install.sh`: interactive, remembers answers, checks the tablet on connect and prints
  the fix for anything missing, installs over adb, verifies the first upload.
- `device/mytower_sync.sh`: 30-minute loop, MD5 dedup, torn-file check, 10-minute
  spacing guard, 4xx never retried, log mirrored to `/sdcard/Download`.
- Reboot hook via Termux:Boot.

Not included (see the full tower-monitor project): Google Drive archive, status Sheet,
RustDesk/Tailscale watchdog, game-foreground enforcement.
