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

# ---------------------------------------------------------------- lib: config
echo "-- lib: config"
out=$(bash -c ". '$SCRIPTS/lib/openrouter.sh'; echo \$TENDER_MIN_LINES \$TENDER_TIMEOUT \$TENDER_MAX_PAYLOAD_BYTES; echo \$TENDER_READER_MODEL; echo \$TENDER_API_URL")
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

report
