#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/kunchen/.no-mistakes/evidence/01M5JA9A65YZTDHAZYVVJGGM9G
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }
. "$ROOT/tests/rex-test-safety.sh"
trap rex_test_cleanup EXIT
rex_test_prepare
sentinel_work=$REX_TEST_WORK
sentinel_pid=$REX_TEST_SERVER_PID
sentinel_endpoint=$REX_TEST_ENDPOINT
pair=$(rex_test_new_session routing-sentinel)
read -r sid bid <<<"$pair"
before=$(rex_test_cli api call -s "$sid" session.view | jq -cS .)
echo "Disposable sentinel endpoint: $sentinel_endpoint"
echo "Sentinel session: $sid"
# Force a real startup error using an overlong Unix-socket pathname.
# Even with a reachable inherited server, this must fail closed, not skip/fallback.
rc=0
env -u REX_BIN_DIR -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE TMPDIR="$PWD/.rex-validation" REX_SERVER="$sentinel_endpoint" bash tests/fm-backend-rex-smoke.test.sh || rc=$?
[ "$rc" = 2 ] || fail "startup failure returned $rc instead of 2"
[ "$before" = "$(rex_test_cli api call -s "$sid" session.view | jq -cS .)" ] || fail 'startup failure changed sentinel'
for d in "$PWD"/.rex-validation/fm-rex-test.*; do [ ! -e "$d" ] || fail "failed startup leaked $d"; done
pass 'real startup error failed closed (2), cleaned scratch, and did not fall back to reachable inherited server'
# An inherited endpoint points to a second disposable real server, never the user's.
env -u REX_BIN_DIR -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE REX_SERVER="$sentinel_endpoint" bash -c '
  set -eu
  fail() { echo "FAIL: $*"; exit 1; }; pass() { echo "PASS: $*"; }
  inherited=$REX_SERVER
  . tests/rex-test-safety.sh
  trap rex_test_cleanup EXIT
  rex_test_prepare
  [ "$REX_TEST_ENDPOINT" != "$inherited" ]
  echo "Nested endpoint: $REX_TEST_ENDPOINT"
  rex_test_new_session nested
  echo
  rex_test_stop_server
  rex_test_start_server
  [ "$(rex_test_cli ls --json | jq ".sessions | length")" = 0 ]
  echo "Nested restart: no persisted sessions"
'
kill -0 "$sentinel_pid"
after=$(rex_test_cli api call -s "$sid" session.view | jq -cS .)
[ "$before" = "$after" ] || fail 'inherited endpoint sentinel changed'
pass 'nested helper ignored inherited REX_SERVER; sentinel remained byte-identical and reachable after private stop/restart'
# A foreign session on this private server must survive a guard refusal.
out=$(rex_test_cli new fm-test-foreign-sentinel --cwd "$REX_TEST_WORK" --json)
foreign=$(printf '%s' "$out" | jq -r .session_id)
set +e
fm_backend_rex_cli kill "$foreign"
rc=$?
set -e
[ "$rc" = 97 ] || fail "unowned kill returned $rc"
rex_test_cli api call -s "$foreign" session.view >/dev/null
pass 'guard refused kill of unowned session (97); real session still exists'
rex_test_cli kill "$foreign" >/dev/null
rex_test_cleanup
[ ! -e "$sentinel_work" ] || fail 'scratch directory leaked'
if kill -0 "$sentinel_pid" 2>/dev/null; then fail 'private server leaked'; fi
pass 'cleanup removed owned state and terminated the private server'
