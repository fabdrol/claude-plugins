#!/bin/bash
# Hook decision tests. Offline. Generates fixture files of given line counts.
TESTS="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$TESTS/../hooks" && pwd)"
. "$TESTS/lib.sh"

FX="$TESTS/.fixtures"
rm -rf "$FX"; mkdir -p "$FX"
export TMPDIR="$FX"
export OPENROUTER_API_KEY="test-key"
unset TENDER_MIN_LINES TENDER_DISABLED

gen() { seq 1 "$2" | awk '{print "line " NR}' > "$1"; }
gen "$FX/small.ts" 100
gen "$FX/edge.ts" 350
gen "$FX/big.ts" 900
: > "$FX/empty.ts"

# read_hook <json> → prints the decision; full output saved to $FX/last.json for `last`
read_hook() { printf '%s' "$1" | "$HOOKS/check-file-size" > "$FX/last.json"; jq -r '.hookSpecificOutput.permissionDecision' "$FX/last.json"; }
last() { jq -r "$1" "$FX/last.json"; }
read_json() { jq -cn --arg p "$1" --arg s "${2:-s1}" '{session_id:$s, cwd:"/", tool_name:"Read", tool_input:{file_path:$p}}'; }

echo "-- check-file-size"
assert_eq "small file allowed" allow "$(read_hook "$(read_json "$FX/small.ts")")"
assert_eq "file at threshold allowed" allow "$(read_hook "$(read_json "$FX/edge.ts")")"
assert_eq "empty file allowed" allow "$(read_hook "$(read_json "$FX/empty.ts")")"
assert_eq "missing file allowed" allow "$(read_hook "$(read_json "$FX/nope.ts")")"
assert_eq "empty path allowed" allow "$(read_hook '{"tool_input":{}}')"
assert_eq "big file denied" deny "$(read_hook "$(read_json "$FX/big.ts")")"
reason=$(last '.hookSpecificOutput.permissionDecisionReason')
assert_contains "deny reason has line count" "$reason" "900 lines"
assert_contains "deny reason has threshold" "$reason" "threshold 350"
assert_contains "deny reason has script path" "$reason" "$(cd "$HOOKS/.." && pwd)/scripts/tender-read"
assert_contains "deny reason has file path" "$reason" "$FX/big.ts"
assert_contains "deny reason names skill" "$reason" "/tender:read"
assert_eq "hookEventName set" PreToolUse "$(last '.hookSpecificOutput.hookEventName')"

assert_eq "offset makes it targeted" allow "$(read_hook "$(jq -cn --arg p "$FX/big.ts" '{tool_input:{file_path:$p, offset:10}}')")"
assert_eq "limit makes it targeted" allow "$(read_hook "$(jq -cn --arg p "$FX/big.ts" '{tool_input:{file_path:$p, limit:50}}')")"

assert_eq "custom threshold denies" deny "$(TENDER_MIN_LINES=50 read_hook "$(read_json "$FX/small.ts")")"
assert_eq "custom threshold allows" allow "$(TENDER_MIN_LINES=1000 read_hook "$(read_json "$FX/big.ts")")"
assert_eq "bad threshold falls back" deny "$(TENDER_MIN_LINES=abc read_hook "$(read_json "$FX/big.ts")")"
assert_eq "TENDER_DISABLED allows" allow "$(TENDER_DISABLED=1 read_hook "$(read_json "$FX/big.ts")")"

rm -f "$FX"/tender-unconfigured-*
assert_eq "no key fails open" allow "$(OPENROUTER_API_KEY= read_hook "$(read_json "$FX/big.ts" s9)")"
assert_contains "no key adds note first time" "$(last '.hookSpecificOutput.additionalContext')" "OPENROUTER_API_KEY"
OPENROUTER_API_KEY= read_hook "$(read_json "$FX/big.ts" s9)" >/dev/null
assert_eq "no key note only once per session" "null" "$(last '.hookSpecificOutput.additionalContext')"

report
