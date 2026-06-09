#!/usr/bin/env bash
set -euo pipefail

PROCESS_NAME="Donkey"
STYLE="compact"
MODE="stream"
LAST_DURATION=""
PID=""
SUBSYSTEM=""
CATEGORY=""
CONTAINS_TEXT=""
ERRORS_ONLY=0
INCLUDE_INFO=1
INCLUDE_DEBUG=0

usage() {
  cat <<'EOF'
Tail Donkey logs from macOS Unified Logging.

Usage:
  scripts/tail-donkey-logs.sh [options]

Options:
  --process NAME       Process name to filter. Default: Donkey
  --pid PID            Process ID to filter instead of process name.
  --errors             Show only error and fault messages.
  --debug              Include debug messages as well as default/info logs.
  --no-info            Do not include info messages.
  --subsystem NAME     Add a subsystem filter.
  --category NAME      Add a category filter.
  --contains TEXT      Add a message text contains filter.
  --last DURATION      Show recent history instead of streaming, e.g. 5m, 1h.
  --style STYLE        log(1) style. Default: compact
  -h, --help           Show this help.

Examples:
  scripts/tail-donkey-logs.sh
  scripts/tail-donkey-logs.sh --errors
  scripts/tail-donkey-logs.sh --last 10m --errors
  scripts/tail-donkey-logs.sh --pid 88494 --debug
EOF
}

quote_predicate_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

append_clause() {
  local clause="$1"
  if [ -z "$PREDICATE" ]; then
    PREDICATE="$clause"
  else
    PREDICATE="$PREDICATE AND $clause"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --process)
      PROCESS_NAME="${2:?--process requires a value}"
      shift 2
      ;;
    --pid)
      PID="${2:?--pid requires a value}"
      shift 2
      ;;
    --errors)
      ERRORS_ONLY=1
      shift
      ;;
    --debug)
      INCLUDE_DEBUG=1
      shift
      ;;
    --no-info)
      INCLUDE_INFO=0
      shift
      ;;
    --subsystem)
      SUBSYSTEM="${2:?--subsystem requires a value}"
      shift 2
      ;;
    --category)
      CATEGORY="${2:?--category requires a value}"
      shift 2
      ;;
    --contains)
      CONTAINS_TEXT="${2:?--contains requires a value}"
      shift 2
      ;;
    --last)
      MODE="show"
      LAST_DURATION="${2:?--last requires a duration}"
      shift 2
      ;;
    --style)
      STYLE="${2:?--style requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -n "$PID" ] && ! [[ "$PID" =~ ^[0-9]+$ ]]; then
  echo "--pid must be numeric." >&2
  exit 2
fi

PREDICATE=""
if [ -n "$PID" ]; then
  append_clause "processID == $PID"
else
  append_clause "process == $(quote_predicate_value "$PROCESS_NAME")"
fi

if [ "$ERRORS_ONLY" -eq 1 ]; then
  append_clause "(messageType == error OR messageType == fault)"
fi

if [ -n "$SUBSYSTEM" ]; then
  append_clause "subsystem == $(quote_predicate_value "$SUBSYSTEM")"
fi

if [ -n "$CATEGORY" ]; then
  append_clause "category == $(quote_predicate_value "$CATEGORY")"
fi

if [ -n "$CONTAINS_TEXT" ]; then
  append_clause "eventMessage CONTAINS[c] $(quote_predicate_value "$CONTAINS_TEXT")"
fi

LOG_COMMAND=(/usr/bin/log "$MODE" --style "$STYLE" --predicate "$PREDICATE")

if [ "$MODE" = "show" ]; then
  LOG_COMMAND=(/usr/bin/log show --last "$LAST_DURATION" --style "$STYLE" --predicate "$PREDICATE")
fi

if [ "$INCLUDE_INFO" -eq 1 ]; then
  LOG_COMMAND+=(--info)
fi

if [ "$INCLUDE_DEBUG" -eq 1 ]; then
  LOG_COMMAND+=(--debug)
fi

# Trim the unified-log boilerplate down to "HH:MM:SS.mmm  message": drop the date,
# the message-type letter, the "Process[pid:tid]" column, and the "[subsystem:category]"
# tag, which are identical on every Donkey line and just add noise.
reformat_log_stream() {
  sed -E \
    -e '/^Filtering the log data using /d' \
    -e '/^Timestamp[[:space:]]+Ty/d' \
    -e 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} //' \
    -e 's/^([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+) +[A-Za-z]+ +[^[]*\[[0-9]+:[0-9a-fx]+\] +(\[[^]]*\] )?/\1  /'
}

exec "${LOG_COMMAND[@]}" > >(reformat_log_stream) 2> >(reformat_log_stream >&2)
