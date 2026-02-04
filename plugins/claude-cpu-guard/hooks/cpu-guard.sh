#!/bin/bash
# Claude CPU Guard — auto-kills stuck Claude Code processes
# When Claude stops but CPU stays above threshold for 30s → kill + show resume command
#
# State machine:
#   SessionStart      → idle + start watcher (daemonized)
#   UserPromptSubmit  → working (heartbeat update)
#   Stop              → stopped (instant, watcher handles the rest)
#
# Crash detection:
#   state file mtime stale (>STALE_TIMEOUT) + CPU high → crash, kill

CACHE_DIR="$HOME/.cache/claude-cpu-guard"
CPU_THRESHOLD=70
WATCH_DURATION=30
WATCH_INTERVAL=5
STALE_TIMEOUT=120

input=$(cat)
session_id=$(echo "$input" | jq -r '.session_id')
event=$(echo "$input" | jq -r '.hook_event_name')

mkdir -p "$CACHE_DIR"
tty_name=$(tty 2>/dev/null | sed 's|/dev/||')
if [ -z "$tty_name" ] || [ "$tty_name" = "not a tty" ]; then
  tty_name=$(ps -p $PPID -o tty= 2>/dev/null | xargs)
fi
[ -z "$tty_name" ] || [ "$tty_name" = "??" ] && exit 0

state_file="$CACHE_DIR/$tty_name.state"

case "$event" in
  SessionStart)
    [ -n "$session_id" ] && echo "$session_id" > "$CACHE_DIR/$tty_name"
    echo "idle" > "$state_file"

    # Kill old watcher if exists
    old_pid=$(cat "$CACHE_DIR/$tty_name.watcher" 2>/dev/null)
    [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null

    # Start watcher daemon (new session via perl setsid)
    perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' -- bash -c '
      CACHE_DIR="$1"; tty_name="$2"; WATCH_INTERVAL="$3"; CPU_THRESHOLD="$4"; WATCH_DURATION="$5"; STALE_TIMEOUT="$6"
      state_file="$CACHE_DIR/$tty_name.state"
      echo $$ > "$CACHE_DIR/$tty_name.watcher"

      is_cpu_high() {
        local pid="$1"
        local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs)
        [ -n "$cpu" ] && (( $(echo "$cpu > $CPU_THRESHOLD" | bc -l) ))
      }

      kill_and_resume() {
        local cached_session=$(cat "$CACHE_DIR/$tty_name" 2>/dev/null)
        local claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
        local cwd=$(lsof -p "$claude_pid" -Fn 2>/dev/null | awk "/^fcwd/{getline; print substr(\$0,2)}")
        [ -z "$cached_session" ] || [ -z "$claude_pid" ] || [ -z "$cwd" ] && return 1

        local escaped_cwd=$(printf "%s" "$cwd" | sed "s/'"'"'/'"'"'\\\\'"'"''"'"'/g")
        kill "$claude_pid" 2>/dev/null
        sleep 1
        kill -0 "$claude_pid" 2>/dev/null && kill -9 "$claude_pid" 2>/dev/null
        sleep 1
        printf "%s" "cd '"'"'${escaped_cwd}'"'"' && claude --resume ${cached_session}" > "/dev/$tty_name"
        echo "idle" > "$state_file"
      }

      while true; do
        sleep "$WATCH_INTERVAL"

        # TTY gone (terminal closed) → self-terminate
        [ ! -e "/dev/$tty_name" ] && rm -f "$CACHE_DIR/$tty_name" "$state_file" "$CACHE_DIR/$tty_name.watcher" && exit 0

        current_state=$(cat "$state_file" 2>/dev/null)

        # Crash detection: state file not updated for STALE_TIMEOUT + CPU high
        if [ "$current_state" = "working" ]; then
          mtime=$(stat -f %m "$state_file" 2>/dev/null)
          now=$(date +%s)
          age=$(( now - mtime ))
          if [ "$age" -ge "$STALE_TIMEOUT" ]; then
            claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
            [ -n "$claude_pid" ] && is_cpu_high "$claude_pid" && kill_and_resume
          fi
          continue
        fi

        # Normal flow: state=stopped → watch CPU for WATCH_DURATION
        [ "$current_state" != "stopped" ] && continue

        checks=$((WATCH_DURATION / WATCH_INTERVAL))
        high_count=0
        for ((i=0; i<checks; i++)); do
          sleep "$WATCH_INTERVAL"

          current_state=$(cat "$state_file" 2>/dev/null)
          [ "$current_state" != "stopped" ] && break

          claude_pid=$(ps -t "$tty_name" -o pid=,comm= 2>/dev/null | grep claude | head -1 | awk "{print \$1}")
          [ -z "$claude_pid" ] && break

          is_cpu_high "$claude_pid" && high_count=$((high_count + 1))
        done

        [ "$high_count" -ge "$checks" ] && kill_and_resume
      done
    ' _ "$CACHE_DIR" "$tty_name" "$WATCH_INTERVAL" "$CPU_THRESHOLD" "$WATCH_DURATION" "$STALE_TIMEOUT" </dev/null >/dev/null 2>&1
    ;;
  UserPromptSubmit)
    echo "working" > "$state_file"
    ;;
  Stop)
    echo "stopped" > "$state_file"
    ;;
esac
