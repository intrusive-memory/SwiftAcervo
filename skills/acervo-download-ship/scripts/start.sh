#!/bin/bash
# Launch a detached `acervo ship` download and write a tracking file.
#
# Usage: start.sh <model-id> [extra-acervo-args...]
#
# Writes:
#   /tmp/acervo-ship.tracking  (key=value pairs describing the in-flight job)
#   $LOG                       (combined stdout+stderr, with sentinel markers)
#
# Sentinel markers in the log (used by check.sh to detect completion):
#   ==ACERVO_START=<iso8601>==
#   ==ACERVO_MODEL=<model-id>==
#   ==ACERVO_EXIT=<code>==
#   ==ACERVO_END=<iso8601>==

set -euo pipefail

MODEL_ID="${1:-}"
if [ -z "$MODEL_ID" ]; then
  echo "error: model-id required" >&2
  echo "usage: $0 <model-id> [extra-acervo-args...]" >&2
  exit 2
fi
shift
EXTRA_ARGS=("$@")

TRACKING=/tmp/acervo-ship.tracking

# Pre-flight: refuse if another download is already in flight.
if [ -f "$TRACKING" ]; then
  # shellcheck disable=SC1090
  . "$TRACKING"
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    echo "error: another acervo ship is already running" >&2
    echo "  model: ${MODEL_ID_RUNNING:-${MODEL_ID:-unknown}}" >&2
    echo "  pid:   $PID" >&2
    echo "  log:   ${LOG:-unknown}" >&2
    echo "Only one download is allowed at a time. Wait for it to finish, or kill PID $PID." >&2
    exit 3
  fi
  # Stale tracking file (process exited but tracking wasn't cleaned). Remove it.
  rm -f "$TRACKING"
fi

TS=$(date -u +%Y%m%d-%H%M%SZ)
SLUG=$(echo "$MODEL_ID" | tr '/' '_')
LOG="/tmp/acervo-ship-${SLUG}-${TS}.log"

# Launch the download in a detached subshell. The wrapping bash captures the
# acervo exit code and emits an end-sentinel so check.sh can distinguish
# success/failure from a crashed process that never wrote an exit line.
nohup bash -c '
  MODEL_ID="$1"; shift
  LOG="$1"; shift
  {
    echo "==ACERVO_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)=="
    echo "==ACERVO_MODEL=$MODEL_ID=="
    echo "==ACERVO_CMD=acervo ship $MODEL_ID --no-verify $*=="
    acervo ship "$MODEL_ID" --no-verify "$@"
    ec=$?
    echo "==ACERVO_EXIT=$ec=="
    echo "==ACERVO_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)=="
  } > "$LOG" 2>&1
' _ "$MODEL_ID" "$LOG" "${EXTRA_ARGS[@]}" >/dev/null 2>&1 &
PID=$!
disown

# Write tracking file. Use a temp file + mv so check.sh never sees a partial file.
TMP=$(mktemp /tmp/acervo-ship.tracking.XXXXXX)
{
  echo "MODEL_ID=$MODEL_ID"
  echo "LOG=$LOG"
  echo "PID=$PID"
  echo "START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP"
mv "$TMP" "$TRACKING"

echo "STATE=launched"
echo "MODEL_ID=$MODEL_ID"
echo "LOG=$LOG"
echo "PID=$PID"
echo "TRACKING=$TRACKING"
