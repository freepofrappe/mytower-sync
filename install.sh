#!/bin/bash
# mytower-sync installer. Run on a Mac (or anything with adb) on the same Wi-Fi
# as the tablet. Only the install needs adb; afterwards the loop runs on the tablet
# alone. Nothing is typed on the tablet by hand.
#
#   ./install.sh            ask the questions, check the tablet, install, start the loop
#   ./install.sh --check    only connect and check; change nothing
#   ./install.sh --once     check, then one upload; leave nothing running
#   ./install.sh --yes      skip the questions and reuse the last answers
#
# Answers are kept in .install.conf beside this script (mode 600, ignored by
# git). Enter at any prompt keeps the previous answer.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HERE/.install.conf"
SYNC_SRC="$HERE/device/mytower_sync.sh"
BOOT_SRC="$HERE/device/boot_hook.sh"
PROBE_SRC="$HERE/device/probe.sh"

SD=/sdcard/Download
THOME=/data/data/com.termux/files/home
GAME=com.TechTreeGames.TheTower
EXPORT="/sdcard/Android/data/$GAME/files/tool_export.json"
SAVE="/sdcard/Android/data/$GAME/files/playerInfo.dat"
MYTOWER_URL=https://mytower.app/api/tower/ingest

MODE=install
YES=0
for a in "$@"; do
    case "$a" in
        --check) MODE=check ;;
        --once)  MODE=once ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $a"; exit 2 ;;
    esac
done

for f in "$SYNC_SRC" "$BOOT_SRC" "$PROBE_SRC"; do
    [ -f "$f" ] || { echo "missing $f (keep install.sh next to device/)"; exit 1; }
done
command -v adb >/dev/null 2>&1 || {
    echo "adb not found. Install Android platform-tools and put adb on your PATH."
    echo "  macOS: brew install --cask android-platform-tools"
    exit 1
}

# ---------------------------------------------------------------------------
# Questions. Defaults are whatever you answered last time.
DEVICE=""
MYTOWER_KEY=""
INTERVAL=1800
BOOT=y
[ -f "$CONF" ] && . "$CONF"

ask() {   # ask VAR "prompt" [secret]
    local var="$1" prompt="$2" secret="${3:-}" cur shown ans
    eval "cur=\${$var}"
    if [ "$YES" -eq 1 ] && [ -n "$cur" ]; then return; fi
    shown="$cur"
    if [ -n "$secret" ] && [ ${#cur} -gt 10 ]; then shown="${cur:0:6}...${cur: -4}"; fi
    if [ -n "$cur" ]; then
        read -r -p "$prompt [$shown]: " ans
    else
        read -r -p "$prompt: " ans
    fi
    [ -n "$ans" ] && eval "$var=\$ans"
    return 0
}

echo "mytower-sync installer ($MODE)"
echo
ask DEVICE      "Tablet adb address (ip:port, from Settings -> Wireless debugging)"
ask MYTOWER_KEY "mytower API key (from the Load save page)" secret
ask INTERVAL    "Seconds between upload checks"
ask BOOT        "Start automatically after a reboot? (y/n)"

case "$DEVICE" in
    '')  echo "need a device address"; exit 1 ;;
    *:*) ;;
    *)   DEVICE="$DEVICE:5555" ;;
esac
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=1800 ;; esac
[ "$INTERVAL" -lt 720 ] && { echo "interval raised to 720s: mytower allows 5 uploads/hour"; INTERVAL=720; }
case "$BOOT" in y|Y|yes) BOOT=y ;; *) BOOT=n ;; esac
case "$MYTOWER_KEY" in mt_*) ;; *) echo "note: mytower keys normally start with mt_" ;; esac

umask 077
{
    printf 'DEVICE=%q\n' "$DEVICE"
    printf 'MYTOWER_KEY=%q\n' "$MYTOWER_KEY"
    printf 'INTERVAL=%q\n' "$INTERVAL"
    printf 'BOOT=%q\n' "$BOOT"
} > "$CONF"
umask 022

# ---------------------------------------------------------------------------
# Helpers
A() { adb -s "$DEVICE" shell "$@" 2>/dev/null | tr -d '\r'; }
PASS=0; FAIL=0; WARN=0
ok()   { printf '  OK    %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf '  WARN  %s\n        -> %s\n' "$1" "$2"; WARN=$((WARN + 1)); }
fail() { printf '  FAIL  %s\n        -> %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
has_pkg() { A pm list packages "$1" | grep -qx "package:$1"; }

# adb shell input text goes through the device shell first, so it can carry no
# quotes, no > & ; |. Spaces become %s. Keep every typed line to plain paths.
type_line() {
    adb -s "$DEVICE" shell input text "$(printf '%s' "$1" | sed 's/ /%s/g')" >/dev/null 2>&1
    adb -s "$DEVICE" shell input keyevent 66 >/dev/null 2>&1
    sleep "${2:-2}"
}
launch() { adb -s "$DEVICE" shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }
wake()   { adb -s "$DEVICE" shell input keyevent 224 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
echo
echo "1. Connecting to $DEVICE"
adb connect "$DEVICE" >/dev/null 2>&1
if ! A echo ok | grep -q ok; then
    echo "  FAIL  cannot reach $DEVICE"
    echo "        -> On the tablet: Developer options -> Wireless debugging on."
    echo "        -> Plug in USB once and run: adb tcpip 5555   (it does not survive a reboot)"
    echo "        -> Mac and tablet must be on the same Wi-Fi. If the tablet runs a VPN"
    echo "           (e.g. Tailscale), connect to its VPN address instead of the Wi-Fi one."
    exit 1
fi
ok "adb reachable ($(A getprop ro.product.model) Android $(A getprop ro.build.version.release))"

echo
echo "2. Checking the tablet"

# The game and its export
if has_pkg "$GAME"; then
    ok "The Tower installed"
    if A "[ -f $EXPORT ] && echo yes" | grep -q yes; then
        esz="$(A stat -c %s "$EXPORT")"; emt="$(A stat -c %Y "$EXPORT")"; smt="$(A stat -c %Y "$SAVE")"
        if [ -n "$smt" ] && [ -n "$emt" ] && [ $((smt - emt)) -gt 3600 ]; then
            warn "tool_export.json exists but is $(( (smt - emt) / 60 )) min older than the save" \
                 "Auto Export may have been turned off. In the game: Settings -> Auto Export on, then play a round."
        else
            ok "tool_export.json present (${esz} bytes, same age as the save)"
        fi
    else
        fail "tool_export.json not found" \
             "In the game: Settings -> turn on Auto Export, then play until it saves once."
    fi
else
    fail "The Tower is not installed (package $GAME)" "Install it from the Play Store and sign in."
fi

# Termux
if has_pkg com.termux; then
    inst="$(A dumpsys package com.termux | grep -m1 installerPackageName | sed 's/.*=//')"
    case "$inst" in
        *vending*) warn "Termux is the Play Store build" \
                        "That build is abandoned and broken. Uninstall it and install Termux from F-Droid (f-droid.org)." ;;
        *) ok "Termux installed (${inst:-sideloaded/F-Droid})" ;;
    esac
    if A dumpsys package com.termux | grep 'android.permission.WRITE_EXTERNAL_STORAGE' | grep -q 'granted=true'; then
        ok "Termux storage permission granted"
    else
        fail "Termux has no storage permission" \
             "In Termux run: termux-setup-storage   and accept the popup. The installer moves files through /sdcard/Download."
    fi
else
    fail "Termux is not installed" \
         "Install F-Droid from f-droid.org, then Termux from F-Droid. Then in Termux: pkg install curl coreutils termux-api"
fi

if [ "$BOOT" = y ]; then
    if has_pkg com.termux.boot; then
        if A dumpsys package com.termux.boot | grep -q 'stopped=true'; then
            warn "Termux:Boot installed but never opened" \
                 "Open the Termux:Boot app once from the app drawer. It does not arm itself until then."
        else
            ok "Termux:Boot installed and armed"
        fi
    else
        fail "Termux:Boot is not installed" "Install Termux:Boot from F-Droid, then open it once."
    fi
fi

# Shizuku
if has_pkg moe.shizuku.privileged.api; then
    if A ps -A -o ARGS | grep -q '[s]hizuku_server'; then
        ok "Shizuku server running"
    else
        fail "Shizuku is installed but not running" \
             "Open Shizuku -> Start via Wireless debugging (pair it under Developer options). Enable 'Start on boot' in its settings."
    fi
else
    fail "Shizuku is not installed" \
         "Install Shizuku (Play Store), start it via Wireless debugging, and export rish to Termux (see README, step 3)."
fi

# mytower key, from here, with an empty body: 400 = key and route fine, costs no quota
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "Authorization: Bearer $MYTOWER_KEY" -H 'Content-Type: application/json' \
        --data-binary '' "$MYTOWER_URL" 2>/dev/null)" || code=curl_failed
case "$code" in
    400)     ok "mytower key accepted" ;;
    401|403) fail "mytower rejected the key (http=$code)" "Copy the key again from mytower.app -> Load save page. Rerun and paste it at the prompt." ;;
    404)     warn "mytower answers 404" "Uploads are switched off on their side right now, or the API moved. The loop will keep trying each cycle." ;;
    *)       warn "mytower probe got http=$code" "Check this machine's internet connection; the tablet's is checked separately." ;;
esac

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "$FAIL thing(s) to fix on the tablet before going on. Fix them and rerun ./install.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
echo
echo "3. Checking inside Termux (rish, tools)"
adb -s "$DEVICE" shell rm -f "$SD/mytower_probe.txt" >/dev/null 2>&1
adb -s "$DEVICE" push "$PROBE_SRC" "$SD/mytower_probe.sh" >/dev/null 2>&1
wake; launch com.termux; sleep 6
type_line "sh $SD/mytower_probe.sh" 3
PROBE="$(mktemp)"
got=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if adb -s "$DEVICE" pull "$SD/mytower_probe.txt" "$PROBE" >/dev/null 2>&1 && grep -q probe_time "$PROBE"; then got=1; break; fi
    sleep 2
done
pget() { grep "^$1=" "$PROBE" 2>/dev/null | head -1 | cut -d= -f2-; }

if [ "$got" -eq 0 ]; then
    fail "Termux did not run the probe" \
         "Either Termux has no storage permission (run termux-setup-storage in Termux) or the typed command did not land. Look at the tablet screen: Termux should be in front showing 'probe written'."
else
    for t in curl md5sum timeout base64 termux-wake-lock; do
        if [ "$(pget tool_$t)" = yes ]; then :; else
            fail "Termux is missing $t" "In Termux run: pkg install curl coreutils termux-api"
        fi
    done
    [ "$(pget tool_curl)" = yes ] && [ "$(pget tool_md5sum)" = yes ] && [ "$(pget tool_timeout)" = yes ] && ok "Termux tools present (curl, coreutils, termux-api)"
    if [ "$(pget rish_installed)" != yes ]; then
        fail "rish is not installed in Termux" \
             "In Shizuku: 'Use Shizuku in terminal apps' -> Export files -> Downloads. Then in Termux:
             cp ~/storage/downloads/rish \$PREFIX/bin/ ; cp ~/storage/downloads/rish_shizuku.dex \$PREFIX/bin/
             sed -i 's/PKG/com.termux/g' \$PREFIX/bin/rish ; chmod +x \$PREFIX/bin/rish"
    elif [ "$(pget rish_ok)" != yes ]; then
        fail "rish is installed but the Shizuku handshake failed (rc=$(pget rish_rc) $(pget rish_out))" \
             "Open Shizuku on the tablet, start it, and allow Termux when it asks. rc=124 means it hung: Shizuku server is not up."
    else
        ok "rish works (Shizuku handshake uid=2000)"
        eb="$(pget export_bytes_via_rish)"
        if [ "${eb:-0}" -gt 0 ] 2>/dev/null; then
            ok "rish can read tool_export.json (${eb} bytes)"
        else
            fail "rish cannot read tool_export.json" "Auto Export off, or Shizuku was started without adb (it must run as the shell user)."
        fi
    fi
fi
rm -f "$PROBE"

if [ "$FAIL" -gt 0 ]; then
    echo
    echo "$FAIL thing(s) to fix before going on. Fix them and rerun ./install.sh"
    launch "$GAME"
    exit 1
fi
if [ "$MODE" = check ]; then
    echo
    echo "All checks passed ($PASS ok, $WARN warnings). Nothing was changed. Run ./install.sh to install."
    launch "$GAME"
    exit 0
fi

# ---------------------------------------------------------------------------
echo
echo "4. Installing"
ENV_TMP="$(mktemp)"
{
    printf 'MYTOWER_URL=%s\n' "$MYTOWER_URL"
    printf 'MYTOWER_KEY=%s\n' "$MYTOWER_KEY"
    printf 'INTERVAL=%s\n' "$INTERVAL"
} > "$ENV_TMP"
START_TMP="$(mktemp)"
cat > "$START_TMP" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
cd "$HOME" || exit 1
nohup sh "$HOME/mytower_sync.sh" >/dev/null 2>&1 &
echo "mytower-sync started pid=$!"
EOF
adb -s "$DEVICE" push "$ENV_TMP"   "$SD/mytower_sync_env"   >/dev/null 2>&1
adb -s "$DEVICE" push "$SYNC_SRC"  "$SD/mytower_sync.sh"    >/dev/null 2>&1
adb -s "$DEVICE" push "$START_TMP" "$SD/mytower_sync_start.sh" >/dev/null 2>&1
adb -s "$DEVICE" push "$BOOT_SRC"  "$SD/mytower_boot.sh"    >/dev/null 2>&1
rm -f "$ENV_TMP" "$START_TMP"

before="$(A wc -l "$SD/mytower_sync.log" | awk '{print $1}')"
[ -n "$before" ] || before=0

type_line "cp -f $SD/mytower_sync_env $THOME/.mytower_sync_env"
type_line "chmod 600 $THOME/.mytower_sync_env"
type_line "cp -f $SD/mytower_sync.sh $THOME/mytower_sync.sh"
type_line "chmod 700 $THOME/mytower_sync.sh"
type_line "cp -f $SD/mytower_sync_start.sh $THOME/mytower_sync_start.sh"
type_line "chmod 700 $THOME/mytower_sync_start.sh"
echo "  files installed into Termux home"

if [ "$MODE" = once ]; then
    echo "  running one sync (a running loop, if any, is left alone)"
    type_line "sh $THOME/mytower_sync.sh --once" 2
else
    type_line "sh $THOME/mytower_sync.sh --stop" 3
    type_line "sh $THOME/mytower_sync_start.sh" 3
    echo "  loop started"
    if [ "$BOOT" = y ]; then
        type_line "mkdir -p $THOME/.termux/boot"
        type_line "cp -f $SD/mytower_boot.sh $THOME/.termux/boot/mytower_sync.sh"
        type_line "chmod 700 $THOME/.termux/boot/mytower_sync.sh"
        launch com.termux.boot; sleep 3
        echo "  reboot hook installed"
    fi
fi

echo
echo "5. Waiting for the first result"
RESULT=""
for i in $(seq 1 45); do
    sleep 2
    RESULT="$(A tail -n +$((before + 1)) "$SD/mytower_sync.log" | grep -E 'OK:|unchanged|deferred|FAILED|SKIPPED|REJECTED|AUTH|ENDPOINT|RATE|STAGE' | tail -1)"
    [ -n "$RESULT" ] && break
done
launch "$GAME"

echo
if [ -z "$RESULT" ]; then
    echo "No result after 90s. Log tail:"
    A tail -8 "$SD/mytower_sync.log"
    echo "Look at the tablet; Termux should show what happened. Rerun with --check to re-test."
    exit 1
fi
echo "  $RESULT"
case "$RESULT" in
    *"OK:"*|*unchanged*|*deferred*)
        echo
        if [ "$MODE" = once ]; then
            echo "Done. One upload went through; nothing is left running. Run ./install.sh to install the loop."
        else
            echo "Done. The tablet now uploads to mytower every ${INTERVAL}s when the export changes."
            [ "$BOOT" = y ] && echo "It restarts itself after a reboot (Termux:Boot)."
        fi
        echo "Log: adb -s $DEVICE shell tail -20 $SD/mytower_sync.log"
        exit 0 ;;
    *)
        echo
        echo "The upload failed; the line above says why. Fix it and rerun ./install.sh"
        exit 1 ;;
esac
