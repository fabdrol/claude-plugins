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

# ---------------------------------------------------------------- lib: guard
echo "-- lib: guard"
G="$TMP/guard"; rm -rf "$G"; mkdir -p "$G/sub/.aws" "$G/repo"
(cd "$G" && git init -q)   # files under $G are governed by this empty repo, not the outer repo's .gitignore
printf 'SAFE=1\n' > "$G/.env"
printf 'SAFE=1\n' > "$G/.env.local"
printf 'EXAMPLE=\n' > "$G/.env.example"
printf 'x\n' > "$G/server.PEM"
printf 'x\n' > "$G/secrets-prod.yml"
printf 'x\n' > "$G/sub/.aws/credentials"
printf 'x\n' > "$G/custom.secretfile"
printf 'plain code\n' > "$G/ok.ts"
printf 'const id = "AKIAIOSFODNN7EXAMPLE";\n' > "$G/aws.ts"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nabc\n' > "$G/key.txt"
printf 'x\nconst token = "ghp_%s";\n' "$(printf 'a%.0s' $(seq 1 40))" > "$G/gh.ts"
printf 'x\ny\npassword: "supersecretvalue123456"\n' > "$G/cfg.yml"
printf 'const risk = "risk-assessment-configuration-value";\n' > "$G/risk.ts"
printf 'class: "desk-lamp-extra-long-class-name"\n' > "$G/desk.yml"
printf 'x\n' > "$G/repo/build.log"; printf 'src\n' > "$G/repo/src.ts"
(cd "$G/repo" && git init -q && printf 'build.log\n' > .gitignore)

# guard <allow_ignored> <paths...>; sets RC, ERR
guard() {
  local allow="$1"; shift
  ERR=$(cd "$TMP" && bash -c ". '$SCRIPTS/lib/openrouter.sh'; tender_guard read $allow \"\$@\"" _ "$@" 2>&1 >/dev/null); RC=$?
}

guard 0 "$G/ok.ts";            assert_exit "plain file passes" 0 $RC
guard 0 "$G/.env";             assert_exit ".env refused" 2 $RC
assert_contains ".env names denylist" "$ERR" "denylist"
assert_contains ".env names the file" "$ERR" "$G/.env"
assert_not_contains ".env does not print contents" "$ERR" "SAFE=1"
guard 0 "$G/.env.local";       assert_exit ".env.local refused" 2 $RC
guard 0 "$G/.env.example";     assert_exit ".env.example allowed" 0 $RC
guard 0 "$G/server.PEM";       assert_exit "*.pem refused case-insensitively" 2 $RC
guard 0 "$G/secrets-prod.yml"; assert_exit "secrets*.yml refused" 2 $RC
guard 0 "$G/sub/.aws/credentials"; assert_exit "path under .aws refused" 2 $RC
guard 0 "$G/custom.secretfile"; assert_exit "custom name passes without TENDER_DENY_GLOBS" 0 $RC
TENDER_DENY_GLOBS='*.secretfile:*.other' guard 0 "$G/custom.secretfile"
assert_exit "TENDER_DENY_GLOBS extends denylist" 2 $RC
guard 0 "$G/ok.ts" "$G/.env";  assert_exit "one bad path refuses the whole call" 2 $RC

guard 0 "$G/aws.ts";           assert_exit "AWS key id refused" 2 $RC
assert_contains "content hit names file and line" "$ERR" "$G/aws.ts:1"
assert_not_contains "content hit hides value" "$ERR" "AKIAIOSFODNN7EXAMPLE"
guard 0 "$G/key.txt";          assert_exit "private key header refused" 2 $RC
guard 0 "$G/gh.ts";            assert_exit "github token refused" 2 $RC
assert_contains "github token line number" "$ERR" "$G/gh.ts:2"
guard 0 "$G/cfg.yml";          assert_exit "password assignment refused" 2 $RC
assert_contains "password assignment line number" "$ERR" "$G/cfg.yml:3"
guard 0 "$G/risk.ts";          assert_exit "risk-… is not an sk- key" 0 $RC
guard 0 "$G/desk.yml";         assert_exit "desk-… is not an sk- key" 0 $RC

guard 0 "$G/repo/build.log";   assert_exit "gitignored refused" 2 $RC
assert_contains "gitignored hint" "$ERR" "--allow-ignored"
guard 1 "$G/repo/build.log";   assert_exit "gitignored allowed with flag" 0 $RC
guard 0 "$G/repo/src.ts";      assert_exit "tracked file passes" 0 $RC

TENDER_ALLOW_SECRETS=1 guard 0 "$G/.env" "$G/aws.ts"
assert_exit "TENDER_ALLOW_SECRETS bypasses everything" 0 $RC

ln -sf "$G/.env" "$G/link_to_env"
ln -sf "$G/sub/.aws/credentials" "$G/link_to_aws"
ln -sf "$G/ok.ts" "$G/link_to_ok"
guard 0 "$G/link_to_env";     assert_exit "symlink to .env refused" 2 $RC
assert_contains "symlink refusal names target" "$ERR" "-> $G/.env"
guard 0 "$G/link_to_aws";     assert_exit "symlink into .aws refused" 2 $RC
guard 0 "$G/link_to_ok";      assert_exit "symlink to plain file passes" 0 $RC

rm -f "$TENDER_LOG"; guard 0 "$G/.env"
assert_eq "refusal logged" "refused" "$(tail -1 "$TENDER_LOG" | jq -r .status)"
assert_contains "refusal reason logged" "$(tail -1 "$TENDER_LOG" | jq -r .reason)" "denylist"

# ---------------------------------------------------------------- tender-read
echo "-- tender-read"
FX="$TESTS/fixtures"
export TENDER_READER_MODEL=stub/ok

run_read() { OUT=$(cd "$TMP" && "$SCRIPTS/tender-read" "$@" 2>"$TMP/err.txt"); RC=$?; ERR=$(cat "$TMP/err.txt"); }

run_read;                                   assert_exit "no args → 1" 1 $RC
assert_contains "no args names --question" "$ERR" "--question"
run_read --question;                        assert_exit "--question without value → 1" 1 $RC
assert_contains "--question without value explains" "$ERR" "needs a value"
run_read --question "q";                    assert_exit "no paths → 1" 1 $RC
assert_contains "no paths names --paths" "$ERR" "--paths"
run_read --question "q" --paths "$TMP/missing.ts"; assert_exit "missing file → 1" 1 $RC
assert_contains "missing file named" "$ERR" "missing.ts"
run_read --question "q" --paths "$FX/user-service.ts" --bogus; assert_exit "unknown flag → 1" 1 $RC
assert_contains "unknown flag named" "$ERR" "--bogus"

rm -f "$TENDER_LOG"
run_read --question "What does this do?" --paths "$FX/user-service.ts" "$G/ok.ts"
assert_exit "happy path → 0" 0 $RC
assert_contains "answer on stdout" "$OUT" "STUB ANSWER"
assert_contains "summary on stderr" "$ERR" "[tender read: 2 file(s)"
req=$(cat "$STUB_LAST_REQUEST")
msg=$(printf '%s' "$req" | jq -r '.messages[1].content')
assert_contains "files wrapped with path" "$msg" "<file path=\"$FX/user-service.ts\">"
assert_contains "file contents included" "$msg" "class UserService"
assert_contains "closing tag" "$msg" "</file>"
assert_contains "question last" "$(printf '%s' "$msg" | tail -1)" "Question: What does this do?"
assert_contains "system prompt is the analyst" "$(printf '%s' "$req" | jq -r '.messages[0].content')" "precise code analyst"
assert_eq "reader model used" "stub/ok" "$(printf '%s' "$req" | jq -r .model)"
assert_eq "logged as read" "read" "$(tail -1 "$TENDER_LOG" | jq -r .mode)"
assert_eq "logged file count" "2" "$(tail -1 "$TENDER_LOG" | jq -r .files)"

run_read --question "q" --paths "$G/.env";  assert_exit "guard refusal → 2" 2 $RC
assert_contains "guard message shown" "$ERR" "denylist"
run_read --question "q" --paths "$G/repo/build.log"; assert_exit "gitignored → 2" 2 $RC
run_read --question "q" --paths "$G/repo/build.log" --allow-ignored; assert_exit "--allow-ignored → 0" 0 $RC

OPENROUTER_API_KEY= run_read --question "q" --paths "$FX/user-service.ts"
assert_exit "missing key → 1" 1 $RC
assert_contains "missing key hint" "$ERR" "OPENROUTER_API_KEY"

TENDER_READER_MODEL=stub/error run_read --question "q" --paths "$FX/user-service.ts"
assert_exit "api error → 1" 1 $RC

# ---------------------------------------------------------------- tender-write
echo "-- tender-write"
export TENDER_WRITER_MODEL=stub/fenced
run_write() { OUT=$(cd "$TMP" && "$SCRIPTS/tender-write" "$@" 2>"$TMP/err.txt"); RC=$?; ERR=$(cat "$TMP/err.txt"); }

run_write;                                  assert_exit "no args → 1" 1 $RC
run_write --spec;                           assert_exit "--spec without value → 1" 1 $RC
assert_contains "--spec without value explains" "$ERR" "needs a value"
run_write --spec "tests";                   assert_exit "no reference → 1" 1 $RC
assert_contains "no reference explains why" "$ERR" "--reference"
run_write --spec "tests" --reference "$TMP/nope.ts"; assert_exit "missing reference → 1" 1 $RC

rm -f "$TENDER_LOG"
run_write --spec "Write tests for UserService" --reference "$FX/user-service.ts"
assert_exit "stdout mode → 0" 0 $RC
assert_eq "fences stripped on stdout" "export const generated = 1;" "$OUT"
assert_contains "summary on stderr" "$ERR" "[tender write: 1 file(s)"
req=$(cat "$STUB_LAST_REQUEST")
msg=$(printf '%s' "$req" | jq -r '.messages[1].content')
assert_contains "spec first" "$(printf '%s' "$msg" | head -1)" "Spec: Write tests for UserService"
assert_contains "reference included" "$msg" "class UserService"
assert_contains "system prompt is the writer" "$(printf '%s' "$req" | jq -r '.messages[0].content')" "Output only the code"
assert_eq "writer model used" "stub/fenced" "$(printf '%s' "$req" | jq -r .model)"
assert_eq "logged as write" "write" "$(tail -1 "$TENDER_LOG" | jq -r .mode)"

target="$TMP/out/generated.test.ts"
run_write --spec "s" --reference "$FX/user-service.ts" --target "$target"
assert_exit "target mode → 0" 0 $RC
assert_eq "target written without fences" "export const generated = 1;" "$(cat "$target")"
assert_eq "nothing on stdout in target mode" "" "$OUT"
assert_contains "reports lines written" "$ERR" "Wrote 1 lines to $target"

printf 'keep me\n' > "$target"
TENDER_WRITER_MODEL=stub/empty run_write --spec "s" --reference "$FX/user-service.ts" --target "$target"
assert_exit "empty completion → 1" 1 $RC
assert_eq "empty completion leaves target untouched" "keep me" "$(cat "$target")"

run_write --spec "s" --reference "$G/.env";  assert_exit "guard on reference → 2" 2 $RC

# ---------------------------------------------------------------- tender-usage
echo "-- tender-usage"
rm -f "$TENDER_LOG"
out=$("$SCRIPTS/tender-usage"); rc=$?
assert_exit "no log → 0" 0 $rc
assert_contains "no log message" "$out" "No usage recorded"

today=$(date -u +%Y-%m-%dT10:00:00Z)
old="2000-01-03T10:00:00Z"
mkdir -p "$(dirname "$TENDER_LOG")"
cat > "$TENDER_LOG" <<EOF
{"ts":"$today","repo":"alpha","mode":"read","model":"m/one","files":2,"prompt_tokens":100,"cached_tokens":0,"completion_tokens":10,"cost":0.01,"duration_ms":1000,"status":"ok"}
{"ts":"$today","repo":"alpha","mode":"write","model":"m/two","files":1,"prompt_tokens":50,"cached_tokens":0,"completion_tokens":5,"cost":0.02,"duration_ms":1000,"status":"ok"}
{"ts":"$today","repo":"beta","mode":"read","model":"m/one","files":1,"prompt_tokens":0,"cached_tokens":0,"completion_tokens":0,"cost":0,"duration_ms":0,"status":"error","error":"boom"}
{"ts":"$today","repo":"beta","mode":"read","model":"","files":0,"prompt_tokens":0,"cached_tokens":0,"completion_tokens":0,"cost":0,"duration_ms":0,"status":"refused","reason":"x"}
{"ts":"$old","repo":"alpha","mode":"read","model":"m/one","files":1,"prompt_tokens":9,"cached_tokens":0,"completion_tokens":9,"cost":9,"duration_ms":1,"status":"ok"}
EOF
out=$("$SCRIPTS/tender-usage")
assert_contains "today header" "$out" "Today $(date -u +%Y-%m-%d)"
assert_contains "today totals" "$out" "4 calls, 2 ok, 1 error, 1 refused, \$0.03"
assert_contains "today by model" "$out" "m/one"
assert_contains "today model cost" "$out" "m/two: 1 calls, \$0.02"
assert_contains "today by repo" "$out" "alpha: 2 calls, \$0.03"
assert_contains "week header" "$out" "Week $(date -u +%G-W%V)"
assert_not_contains "old row excluded from week" "$out" "\$9.03"
assert_not_contains "old row excluded from today" "$out" "\$9"

report
