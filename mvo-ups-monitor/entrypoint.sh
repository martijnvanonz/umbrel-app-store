#!/bin/bash
set -u
mkdir -p /state 2>/dev/null
echo "[$(date '+%F %T')] ups-monitor started — open the app to configure the NUT server on the settings page."

# Web UI + widget server (status dashboard, settings form, four-stats JSON) on :8099.
python3 /app/server.py &

# Read the poll interval safely from the settings-page config (parsed, never sourced).
poll_interval(){
  local v=15 line
  if [ -f /state/config.env ]; then
    line=$(grep -E '^CHECK_INTERVAL=' /state/config.env 2>/dev/null | tail -1)
    line="${line#CHECK_INTERVAL=}"; line="${line%\"}"; line="${line#\"}"
    [[ "$line" =~ ^[0-9]+$ ]] && [ "$line" -ge 1 ] && v="$line"
  fi
  echo "$v"
}

# Monitor loop: run the shutdown watcher, then wait the configured interval.
while true; do
  /app/watch.sh
  sleep "$(poll_interval)"
done
