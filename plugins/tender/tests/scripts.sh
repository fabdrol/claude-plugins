#!/bin/bash
# Tests for lib/openrouter.sh and the tender-* scripts, offline against a stub.
TESTS="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$TESTS/.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
. "$TESTS/lib.sh"

TMP="$TESTS/.tmp"
rm -rf "$TMP"; mkdir -p "$TMP"
export TENDER_LOG="$TMP/usage.jsonl"
export OPENROUTER_API_KEY="test-key"
export HOME="$TMP/home"; mkdir -p "$HOME"
unset TENDER_MIN_LINES TENDER_MAX_PAYLOAD_BYTES TENDER_TIMEOUT TENDER_READER_MODEL \
      TENDER_WRITER_MODEL TENDER_API_URL TENDER_DENY_GLOBS TENDER_ALLOW_SECRETS TENDER_DISABLED

# ---------------------------------------------------------------- stub server
STUB_PORT="${STUB_PORT:-48123}"
export STUB_LAST_REQUEST="$TMP/last-request.json"
python3 "$TESTS/stub/openrouter-stub.py" "$STUB_PORT" &
STUB_PID=$!
trap 'kill $STUB_PID 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  curl -s -o /dev/null "http://127.0.0.1:$STUB_PORT/" && break
  sleep 0.25
done
export TENDER_API_URL="http://127.0.0.1:$STUB_PORT/api/v1/chat/completions"

# invoke <mode> <model> <system text> <message text> [files]; echoes stdout, sets RC/ERR/SUMMARY
invoke() {
  local sysf="$TMP/sys.txt" msgf="$TMP/msg.txt" errf="$TMP/err.txt"
  printf '%s' "$3" > "$sysf"; printf '%s' "$4" > "$msgf"
  OUT=$(cd "$TMP" && bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_invoke '$1' '$2' '$sysf' '$msgf' '${5:-1}'; rc=\$?; echo \"SUMMARY=\$TENDER_LAST_SUMMARY\" >&2; exit \$rc" 2>"$errf")
  RC=$?
  ERR=$(cat "$errf")
  SUMMARY=$(grep '^SUMMARY=' "$errf" | sed 's/^SUMMARY=//')
}

# ---------------------------------------------------------------- lib: config
echo "-- lib: config"
out=$(TENDER_API_URL= bash -c ". '$SCRIPTS/lib/openrouter.sh'; echo \$TENDER_MIN_LINES \$TENDER_TIMEOUT \$TENDER_MAX_PAYLOAD_BYTES; echo \$TENDER_READER_MODEL; echo \$TENDER_API_URL")
assert_eq "numeric defaults" "350 180 2000000" "$(echo "$out" | sed -n 1p)"
assert_eq "reader model default" "deepseek/deepseek-v4.1-flash" "$(echo "$out" | sed -n 2p)"
assert_eq "api url default" "https://openrouter.ai/api/v1/chat/completions" "$(echo "$out" | sed -n 3p)"

out=$(TENDER_MIN_LINES=abc TENDER_TIMEOUT=12 bash -c ". '$SCRIPTS/lib/openrouter.sh'; echo \$TENDER_MIN_LINES \$TENDER_TIMEOUT")
assert_eq "non-numeric falls back, numeric kept" "350 12" "$out"

out=$(unset TENDER_LOG; XDG_STATE_HOME="$TMP/xdg" bash -c ". '$SCRIPTS/lib/openrouter.sh'; echo \$TENDER_LOG")
assert_eq "log honours XDG_STATE_HOME" "$TMP/xdg/tender/usage.jsonl" "$out"

out=$(unset TENDER_LOG XDG_STATE_HOME; bash -c ". '$SCRIPTS/lib/openrouter.sh'; echo \$TENDER_LOG")
assert_eq "log default under HOME" "$HOME/.local/state/tender/usage.jsonl" "$out"

# ---------------------------------------------------------------- lib: preflight
echo "-- lib: preflight"
err=$(OPENROUTER_API_KEY= bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_preflight" 2>&1); rc=$?
assert_exit "preflight fails without key" 1 $rc
assert_contains "preflight names the key" "$err" "OPENROUTER_API_KEY"
bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_preflight" 2>/dev/null; rc=$?
assert_exit "preflight passes with key" 0 $rc

# ---------------------------------------------------------------- lib: tmpfile
echo "-- lib: tmpfile"
path=$(bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_tmpfile f; echo \$f; [ -f \"\$f\" ] && echo exists")
f=$(echo "$path" | sed -n 1p)
assert_eq "tmpfile exists during script" "exists" "$(echo "$path" | sed -n 2p)"
[ -e "$f" ] && fail "tmpfile removed on exit" "$f still exists" || pass "tmpfile removed on exit"
path=$(bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_tmpfile tmp_file; [ -n \"\$tmp_file\" ] && [ -f \"\$tmp_file\" ] && echo set")
assert_eq "tmpfile works for varname tmp_file" "set" "$path"

# ---------------------------------------------------------------- lib: log
echo "-- lib: log"
rm -f "$TENDER_LOG"
(cd "$TMP" && bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_log read some/model 3 100 10 20 0.0042 900 ok")
line=$(tail -1 "$TENDER_LOG")
assert_eq "log is valid json" "read" "$(printf '%s' "$line" | jq -r .mode)"
assert_eq "log numbers are numbers" "100 10 20 0.0042 900" "$(printf '%s' "$line" | jq -r '"\(.prompt_tokens) \(.cached_tokens) \(.completion_tokens) \(.cost) \(.duration_ms)"')"
assert_eq "log repo is git toplevel basename" "$(basename "$(git -C "$TMP" rev-parse --show-toplevel)")" "$(printf '%s' "$line" | jq -r .repo)"
(cd "$TMP" && GIT_DIR=/nonexistent bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_log read some/model 1 0 0 0 0 0 ok")
assert_eq "log repo falls back to cwd basename outside git" ".tmp" "$(tail -1 "$TENDER_LOG" | jq -r .repo)"
assert_contains "log has ts" "$(printf '%s' "$line" | jq -r .ts)" "T"
assert_eq "log has no error key on ok" "null" "$(printf '%s' "$line" | jq -r .error)"

(cd "$TMP" && bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_log read '' 0 0 0 0 0 0 refused 'refused: x'")
assert_eq "refused logs reason" "refused: x" "$(tail -1 "$TENDER_LOG" | jq -r .reason)"
(cd "$TMP" && bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_log write m 1 0 0 0 0 5 error 'boom'")
assert_eq "error logs error" "boom" "$(tail -1 "$TENDER_LOG" | jq -r .error)"

err=$(TENDER_LOG=/dev/null/nope/usage.jsonl bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_log read m 1 0 0 0 0 0 ok; echo rc=\$?" 2>&1)
assert_contains "unwritable log warns but returns 0" "$err" "rc=0"
assert_contains "unwritable log names the problem" "$err" "Warning"

# ---------------------------------------------------------------- lib: invoke
echo "-- lib: invoke"
rm -f "$TENDER_LOG"
invoke read stub/ok "SYSTEM PROMPT" "hello world" 2
assert_exit "ok returns 0" 0 $RC
assert_contains "ok prints content" "$OUT" "STUB ANSWER"
assert_contains "ok content names model" "$OUT" "stub/ok"
req=$(cat "$STUB_LAST_REQUEST")
assert_eq "request model" "stub/ok" "$(printf '%s' "$req" | jq -r .model)"
assert_eq "request system prompt" "SYSTEM PROMPT" "$(printf '%s' "$req" | jq -r '.messages[0].content')"
assert_eq "request user message" "hello world" "$(printf '%s' "$req" | jq -r '.messages[1].content')"
assert_eq "request temperature" "0.2" "$(printf '%s' "$req" | jq -r .temperature)"
assert_eq "request denies data collection" "deny" "$(printf '%s' "$req" | jq -r .provider.data_collection)"
line=$(tail -1 "$TENDER_LOG")
assert_eq "ok logged" "ok" "$(printf '%s' "$line" | jq -r .status)"
assert_eq "log tokens from usage" "2 3 12 0.0042" "$(printf '%s' "$line" | jq -r '"\(.files) \(.cached_tokens) \(.completion_tokens) \(.cost)"')"
assert_contains "summary has mode" "$SUMMARY" "[tender read:"
assert_contains "summary has cost" "$SUMMARY" "\$0.0042"
assert_contains "summary has model" "$SUMMARY" "stub/ok"
assert_not_contains "summary hides guard note when guard on" "$SUMMARY" "guard OFF"

invoke read stub/error "s" "m"
assert_exit "error envelope returns 1" 1 $RC
assert_contains "error envelope surfaces message" "$ERR" "stub failure"
assert_eq "error logged" "error" "$(tail -1 "$TENDER_LOG" | jq -r .status)"
assert_eq "error logged with message" "stub failure" "$(tail -1 "$TENDER_LOG" | jq -r .error)"

invoke read stub/garbage "s" "m"
assert_exit "garbage returns 1" 1 $RC
assert_contains "garbage reported" "$ERR" "unparseable"

invoke read stub/empty "s" "m"
assert_exit "empty returns 1" 1 $RC
assert_contains "empty reported" "$ERR" "empty completion"
assert_eq "empty prints nothing" "" "$OUT"

TENDER_MAX_PAYLOAD_BYTES=100 invoke read stub/ok "s" "$(printf 'x%.0s' $(seq 1 200))"
assert_exit "oversize returns 1" 1 $RC
assert_contains "oversize reported" "$ERR" "TENDER_MAX_PAYLOAD_BYTES"
assert_eq "oversize logged" "error" "$(tail -1 "$TENDER_LOG" | jq -r .status)"

TENDER_TIMEOUT=1 invoke read stub/slow "s" "m"
assert_exit "timeout returns 1" 1 $RC
assert_contains "timeout hints to split" "$ERR" "Split"

TENDER_API_URL="http://127.0.0.1:1/x" invoke read stub/ok "s" "m"
assert_exit "connection refused returns 1" 1 $RC
assert_contains "connection refused reported" "$ERR" "curl exit"

TENDER_API_URL="http://nonexistent.invalid/x" invoke read stub/ok "s" "m"
assert_exit "dns failure returns 1" 1 $RC
assert_contains "dns failure shows curl text" "$ERR" "resolve"
assert_contains "dns failure logged with curl text" "$(tail -1 "$TENDER_LOG" | jq -r .error)" "resolve"

invoke read stub/badcost "s" "m"
assert_exit "bad cost still returns 0" 0 $RC
assert_eq "bad cost logged as 0" "0" "$(tail -1 "$TENDER_LOG" | jq -r .cost)"
assert_eq "bad cost row is still ok" "ok" "$(tail -1 "$TENDER_LOG" | jq -r .status)"

out=$(printf '```ts\nline1\nline2\n```\n' | bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_strip_fences")
assert_eq "strip fences removes outer fences" "line1
line2" "$out"
out=$(printf 'no fences\n' | bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_strip_fences")
assert_eq "strip fences leaves plain text" "no fences" "$out"
out=$(printf 'a\n```\ninner\n```\nb\n' | bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_strip_fences")
assert_eq "strip fences keeps inner fences" "a
\`\`\`
inner
\`\`\`
b" "$out"

report
