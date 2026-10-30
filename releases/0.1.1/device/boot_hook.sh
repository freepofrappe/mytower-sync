#!/data/data/com.termux/files/usr/bin/sh
# Installed to ~/.termux/boot/mytower_sync.sh by install.sh.
# Termux:Boot runs it after every reboot. Shizuku may not be up yet; the sync
# script keeps retrying the handshake, so a short delay is enough.
termux-wake-lock
sleep 20
nohup /data/data/com.termux/files/home/mytower_sync.sh >/dev/null 2>&1 &
