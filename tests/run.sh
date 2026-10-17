#!/bin/bash
# Tests for watch.sh (against a fake NUT server and a fake nsenter) and server.py.
# Never runs the real nsenter/poweroff: a fake `nsenter` is put first on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../mvo-ups-monitor"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS  $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# ---- fake binaries ----------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/nsenter" <<'SH'
#!/bin/bash
echo "$*" >> "$NSENTER_LOG"
[ "$*" = "${FAKE_NSENTER_FAIL:-}" ] && exit 1
exit 0
SH
chmod +x "$BIN/nsenter"
if ! command -v timeout >/dev/null; then   # macOS has no `timeout`
  printf '#!/bin/bash\nshift\nexec "$@"\n' > "$BIN/timeout"; chmod +x "$BIN/timeout"
fi

# ---- fake NUT server --------------------------------------------------------
free_port(){ python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
NUT_PORT="$(free_port)"; DEAD_PORT="$(free_port)"
VALUES="$TMP/values.json"
echo '{}' > "$VALUES"
python3 "$HERE/fake_nut.py" "$NUT_PORT" "$VALUES" &
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$NUT_PORT") 2>/dev/null && break; sleep 0.1; done

# ---- helpers ----------------------------------------------------------------
# new_case: fresh state dir + empty nsenter log
new_case(){
  S="$TMP/state"; rm -rf "$S"; mkdir -p "$S"
  export STATE_DIR="$S" NSENTER_LOG="$TMP/nsenter.log"
  : > "$NSENTER_LOG"
  unset FAKE_NSENTER_FAIL
  # fake host boot time: ~28h ago, so flags written during a test are "after boot"
  export PROC_STAT="$TMP/proc_stat"; printf 'cpu 1 2 3\nbtime %s\n' $(( $(date +%s) - 100000 )) > "$PROC_STAT"
}
set_nut(){ echo "$1" > "$VALUES"; }               # JSON
set_config(){ printf '%s\n' "$@" > "$S/config.env"; }  # KEY=value lines
poll(){ PATH="$BIN:$PATH" bash "$APP/watch.sh" >> "$TMP/watch.out" 2>&1; }
shut_count(){ wc -l < "$NSENTER_LOG" | tr -d ' '; }
expect_no_shutdown(){ [ "$(shut_count)" = 0 ] && ok "$1" || bad "$1 (nsenter was called: $(cat "$NSENTER_LOG"))"; }
expect_shutdown(){ [ "$(shut_count)" -ge 1 ] && [ -s "$S/last_shutdown" ] && ok "$1" || bad "$1 (nsenter calls: $(shut_count), last_shutdown: $(cat "$S/last_shutdown" 2>/dev/null))"; }
cfg(){ set_config "NUT_HOST=127.0.0.1" "NUT_PORT=$NUT_PORT" "NUT_UPS=ups" "$@"; }

echo "== watch.sh"

new_case; cfg "SHUTDOWN_AFTER_SECONDS=90" "SHUTDOWN_AT_PERCENT=20"
set_nut '{"ups.status":"OL CHRG","battery.charge":"100"}'; poll
expect_no_shutdown "OL: no action"

new_case; cfg "SHUTDOWN_AFTER_SECONDS=90"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll; poll
expect_no_shutdown "OB below SHUTDOWN_AFTER_SECONDS: no action"
grep -qE '^[0-9]+$' "$S/on_battery.flag" && ok "OB: flag file holds epoch time" || bad "OB: flag file holds epoch time"

new_case; cfg "SHUTDOWN_AFTER_SECONDS=90"
echo $(( $(date +%s) - 120 )) > "$S/on_battery.flag"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll
expect_shutdown "OB past SHUTDOWN_AFTER_SECONDS (back-dated flag): shutdown"
grep -q "limit 90s" "$S/last_shutdown" && ok "last_shutdown names the reason" || bad "last_shutdown names the reason"

new_case; cfg
echo $(( $(date +%s) - 9999 )) > "$S/on_battery.flag"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll
expect_no_shutdown "OB long outage but SHUTDOWN_AFTER_SECONDS unset: no action"

new_case; cfg "SHUTDOWN_AFTER_SECONDS=90"
: > "$S/on_battery.flag"     # old format: empty flag
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll
expect_no_shutdown "OB with old empty flag: restarted, no action"
grep -qE '^[0-9]+$' "$S/on_battery.flag" && ok "old empty flag rewritten with epoch time" || bad "old empty flag rewritten with epoch time"
echo "garbage" > "$S/on_battery.flag"; poll
grep -qE '^[0-9]+$' "$S/on_battery.flag" && ok "garbage flag rewritten with epoch time" || bad "garbage flag rewritten with epoch time"

new_case; cfg
set_nut '{"ups.status":"OB DISCHRG LB","battery.charge":"60"}'; poll
expect_shutdown "OB + LB: shutdown"

new_case; cfg
set_nut '{"ups.status":"OL FSD","battery.charge":"60"}'; poll
expect_shutdown "FSD: shutdown"
grep -q FSD "$S/last_shutdown" && ok "FSD reason recorded" || bad "FSD reason recorded"

new_case; cfg "SHUTDOWN_AT_PERCENT=30"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"31"}'; poll
expect_no_shutdown "OB charge above percent: no action"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"30"}'; poll
expect_shutdown "OB + charge <= percent: shutdown"

new_case; cfg
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll
set_config "NUT_HOST=127.0.0.1" "NUT_PORT=$DEAD_PORT" "NUT_UPS=ups"
poll; poll; poll
expect_no_shutdown "OB then NUT unreachable 3 polls: no action yet"
poll
expect_shutdown "OB then NUT unreachable 4 polls: shutdown"

new_case; set_config "NUT_HOST=127.0.0.1" "NUT_PORT=$DEAD_PORT" "NUT_UPS=ups"
poll; poll; poll; poll; poll
expect_no_shutdown "NUT unreachable while OL: no action"

new_case; cfg
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll
[ -f "$S/on_battery.flag" ] && ok "OB creates flag" || bad "OB creates flag"
set_nut '{"ups.status":"OL CHRG","battery.charge":"95"}'; poll
[ ! -f "$S/on_battery.flag" ] && ok "OB then OL clears flag" || bad "OB then OL clears flag"

new_case; set_config "NUT_HOST=127.0.0.1" "NUT_PORT=$NUT_PORT" "NUT_UPS=ups" "SHUTDOWN_AT_PERCENT=abc" "SHUTDOWN_AFTER_SECONDS=\$(touch $TMP/pwned)" "CHECK_INTERVAL=x" "EVIL=1"
echo $(( $(date +%s) - 9999 )) > "$S/on_battery.flag"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"5"}'; poll
expect_no_shutdown "garbage config values are ignored (no shutdown, not executed)"
[ ! -e "$TMP/pwned" ] && ok "config value never executed" || bad "config value never executed"

new_case; cfg
set_nut '{"ups.status":"OB DISCHRG LB"}'; poll
[ "$(head -1 "$NSENTER_LOG")" = "-t 1 -m -u -n -i poweroff" ] && [ "$(shut_count)" = 1 ] \
  && ok "poweroff is the first (and only needed) command" || bad "poweroff first: $(cat "$NSENTER_LOG")"

new_case; cfg
export FAKE_NSENTER_FAIL="-t 1 -m -u -n -i poweroff"
set_nut '{"ups.status":"OB DISCHRG LB"}'; poll
[ "$(sed -n 2p "$NSENTER_LOG")" = "-t 1 -m -u -n -i systemctl poweroff" ] && ok "fallback: systemctl poweroff second" || bad "fallback second: $(cat "$NSENTER_LOG")"

new_case; cfg
cat > "$BIN/nsenter" <<'SH'
#!/bin/bash
echo "$*" >> "$NSENTER_LOG"
case "$*" in *shutdown*) exit 0 ;; *) exit 1 ;; esac
SH
set_nut '{"ups.status":"OB DISCHRG LB"}'; poll
[ "$(sed -n 3p "$NSENTER_LOG")" = "-t 1 -m -u -n -i /sbin/shutdown -h now UPS: UPS Low Battery (LB)" ] && ok "fallback: shutdown -h now third" || bad "fallback third: $(cat "$NSENTER_LOG")"
grep -q "ran: nsenter shutdown" "$TMP/watch.out" && ok "log says which command ran" || bad "log says which command ran"

echo "== stale outage flag (reboot loop)"
BTIME="$(( $(date +%s) - 3600 ))"     # host booted 1h ago
set_btime(){ printf 'cpu 1 2 3\nbtime %s\n' "$BTIME" > "$PROC_STAT"; }
unreach_polls(){ set_config "NUT_HOST=127.0.0.1" "NUT_PORT=$DEAD_PORT" "NUT_UPS=ups" "$@"; poll; poll; poll; poll; poll; }

new_case; set_btime; echo $(( BTIME - 600 )) > "$S/on_battery.flag"; unreach_polls
expect_no_shutdown "flag older than boot + NUT unreachable: no shutdown"
[ ! -e "$S/on_battery.flag" ] && ok "stale flag removed" || bad "stale flag removed"
grep -q "stale outage flag from before last boot — cleared" "$TMP/watch.out" && ok "stale flag logged" || bad "stale flag logged"

new_case; set_btime; echo $(( BTIME + 600 )) > "$S/on_battery.flag"; unreach_polls
expect_shutdown "flag newer than boot + NUT unreachable 4 polls: shutdown (kept)"

new_case; cfg "SHUTDOWN_AFTER_SECONDS=90"; set_btime; echo $(( BTIME - 600 )) > "$S/on_battery.flag"
set_nut '{"ups.status":"OB DISCHRG","battery.charge":"95"}'; poll
expect_no_shutdown "flag older than boot + OB: no timer shutdown"
[ "$(cat "$S/on_battery.flag")" -ge $(( $(date +%s) - 10 )) ] && ok "flag rewritten with current time" || bad "flag rewritten: $(cat "$S/on_battery.flag")"

new_case; rm -f "$PROC_STAT"; echo $(( BTIME - 600 )) > "$S/on_battery.flag"; unreach_polls
expect_shutdown "PROC_STAT unreadable: old behaviour (shutdown), flag not cleared"
grep -q "cannot read boot time" "$TMP/watch.out" && ok "unreadable boot time warns" || bad "unreadable boot time warns"

new_case; set_btime; : > "$S/on_battery.flag"; unreach_polls
expect_no_shutdown "empty flag + NUT unreachable: no shutdown"
[ ! -e "$S/on_battery.flag" ] && ok "empty flag removed" || bad "empty flag removed"
new_case; set_btime; echo garbage > "$S/on_battery.flag"; unreach_polls
expect_no_shutdown "garbage flag + NUT unreachable: no shutdown"
[ ! -e "$S/on_battery.flag" ] && ok "garbage flag removed" || bad "garbage flag removed"

# ---- shell syntax / lint ----------------------------------------------------
echo "== static checks"
for f in "$APP/watch.sh" "$APP/entrypoint.sh" "$HERE/run.sh"; do
  bash -n "$f" && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"
done
if command -v shellcheck >/dev/null; then
  shellcheck "$APP/watch.sh" "$APP/entrypoint.sh" && ok "shellcheck watch.sh entrypoint.sh" || bad "shellcheck"
else echo "  SKIP  shellcheck not installed"; fi
python3 -m py_compile "$APP/server.py" && ok "py_compile server.py" || bad "py_compile server.py"
rm -rf "$APP/__pycache__"

# ---- server.py --------------------------------------------------------------
echo "== server.py"
SPORT="$(free_port)"; SSTATE="$TMP/srvstate"; mkdir -p "$SSTATE"
echo "2026-01-01 00:00:00 <b>test</b> reason" > "$SSTATE/last_shutdown"
# Point the module at a temp state dir and free port without editing the source.
python3 -I -c "
import sys, os
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import server
server.STATE_DIR = sys.argv[2]
server.CONFIG = os.path.join(sys.argv[2], 'config.env')
server.LAST_SHUTDOWN = os.path.join(sys.argv[2], 'last_shutdown')
server.PORT = int(sys.argv[3])
server.DualStackServer(('', server.PORT), server.Handler).serve_forever()
" "$APP" "$SSTATE" "$SPORT" &
for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$SPORT") 2>/dev/null && break; sleep 0.1; done
CODE="$(curl -s -o "$TMP/page.html" -w '%{http_code}' "http://127.0.0.1:$SPORT/")"
[ "$CODE" = 200 ] && ok "GET / returns 200" || bad "GET / returned $CODE"
grep -q 'SHUTDOWN_AFTER_SECONDS' "$TMP/page.html" && grep -q 'placeholder="90"' "$TMP/page.html" && ok "settings page has SHUTDOWN_AFTER_SECONDS (placeholder 90)" || bad "SHUTDOWN_AFTER_SECONDS field missing"
grep -q 'value="90"' "$TMP/page.html" && bad "90 must be a placeholder, not a prefilled value" || ok "SHUTDOWN_AFTER_SECONDS not prefilled (off by default)"
grep -q '&lt;b&gt;test&lt;/b&gt; reason' "$TMP/page.html" && ok "last_shutdown shown, html-escaped" || bad "last_shutdown not shown escaped"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '_csrf=wrong&NUT_HOST=x' "http://127.0.0.1:$SPORT/save")"
[ "$CODE" = 403 ] && ok "POST with wrong CSRF token returns 403" || bad "POST wrong CSRF returned $CODE"
TOKEN="$(sed -n 's/.*name="_csrf" value="\([0-9a-f]*\)".*/\1/p' "$TMP/page.html")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "_csrf=$TOKEN&NUT_HOST=nas.local&SHUTDOWN_AFTER_SECONDS=120" "http://127.0.0.1:$SPORT/save")"
[ "$CODE" = 303 ] && grep -q '^SHUTDOWN_AFTER_SECONDS=120$' "$SSTATE/config.env" && ok "valid POST saves SHUTDOWN_AFTER_SECONDS" || bad "valid POST: $CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d "_csrf=$TOKEN&NUT_HOST=nas.local&SHUTDOWN_AFTER_SECONDS=12x" "http://127.0.0.1:$SPORT/save")"
[ "$CODE" = 200 ] && grep -q '^SHUTDOWN_AFTER_SECONDS=120$' "$SSTATE/config.env" && ok "invalid SHUTDOWN_AFTER_SECONDS rejected" || bad "invalid value: $CODE"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
