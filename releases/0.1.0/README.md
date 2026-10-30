# mytower-sync

Automatic upload of The Tower's save to [mytower.app](https://mytower.app) from an Android
tablet, with no typing on the tablet. A small script in Termux copies the game's
`tool_export.json` out of its private folder every 30 minutes (through Shizuku) and POSTs
it to mytower when it has changed. `install.sh` on your Mac checks the tablet, installs
it, and tells you exactly what is missing if something is not ready.

## Files

| File | Where it runs | What |
| --- | --- | --- |
| `install.sh` | Mac | Asks four questions, checks the tablet, installs, starts. Remembers your answers. |
| `device/mytower_sync.sh` | Tablet (Termux) | The loop. `--once`, `--stop`, `--status`. |
| `device/boot_hook.sh` | Tablet (Termux:Boot) | Restarts the loop after a reboot. |
| `device/probe.sh` | Tablet (Termux) | Used by the installer to look inside Termux. |
| `releases/` | | Frozen copies of each version, unzipped. `release.sh` makes them. |

## One-time tablet preparation

The installer checks every one of these and prints the fix for whatever is missing, so
you can also just run `./install.sh --check` and follow the output.

1. **Developer options**: Settings → About → tap Build number 7 times. Then in Developer
   options turn on **Wireless debugging** and **Disable child process restrictions**.
   Screen lock → None (the loop cannot unlock the tablet after a reboot).
2. **Termux** from F-Droid (not the Play Store), plus **Termux:Boot** from F-Droid. Open
   Termux:Boot once. In Termux run:
   ```
   pkg install curl coreutils termux-api
   termux-setup-storage
   ```
3. **Shizuku** from the Play Store. Start it via Wireless debugging, turn on *Start on boot*
   in its settings. Then *Use Shizuku in terminal apps* → *Export files* → Downloads, and
   in Termux:
   ```
   cp ~/storage/downloads/rish $PREFIX/bin/
   cp ~/storage/downloads/rish_shizuku.dex $PREFIX/bin/
   sed -i 's/PKG/com.termux/g' $PREFIX/bin/rish
   chmod +x $PREFIX/bin/rish
   rish -c id < /dev/null        # must print uid=2000(shell); allow Termux in the Shizuku popup
   ```
4. **The Tower**: Settings → **Auto Export** on. Play until it saves once.
5. **adb over Wi-Fi**: plug in USB once and run `adb tcpip 5555` on the Mac. Prefer the
   tablet's Tailscale address if you have one. This step repeats after every reboot.
6. **mytower API key**: mytower.app → Load save page → create a key (`mt_...`).

## Install

```
./install.sh
```

Four questions, each with a default in brackets. Enter keeps it. On a rerun the defaults
are your previous answers, so `./install.sh --yes` repeats the last install with no questions.

```
Tablet adb address (ip:port, use the Tailscale IP if you have one) [100.x.y.z:5555]:
mytower API key (from the Load save page) [mt_abc...xyz]:
Seconds between upload checks [1800]:
Start automatically after a reboot? (y/n) [y]:
```

Then it connects and checks: adb, the game and its export, Termux and its storage
permission, Termux:Boot, Shizuku, the key (an empty-body probe, which costs no quota),
and, by running a probe inside Termux, rish and the tools. Every failure comes with the
command or setting that fixes it. When all pass it installs, starts the loop, waits for the
first upload and shows the result, then puts the game back in front.

Other modes:

```
./install.sh --check     connect and check only, change nothing
./install.sh --once      check, then one upload, leave nothing running
```

## Watching it

```
adb shell tail -20 /sdcard/Download/mytower_sync.log
```

| Log line | Meaning |
| --- | --- |
| `OK: 3f2a9c1 http=200 {"ok":true,"version":1234,...}` | Uploaded. `version` goes up by one each time. |
| `unchanged (...); nothing to send` | Export identical to the last one sent. Normal when the game is idle. |
| `deferred: ...` | Quota or the 10-minute spacing guard. Next cycle retries. |
| `STAGE FAILED` | Shizuku is down or Auto Export is off. |
| `REJECTED http=400` | Torn copy, or the game changed its format. One-off is fine. |
| `AUTH FAILURE http=401` | Wrong key. Rerun `./install.sh` with the right one. |
| `RATE LIMITED http=429` | 5 uploads this hour (the loop uses at most 2; the rest were yours). |

On the tablet, in Termux: `sh ~/mytower_sync.sh --status`, `--once`, `--stop`.

## Quota

mytower allows 5 uploads per hour per account, shared with your browser. The loop sends
only when the export changed and never closer than 10 minutes apart, so it uses at most
2 per hour. Rejected uploads do not count.

## Uninstall

In Termux: `sh ~/mytower_sync.sh --stop`, then
`rm -f ~/mytower_sync.sh ~/mytower_sync_start.sh ~/.mytower_sync_env ~/.termux/boot/mytower_sync.sh`.

## Versions

Git tracks changes. `./release.sh 0.2.0 "what changed"` copies the current files into
`releases/0.2.0/`, commits and tags. See `CHANGELOG.md`.
