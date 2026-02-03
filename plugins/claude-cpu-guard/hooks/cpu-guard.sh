#!/bin/bash
# Claude CPU Guard — auto-kills stuck Claude Code processes
# When Claude stops but CPU stays above threshold for 30s → kill + show resume command
#
# State machine:
#   SessionStart      → idle
#   UserPromptSubmit  → working (don't touch)
#   Stop              → stopped → watch CPU for 30s → all high? → kill

CACHE_DIR="$HOME/.cache/claude-cpu-guard"
CPU_THRESHOLD=80
WATCH_DURATION=30
WATCH_INTERVAL=5

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id')
event=$(echo "$input" | jq -r '.hook_event_name')

mkdir -p "$CACHE_DIR"
tty_name=$(tty 2>/dev/null | sed 's|/dev/||')
if [ -z "$tty_name" ] || [ "$tty_name" = "not a tty" ]; then
  tty_name=$(ps -p $PPID -o tty= 2>/dev/null | xargs)
fi
[ -z "$tty_name" ] || [ "$tty_name" = "??" ] && exit 0

case "$event" in
  SessionStart)
    [ -n "$session_id" ] && echo "$session_id" > "$CACHE_DIR/$tty_name"
    echo "idle" > "$CACHE_DIR/$tty_name.state"
    ;;
  UserPromptSubmit)
    echo "working" > "$CACHE_DIR/$tty_name.state"
    ;;
  Stop)
    echo "stopped" > "$CACHE_DIR/$tty_name.state"

    nohup bash -c '
      CACHE_DIR="$1"; tty_name="$2"; WATCH_INTERVAL="$3"; CPU_THRESHOLD="$4"
      checks=$(($5 / WATCH_INTERVAL))
      high_count=0

      for ((i=0; i<checks; i++)); do
        sleep "$WATCH_INTERVAL"

        current_state=$(cat "$CACHE_DIR/$tty_name.state" 2>/dev/null)
        [ "$current_state" != "stopped" ] && exit 0

        claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
        [ -z "$claude_pid" ] && exit 0

        cpu=$(ps -p "$claude_pid" -o %cpu= 2>/dev/null | xargs)
        [ -z "$cpu" ] && exit 0

        if (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l) )); then
          high_count=$((high_count + 1))
        fi
      done

      [ "$high_count" -lt "$checks" ] && exit 0

      cached_session=$(cat "$CACHE_DIR/$tty_name" 2>/dev/null)
      claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
      cwd=$(lsof -p "$claude_pid" -Fn 2>/dev/null | awk "/^fcwd/{getline; print substr(\$0,2)}")
      [ -z "$cached_session" ] && exit 0
      [ -z "$claude_pid" ] && exit 0
      [ -z "$cwd" ] && exit 0

      escaped_cwd=$(printf "%s" "$cwd" | sed "s/'"'"'/'"'"'\\\\'"'"''"'"'/g")
      kill "$claude_pid" 2>/dev/null
      sleep 1
      kill -0 "$claude_pid" 2>/dev/null && kill -9 "$claude_pid" 2>/dev/null
      sleep 1
      printf "%s" "cd '"'"'${escaped_cwd}'"'"' && claude --resume ${cached_session}" > "/dev/$tty_name"
    ' _ "$CACHE_DIR" "$tty_name" "$WATCH_INTERVAL" "$CPU_THRESHOLD" "$WATCH_DURATION" </dev/null >/dev/null 2>&1 &
    ;;
esac
