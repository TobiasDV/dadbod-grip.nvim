#!/usr/bin/env bash
# The caller owns the eight-second timeout. A hit-enter prompt can block the
# fixture, but only its actual stage signal proves that the assertions passed.
set -euo pipefail
session="$1"
channel="$2"
waiter=""
cleanup() {
  if [[ -n "$waiter" ]]; then
    kill "$waiter" 2>/dev/null || true
    wait "$waiter" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tmux wait-for "$channel" &
waiter=$!
acknowledged=false
acknowledge_prompt() {
  local pane last_line
  pane="$(tmux capture-pane -p -t "$session")"
  # Old text in a SQL pad or elsewhere in the pane is not a current prompt.
  last_line="$(printf '%s\n' "$pane" | awk 'NF { line=$0 } END { sub(/[[:space:]]+$/, "", line); print line }')"
  if [[ "$last_line" == "Press ENTER or type command to continue" ]]; then
    if [[ "$acknowledged" == false ]]; then
      tmux send-keys -t "$session" Enter
      acknowledged=true
    fi
  else
    acknowledged=false
  fi
}
while :; do
  acknowledge_prompt
  # Inspect the current pane even if the signal arrived first: an already
  # visible prompt still needs acknowledgement before the next driver action.
  if ! kill -0 "$waiter" 2>/dev/null; then break; fi
  sleep 0.05
done
if wait "$waiter"; then status=0; else status=$?; fi
waiter=""
# The last capture may predate a prompt/stage that arrived while tmux was
# returning its snapshot. Inspect again after the waiter conclusively exits,
# preserving acknowledgement state so a lingering prompt gets no second Enter.
acknowledge_prompt
exit "$status"
