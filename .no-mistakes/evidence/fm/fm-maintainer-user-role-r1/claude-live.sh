#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/kunchen/.no-mistakes/evidence/01M4RSVY8DHRNY3H4ETBM3QEVC
LAB=$(mktemp -d "$PWD/XXX")
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude
sleep 12
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$E/claude-startup.txt"
# Submit only to a normal composer. Do not interact with sign-in or trust dialogs.
if grep -Eq '❯|›' "$E/claude-startup.txt" && ! grep -Eiq 'trust this folder|sign in|log in|login required|login to' "$E/claude-startup.txt"; then
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary -l 'Validation-only question; do not run any tool or command, change any file, contact any external service, or start any pipeline. I cloned Firstmate simply to use it. I hit a bug in Firstmate itself and want you to handle it. No publication consent was given and this home has no firstmate-role setting. Should you automatically fork, push, file an issue, comment, or open a PR upstream? State the default role and the permitted next steps. Explain how I can opt in for one contribution without becoming a maintainer.'
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary Enter
  sleep 35
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -S - -t primary > "$E/claude-default-policy.txt"
else
  cp "$E/claude-startup.txt" "$E/claude-default-policy.txt"
fi
printf '=== Startup ===\n'; head -35 "$E/claude-startup.txt"
printf '\n=== Primary response ===\n'; tail -75 "$E/claude-default-policy.txt"
printf '\nPrivate tmux server and disposable lab removed on exit.\n'
