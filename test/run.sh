#!/usr/bin/env bash
# test/run.sh - test nb-prober against a test double of curl
#
# Usage:
#   test/run.sh
#   test/run.sh -h | --help
#
# No network and no real token is involved: test/shim/curl answers what nb-prober asks of Evolution
# and of the monitored targets from files, and logs what it was asked. Needs bash and jq.
# Exits 0 if every check passes, 1 otherwise.

# SC2016: single-quoted snippets below are meant to expand in the child shell.
# shellcheck disable=SC2016
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^$/{/^$/!p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

here=$(cd "$(dirname "$0")" && pwd)
NBP="$here/../bin/nb-prober"
work=$(mktemp -d "${TMPDIR:-/tmp}/nb-prober-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
export PATH="$here/shim:$PATH"
export SHIM_DIR="$work/shim"
export NB_PROBER_STATE_DIR="$work/state"
export NB_PROBER_KEY="nbp_probe1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
export NB_PROBER_RETRY_WAIT=0
export NB_ASSURANCE_BASE_URL="http://evolution.test"
unset NB_PROBER_TOKEN NB_TOKEN NB_PROBER_NAME NB_ACTIVE_ORGANIZATION_ID
cd "$work" || exit 1

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# run_nbp <args...>: run nb-prober; sets $out (stdout and stderr) and $rc.
run_nbp() { out=$("$NBP" "$@" 2>&1); rc=$?; }
has()    { printf '%s' "$out" | grep -qF -- "$1"; }
hasnt()  { ! has "$1"; }
rc_is()  { [ "$rc" -eq "$1" ]; }
check() { # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name" "rc=$rc out=$(printf '%s' "$out" | head -4 | tr '\n' '|')"; fi
}
reset_shim() { rm -rf "$SHIM_DIR" "$NB_PROBER_STATE_DIR"; mkdir -p "$SHIM_DIR/target"; }
requests() { cat "$SHIM_DIR/requests.log" 2>/dev/null; }
posts()    { find "$SHIM_DIR/posts" -type f 2>/dev/null | wc -l | tr -d ' '; }
count_req() { requests | grep -c -- "$1" || true; }
# target <url> <status> <seconds> [exit] [body]: what a monitored URL answers (status 000 = no answer)
target() { printf 'status=%s\ntime=%s\nexit=%s\nbody=%s\n' "$2" "$3" "${4:-0}" "${5:-hello}" > "$SHIM_DIR/target/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
# monitors <json-array-body>: what Evolution lists
monitors() { printf '{"success":true,"data":{"data":%s,"total":0,"limit":20}}' "$1" > "$SHIM_DIR/monitors.json"; }
M1='{"id":"m1","name":"Intranet","url":"http://intra.test/health","method":"GET","interval_minutes":5,"timeout_ms":10000,"expected_status":null,"keyword":null,"enabled":true,"state":"up"}'
M2='{"id":"m2","name":"Wiki","url":"http://wiki.test/","method":"HEAD","interval_minutes":5,"timeout_ms":10000,"expected_status":204,"keyword":null,"enabled":true,"state":"pending"}'
M3='{"id":"m3","name":"Off","url":"http://off.test/","method":"GET","interval_minutes":5,"timeout_ms":10000,"expected_status":null,"keyword":null,"enabled":false,"state":"pending"}'
M4='{"id":"m4","name":"Keyword","url":"http://kw.test/","method":"GET","interval_minutes":5,"timeout_ms":3000,"expected_status":null,"keyword":"all systems go","enabled":true,"state":"pending"}'

echo "usage"
run_nbp -h
check "-h exits 0 and names the tool" rc_is 0
check "-h has the shared layout (description line, Commands, Options)" has "📡 NASEBANAL Prober - check services on a private network"
check "-h lists run, list, check, doctor, --install" has "--install [DIR]"
run_nbp
check "no command shows the usage and exits 1" rc_is 1
check "the usage says it also runs as nb prober" has "Also runs as: nb prober"
out=$(NB_PLUGIN_NAME="nb prober" "$NBP" -h 2>&1); rc=$?
check "run through nb, the name shown is nb prober" has "Usage: nb prober <command>"
check "run through nb, the Also runs as line is dropped" hasnt "Also runs as"
run_nbp --version
check "--version" has "nb-prober 0."
run_nbp bogus
check "an unknown command shows the usage and exits 1" rc_is 1
run_nbp run --bogus
check "an unknown option shows the usage and exits 1" rc_is 1
run_nbp run -h
check "-h after a command shows the help" has "NASEBANAL Prober"

echo "install"
inst="$work/bin"
run_nbp --install "$inst"
check "--install links nb-prober into DIR" test -L "$inst/nb-prober"
check "--install says where it linked" has "Linked"
run_nbp --install "$inst"
check "--install twice is a no-op" has "Already linked"
rm "$inst/nb-prober"; echo foreign > "$inst/nb-prober"
run_nbp --install "$inst"
check "--install refuses to replace a file it did not make" rc_is 1
check "--install explains the refusal" has "already exists"
run_nbp --install "$inst" "$work/other"
check "--install with two directories shows the usage" rc_is 1

echo "check"
reset_shim
target http://a.test/ 200 0.123
run_nbp check http://a.test/
check "check: an ok target exits 0" rc_is 0
check "check: prints ok, status and milliseconds as JSON" has '"ok":true,"status_code":200,"response_ms":123'
check "check: error is null when ok" has '"error":null'
target http://a.test/ 302 0.010
run_nbp check http://a.test/
check "check: with no expected status a 3xx is ok" rc_is 0
target http://a.test/ 404 0.010
run_nbp check http://a.test/
check "check: a 4xx is unexpected_status, exit 1" has '"error":"unexpected_status"'
check "check: the status is kept on unexpected_status" has '"status_code":404'
run_nbp check http://a.test/ --expect-status 404
check "check: --expect-status makes that status ok" rc_is 0
target http://a.test/ 200 0.010 0 "welcome home"
run_nbp check http://a.test/ --expect-status 204
check "check: --expect-status other than the answer fails" has '"error":"unexpected_status"'
run_nbp check http://a.test/ --keyword "welcome"
check "check: a keyword in the body is ok" rc_is 0
run_nbp check http://a.test/ --keyword "goodbye"
check "check: a missing keyword is keyword_not_found" has '"error":"keyword_not_found"'
run_nbp check http://a.test/ --keyword "goodbye" --method HEAD
check "check: a keyword is ignored for HEAD (as Evolution does)" rc_is 0
check "check: HEAD sends a HEAD request" test "$(count_req 'HEAD http://a.test/')" -ge 1
target http://a.test/ 000 10.0 28
run_nbp check http://a.test/
check "check: curl exit 28 is timeout" has '"error":"timeout"'
check "check: a timeout has no status code" has '"status_code":null'
check "check: a timeout reports the total time" has '"response_ms":10000'
target http://a.test/ 000 0.004 7
run_nbp check http://a.test/
check "check: curl exit 7 is connection_failed" has '"error":"connection_failed"'
target http://a.test/ 200 0.050 63 "big"
run_nbp check http://a.test/
check "check: a body cut at 1 MiB (curl exit 63) is not an error" rc_is 0
run_nbp check http://nowhere.test/
check "check: an unreachable URL is connection_failed" has '"error":"connection_failed"'
check "check: a failed check is repeated once (two requests)" test "$(count_req 'GET http://nowhere.test/')" -eq 2
run_nbp check http://a.test/ --method POST
check "check: --method accepts GET and HEAD only" rc_is 1
run_nbp check http://a.test/ --expect-status 20
check "check: --expect-status must be three digits" has "three-digit"
run_nbp check http://a.test/ --timeout-ms abc
check "check: --timeout-ms must be a number" has "milliseconds"
run_nbp check
check "check without a URL shows the usage" rc_is 1

echo "run"
reset_shim
monitors "[$M1,$M2,$M3,$M4]"
target http://intra.test/health 200 0.050
target http://wiki.test/ 204 0.100
target http://kw.test/ 200 0.020 0 "all systems go"
run_nbp run --once
check "run --once exits 0" rc_is 0
check "run: one POST per enabled monitor" test "$(posts)" -eq 3
check "run: the disabled monitor is not checked" hasnt "Off"
check "run: asked for the probe's own monitors" test "$(count_req 'GET http://evolution.test/api/v1/probe/monitors')" -ge 1
check "run: reported to the monitor's own path" test "$(count_req 'POST http://evolution.test/api/v1/probe/monitors/m1/results')" -eq 1
check "run: the monitor's own method is used (HEAD for Wiki)" test "$(count_req 'HEAD http://wiki.test/')" -eq 1
check "run: the monitor's expected status is used (204 is ok)" jq -e -s 'map(.results[0]) | any(.response_ms == 100 and .ok == true and .status_code == 204)' "$SHIM_DIR"/posts/*.json >/dev/null
check "run: the monitor's keyword is used" jq -e -s 'map(.results[0]) | any(.response_ms == 20 and .ok == true)' "$SHIM_DIR"/posts/*.json >/dev/null
check "run: the report has the contract's fields" jq -e '.results[0] | has("checked_at") and .ok == true and .response_ms == 50 and .status_code == 200 and .error == null' "$SHIM_DIR/posts/1.json" >/dev/null
check "run: checked_at is UTC ISO 8601" bash -c 'jq -r ".results[0].checked_at" "$1" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"' _ "$SHIM_DIR/posts/1.json"
check "run: the buffer is empty after a successful report" test ! -s "$NB_PROBER_STATE_DIR/probe1/buffer/m1.jsonl"
check "run: the key arrived on stdin" test -s "$SHIM_DIR/auth.log"
check "run: the args log is not empty (so the next check means something)" test -s "$SHIM_DIR/args.log"
check "run: the key is not in any command line" bash -c '! grep -q "$NB_PROBER_KEY" "$1"' _ "$SHIM_DIR/args.log"
check "run: the version is sent with every request" bash -c 'grep -q "^0\." "$1"' _ "$SHIM_DIR/version.log"
check "run: the user agent names the prober" bash -c 'grep -q "NASEBANAL-Prober/" "$1"' _ "$SHIM_DIR/args.log"
run_nbp run --once
check "run: a monitor not yet due is not checked again" test "$(posts)" -eq 3

echo "settings follow Evolution"
reset_shim
monitors "[$M1]"
target http://intra.test/health 503 0.050
run_nbp run --once
check "a 503 is down with unexpected_status" jq -e '.results[0].ok == false and .results[0].error == "unexpected_status" and .results[0].status_code == 503' "$SHIM_DIR/posts/1.json" >/dev/null
check "a failed check is repeated once, and shown as DOWN" bash -c '[ "$(grep -c "GET http://intra.test/health" "$1/requests.log")" = 2 ] && grep -q DOWN <<< "$2"' _ "$SHIM_DIR" "$out"
# the owner now accepts 503 on the monitor's screen: the next pass uses it
monitors "[$(printf '%s' "$M1" | jq -c '.expected_status = 503')]"
rm "$NB_PROBER_STATE_DIR/probe1/last/m1"
run_nbp run --once
check "a changed expected status takes effect on the next pass" jq -e '.results[0].ok == true' "$SHIM_DIR/posts/2.json" >/dev/null
# the monitor is disabled
monitors "[$(printf '%s' "$M1" | jq -c '.enabled = false')]"
rm "$NB_PROBER_STATE_DIR/probe1/last/m1"
run_nbp run --once
check "a monitor disabled on its screen is no longer checked" test "$(posts)" -eq 2
# the interval is lengthened
monitors "[$(printf '%s' "$M1" | jq -c '.interval_minutes = 60')]"
echo "$(( $(date +%s) - 600 ))" > "$NB_PROBER_STATE_DIR/probe1/last/m1"
run_nbp run --once
check "a longer interval is respected (10 minutes ago is not due at 60)" test "$(posts)" -eq 2

echo "an edited monitor is checked at once"
reset_shim
target http://intra.test/health 200 0.050
withupd() { printf '%s' "$M1" | jq -c --arg u "$1" '.updated_at = $u'; }
monitors "[$(withupd 2026-11-25T10:00:00.000Z)]"
run_nbp run --once
check "a first pass checks the monitor" test "$(posts)" -eq 1
run_nbp run --once
check "an unedited monitor inside its interval is not checked again" test "$(posts)" -eq 1
monitors "[$(withupd 2026-11-25T10:07:30.500Z)]"
run_nbp run --once
check "after an edit the monitor is checked at once, without waiting for its interval" test "$(posts)" -eq 2
run_nbp run --once
check "and only once: the same edit does not check it again" test "$(posts)" -eq 2
# a different edit (any later or earlier time: it is the difference that counts, not this machine's clock)
monitors "[$(withupd 2026-11-25T09:00:00.000Z)]"
run_nbp run --once
check "an updated_at that is EARLIER than the one seen is still a change" test "$(posts)" -eq 3
monitors "[$(withupd 2099-01-01T00:00:00.000Z)]"
run_nbp run --once
check "an updated_at far ahead of this machine's clock is checked once" test "$(posts)" -eq 4
run_nbp run --once
run_nbp run --once
check "and does not loop on the clock difference" test "$(posts)" -eq 4
check "the edit time seen is kept under the probe's state" test -s "$NB_PROBER_STATE_DIR/probe1/updated/m1"

reset_shim
monitors "[$(withupd 2026-11-25T10:00:00.000Z)]"
target http://intra.test/health 200 0.050
run_nbp run --once --dry-run
monitors "[$(withupd 2026-11-25T11:00:00.000Z)]"
run_nbp run --once --dry-run
check "--dry-run keeps no edit time (and checks every pass)" test ! -e "$NB_PROBER_STATE_DIR/probe1"

reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --once
rm -f "$SHIM_DIR/requests.log"
run_nbp run --once
check "a monitor the server gives no edit time for is never treated as edited (interval only)" test "$(count_req 'intra.test')" -eq 0

echo "log file kept bounded"
reset_shim
monitors "[]"
LOGF="$work/prober.log"; rm -f "$LOGF" "$LOGF.1"
NB_PROBER_LOG="$LOGF" run_nbp run --once
check "NB_PROBER_LOG sends the output to the file" grep -q "reporting to" "$LOGF"
check "and nothing to the terminal" hasnt "reporting to"
head -c 2000 /dev/zero | tr '\0' 'x' >> "$LOGF"; echo >> "$LOGF"
NB_PROBER_LOG="$LOGF" NB_PROBER_LOG_MAX_BYTES=1000 run_nbp run --once
check "a log over the limit is moved to FILE.1" test -s "$LOGF.1"
check "the old content went to FILE.1" grep -q xxxxxxxxxx "$LOGF.1"
check "and a fresh file started" bash -c '! grep -q xxxxxxxxxx "$1" && grep -q "reporting to" "$1"' _ "$LOGF"
head -c 3000 /dev/zero | tr '\0' 'y' >> "$LOGF"; echo >> "$LOGF"
NB_PROBER_LOG="$LOGF" NB_PROBER_LOG_MAX_BYTES=1000 run_nbp run --once
check "the next rotation replaces FILE.1 (two files at most)" bash -c 'grep -q yyyyyyyy "$1.1" && ! grep -q xxxxxxxxxx "$1.1" && ! ls "$1".[2-9] >/dev/null 2>&1' _ "$LOGF"
NB_PROBER_LOG="$LOGF" NB_PROBER_LOG_MAX_BYTES=abc run_nbp run --once
check "a limit that is not a number falls back to the default" rc_is 0
run_nbp run --once
check "without NB_PROBER_LOG the output stays on the terminal" has "reporting to"

echo "service (systemd)"
reset_shim
monitors "[]"
perm() { ls -ld "$1" | cut -c1-10; }
run_nbp service install --os ubuntu --dry-run
check "service install --os ubuntu --dry-run shows the unit and writes nothing" has "Restart=always"
check "the dry run names the key file and the script" has "/etc/nb-prober/env"
check "the dry run never prints the key's secret" hasnt "AAAAAAAAAAAAAAAA"
check "the unit starts at boot, locked down, with the state in its own directory" has "StateDirectory=nb-prober"
ROOT_DIR="$work/root"; rm -rf "$ROOT_DIR"
out=$(printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os ubuntu --root "$ROOT_DIR" 2>&1); rc=$?
check "the key can come from stdin (not an argument)" rc_is 0
ARG_ROOT="$work/argroot"; rm -rf "$ARG_ROOT"
out=$(env -u NB_PROBER_KEY "$NBP" service install "$NB_PROBER_KEY" --os ubuntu --root "$ARG_ROOT" 2>&1); rc=$?
check "the key can be the argument (service install KEY), like cloudflared" rc_is 0
check "and is kept in the root-only file" grep -qxF "NB_PROBER_KEY=$NB_PROBER_KEY" "$ARG_ROOT/etc/nb-prober/env"
check "the argument form is accepted after the options too" bash -c 'env -u NB_PROBER_KEY "$1" service install --os ubuntu --root "$2" "$3" >/dev/null 2>&1' _ "$NBP" "$ARG_ROOT" "$NB_PROBER_KEY"
URL_ROOT="$work/urlroot"; rm -rf "$URL_ROOT"
out=$(env -u NB_PROBER_KEY -u NB_ASSURANCE_BASE_URL "$NBP" service install "$NB_PROBER_KEY" --url http://evolution.test --os ubuntu --root "$URL_ROOT" 2>&1); rc=$?
check "--url is the Evolution address the key is checked against (sudo does not pass NB_ASSURANCE_BASE_URL on)" rc_is 0
check "and is kept for the service" grep -qxF "NB_ASSURANCE_BASE_URL=http://evolution.test" "$URL_ROOT/etc/nb-prober/env"
check "--url wins over the environment" bash -c 'NB_ASSURANCE_BASE_URL=http://other.test env -u NB_PROBER_KEY "$1" service install "$2" --url=http://evolution.test --os ubuntu --root "$3" 2>&1 | grep -q "other.test" && exit 1 || exit 0' _ "$NBP" "$NB_PROBER_KEY" "$URL_ROOT"
rm -rf "$URL_ROOT"; env -u NB_PROBER_KEY -u NB_ASSURANCE_BASE_URL "$NBP" service install "$NB_PROBER_KEY" --os ubuntu --root "$URL_ROOT" >/dev/null 2>&1 || true
check "with no --url and no variable the default is not written into the service" bash -c '! grep -q NB_ASSURANCE_BASE_URL "$1" 2>/dev/null' _ "$URL_ROOT/etc/nb-prober/env"
out=$(env -u NB_PROBER_KEY "$NBP" service install a b --os ubuntu --root "$ARG_ROOT" 2>&1); rc=$?
check "two arguments are refused" rc_is 1
out=$(env -u NB_PROBER_KEY "$NBP" service uninstall x --os ubuntu --root "$ARG_ROOT" 2>&1); rc=$?
check "uninstall takes no key" rc_is 1
check "install --root puts the key in a file only its owner can read" test "$(perm "$ROOT_DIR/etc/nb-prober/env")" = "-rw-------"
check "and the directory too" test "$(perm "$ROOT_DIR/etc/nb-prober")" = "drwx------"
check "the file holds the key" grep -qxF "NB_PROBER_KEY=$NB_PROBER_KEY" "$ROOT_DIR/etc/nb-prober/env"
check "the base URL set when installing is kept for the service" grep -qxF "NB_ASSURANCE_BASE_URL=$NB_ASSURANCE_BASE_URL" "$ROOT_DIR/etc/nb-prober/env"
check "the unit is written" grep -q "^ExecStart=/usr/local/bin/nb-prober run$" "$ROOT_DIR/etc/systemd/system/nb-prober.service"
check "the unit reads the key from the file, never carries it" bash -c '! grep -q AAAAAAAA "$1"' _ "$ROOT_DIR/etc/systemd/system/nb-prober.service"
check "the script is put on the path and is executable" test -x "$ROOT_DIR/usr/local/bin/nb-prober"
check "it is the same script" cmp -s "$NBP" "$ROOT_DIR/usr/local/bin/nb-prober"
check "the key is not in any command line" bash -c '! grep -q "$NB_PROBER_KEY" "$1"' _ "$SHIM_DIR/args.log"
check "it checked the key against Evolution first" test "$(count_req 'GET http://evolution.test/api/v1/probe/monitors')" -ge 1
NEWKEY="nbp_probe1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
printf '%s' "$NEWKEY" | env -u NB_PROBER_KEY NB_PROBER_KEY="" "$NBP" service install --os ubuntu --root "$ROOT_DIR" >/dev/null 2>&1
check "running it again with a new key replaces the key" grep -qxF "NB_PROBER_KEY=$NEWKEY" "$ROOT_DIR/etc/nb-prober/env"
check "and leaves one key line" test "$(grep -c '^NB_PROBER_KEY=' "$ROOT_DIR/etc/nb-prober/env")" -eq 1

rm -rf "$ROOT_DIR"; echo 401 > "$SHIM_DIR/list_code"
out=$(printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os ubuntu --root "$ROOT_DIR" 2>&1); rc=$?
check "a key Evolution refuses installs nothing" rc_is 1
check "and says so" has "refused this key"
check "nothing was written" test ! -e "$ROOT_DIR"
rm "$SHIM_DIR/list_code"; touch "$SHIM_DIR/offline"
out=$(printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os ubuntu --root "$ROOT_DIR" 2>&1); rc=$?
check "with Evolution unreachable it warns and installs anyway" rc_is 0
check "the warning says it keeps trying" has "keeps trying"
rm "$SHIM_DIR/offline"
out=$(env -u NB_PROBER_KEY "$NBP" service install --os ubuntu --root "$ROOT_DIR" < /dev/null 2>&1); rc=$?
check "no key at all is refused, with the way to give one" has "pipe it in"
out=$(printf '%s' "nbp_x_y" | env -u NB_PROBER_KEY "$NBP" service install --os ubuntu --root "$ROOT_DIR" 2>&1); rc=$?
check "a key of the wrong shape is refused" has "not a probe key"
out=$(printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os ubuntu 2>&1); rc=$?
if [ "$(id -u)" -ne 0 ]; then check "without root (and without --root) it asks for sudo and writes nothing" has "run it with sudo"; fi
run_nbp service uninstall --os ubuntu --root "$ROOT_DIR"
check "uninstall removes the unit and the key file" test ! -e "$ROOT_DIR/etc/systemd/system/nb-prober.service" -a ! -e "$ROOT_DIR/etc/nb-prober/env"
check "and says the state directory stays" has "state directory"
out=$(env -u NB_PROBER_KEY "$NBP" service restart --os ubuntu --root "$work/none" 2>&1); rc=$?
check "restart with nothing installed says to install first" has "is not installed"
check "and fails" rc_is 1
printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os ubuntu --root "$work/ctl" >/dev/null 2>&1
for v in start stop restart; do
  out=$(env -u NB_PROBER_KEY "$NBP" service $v --os ubuntu --root "$work/ctl" 2>&1); rc=$?
  check "service $v needs no key (installed, --root: not run)" rc_is 0
done
printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os macos --root "$work/ctlm" >/dev/null 2>&1
out=$(env -u NB_PROBER_KEY "$NBP" service restart --os macos --root "$work/ctlm" 2>&1); rc=$?
check "the same on macOS" rc_is 0
out=$(env -u NB_PROBER_KEY "$NBP" service restart now --os ubuntu --root "$work/ctl" 2>&1); rc=$?
check "start|stop|restart take no argument" rc_is 1
out=$(env -u NB_PROBER_KEY "$NBP" service logs --os ubuntu --root "$work/ctl" 2>&1); rc=$?
check "logs needs the real system (not --root)" has "needs the real system"
out=$(env -u NB_PROBER_KEY "$NBP" service logs -n abc --os ubuntu 2>&1); rc=$?
check "logs -n takes a number" has "-n takes a number"
out=$(env -u NB_PROBER_KEY "$NBP" service logs -f -n 5 x --os ubuntu 2>&1); rc=$?
check "logs takes no other argument" rc_is 1
run_nbp service
check "service without a subcommand shows the usage" rc_is 1
run_nbp service bogus
check "an unknown service subcommand shows the usage" rc_is 1
run_nbp -h
check "-h lists the service command" has "service install [KEY]|start|stop|restart|status|logs|uninstall"

echo "service (launchd, macOS)"
MAC_ROOT="$work/macroot"; rm -rf "$MAC_ROOT"
run_nbp service install --os macos --dry-run
check "macOS dry run shows the daemon file" has "com.nasebanal.nb-prober.plist"
check "macOS dry run never prints the key's secret" hasnt "AAAAAAAAAAAAAAAA"
out=$(printf '%s' "$NB_PROBER_KEY" | env -u NB_PROBER_KEY "$NBP" service install --os macos --root "$MAC_ROOT" 2>&1); rc=$?
check "macOS install --root succeeds" rc_is 0
PL="$MAC_ROOT/Library/LaunchDaemons/com.nasebanal.nb-prober.plist"
check "the plist is private to its owner (it holds the key)" test "$(perm "$PL")" = "-rw-------"
check "the plist holds the key" grep -qF "$NB_PROBER_KEY" "$PL"
check "the macOS service writes its own bounded log (NB_PROBER_LOG)" grep -q "<key>NB_PROBER_LOG</key><string>/var/log/nb-prober.log</string>" "$PL"
check "launchd's own output goes to a separate, small file" grep -q "<key>StandardOutPath</key><string>/var/log/nb-prober.err</string>" "$PL"
check "the plist is valid XML (plutil, where available)" bash -c 'command -v plutil >/dev/null && plutil -lint "$1" >/dev/null || ! command -v plutil >/dev/null' _ "$PL"
check "it restarts itself and runs at boot" grep -q "<key>KeepAlive</key><true/>" "$PL"
check "it does not run as root" grep -q "<key>UserName</key><string>nobody</string>" "$PL"
check "the script is put on the path" test -x "$MAC_ROOT/usr/local/bin/nb-prober"
run_nbp service uninstall --os macos --root "$MAC_ROOT"
check "macOS uninstall removes the plist" test ! -e "$PL"
run_nbp service install --os windows --dry-run
check "an unknown platform is refused" has "ubuntu or macos"

echo "buffer"
reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --once
touch "$SHIM_DIR/offline"; rm "$NB_PROBER_STATE_DIR/probe1/last/m1"
run_nbp run --once
check "Evolution unreachable: checking goes on from the last list, the result stays in the buffer" test "$(wc -l < "$NB_PROBER_STATE_DIR/probe1/buffer/m1.jsonl" | tr -d ' ')" -eq 1
check "Evolution unreachable: says it uses the last list" has "using the last list"
check "Evolution unreachable: says it is buffered" has "stay buffered"

rm "$NB_PROBER_STATE_DIR/probe1/last/m1" "$SHIM_DIR/offline"
run_nbp run --once
check "Evolution back: the buffer is flushed, oldest first, with the new result" jq -e '(.results | length) == 2 and (.results[0].checked_at <= .results[1].checked_at)' "$SHIM_DIR/posts/2.json" >/dev/null
check "Evolution back: the buffer is empty" test ! -s "$NB_PROBER_STATE_DIR/probe1/buffer/m1.jsonl"

# A link that stays down is said once, not on every pass.
reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --once
touch "$SHIM_DIR/offline"
NB_PROBER_TICK=1 "$NBP" run > "$work/long.log" 2>&1 &
lp=$!; sleep 4; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
out=$(cat "$work/long.log")
check "a link that stays down: the list failure is said once, not every pass" test "$(printf '%s\n' "$out" | grep -c 'cannot list')" -eq 1

reset_shim
monitors "[$M1]"
touch "$SHIM_DIR/offline"
run_nbp run --once
check "Evolution unreachable and no list yet: nothing is checked" test "$(count_req 'intra.test')" -eq 0

reset_shim
monitors "[]"
mkdir -p "$NB_PROBER_STATE_DIR/probe1/buffer"
for i in $(seq 1 150); do printf '{"checked_at":"2026-11-25T00:%02d:%02dZ","ok":true,"status_code":200,"response_ms":%d,"error":null}\n' $((i / 60)) $((i % 60)) "$i"; done > "$NB_PROBER_STATE_DIR/probe1/buffer/m1.jsonl"
run_nbp run --once
check "150 buffered results go in two requests (100, then 50)" bash -c '[ "$(jq ".results|length" "$1/posts/1.json")" = 100 ] && [ "$(jq ".results|length" "$1/posts/2.json")" = 50 ]' _ "$SHIM_DIR"
check "batches keep the order" jq -e '.results[0].response_ms == 1' "$SHIM_DIR/posts/1.json" >/dev/null

reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
echo 409 > "$SHIM_DIR/post_code"
run_nbp run --once
check "409: the batch is dropped, not retried for ever" test ! -s "$NB_PROBER_STATE_DIR/probe1/buffer/m1.jsonl"
check "409: says it was refused" has "refused (HTTP 409)"

reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
echo 401 > "$SHIM_DIR/post_code"
run_nbp run --once
check "401: the results are kept" test "$(wc -l < "$NB_PROBER_STATE_DIR/probe1/buffer/m1.jsonl" | tr -d ' ')" -eq 1
check "401: says the key was refused" has "key refused"

reset_shim
monitors "[$M1]"
echo 401 > "$SHIM_DIR/list_code"
run_nbp run --once
check "401 when listing: says the key was refused" has "key refused (HTTP 401) when listing"

echo "dry run"
reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --once --dry-run
check "--dry-run prints the outcome" has "ok"
check "--dry-run reports nothing" test "$(posts)" -eq 0
check "--dry-run keeps nothing" test ! -e "$NB_PROBER_STATE_DIR/probe1"

echo "list"
reset_shim
monitors "[$M1,$M2]"
run_nbp list
check "list: header and both monitors" bash -c 'printf "%s" "$1" | grep -q "^ID" && printf "%s" "$1" | grep -q "http://wiki.test/"' _ "$out"
check "list: shows interval, method and state" has "HEAD"
echo 403 > "$SHIM_DIR/list_code"
run_nbp list
check "list: a refused key exits 1" rc_is 1

echo "arguments"
out=$(NB_PROBER_KEY="" "$NBP" run --once 2>&1); rc=$?
check "no key is refused" has "no key"
out=$(NB_PROBER_KEY="nbp_probe1_short" "$NBP" run --once 2>&1); rc=$?
check "a key of the wrong shape is refused" has "not a probe key"
out=$(NB_PROBER_KEY="nbpat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "$NBP" run --once 2>&1); rc=$?
check "a personal access token is not a probe key" has "not a probe key"
out=$(NB_PROBER_TICK=61 "$NBP" run --once 2>&1); rc=$?
check "a pass longer than 60 seconds is refused (Evolution shows the probe offline after 2 minutes)" has "1 to 60 seconds"
out=$(NB_PROBER_TICK=0 "$NBP" run --once 2>&1); rc=$?
check "a pass of 0 seconds is refused" has "1 to 60 seconds"
out=$(NB_PROBER_TICK=abc "$NBP" run --once 2>&1); rc=$?
check "a pass that is not a number is refused" has "number of seconds"
out=$(NB_PROBER_TOKEN="test-token" NB_PROBER_NAME=office "$NBP" run --probe office --once 2>&1); rc=$?
check "the old way (a token and --probe) is gone" rc_is 1
reset_shim
monitors "[]"
run_nbp run --once
check "the probe's state lives under the probe id taken from the key" test -d "$NB_PROBER_STATE_DIR/probe1"

echo "doctor"
reset_shim
monitors "[]"
run_nbp doctor
check "doctor: all fine exits 0" rc_is 0
check "doctor: reports the key accepted and which probe it is" has "key set (probe probe1)"
check "doctor: reports Evolution reachable" has "key accepted"
check "doctor: never prints the key" hasnt "AAAAAAAAAAAAAAAA"
out=$(NB_PROBER_KEY="" "$NBP" doctor 2>&1); rc=$?
check "doctor: no key is flagged" has "no key"
out=$(NB_PROBER_KEY="nbp_x_y" "$NBP" doctor 2>&1); rc=$?
check "doctor: a malformed key is flagged" has "not a probe key"
out=$(NB_PROBER_TICK=300 "$NBP" doctor 2>&1); rc=$?
check "doctor: a pass over 60 seconds is flagged" has "1 to 60 seconds"
echo 401 > "$SHIM_DIR/list_code"
run_nbp doctor
check "doctor: a refused key is flagged" has "refused the key"
touch "$SHIM_DIR/offline"; rm "$SHIM_DIR/list_code"
run_nbp doctor
check "doctor: Evolution unreachable is flagged, exit 1" rc_is 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
