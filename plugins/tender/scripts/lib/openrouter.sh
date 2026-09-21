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

# ---------------------------------------------------------------- transport

# tender_strip_fences: stdin → stdout, dropping a first line that starts with
# ``` and a last line that is only ```. Inner fences are kept.
tender_strip_fences() {
  awk 'NR == 1 && /^```/ { next }
       { buf[++n] = $0 }
       END {
         if (n > 0 && buf[n] ~ /^```[[:space:]]*$/) n--
         for (i = 1; i <= n; i++) print buf[i]
       }'
}

TENDER_LAST_SUMMARY=""
TENDER_GUARD_BYPASSED=""

# tender_invoke <mode> <model> <system_file> <message_file> <files_count>
# Prints the completion. Returns 1 on any failure (message on stderr, logged).
tender_invoke() {
  local mode="$1" model="$2" system_file="$3" message_file="$4" nfiles="$5"
  local body resp bytes rc err content pt ct out cost dur secs curl_err curl_msg log_detail

  tender_tmpfile body || return 1
  tender_tmpfile resp || return 1
  tender_tmpfile curl_err || return 1

  jq -n --arg model "$model" --rawfile sys "$system_file" --rawfile msg "$message_file" \
    '{model: $model,
      messages: [{role: "system", content: $sys}, {role: "user", content: $msg}],
      temperature: 0.2,
      provider: {data_collection: "deny"}}' > "$body" || return 1

  bytes=$(wc -c < "$body" | tr -d ' ')
  if [ "$bytes" -gt "$TENDER_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: request is $bytes bytes, over TENDER_MAX_PAYLOAD_BYTES ($TENDER_MAX_PAYLOAD_BYTES)." >&2
    echo "  Send fewer or smaller files, or raise TENDER_MAX_PAYLOAD_BYTES if the model's context allows." >&2
    tender_log "$mode" "$model" "$nfiles" 0 0 0 0 0 error "payload too large ($bytes bytes)"
    return 1
  fi

  SECONDS=0
  curl -sS --max-time "$TENDER_TIMEOUT" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/fabdrol/claude-plugins" \
    -H "X-Title: tender" \
    --data-binary "@$body" -o "$resp" "$TENDER_API_URL" 2>"$curl_err"
  rc=$?
  secs=$SECONDS
  dur=$((secs * 1000))

  if [ "$rc" -ne 0 ]; then
    echo "Error: request to $TENDER_API_URL failed (curl exit $rc)." >&2
    if [ -s "$curl_err" ]; then
      sed 's/^/  /' "$curl_err" >&2
    fi
    if [ "$rc" -eq 28 ]; then
      echo "  Timed out after ${TENDER_TIMEOUT}s. Split the work into smaller calls or raise TENDER_TIMEOUT." >&2
    fi
    curl_msg=$(head -1 "$curl_err")
    log_detail="curl exit $rc"
    [ -n "$curl_msg" ] && log_detail="$curl_msg"
    tender_log "$mode" "$model" "$nfiles" 0 0 0 0 "$dur" error "$log_detail"
    return 1
  fi

  if ! jq -e . "$resp" >/dev/null 2>&1; then
    echo "Error: unparseable response from $TENDER_API_URL:" >&2
    head -c 400 "$resp" >&2; echo >&2
    tender_log "$mode" "$model" "$nfiles" 0 0 0 0 "$dur" error "unparseable response"
    return 1
  fi

  err=$(jq -r '.error.message // empty' "$resp")
  if [ -n "$err" ]; then
    echo "Error: OpenRouter: $err" >&2
    tender_log "$mode" "$model" "$nfiles" 0 0 0 0 "$dur" error "$err"
    return 1
  fi

  content=$(jq -r '.choices[0].message.content // empty' "$resp")
  if [ -z "$content" ]; then
    echo "Error: empty completion from $model." >&2
    tender_log "$mode" "$model" "$nfiles" 0 0 0 0 "$dur" error "empty completion"
    return 1
  fi

  pt=$(jq -r '.usage.prompt_tokens // 0' "$resp")
  ct=$(jq -r '.usage.prompt_tokens_details.cached_tokens // 0' "$resp")
  out=$(jq -r '.usage.completion_tokens // 0' "$resp")
  cost=$(jq -r '(.usage.cost // 0) | tostring' "$resp")
  case "$cost" in
    ''|*[!0-9.eE+-]*) cost=0 ;;
  esac
  case "$cost" in
    *[0-9]*) ;;
    *) cost=0 ;;
  esac
  tender_log "$mode" "$model" "$nfiles" "$pt" "$ct" "$out" "$cost" "$dur" ok

  TENDER_LAST_SUMMARY="[tender $mode: $nfiles file(s), ${pt} in (${ct} cached) / ${out} out, \$${cost}, ${secs}s, $model${TENDER_GUARD_BYPASSED:+, secrets guard OFF}]"
  printf '%s\n' "$content"
  return 0
}
