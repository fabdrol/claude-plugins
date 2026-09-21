#!/bin/bash
# Shared plumbing for tender's scripts: configuration, temp files, secrets
# guard, OpenRouter transport and the cost log. Source it; don't run it.
#
# Targets bash 3.2 (macOS) and bash 5 (Linux). Runtime deps: jq, curl.

TENDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TENDER_PLUGIN_DIR="$(cd "$TENDER_LIB_DIR/../.." && pwd)"

# tender_num <value> <default>: prints value if it is all digits, else default.
tender_num() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

TENDER_MIN_LINES=$(tender_num "${TENDER_MIN_LINES:-}" 350)
TENDER_MAX_PAYLOAD_BYTES=$(tender_num "${TENDER_MAX_PAYLOAD_BYTES:-}" 2000000)
TENDER_TIMEOUT=$(tender_num "${TENDER_TIMEOUT:-}" 180)
TENDER_READER_MODEL="${TENDER_READER_MODEL:-deepseek/deepseek-v4.1-flash}"
TENDER_WRITER_MODEL="${TENDER_WRITER_MODEL:-deepseek/deepseek-v4.1-flash}"
TENDER_API_URL="${TENDER_API_URL:-https://openrouter.ai/api/v1/chat/completions}"
TENDER_LOG="${TENDER_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/tender/usage.jsonl}"

# ---------------------------------------------------------------- temp files

TENDER_TMPFILES=""
# tender_tmpfile <varname>: mktemp, remember for cleanup, store path in varname.
tender_tmpfile() {
  local __tender_tmpfile_path
  __tender_tmpfile_path=$(mktemp) || return 1
  TENDER_TMPFILES="$TENDER_TMPFILES $__tender_tmpfile_path"
  # shellcheck disable=SC2064
  trap "rm -f $TENDER_TMPFILES" EXIT
  printf -v "$1" '%s' "$__tender_tmpfile_path"
}

# ---------------------------------------------------------------- preflight

tender_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  macOS: brew install jq curl   Debian/Ubuntu: apt install jq curl" >&2
    return 1
  fi
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "Error: OPENROUTER_API_KEY is not set." >&2
    echo "  Create a key at https://openrouter.ai/keys and export it in your shell profile." >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- cost log

tender_repo() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top="$PWD"
  basename "$top"
}

# tender_log <mode> <model> <files> <prompt> <cached> <completion> <cost> <duration_ms> <status> [detail]
# Appends one JSON line. Never fails the caller; warns on stderr instead.
tender_log() {
  local dir
  dir=$(dirname "$TENDER_LOG")
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "Warning: cannot create $dir; usage not logged" >&2
    return 0
  fi
  if ! jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg repo "$(tender_repo)" \
      --arg cwd "$PWD" \
      --arg mode "$1" \
      --arg model "$2" \
      --argjson files "$(tender_num "$3" 0)" \
      --argjson pt "$(tender_num "$4" 0)" \
      --argjson ct "$(tender_num "$5" 0)" \
      --argjson out "$(tender_num "$6" 0)" \
      --argjson cost "${7:-0}" \
      --argjson dur "$(tender_num "$8" 0)" \
      --arg status "$9" \
      --arg detail "${10:-}" \
      '{ts:$ts, repo:$repo, cwd:$cwd, mode:$mode, model:$model, files:$files,
        prompt_tokens:$pt, cached_tokens:$ct, completion_tokens:$out,
        cost:$cost, duration_ms:$dur, status:$status}
       + (if $detail == "" then {}
          elif $status == "refused" then {reason:$detail}
          else {error:$detail} end)' >> "$TENDER_LOG" 2>/dev/null; then
    echo "Warning: could not write $TENDER_LOG; usage not logged" >&2
  fi
  return 0
}
