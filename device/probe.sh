#!/data/data/com.termux/files/usr/bin/sh
# Run inside Termux by install.sh. Answers the questions adb cannot answer
# from outside (Termux's home is private): is rish installed and working, are
# the tools there, can Termux write shared storage. Writes key=value lines.
OUT=/sdcard/Download/mytower_probe.txt
EXPORT=/sdcard/Android/data/com.TechTreeGames.TheTower/files/tool_export.json
RISH="$PREFIX/bin/rish"
{
    echo "probe_time=$(date +%s)"
    echo "storage=yes"
    if [ -x "$RISH" ]; then
        echo "rish_installed=yes"
        out="$(env -u LD_LIBRARY_PATH timeout 10s "$RISH" -c id < /dev/null 2>&1)"
        rc=$?
        echo "rish_rc=$rc"
        case "$out" in
            *uid=2000*) echo "rish_ok=yes" ;;
            *)          echo "rish_ok=no"; echo "rish_out=$(printf '%s' "$out" | head -c 160 | tr '\n' ' ')" ;;
        esac
        n="$(env -u LD_LIBRARY_PATH timeout 20s "$RISH" -c "wc -c < '$EXPORT'" < /dev/null 2>/dev/null | tr -d ' \r\n')"
        echo "export_bytes_via_rish=${n:-0}"
    else
        echo "rish_installed=no"
        echo "rish_ok=no"
    fi
    for t in curl md5sum timeout base64 termux-wake-lock; do
        if command -v "$t" >/dev/null 2>&1; then echo "tool_$t=yes"; else echo "tool_$t=no"; fi
    done
} > "$OUT" 2>&1
chmod 666 "$OUT" 2>/dev/null
echo "probe written"
