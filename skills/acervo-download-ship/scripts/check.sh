#!/bin/bash
# Report the status of the current acervo ship download (if any).
#
# Output is key=value pairs followed by ---LOG_TAIL--- and the last N log lines.
# Designed to be parsed by humans and by SKILL.md instructions.
#
# STATE values:
#   none      - no tracking file; nothing in flight
#   running   - tracked process is alive
#   success   - tracked process exited 0
#   failure   - tracked process exited non-zero (EXIT_CODE field gives the code)
#   died      - tracked process gone but no exit sentinel found (crashed/killed)

set -euo pipefail

TRACKING=/tmp/acervo-ship.tracking
TAIL_LINES="${1:-30}"

if [ ! -f "$TRACKING" ]; then
  echo "STATE=none"
  exit 0
fi

# shellcheck disable=SC1090
. "$TRACKING"

if [ -z "${PID:-}" ] || [ -z "${LOG:-}" ]; then
  echo "STATE=none"
  echo "note=tracking file present but malformed; removing"
  rm -f "$TRACKING"
  exit 0
fi

if kill -0 "$PID" 2>/dev/null; then
  # Still running.
  ELAPSED_S=""
  if [ -n "${START:-}" ]; then
    # macOS date supports -j -f for parsing.
    if start_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$START" +%s 2>/dev/null); then
      now_epoch=$(date -u +%s)
      ELAPSED_S=$((now_epoch - start_epoch))
    fi
  fi
  echo "STATE=running"
  echo "MODEL_ID=${MODEL_ID:-unknown}"
  echo "LOG=$LOG"
  echo "PID=$PID"
  echo "START=${START:-unknown}"
  [ -n "$ELAPSED_S" ] && echo "ELAPSED_SECONDS=$ELAPSED_S"
  echo "---LOG_TAIL---"
  tr '\r' '\n' < "$LOG" 2>/dev/null | tail -n "$TAIL_LINES" || echo "(log unreadable: $LOG)"
  exit 0
fi

# Process is gone. Look for the exit sentinel.
exit_line=$(grep "==ACERVO_EXIT=" "$LOG" 2>/dev/null | tail -1 || true)
if [ -z "$exit_line" ]; then
  echo "STATE=died"
  echo "MODEL_ID=${MODEL_ID:-unknown}"
  echo "LOG=$LOG"
  echo "PID=$PID"
  echo "note=process exited without writing exit sentinel (crashed, killed, or out-of-memory)"
  echo "---LOG_TAIL---"
  tr '\r' '\n' < "$LOG" 2>/dev/null | tail -n "$TAIL_LINES" || echo "(log unreadable: $LOG)"
  exit 0
fi

ec=$(echo "$exit_line" | sed -n 's/.*==ACERVO_EXIT=\([0-9]*\)==.*/\1/p')
if [ "$ec" = "0" ]; then
  echo "STATE=success"
else
  echo "STATE=failure"
fi
echo "EXIT_CODE=${ec:-unknown}"
echo "MODEL_ID=${MODEL_ID:-unknown}"
echo "LOG=$LOG"
echo "PID=$PID"
echo "START=${START:-unknown}"
echo "---LOG_TAIL---"
tr '\r' '\n' < "$LOG" 2>/dev/null | tail -n "$TAIL_LINES" || echo "(log unreadable: $LOG)"
