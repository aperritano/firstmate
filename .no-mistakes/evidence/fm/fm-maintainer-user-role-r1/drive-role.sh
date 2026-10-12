#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/kunchen/.no-mistakes/evidence/01M4RSVY8DHRNY3H4ETBM3QEVC
T=$(mktemp -d "$ROOT/.test-tmp/live.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
bin/fm-lab-home.sh create "$T/home"
export FM_HOME="$T/home" FM_BACKEND=tmux TMPDIR="$T"
run() { local want=$1; shift; printf '\n$'; printf ' %q' "$@"; printf '\n'; local rc=0; LAST=$("$@" 2>&1) || rc=$?; printf '%s\n' "$LAST"; printf 'exit=%s (expected %s)\n' "$rc" "$want"; [ "$rc" = "$want" ]; }
commit() { git -C "$1" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm "$2"; }
git clone -q --no-hardlinks --no-checkout "$ROOT" "$T/parent"
git -C "$T/parent" remote set-url origin https://github.com/kunchenguid/firstmate.git/
git clone -q --no-hardlinks --no-checkout "$ROOT" "$T/fork"
git -C "$T/fork" remote set-url origin https://github.com/example/firstmate-fork.git
git init -q "$T/own"; commit "$T/own" own; git -C "$T/own" remote add origin https://github.com/example/own.git
printf '\n=== Default user and no inferred authority ===\n'
run 0 bin/fm-role.sh report
run 1 bin/fm-role.sh check "$ROOT"
run 1 bin/fm-brief.sh denied lab --mode direct-PR --project "$T/parent"
[ ! -e "$FM_HOME/data/denied/brief.md" ]
run 0 bin/fm-brief.sh private lab --mode local-only --project "$T/parent"
printf '\n=== Ordinary project publishing contract remains available ===\n'
run 2 bin/fm-role.sh check "$T/own"
run 0 bin/fm-brief.sh own-task own --mode direct-PR --project "$T/own"
printf '\n=== Scoped maintainer and one-task consent ===\n'
printf 'maintainer github.com/kunchenguid/firstmate\n' > "$FM_HOME/config/firstmate-role"
run 0 bin/fm-role.sh report
run 0 bin/fm-brief.sh maint lab --mode direct-PR --project "$T/parent"
rm "$FM_HOME/config/firstmate-role"
run 0 bin/fm-brief.sh consent lab --mode direct-PR --project "$T/parent" --upstream-consent github.com/kunchenguid/firstmate
cp "$FM_HOME/data/consent/brief.md" "$E/consented-brief.md"
run 1 bin/fm-brief.sh wrong lab --mode direct-PR --project "$T/parent" --upstream-consent github.com/example/other
run 1 bin/fm-brief.sh next-task lab --mode direct-PR --project "$T/parent"
run 0 bin/fm-role.sh report
printf '\n=== Fork-origin code root still gates the parent clone ===\n'
run 1 env FM_ROOT_OVERRIDE="$T/fork" bin/fm-role.sh check "$T/parent"
printf 'maintainer github.com/example/firstmate-fork\n' > "$FM_HOME/config/firstmate-role"
run 1 env FM_ROOT_OVERRIDE="$T/fork" bin/fm-role.sh check "$T/parent"
run 0 env FM_ROOT_OVERRIDE="$T/fork" bin/fm-role.sh check "$T/parent" upstream-consent github.com/kunchenguid/firstmate
rm "$FM_HOME/config/firstmate-role"
printf '\n=== Unknown target and shallow lineage fail closed ===\n'
git -C "$T/parent" remote remove origin
run 1 bin/fm-role.sh check "$T/parent" upstream-consent github.com/kunchenguid/firstmate
git -C "$T/parent" remote add origin https://github.com/kunchenguid/firstmate.git
# A full local clone's current tip is not the root; depth 1 deliberately hides lineage.
git clone -q --depth 1 "file://$T/parent" "$T/shallow"
git -C "$T/shallow" remote set-url origin https://github.com/kunchenguid/firstmate.git
run 1 bin/fm-role.sh check "$T/shallow" upstream-consent github.com/kunchenguid/firstmate
printf '\n=== Supported secondmate inheritance, rejected-primary revocation, and drift ===\n'
mkdir -p "$T/second/config" "$T/second/state" "$T/second/data"
touch "$T/second/.fm-secondmate-home"
. bin/fm-config-inherit-lib.sh
printf 'maintainer github.com/kunchenguid/firstmate\n' > "$FM_HOME/config/firstmate-role"
FM_INHERITABLE_CONFIG=firstmate-role propagate_inheritable_config "$FM_HOME/config" "$T/second/config"
run 0 env FM_HOME="$T/second" bin/fm-role.sh report
run 0 env FM_HOME="$T/second" bin/fm-role.sh check "$ROOT"
printf 'maintainer github.com/evil/firstmate\n' > "$T/second/config/firstmate-role"
run 1 env FM_HOME="$T/second" bin/fm-role.sh check "$ROOT"
for bad in symlink conflicting multiple-scopes; do
  rm -f "$FM_HOME/config/firstmate-role"
  case $bad in
    symlink) printf 'maintainer github.com/kunchenguid/firstmate\n' > "$T/role-target"; ln -s "$T/role-target" "$FM_HOME/config/firstmate-role" ;;
    conflicting) printf 'maintainer github.com/kunchenguid/firstmate\nuser\n' > "$FM_HOME/config/firstmate-role" ;;
    multiple-scopes) printf 'maintainer github.com/kunchenguid/firstmate github.com/example/other\n' > "$FM_HOME/config/firstmate-role" ;;
  esac
  run 0 bin/fm-role.sh report
  run 1 bin/fm-role.sh check "$ROOT"
  FM_INHERITABLE_CONFIG=firstmate-role propagate_inheritable_config "$FM_HOME/config" "$T/second/config"
  run 0 env FM_HOME="$T/second" bin/fm-role.sh report
  run 1 env FM_HOME="$T/second" bin/fm-role.sh check "$ROOT"
done
rm "$FM_HOME/config/firstmate-role"
printf '\n=== Real spawn refusal writes no task metadata ===\n'
python3 - "$FM_HOME/data/consent/brief.md" "$FM_HOME/data/own-task/brief.md" <<'PY'
import sys
for p in sys.argv[1:]:
 s=open(p).read().replace('{TASK}', 'Investigate locally; do not publish.').replace('{FIRSTMATE_SPEC}', 'Report locally.')
 open(p,'w').write(s)
PY
run 1 bin/fm-spawn.sh consent "$T/parent" claude --mode direct-PR --yolo off
[[ "$LAST" = *'upstream-consent mismatch'* ]]
[ ! -e "$FM_HOME/state/consent.meta" ]
run 1 bin/fm-spawn.sh own-task "$ROOT" claude --mode direct-PR --yolo off
[[ "$LAST" = *'spawn refused'* ]]
[ ! -e "$FM_HOME/state/own-task.meta" ]
printf '\n=== Real promotion refusal preserves scout; consent emits ship contract ===\n'
run 0 bin/fm-brief.sh promote lab --scout
# Replace only the generated task placeholders with a concrete safe task, as an operator fills a scaffold.
python3 - "$FM_HOME/data/promote/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Investigate locally; do not publish.').replace('{FIRSTMATE_SPEC}', 'Report locally.')
open(p,'w').write(s)
PY
printf 'window=fm-promote\nkind=scout\nproject=%s\nworktree=%s\n' "$T/parent" "$T/parent" > "$FM_HOME/state/promote.meta"
run 1 bin/fm-promote.sh promote --mode direct-PR --yolo off
[ ! -e "$FM_HOME/data/promote/ship-instructions.md" ]
run 0 bin/fm-promote.sh promote --mode direct-PR --yolo off --upstream-consent github.com/kunchenguid/firstmate
cp "$FM_HOME/data/promote/ship-instructions.md" "$E/promoted-ship-instructions.md"
cp "$FM_HOME/state/promote.meta" "$E/promoted-task.meta"
printf '\nAll disposable homes and Git repositories removed by EXIT trap.\n'
