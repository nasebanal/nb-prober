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
export NB_PROBER_TOKEN="test-token"
export NB_PROBER_RETRY_WAIT=0
export NB_ASSURANCE_BASE_URL="http://evolution.test"
unset NB_TOKEN NB_PROBER_NAME NB_ACTIVE_ORGANIZATION_ID
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
run_nbp run --probe office --once
check "run --once exits 0" rc_is 0
check "run: one POST per enabled monitor" test "$(posts)" -eq 3
check "run: the disabled monitor is not checked" hasnt "Off"
check "run: asked for mode=push and the probe" test "$(count_req 'mode=push&probe=office')" -ge 1
check "run: reported to the monitor's own path" test "$(count_req 'POST http://evolution.test/api/v1/monitors/m1/results')" -eq 1
check "run: the monitor's own method is used (HEAD for Wiki)" test "$(count_req 'HEAD http://wiki.test/')" -eq 1
check "run: the monitor's expected status is used (204 is ok)" bash -c 'grep -l "\"response_ms\":100" "$1"/posts/*.json | xargs jq -e ".results[0].ok == true and .results[0].status_code == 204" >/dev/null' _ "$SHIM_DIR"
check "run: the monitor's keyword is used" bash -c 'grep -l "\"response_ms\":20" "$1"/posts/*.json | xargs jq -e ".results[0].ok == true" >/dev/null' _ "$SHIM_DIR"
check "run: the report has the contract's fields" jq -e '.results[0] | has("checked_at") and .ok == true and .response_ms == 50 and .status_code == 200 and .error == null' "$SHIM_DIR/posts/1.json" >/dev/null
check "run: checked_at is UTC ISO 8601" bash -c 'jq -r ".results[0].checked_at" "$1" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"' _ "$SHIM_DIR/posts/1.json"
check "run: the buffer is empty after a successful report" test ! -s "$NB_PROBER_STATE_DIR/office/buffer/m1.jsonl"
check "run: the token arrived on stdin" test -s "$SHIM_DIR/auth.log"
check "run: the args log is not empty (so the next check means something)" test -s "$SHIM_DIR/args.log"
check "run: the token is not in any command line" bash -c '! grep -q test-token "$1"' _ "$SHIM_DIR/args.log"
check "run: the user agent names the prober" bash -c 'grep -q "NASEBANAL-Prober/" "$1"' _ "$SHIM_DIR/args.log"
run_nbp run --probe office --once
check "run: a monitor not yet due is not checked again" test "$(posts)" -eq 3

echo "settings follow Evolution"
reset_shim
monitors "[$M1]"
target http://intra.test/health 503 0.050
run_nbp run --probe office --once
check "a 503 is down with unexpected_status" jq -e '.results[0].ok == false and .results[0].error == "unexpected_status" and .results[0].status_code == 503' "$SHIM_DIR/posts/1.json" >/dev/null
check "a failed check is repeated once, and shown as DOWN" bash -c '[ "$(grep -c "GET http://intra.test/health" "$1/requests.log")" = 2 ] && grep -q DOWN <<< "$2"' _ "$SHIM_DIR" "$out"
# the owner now accepts 503 on the monitor's screen: the next pass uses it
monitors "[$(printf '%s' "$M1" | jq -c '.expected_status = 503')]"
rm "$NB_PROBER_STATE_DIR/office/last/m1"
run_nbp run --probe office --once
check "a changed expected status takes effect on the next pass" jq -e '.results[0].ok == true' "$SHIM_DIR/posts/2.json" >/dev/null
# the monitor is disabled
monitors "[$(printf '%s' "$M1" | jq -c '.enabled = false')]"
rm "$NB_PROBER_STATE_DIR/office/last/m1"
run_nbp run --probe office --once
check "a monitor disabled on its screen is no longer checked" test "$(posts)" -eq 2
# the interval is lengthened
monitors "[$(printf '%s' "$M1" | jq -c '.interval_minutes = 60')]"
echo "$(( $(date +%s) - 600 ))" > "$NB_PROBER_STATE_DIR/office/last/m1"
run_nbp run --probe office --once
check "a longer interval is respected (10 minutes ago is not due at 60)" test "$(posts)" -eq 2

echo "buffer"
reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --probe office --once
touch "$SHIM_DIR/offline"; rm "$NB_PROBER_STATE_DIR/office/last/m1"
run_nbp run --probe office --once
check "Evolution unreachable: checking goes on from the last list, the result stays in the buffer" test "$(wc -l < "$NB_PROBER_STATE_DIR/office/buffer/m1.jsonl" | tr -d ' ')" -eq 1
check "Evolution unreachable: says it uses the last list" has "using the last list"
check "Evolution unreachable: says it is buffered" has "stay buffered"

rm "$NB_PROBER_STATE_DIR/office/last/m1" "$SHIM_DIR/offline"
run_nbp run --probe office --once
check "Evolution back: the buffer is flushed, oldest first, with the new result" jq -e '(.results | length) == 2 and (.results[0].checked_at <= .results[1].checked_at)' "$SHIM_DIR/posts/2.json" >/dev/null
check "Evolution back: the buffer is empty" test ! -s "$NB_PROBER_STATE_DIR/office/buffer/m1.jsonl"

# A link that stays down is said once, not on every pass.
reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --probe office --once
touch "$SHIM_DIR/offline"
NB_PROBER_TICK=1 "$NBP" run --probe office > "$work/long.log" 2>&1 &
lp=$!; sleep 4; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
out=$(cat "$work/long.log")
check "a link that stays down: the list failure is said once, not every pass" test "$(printf '%s\n' "$out" | grep -c 'cannot list')" -eq 1

reset_shim
monitors "[$M1]"
touch "$SHIM_DIR/offline"
run_nbp run --probe office --once
check "Evolution unreachable and no list yet: nothing is checked" test "$(count_req 'intra.test')" -eq 0

reset_shim
monitors "[]"
mkdir -p "$NB_PROBER_STATE_DIR/office/buffer"
for i in $(seq 1 150); do printf '{"checked_at":"2026-11-25T00:%02d:%02dZ","ok":true,"status_code":200,"response_ms":%d,"error":null}\n' $((i / 60)) $((i % 60)) "$i"; done > "$NB_PROBER_STATE_DIR/office/buffer/m1.jsonl"
run_nbp run --probe office --once
check "150 buffered results go in two requests (100, then 50)" bash -c '[ "$(jq ".results|length" "$1/posts/1.json")" = 100 ] && [ "$(jq ".results|length" "$1/posts/2.json")" = 50 ]' _ "$SHIM_DIR"
check "batches keep the order" jq -e '.results[0].response_ms == 1' "$SHIM_DIR/posts/1.json" >/dev/null

reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
echo 409 > "$SHIM_DIR/post_code"
run_nbp run --probe office --once
check "409: the batch is dropped, not retried for ever" test ! -s "$NB_PROBER_STATE_DIR/office/buffer/m1.jsonl"
check "409: says it was refused" has "refused (HTTP 409)"

reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
echo 401 > "$SHIM_DIR/post_code"
run_nbp run --probe office --once
check "401: the results are kept" test "$(wc -l < "$NB_PROBER_STATE_DIR/office/buffer/m1.jsonl" | tr -d ' ')" -eq 1
check "401: says the token was refused" has "token refused"

reset_shim
monitors "[$M1]"
echo 401 > "$SHIM_DIR/list_code"
run_nbp run --probe office --once
check "401 when listing: says the token was refused" has "token refused (HTTP 401) when listing"

echo "dry run"
reset_shim
monitors "[$M1]"
target http://intra.test/health 200 0.050
run_nbp run --probe office --once --dry-run
check "--dry-run prints the outcome" has "ok"
check "--dry-run reports nothing" test "$(posts)" -eq 0
check "--dry-run keeps nothing" test ! -e "$NB_PROBER_STATE_DIR/office"

echo "list"
reset_shim
monitors "[$M1,$M2]"
run_nbp list --probe office
check "list: header and both monitors" bash -c 'printf "%s" "$1" | grep -q "^ID" && printf "%s" "$1" | grep -q "http://wiki.test/"' _ "$out"
check "list: shows interval, method and state" has "HEAD"
echo 403 > "$SHIM_DIR/list_code"
run_nbp list --probe office
check "list: a refused token exits 1" rc_is 1

echo "arguments"
run_nbp run --once
check "no probe name: asks for one" has "which probe?"
run_nbp run --probe "Bad Name" --once
check "an invalid probe name is refused" has "invalid probe name"
out=$(NB_PROBER_TOKEN="" "$NBP" run --probe office --once 2>&1); rc=$?
check "no token is refused" has "no token"
out=$(NB_PROBER_NAME=office "$NBP" run --once 2>&1); rc=$?
check "NB_PROBER_NAME stands in for --probe" hasnt "which probe?"
out=$(NB_PROBER_TOKEN="" NB_TOKEN="test-token" "$NBP" run --probe office --once 2>&1); rc=$?
check "NB_TOKEN is read when NB_PROBER_TOKEN is not set" hasnt "no token"

echo "doctor"
reset_shim
monitors "[]"
run_nbp doctor --probe office
check "doctor: all fine exits 0" rc_is 0
check "doctor: reports the token accepted" has "token accepted"
check "doctor: never prints the token" hasnt "test-token"
out=$(NB_PROBER_TOKEN="" "$NBP" doctor --probe office 2>&1); rc=$?
check "doctor: no token is flagged" has "no token"
echo 401 > "$SHIM_DIR/list_code"
run_nbp doctor --probe office
check "doctor: a refused token is flagged" has "refused the token"
touch "$SHIM_DIR/offline"; rm "$SHIM_DIR/list_code"
run_nbp doctor --probe office
check "doctor: Evolution unreachable is flagged, exit 1" rc_is 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
