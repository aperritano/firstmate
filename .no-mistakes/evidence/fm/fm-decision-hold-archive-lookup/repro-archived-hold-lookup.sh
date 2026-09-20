#!/usr/bin/env bash
# Manual reproduction of the reported failure, as an operator would hit it.
#
# Usage: repro-archived-hold-lookup.sh <firstmate-tree>
#
# Mirrors the xmarks-repo-analysis loss with a synthetic name: a captain hold is
# raised on a scout origin, the captain answers it, tasks-axi ages the resolved
# row out of data/backlog.md into data/done-archive.md past done_keep, and the
# downstream lookups (the completion gate, and the decision-hold shim's
# idempotent resolve replay) go looking for it again.
set -u
TREE=${1:?usage: repro-archived-hold-lookup.sh <firstmate-tree>}
. "$TREE/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-repro-archive)
home="$TMP_ROOT/home"
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home")
fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi

TASKS_AXI_BIN=$(command -v tasks-axi)
run_captain() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  "$ROOT/bin/fm-captain-hold.sh" "$@"; }
run_shim() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  "$ROOT/bin/fm-decision-hold.sh" "$@"; }
step() { printf '\n$ %s\n' "$*"; }

id=xmarks-style-analysis
mkdir -p "$home/data/$id"
(cd "$home" && tasks-axi add "$id" "Analyse the sample repo" --kind scout --repo sample --start) >/dev/null
fm_write_meta "$home/state/$id.meta" "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
  "project=$home/projects/sample" "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
printf 'done: report complete\n' > "$home/state/$id.status"
printf '# Sample analysis\n\nThe captain must choose the owner model.\n' > "$home/data/$id/report.md"
printf 'Use the shared-owner model.\n' > "$home/owner-model.txt"

printf '=== firstmate tree under test: %s ===\n' "$ROOT"

step "fm-decision-hold.sh hold $id owner-model --title ... --reason ..."
hold=$(run_shim hold "$id" owner-model --title "Choose the sample owner model" \
  --reason "captain owner-model choice pending" --repo sample) && printf '%s\n' "$hold"
(cd "$home" && tasks-axi add xmarks-style-work "Apply the chosen owner model" \
  --kind ship --repo sample --blocked-by "$hold") >/dev/null

step "fm-decision-hold.sh resolve $id owner-model --decision-file owner-model.txt --routed-to xmarks-style-work"
run_shim resolve "$id" owner-model --decision-file "$home/owner-model.txt" --routed-to xmarks-style-work

step "tasks-axi prune --keep 0 --state done   # done_keep ages the resolved hold out"
(cd "$home" && tasks-axi prune --keep 0 --state done)

step "tasks-axi show $hold --full   # the active backlog no longer has it"
(cd "$home" && tasks-axi show "$hold" --full); printf '[exit %s]\n' "$?"

step "grep -c $hold data/done-archive.md   # it is in the archive, a real record"
(cd "$home" && grep -c -- "$hold" data/done-archive.md)

printf '\n--- the two lookups that must still find it ---\n'

printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$hold" >> "$home/state/$id.meta"
step "fm-captain-hold.sh verify $id   # the completion gate"
run_captain verify "$id"; printf '[exit %s]\n' "$?"

step "fm-decision-hold.sh resolve $id owner-model ...   # idempotent replay of the same resolution"
run_shim resolve "$id" owner-model --decision-file "$home/owner-model.txt" --routed-to xmarks-style-work
printf '[exit %s]\n' "$?"

step "tasks-axi show xmarks-style-work --full   # the routed work is released"
(cd "$home" && tasks-axi show xmarks-style-work --full | sed -n '1,8p')
