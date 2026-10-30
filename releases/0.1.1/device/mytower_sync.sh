#!/data/data/com.termux/files/usr/bin/sh
# mytower-sync: uploads The Tower's tool_export.json to mytower.app.
#
# Runs inside Termux on the tablet. Every INTERVAL seconds it copies the
# export out of the game's private folder (through Shizuku's rish, which runs
# as the shell user and so can read it), skips it if the bytes have not
# changed, and POSTs it to mytower.
#
#   mytower_sync.sh            run the loop (single instance)
#   mytower_sync.sh --once     one sync now, then exit; safe beside the loop
#   mytower_sync.sh --stop     stop a running loop
#   mytower_sync.sh --status   is it running, and the last log lines
#
# Settings come from ~/.mytower_sync_env, written by install.sh.

set -u

PREFIX=/data/data/com.termux/files/usr
export PREFIX
export PATH="$PREFIX/bin:/system/bin:/system/xbin"
export LD_LIBRARY_PATH="$PREFIX/lib"

HOME_DIR=/data/data/com.termux/files/home
ENV_FILE="$HOME_DIR/.mytower_sync_env"
LOG="$HOME_DIR/mytower_sync.log"
MIRROR=/sdcard/Download/mytower_sync.log      # same log, readable by adb
LOCK="$HOME_DIR/mytower_sync.lock"
TMP="$HOME_DIR/tmp"
LAST_MD5="$HOME_DIR/.mytower_sync_md5"
LAST_TIME="$HOME_DIR/.mytower_sync_time"

EXPORT=/sdcard/Android/data/com.TechTreeGames.TheTower/files/tool_export.json
STAGE=/sdcard/Download/mytower_export_stage.json
LOCAL="$TMP/tool_export.json"

# Defaults. The env file overrides any of them.
MYTOWER_URL=https://mytower.app/api/tower/ingest
MYTOWER_KEY=
INTERVAL=1800        # seconds between checks
MIN_GAP=600          # never two uploads closer than this (quota is 5/hour)
MAX_BYTES=5000000    # the API limit
RETRIES=3            # for transport errors and 5xx only; a 4xx is never retried
RETRY_DELAY=15
LOG_MAX=2097152
LOG_KEEP=524288
RISH="$PREFIX/bin/rish"
RISH_TIMEOUT=30

[ -f "$ENV_FILE" ] && . "$ENV_FILE"
mkdir -p "$TMP" 2>/dev/null

MIRROR_OK=0
( : >> "$MIRROR" ) 2>/dev/null && MIRROR_OK=1

log() {
    line="$(date '+%Y-%m-%d %H:%M:%S') [$$] $*"
    printf '%s\n' "$line" >> "$LOG"
    [ "$MIRROR_OK" -eq 1 ] && printf '%s\n' "$line" >> "$MIRROR" 2>/dev/null
    return 0
}

rotate() {
    for f in "$LOG" "$MIRROR"; do
        [ -f "$f" ] || continue
        sz="$(wc -c < "$f" 2>/dev/null || echo 0)"
        if [ "$sz" -gt "$LOG_MAX" ]; then
            tail -c "$LOG_KEEP" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
            rm -f "$f.tmp"
        fi
    done
}

# rish pumps stdin until end-of-file when stdout is not a terminal, so without
# </dev/null every call hangs and looks like a broken Shizuku. timeout guards
# a dead Shizuku server.
rish_run() {
    env -u LD_LIBRARY_PATH timeout "${RISH_TIMEOUT}s" "$RISH" -c "$1" < /dev/null 2>/dev/null
}

shizuku_ok() {
    out="$(rish_run id 2>&1)"
    case "$out" in *uid=2000*) return 0 ;; esac
    return 1
}

# Copies the export to shared storage as the shell user, then into $TMP.
stage_export() {
    rm -f "$LOCAL"
    rish_run "cp -f '$EXPORT' '$STAGE' && chmod 666 '$STAGE'" >/dev/null
    [ -r "$STAGE" ] && cp -f "$STAGE" "$LOCAL" 2>/dev/null
    if [ ! -s "$LOCAL" ]; then
        # Fallback: text-safe pipe through rish for devices where Termux
        # cannot read /sdcard/Download back.
        rish_run "base64 '$EXPORT'" | tr -d '\r\n ' | base64 -d > "$LOCAL" 2>/dev/null
    fi
    [ -s "$LOCAL" ] && return 0
    log "STAGE FAILED: cannot read $EXPORT (Shizuku not running, or Auto Export off in the game)"
    rm -f "$LOCAL"
    return 1
}

# Returns 0 sent, 1 failed, 2 deferred (nothing wrong; next cycle), 3 unchanged.
upload() {
    size="$(wc -c < "$LOCAL" 2>/dev/null || echo 0)"
    cur="$(md5sum "$LOCAL" | cut -d' ' -f1)"
    prev="$(cat "$LAST_MD5" 2>/dev/null)"
    if [ "$cur" = "$prev" ]; then
        log "unchanged (${size}b); nothing to send"
        return 3
    fi
    if [ "$size" -gt "$MAX_BYTES" ]; then
        log "SKIPPED: export too large (${size}b > ${MAX_BYTES}b)"
        return 1
    fi
    # The copy is not atomic. A torn file is a guaranteed 400; check the braces first.
    first="$(head -c 1 "$LOCAL")"
    last="$(tail -c 64 "$LOCAL" | tr -d ' \t\r\n' | tail -c 1)"
    if [ "$first" != "{" ] || [ "$last" != "}" ]; then
        log "SKIPPED: export looks torn (copied mid-write); next cycle re-copies it"
        return 1
    fi
    last_ts="$(cat "$LAST_TIME" 2>/dev/null)"
    now="$(date +%s)"
    case "$last_ts" in
        ''|*[!0-9]*) ;;
        *)  if [ $((now - last_ts)) -lt "$MIN_GAP" ]; then
                log "deferred: last upload $((now - last_ts))s ago (< ${MIN_GAP}s)"
                return 2
            fi ;;
    esac

    try=1
    while [ "$try" -le "$RETRIES" ]; do
        code="$(curl -sS --max-time 60 \
            -H "Authorization: Bearer $MYTOWER_KEY" \
            -H 'Content-Type: application/json' \
            --data-binary "@$LOCAL" \
            -D "$TMP/mt.hdr" -o "$TMP/mt.out" -w '%{http_code}' \
            "$MYTOWER_URL" 2>>"$LOG")" || code=curl_failed
        body="$(head -c 160 "$TMP/mt.out" 2>/dev/null | tr '\n' ' ')"
        retry_after="$(grep -i '^retry-after:' "$TMP/mt.hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' | head -1)"
        rm -f "$TMP/mt.hdr" "$TMP/mt.out"
        case "$code" in
            2*)
                echo "$cur" > "$LAST_MD5"
                echo "$now" > "$LAST_TIME"
                log "OK: ${size}b http=$code $body"
                return 0 ;;
            401|403)
                log "AUTH FAILURE http=$code $body (wrong key: rerun install.sh)"
                return 1 ;;
            400)
                log "REJECTED http=400 ${size}b $body"
                return 1 ;;
            404)
                log "ENDPOINT UNAVAILABLE http=404 $MYTOWER_URL (uploads switched off, or the API moved)"
                return 1 ;;
            429)
                log "RATE LIMITED http=429 retry-after=${retry_after:-?}s; next cycle will retry"
                return 2 ;;
        esac
        log "attempt $try/$RETRIES failed http=$code $body"
        [ "$try" -lt "$RETRIES" ] && sleep "$RETRY_DELAY"
        try=$((try + 1))
    done
    log "FAILED after $RETRIES attempts (${size}b)"
    return 1
}

sync_once() {
    stage_export || return 1
    upload
    rc=$?
    rm -f "$LOCAL"
    [ "$rc" -eq 1 ] && return 1
    return 0
}

# kill -0 alone is not enough: after a reboot PIDs restart low and a stale
# lock can match an unrelated process. Check the command line too.
pid_is_sync() {
    p="$1"
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q mytower_sync
}

# A plain "sleep N" returns early when the shell catches a signal (screen
# on/off, wake-lock churn). Sleep against a wall-clock deadline instead.
sleep_until() {
    target=$(( $(date +%s) + $1 ))
    while :; do
        now="$(date +%s)"
        [ "$now" -ge "$target" ] && break
        left=$(( target - now ))
        [ "$left" -gt 60 ] && left=60
        sleep "$left"
    done
}

case "${1:-}" in
    --once)
        [ -n "$MYTOWER_KEY" ] || { echo "no MYTOWER_KEY in $ENV_FILE"; exit 1; }
        log "one-shot sync requested"
        if sync_once; then echo "SYNC OK (see $MIRROR)"; exit 0
        else echo "SYNC FAILED (see $MIRROR)"; exit 1; fi ;;
    --stop)
        p="$(cat "$LOCK" 2>/dev/null)"
        if pid_is_sync "$p"; then
            kill "$p" 2>/dev/null; sleep 1
            kill -9 "$p" 2>/dev/null
            rm -f "$LOCK"
            echo "stopped pid=$p"
        else
            rm -f "$LOCK"
            echo "not running"
        fi
        exit 0 ;;
    --status)
        p="$(cat "$LOCK" 2>/dev/null)"
        if pid_is_sync "$p"; then echo "RUNNING pid=$p"; else echo "NOT RUNNING"; fi
        echo "interval=${INTERVAL}s url=$MYTOWER_URL key=$([ -n "$MYTOWER_KEY" ] && echo set || echo MISSING)"
        echo "last md5 sent: $(cat "$LAST_MD5" 2>/dev/null || echo none)"
        tail -5 "$LOG" 2>/dev/null
        exit 0 ;;
    '') ;;
    *)  echo "usage: mytower_sync.sh [--once|--stop|--status]"; exit 2 ;;
esac

# ---- the loop ----
p="$(cat "$LOCK" 2>/dev/null)"
if pid_is_sync "$p"; then
    echo "already running pid=$p"
    exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

termux-wake-lock 2>/dev/null
rotate
log "starting: interval=${INTERVAL}s key=$([ -n "$MYTOWER_KEY" ] && echo set || echo MISSING) mirror=$MIRROR_OK"
[ -n "$MYTOWER_KEY" ] || { log "no MYTOWER_KEY in $ENV_FILE; exiting"; exit 1; }

# Shizuku comes up some time after boot. Retry fast, then slowly; never exit.
tries=0
until shizuku_ok; do
    tries=$((tries + 1))
    [ "$tries" -eq 1 ] && log "waiting for Shizuku (rish handshake failed)"
    if [ "$tries" -le 8 ]; then sleep 20; else sleep 300; fi
done
[ "$tries" -gt 0 ] && log "Shizuku ready after $tries tries"

while :; do
    rotate
    sync_once
    sleep_until "$INTERVAL"
    # Shizuku can die mid-run (it does not survive a reboot on its own).
    shizuku_ok || log "Shizuku handshake failed; will retry next cycle"
done
