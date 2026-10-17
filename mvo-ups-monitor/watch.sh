#!/bin/bash
# UPS watcher — polls a remote NUT server (raw protocol) and shuts the host down
# before the UPS dies. Configuration comes from the in-app settings page.
set -u

STATE_DIR="${STATE_DIR:-/state}"
CONFIG="${STATE_DIR}/config.env"
OUTAGE_FLAG="${STATE_DIR}/on_battery.flag"
UNREACH_FILE="${STATE_DIR}/unreach_count"
LAST_SHUTDOWN="${STATE_DIR}/last_shutdown"
UNREACH_LIMIT=4   # consecutive unreachable polls during an outage before assuming the UPS is failing
mkdir -p "$STATE_DIR" 2>/dev/null

# Defaults (env can seed them; the settings page below overrides).
NUT_HOST="${NUT_HOST:-}"
NUT_PORT="${NUT_PORT:-3493}"
NUT_UPS="${NUT_UPS:-ups}"
SHUTDOWN_AT_PERCENT="${SHUTDOWN_AT_PERCENT:-}"
SHUTDOWN_AFTER_SECONDS="${SHUTDOWN_AFTER_SECONDS:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"

# Runtime config from the settings page. PARSED, never `source`d — a value can therefore
# never be executed as a shell command — and only whitelisted keys are accepted.
if [ -f "$CONFIG" ]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      NUT_HOST|NUT_PORT|NUT_UPS|SHUTDOWN_AT_PERCENT|SHUTDOWN_AFTER_SECONDS|CHECK_INTERVAL)
        _v="${_v%\"}"; _v="${_v#\"}"     # strip any surrounding quotes
        printf -v "$_k" '%s' "$_v"        # literal assignment, no eval
        ;;
    esac
  done < "$CONFIG"
fi

# Validate; fall back to safe defaults on garbage (defence in depth — server.py also validates).
[[ "$NUT_PORT" =~ ^[0-9]+$ ]] || NUT_PORT=3493
[[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || CHECK_INTERVAL=15
if [ -n "$SHUTDOWN_AT_PERCENT" ] && ! [[ "$SHUTDOWN_AT_PERCENT" =~ ^[0-9]+$ ]]; then
  echo "[$(date '+%F %T')] ups-monitor: WARNING: invalid SHUTDOWN_AT_PERCENT, ignoring"
  SHUTDOWN_AT_PERCENT=""
fi
if [ -n "$SHUTDOWN_AFTER_SECONDS" ] && ! [[ "$SHUTDOWN_AFTER_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "[$(date '+%F %T')] ups-monitor: WARNING: invalid SHUTDOWN_AFTER_SECONDS, ignoring"
  SHUTDOWN_AFTER_SECONDS=""
fi

log(){ echo "[$(date '+%F %T')] ups-monitor: $*"; }

nut_get(){
  local var="$1" line
  exec 3<>"/dev/tcp/${NUT_HOST}/${NUT_PORT}" 2>/dev/null || return 1
  printf 'GET VAR %s %s\nLOGOUT\n' "$NUT_UPS" "$var" >&3
  line=$(timeout 4 head -1 <&3 2>/dev/null)
  exec 3<&- 2>/dev/null
  case "$line" in
    VAR*\"*\"*) echo "$line" | sed -n 's/.*"\(.*\)".*/\1/p'; return 0 ;;
    *) return 1 ;;
  esac
}

do_shutdown(){
  # $1 = reason; recorded in /state/last_shutdown so it can be checked after the host is back.
  echo "$(date '+%F %T') $1" > "$LAST_SHUTDOWN" 2>/dev/null
  log "SHUTDOWN ($1) — powering off the host (nsenter into PID 1)"
  # `poweroff` first: it is what umbrelOS's own Shutdown button runs.
  if nsenter -t 1 -m -u -n -i poweroff 2>/dev/null; then log "ran: nsenter poweroff"
  elif nsenter -t 1 -m -u -n -i systemctl poweroff 2>/dev/null; then log "ran: nsenter systemctl poweroff"
  elif nsenter -t 1 -m -u -n -i /sbin/shutdown -h now "UPS: $1" 2>/dev/null; then log "ran: nsenter shutdown -h now"
  else log "ERROR: shutdown command failed"
  fi
}

evaluate(){
  local status charge reachable=1 count now start
  if [ -z "$NUT_HOST" ]; then
    log "NUT server not set — open the app and configure it on the settings page"
    return
  fi
  status=$(nut_get ups.status) || reachable=0

  # Unreachable: only act if we were already in an outage (then assume the UPS is dying).
  if [ "$reachable" -eq 0 ]; then
    if [ -f "$OUTAGE_FLAG" ]; then
      count=$(cat "$UNREACH_FILE" 2>/dev/null || echo 0)
      [[ "$count" =~ ^[0-9]+$ ]] || count=0
      count=$((count + 1)); echo "$count" > "$UNREACH_FILE"
      if [ "$count" -ge "$UNREACH_LIMIT" ]; then
        log "On battery and NUT unreachable for ${count} polls — assuming UPS is failing, shutting down"
        do_shutdown "On battery and NUT unreachable for ${count} polls"; exit 0
      fi
      log "On battery but NUT unreachable (${count}/${UNREACH_LIMIT})"
    else
      log "NUT server unreachable — no action"
    fi
    return
  fi

  # FSD: the NUT master has started its own shutdown — follow it at once.
  if echo "$status" | grep -qw "FSD"; then
    log "UPS reports Forced Shutdown (FSD) — shutting down"
    do_shutdown "UPS Forced Shutdown (FSD)"; exit 0
  fi

  if echo "$status" | grep -qw "OB"; then
    # The flag file holds the epoch time the outage started; old/garbage content is restarted.
    now=$(date +%s)
    start=$(cat "$OUTAGE_FLAG" 2>/dev/null)
    if ! [[ "$start" =~ ^[0-9]+$ ]] || [ "$start" -gt "$now" ]; then
      start="$now"; echo "$now" > "$OUTAGE_FLAG"
    fi
    echo 0 > "$UNREACH_FILE"
    charge=$(nut_get battery.charge) || charge=""
    if echo "$status" | grep -qw "LB"; then
      log "UPS reports Low Battery — shutting down"
      do_shutdown "UPS Low Battery (LB)"; exit 0
    fi
    if [ -n "$SHUTDOWN_AFTER_SECONDS" ] && [ "$SHUTDOWN_AFTER_SECONDS" -gt 0 ] && [ $((now - start)) -ge "$SHUTDOWN_AFTER_SECONDS" ]; then
      log "On battery for $((now - start))s >= ${SHUTDOWN_AFTER_SECONDS}s — shutting down"
      do_shutdown "On battery for $((now - start))s (limit ${SHUTDOWN_AFTER_SECONDS}s)"; exit 0
    fi
    if [ -n "$SHUTDOWN_AT_PERCENT" ] && [[ "$charge" =~ ^[0-9]+$ ]] && [ "$charge" -le "$SHUTDOWN_AT_PERCENT" ]; then
      log "On battery and charge ${charge}% <= ${SHUTDOWN_AT_PERCENT}% — shutting down"
      do_shutdown "On battery, charge ${charge}% <= ${SHUTDOWN_AT_PERCENT}%"; exit 0
    fi
    log "On battery $((now - start))s — charge ${charge:-?}%${SHUTDOWN_AT_PERCENT:+, shutdown at ${SHUTDOWN_AT_PERCENT}%}${SHUTDOWN_AFTER_SECONDS:+, shutdown after ${SHUTDOWN_AFTER_SECONDS}s}"
  else
    if [ -f "$OUTAGE_FLAG" ]; then
      log "Power restored (status=$status) — outage cleared"
      rm -f "$OUTAGE_FLAG" "$UNREACH_FILE"
    fi
  fi
}

evaluate
