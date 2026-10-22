#!/usr/bin/env bash
set -eu
ROOT=$PWD
WORK="$ROOT/.test-rex-live"
export TMPDIR="$WORK"
REAL=$(command -v rex)
export REX_SERVER="unix://$WORK/rex.sock"
mkdir -p "$WORK/server-state" "$WORK/parent/state" "$WORK/mate/state" "$WORK/other/state"
: > "$WORK/config.lua"
SERVER_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
"$REAL" --autostart=false server run --listen "$REX_SERVER" --state-dir "$WORK/server-state" --config "$WORK/config.lua" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
r() { "$REAL" --autostart=false -S "$REX_SERVER" "$@"; }
for i in {1..100}; do r api call server.status >/dev/null 2>&1 && break; sleep .1; done
r api call server.status
unset REX_SESSION REX_BLOCK FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$WORK/parent" FM_ROOT="$ROOT" STATE="$WORK/parent/state" TERM_PROGRAM=fm-test
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex
parent=$(r new lab-parent --window captain --cwd "$WORK" --json | jq -r .session_id)
other=$(r new lab-unrelated --window keep --cwd "$WORK" --json | jq -r .session_id)
export REX_SESSION="$parent"
printf 'mate\n' > "$WORK/mate/.fm-secondmate-home"
export FM_HOME="$WORK/mate" FM_ROOT="$WORK/mate" STATE="$WORK/mate/state"
triple=$(fm_backend_rex_create_task fm-mate "$WORK" other-home)
read -r sid wid bid <<< "$triple"
expected="2ndmate-mate-$(printf '%s' "$WORK/mate" | shasum -a 256 | cut -c1-8)"
view=$(fm_backend_rex_session_view "$sid")
printf 'NEW SECONDMATE VIEW\n%s\n' "$view"
[ "$(printf '%s' "$view" | jq -r .label)" = "$expected" ]
list=$(r ls --json)
printf 'SESSION ORDER\n%s\n' "$list"
printf '%s' "$list" | jq -e --arg p "$parent" --arg s "$sid" '[.sessions[].session_id] | index($s) == (index($p) + 1)' >/dev/null
printf 'PROVEN: child-home hash; new secondmate immediately follows parent\n'
# Keep a crew tab while the mate exits, then verify the replacement is first.
crew=$(fm_backend_rex_create_task fm-crew "$WORK")
read -r crew_sid crew_wid crew_bid <<< "$crew"
[ "$crew_sid" = "$sid" ]
r block close -s "$sid" "$bid"
triple=$(fm_backend_rex_create_task fm-mate "$WORK" other-home)
read -r again_sid again_wid again_bid <<< "$triple"
[ "$again_sid" = "$sid" ]
view=$(fm_backend_rex_session_view "$sid")
printf 'RESPAWN WITH CREW VIEW\n%s\n' "$view"
printf '%s' "$view" | jq -e --arg w "$again_wid" '.windows[0].window_id == $w and (.windows | length) == 2' >/dev/null
fm_backend_rex_retire_session "$sid"
fm_backend_rex_session_view "$sid" >/dev/null
printf 'PROVEN: respawn first, crew preserved, nonempty retirement refused\n'
# Close all tabs directly so retirement does not run; the real server omits windows.
r block close -s "$sid" "$again_bid"
r block close -s "$sid" "$crew_bid"
view=$(fm_backend_rex_session_view "$sid")
printf 'EMPTY VIEW FROM REAL REX\n%s\n' "$view"
printf '%s' "$view" | jq -e 'has("windows") | not' >/dev/null
triple=$(fm_backend_rex_create_task fm-mate "$WORK" other-home)
read -r again_sid again_wid again_bid <<< "$triple"
[ "$again_sid" = "$sid" ]
printf 'ADOPTED EMPTY SESSION\n'; fm_backend_rex_session_view "$sid"
printf 'PROVEN: session with omitted windows adopted and crewless mate relaunched\n'
# A matching empty session elsewhere must not be retired with the recorded one.
decoy=$(r new "$expected" --window decoy --cwd "$WORK" --json)
decoy_sid=$(printf '%s' "$decoy" | jq -r .session_id)
decoy_bid=$(printf '%s' "$decoy" | jq -r '.initial_windows[0].block_ids[0]')
r block close -s "$decoy_sid" "$decoy_bid"
fm_backend_kill rex "$(fm_backend_rex_target "$sid" "$again_bid")"
if fm_backend_rex_session_view "$sid" >/dev/null; then echo 'FAIL: recorded session survived'; exit 1; fi
printf 'DECOY MATCHING EMPTY SESSION SURVIVES\n'; fm_backend_rex_session_view "$decoy_sid"
fm_backend_rex_session_view "$parent" >/dev/null
fm_backend_rex_session_view "$other" >/dev/null
printf 'PROVEN: only exact recorded empty session retired, parent/unrelated/duplicate-label session preserved\n'
# Renamed labels cannot authorize session retirement.
r session rename "$decoy_sid" captain-renamed
fm_backend_rex_retire_session "$decoy_sid"
printf 'RENAMED EMPTY SESSION PRESERVED\n'; fm_backend_rex_session_view "$decoy_sid"
# Force a genuine server-side session-move failure using a nonexistent parent.
export FM_HOME="$WORK/other" FM_ROOT="$WORK/other" STATE="$WORK/other/state"
export REX_SESSION=session:00000000-0000-7000-8000-000000000000
triple=$(fm_backend_rex_create_task fm-order-failure "$WORK" other-home)
read -r failed_sid failed_wid failed_bid <<< "$triple"
printf 'ORDER FAILURE STILL CREATED TASK\n'; fm_backend_rex_session_view "$failed_sid"
fm_backend_rex_kill "$(fm_backend_rex_target "$failed_sid" "$failed_bid")"
printf 'PROVEN: session ordering failure is non-fatal\n'
# Exercise the second best-effort boundary with a move-only fault guard.
# All reads and tab creation still reach the private, real Rex server.
mkdir -p "$WORK/fault-guard"
cat > "$WORK/fault-guard/rex" <<'GUARD'
#!/usr/bin/env bash
case " $* " in *' window move '*) echo 'injected window ordering refusal' >&2; exit 97 ;; esac
exec "$FM_LIVE_REAL_REX" "$@"
GUARD
chmod +x "$WORK/fault-guard/rex"
export FM_LIVE_REAL_REX="$REAL" REX_BIN_DIR="$WORK/fault-guard"
export FM_HOME="$WORK/mate" FM_ROOT="$WORK/mate" STATE="$WORK/mate/state" REX_SESSION="$parent"
r session rename "$decoy_sid" "$expected"
triple=$(fm_backend_rex_create_task fm-window-order-failure "$WORK" other-home)
read -r fault_sid fault_wid fault_bid <<< "$triple"
[ "$fault_sid" = "$decoy_sid" ]
printf 'WINDOW ORDER REFUSAL STILL CREATED TASK\n'; fm_backend_rex_session_view "$fault_sid"
fm_backend_rex_kill "$(fm_backend_rex_target "$fault_sid" "$fault_bid")"
unset REX_BIN_DIR
printf 'PROVEN: window ordering failure is non-fatal; task remains routable and can retire\n'
# An ordinary home separate from the code root must keep code-root identity.
export FM_HOME="$WORK/parent" FM_ROOT="$ROOT" STATE="$WORK/parent/state"
unset REX_SESSION
triple=$(fm_backend_rex_create_task fm-ordinary "$WORK")
read -r normal_sid normal_wid normal_bid <<< "$triple"
normal_expected="firstmate-$(printf '%s' "$ROOT" | shasum -a 256 | cut -c1-8)"
view=$(fm_backend_rex_session_view "$normal_sid")
printf 'ORDINARY SEPARATE HOME VIEW\n%s\n' "$view"
[ "$(printf '%s' "$view" | jq -r .label)" = "$normal_expected" ]
fm_backend_rex_kill "$(fm_backend_rex_target "$normal_sid" "$normal_bid")"
if fm_backend_rex_session_view "$normal_sid" >/dev/null; then echo 'FAIL: ordinary session survived'; exit 1; fi
printf 'PROVEN: ordinary separate-home adapter creation and retirement retain code-root identity\n'
printf 'FINAL PRIVATE INVENTORY\n'; r ls --json
printf 'ALL LIVE ADAPTER SCENARIOS COMPLETED\n'
