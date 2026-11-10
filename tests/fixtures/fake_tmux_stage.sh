#!/usr/bin/env bash
# A socket-free tmux boundary for the real stage-wait coordinator specs.
set -euo pipefail
root="${GRIP_FAKE_TMUX_ROOT:?}"
scenario="${GRIP_FAKE_TMUX_CASE:?}"
case "$1" in
  wait-for)
    [[ "$2" == "fixture-import-staged" ]]
    printf 'wait:stage\n' >> "$root/calls"
    printf '%s\n' "$$" > "$root/waiter"
    case "$scenario" in
      no-prompt|old-prompt-in-grid) sleep 0.03 ;;
      complete-with-prompt) ;;
      stage-during-capture)
        while [[ ! -f "$root/grid-captured" ]]; do sleep 0.005; done
        touch "$root/current-prompt"
        ;;
      failed-stage) exit 7 ;;
      never-stage|prompt-without-stage|capture-error) exec sleep 30 ;;
      *)
        while [[ ! -f "$root/entered" ]]; do sleep 0.01; done
        if [[ "$scenario" == "sticky-prompt" ]]; then sleep 0.12; fi
        ;;
    esac
    printf 'stage-complete\n' >> "$root/calls"
    ;;
  capture-pane)
    [[ "$*" == "capture-pane -p -t fixture-session" ]]
    if [[ "$scenario" == "capture-error" ]]; then exit 9; fi
    count=0
    if [[ -f "$root/captures" ]]; then count="$(cat "$root/captures")"; fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$root/captures"
    if [[ "$scenario" == "stage-during-capture" && ! -f "$root/grid-captured" ]]; then
      # The captured grid predates the prompt/stage, but returns afterwards.
      touch "$root/grid-captured"
      while [[ ! -f "$root/current-prompt" ]]; do sleep 0.005; done
      sleep 0.04
      printf 'capture:result-before-stage\n' >> "$root/calls"
      printf '17 rows  Write: 4ms client  Query: 2ms client\n'
      exit 0
    fi
    case "$scenario" in
      no-prompt|old-prompt-in-grid|never-stage|failed-stage) prompt=false ;;
      late-prompt) [[ "$count" -lt 2 ]] && prompt=false || prompt=true ;;
      stage-during-capture) [[ -f "$root/current-prompt" ]] && prompt=true || prompt=false ;;
      *) prompt=true ;;
    esac
    if [[ "$prompt" == true ]]; then
      printf 'capture:prompt\n' >> "$root/calls"
      printf 'Press ENTER or type command to continue\n'
    else
      printf 'capture:result\n' >> "$root/calls"
      if [[ "$scenario" == "old-prompt-in-grid" ]]; then
        printf 'Press ENTER or type command to continue\n'
      fi
      printf '17 rows  Write: 4ms client  Query: 2ms client\n'
    fi
    ;;
  send-keys)
    [[ "$*" == "send-keys -t fixture-session Enter" ]]
    if [[ "$scenario" == "stage-during-capture" ]]; then
      [[ -f "$root/current-prompt" ]]
      rm "$root/current-prompt"
    fi
    printf 'send:Enter\n' >> "$root/calls"
    touch "$root/entered"
    ;;
  *) printf 'unexpected fake tmux operation: %s\n' "$*" >&2; exit 10 ;;
esac
