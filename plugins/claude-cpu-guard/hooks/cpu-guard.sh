#!/bin/bash
# Claude CPU Guard — auto-kills stuck Claude Code processes
# When Claude stops but CPU stays above threshold for 30s → kill + show resume command
#
# State machine:
#   SessionStart      → idle + start watcher (daemonized)
#   UserPromptSubmit  → working (don't touch)
#   Stop              → stopped (instant, watcher handles the rest)

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

    # Kill old watcher if exists
    old_pid=$(cat "$CACHE_DIR/$tty_name.watcher" 2>/dev/null)
    [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null

    # Start watcher daemon (new session via perl setsid)
    perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' -- bash -c '
      CACHE_DIR="$1"; tty_name="$2"; WATCH_INTERVAL="$3"; CPU_THRESHOLD="$4"; WATCH_DURATION="$5"
      echo $$ > "$CACHE_DIR/$tty_name.watcher"

      while true; do
        sleep "$WATCH_INTERVAL"

        # TTY gone (terminal closed) → self-terminate
        [ ! -e "/dev/$tty_name" ] && rm -f "$CACHE_DIR/$tty_name" "$CACHE_DIR/$tty_name.state" "$CACHE_DIR/$tty_name.watcher" && exit 0

        current_state=$(cat "$CACHE_DIR/$tty_name.state" 2>/dev/null)
        [ "$current_state" != "stopped" ] && continue

        checks=$((WATCH_DURATION / WATCH_INTERVAL))
        high_count=0
        for ((i=0; i<checks; i++)); do
          sleep "$WATCH_INTERVAL"

          current_state=$(cat "$CACHE_DIR/$tty_name.state" 2>/dev/null)
          [ "$current_state" != "stopped" ] && break

          claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
          [ -z "$claude_pid" ] && break

          cpu=$(ps -p "$claude_pid" -o %cpu= 2>/dev/null | xargs)
          [ -z "$cpu" ] && break

          if (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l) )); then
            high_count=$((high_count + 1))
          fi
        done

        [ "$high_count" -lt "$checks" ] && continue

        cached_session=$(cat "$CACHE_DIR/$tty_name" 2>/dev/null)
        claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
        cwd=$(lsof -p "$claude_pid" -Fn 2>/dev/null | awk "/^fcwd/{getline; print substr(\$0,2)}")
        [ -z "$cached_session" ] && continue
        [ -z "$claude_pid" ] && continue
        [ -z "$cwd" ] && continue

        escaped_cwd=$(printf "%s" "$cwd" | sed "s/'"'"'/'"'"'\\\\'"'"''"'"'/g")
        kill "$claude_pid" 2>/dev/null
        sleep 1
        kill -0 "$claude_pid" 2>/dev/null && kill -9 "$claude_pid" 2>/dev/null
        sleep 1
        printf "%s" "cd '"'"'${escaped_cwd}'"'"' && claude --resume ${cached_session}" > "/dev/$tty_name"
        echo "idle" > "$CACHE_DIR/$tty_name.state"
      done
    ' _ "$CACHE_DIR" "$tty_name" "$WATCH_INTERVAL" "$CPU_THRESHOLD" "$WATCH_DURATION" </dev/null >/dev/null 2>&1
    ;;
  UserPromptSubmit)
    echo "working" > "$CACHE_DIR/$tty_name.state"
    ;;
  Stop)
    echo "stopped" > "$CACHE_DIR/$tty_name.state"
    ;;
esac
