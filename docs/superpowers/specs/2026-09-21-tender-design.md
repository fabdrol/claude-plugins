# Tender — design spec

**Date:** 2026-09-21
**Status:** Approved design, awaiting implementation plan
**Repo:** `fabdrol/claude-plugins`, plugin at `plugins/tender`
**Derived from:** Spotify's [shunt](https://github.com/sorantis/portal-ai-plugins/tree/add-shunt-claude/plugins/shunt) (Apache 2.0)

## 1. Purpose

Claude Code spends most of its tokens on I/O, not reasoning: reading whole files
to answer one question, or generating boilerplate that follows the file next to
it. Tender shunts that work to a cheap model via OpenRouter so the premium model
(Fable 5.1 on a Max subscription) keeps its allowance for planning, review and
hard problems.

Tender is sub-project one of three in the "Agent Delegation" concept
(`docs/agent-delegation-concept.md`). It is independent of the other two
(worker service, usage-aware routing) and ships first.

A tender is the small boat that runs errands so the yacht doesn't have to move.

## 2. Non-goals

- No editing by the worker model. Its summaries lack reliable line numbers;
  Claude still reads the exact section it edits (targeted reads always pass).
- No reasoning delegation. Debugging, architecture, security review stay with
  the premium model.
- No multi-file write, no review mode, no docs mode. New modes are additive and
  don't touch the hooks; they come later if needed.
- No Anthropic/Max routing. Tender always calls OpenRouter.
- No config file. Environment variables only.

## 3. Repo layout

```
claude-plugins/
  .claude-plugin/marketplace.json     # marketplace "fabdrol", lists plugins
  LICENSE                             # Apache-2.0
  NOTICE                              # credits Spotify's shunt
  README.md                           # marketplace overview + install
  docs/superpowers/specs/…            # this spec
  plugins/tender/
    .claude-plugin/plugin.json
    README.md
    hooks/
      hooks.json
      check-file-size                 # PreToolUse: Read
      check-bash-read                 # PreToolUse: Bash
    scripts/
      tender-read
      tender-write
      tender-usage
      tender-doctor
      lib/openrouter.sh               # transport, guard, cost log
    skills/
      read/SKILL.md                   # surfaces as /tender:read
      write/SKILL.md                  # surfaces as /tender:write
    tests/
      run.sh                          # runs hooks.sh + scripts.sh; --benchmark
      lib.sh                          # assertion helpers
      hooks.sh                        # hook decision tests (offline)
      scripts.sh                      # lib + script tests against the stub
      benchmark.sh                    # real key: token saving on fixtures
      fixtures/
      stub/openrouter-stub.py         # fake endpoint for offline tests
```

Install:

```
claude plugin marketplace add fabdrol/claude-plugins
claude plugin install tender@fabdrol
```

## 4. Configuration (environment only)

| Variable | Default | Purpose |
|---|---|---|
| `OPENROUTER_API_KEY` | — | Required for any call. Absent → hooks fail open. |
| `TENDER_MIN_LINES` | `350` | Files at or below this pass the hooks untouched. |
| `TENDER_READER_MODEL` | `google/gemini-3.1-flash-lite` | Model for `read`. |
| `TENDER_WRITER_MODEL` | `deepseek/deepseek-v4.1-flash` | Model for `write`. |
| `TENDER_MAX_PAYLOAD_BYTES` | `2000000` | Refuse larger request bodies. |
| `TENDER_TIMEOUT` | `180` | `curl --max-time` seconds. |
| `TENDER_API_URL` | `https://openrouter.ai/api/v1/chat/completions` | Override for tests. |
| `TENDER_LOG` | `~/.local/state/tender/usage.jsonl` | Cost log path (`$XDG_STATE_HOME` respected). |
| `TENDER_DENY_GLOBS` | empty | Extra colon-separated filename globs to refuse. |
| `TENDER_ALLOW_SECRETS` | unset | `1` disables the secrets guard. Env only, never a flag. |
| `TENDER_DISABLED` | unset | `1` makes hooks allow everything. |

Non-numeric values for numeric variables fall back to the default.

## 5. Hooks

Both are PreToolUse command hooks registered in `hooks/hooks.json`, output in
the current format:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}
```

Allow is `permissionDecision: "allow"`. Fail-open allows carry
`additionalContext` with a one-line note ("tender installed but
OPENROUTER_API_KEY is unset; large reads are not being delegated") so the
model and user learn why nothing is delegated.

### 5.1 `check-file-size` (matcher `Read`)

Allow when any of:

- `TENDER_DISABLED=1` or `OPENROUTER_API_KEY` empty (fail open, with note);
- `offset` or `limit` present (targeted read);
- path empty or not a regular file;
- line count ≤ `TENDER_MIN_LINES`.

Otherwise deny with reason:

> File is N lines (threshold T). Delegate it: run
> `${CLAUDE_PLUGIN_ROOT}/scripts/tender-read --question "<what you need>" --paths <path>`
> (skill `/tender:read`). If you need exact lines for an edit, re-read with
> offset/limit for just that section.

### 5.2 `check-bash-read` (matcher `Bash`)

Same allow rules, plus:

- allow if the command contains `|` or `>` (piped or redirected, not
  read-into-context), after stripping stderr-only redirections such as
  `2>/dev/null` and `2>&1`, which do not keep output out of context;
- only inspect commands starting with `cat`, `head`, `tail`, `less`, `more`,
  or `sed -n` (also `sed -ne` and `sed -n -e`);
- first non-flag argument is the path; for `sed -n 'A,Bp' file` the path is
  the argument after the range;
- `head`/`tail` with an explicit `-n N` or `-N` where N ≤ threshold → allow;
- `sed -n` with a range whose span ≤ threshold → allow;
- otherwise apply the line-count rule to the path.

Deny reason mirrors 5.1.

Compound commands (`&&`, `;`) are inspected on the first segment only, as in
shunt, and the word split ignores shell quoting, so a quoted path containing
spaces is not matched. Good enough; the hooks are a backstop, not a sandbox.

## 6. Scripts

### 6.1 `tender-read`

```
tender-read --question "<q>" --paths <file> [<file> …] [--allow-ignored]
```

- Every path must exist and be readable, else exit 1 before any network call.
- Secrets guard (section 7) runs on every path.
- Message: each file wrapped as `<file path="…">…</file>`, then
  `Question: <q>`.
- System prompt (inlined in the script): precise code analyst; structured
  bullets only; lead each bullet with the exact name, type or line number;
  nested bullets for detail; no preamble; skip what wasn't asked.
- Prints the answer to stdout. Prints a one-line summary to stderr:
  `[tender read: 3 files, ~41k in / 612 out, $0.0031, 9.4s, deepseek/deepseek-v4.1-flash]`.

### 6.2 `tender-write`

```
tender-write --spec "<what>" --reference <file> [--target <path>] [--allow-ignored]
```

- `--reference` required and must exist. Guard runs on it.
- Message: `Spec: <spec>\n\nReference:\n<file contents>`.
- System prompt: match the reference's patterns, naming and style exactly;
  output only code; no fences; make reasonable choices matching the reference
  when the spec is ambiguous.
- Response has leading/trailing fences stripped. Empty result → exit 1,
  target untouched.
- With `--target`, writes the file and reports the line count to stderr.
  Without, prints to stdout. Same cost summary line.

### 6.3 `tender-usage`

Reads the log and prints today and this ISO week, each as totals by model and
by repo, plus counts of calls, errors and guard refusals. No network.

### 6.4 `tender-doctor`

Checks in order, printing one line each: `jq` and `curl` present; key set;
log path writable; one minimal chat call (a few tokens) succeeds and returns
a usage block. Exit 1 on the first failure with a remediation hint.

## 7. Secrets guard (in `lib/openrouter.sh`)

Runs on every file that would be sent, before building the request. Any hit
refuses the entire call with exit 2 and a message naming the file (and line,
for content hits) but never the matched value. The cost log records the
refusal (`status: "refused"`).

1. **Filename denylist** (basename or path segment, case-insensitive):
   `.env`, `.env.*` except `.env.example`/`.env.sample`/`.env.template`,
   `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.keystore`, `*.jks`,
   `id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `.netrc`, `.npmrc`, `.pypirc`,
   `secrets*.{yml,yaml,json}`, `credentials*`, `*.tfvars`,
   any path containing `/.aws/`, `/.ssh/`, `/.gnupg/`, `/.kube/`.
   Extended by `TENDER_DENY_GLOBS`.
2. **Gitignore check.** Inside a git work tree, `git check-ignore -q <path>`
   matching refuses unless `--allow-ignored` was passed. Outside a repo this
   layer is skipped.
3. **Content scan** (`grep -nE`, first hit wins):
   - `-----BEGIN [A-Z ]*PRIVATE KEY-----`
   - `AKIA[0-9A-Z]{16}` (AWS access key id)
   - `gh[pousr]_[A-Za-z0-9]{36,}` (GitHub tokens)
   - `xox[baprs]-[A-Za-z0-9-]{10,}` (Slack tokens)
   - `sk-[A-Za-z0-9_-]{20,}` (common API key prefix)
   - `eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}` (JWT)
   - `(password|passwd|secret|token|api[_-]?key)["']?\s*[:=]\s*["'][^"']{16,}["']`
     (case-insensitive)

`TENDER_ALLOW_SECRETS=1` disables all three layers; the summary line then
says so.

## 8. Transport (`lib/openrouter.sh`)

- Build the request body with `jq -n --rawfile` into a temp file (cleaned on
  exit). Body:
  `{model, messages:[{role:"system",…},{role:"user",…}], temperature:0.2,
  provider:{data_collection:"deny"}}`.
- Refuse if body > `TENDER_MAX_PAYLOAD_BYTES`.
- `curl -sS --max-time $TENDER_TIMEOUT -H "Authorization: Bearer …"
  -H "Content-Type: application/json" -H "HTTP-Referer: https://github.com/fabdrol/claude-plugins"
  -H "X-Title: tender" --data-binary @body $TENDER_API_URL`.
- Parse: non-JSON → transport error; `.error.message` present → surface it;
  `.choices[0].message.content` empty → error. Curl exit 28 → append hint to
  split the call.
- Extract `.usage` (`prompt_tokens`, `prompt_tokens_details.cached_tokens`,
  `completion_tokens`, `cost`) and wall time; append log line; print summary.
- The key is never echoed, logged, or passed on the command line of any
  process other than curl.

## 9. Cost log

One JSON object per line at `TENDER_LOG`, directory created on demand:

```json
{"ts":"2026-09-21T12:41:03Z","repo":"iq-next","cwd":"/Users/x/Development/iq-next",
 "mode":"read","model":"deepseek/deepseek-v4.1-flash","files":3,
 "prompt_tokens":41230,"cached_tokens":0,"completion_tokens":612,
 "cost":0.0031,"duration_ms":9400,"status":"ok"}
```

`status` is `ok`, `error` (with `error` string) or `refused` (with `reason`).
`repo` is the basename of `git rev-parse --show-toplevel`, else of `cwd`.
`duration_ms` has whole-second granularity (bash `SECONDS`), since portable
millisecond timing would need perl or python, which are not runtime deps.
No file contents, questions, specs or answers are logged.

## 10. Skills

`skills/read/SKILL.md` and `skills/write/SKILL.md`, wording adapted from
shunt: when to use (files > threshold, questions across 3+ files, large
diffs; boilerplate > 80 % predictable from a reference), the exact command
using `${CLAUDE_PLUGIN_ROOT}`, and the two caveats: each call is one-shot so
re-send paths for follow-ups, and verify line numbers before editing.

## 11. Testing

- `tests/hooks.sh` — hook decision tests. Generates fixture files of given line
  counts, feeds JSON to each hook, asserts allow/deny. Runs offline. Includes
  fail-open, disabled, targeted-read, small-file, piped, redirected,
  `head -n`, and `sed -n` range cases.
- `tests/scripts.sh` — starts `stub/openrouter-stub.py` (a tiny local
  HTTP responder returning canned completions and usage; behaviour picked by
  the requested model name, e.g. `stub/error`), points
  `TENDER_API_URL` at it, and asserts: happy path output and log line;
  missing file; missing reference; each guard layer refusing; `--allow-ignored`;
  `TENDER_ALLOW_SECRETS`; fence stripping; empty response; error envelope;
  oversize payload.
- `tests/run.sh --benchmark` — with a real key, runs the fixture questions and
  reports tokens Claude would have read versus tokens in the answer.
- `shellcheck` on every script when installed (`brew install shellcheck`).
- All scripts target bash 3.2 (macOS default) and must also run on Linux
  bash 5: no `mapfile`, associative arrays, `${var,,}`, or `set -u` with
  possibly-empty arrays. `tests/` is used instead of `evals/` because
  `claude plugin eval` reserves that directory for its own YAML case format.

## 12. Error handling summary

| Condition | Behaviour |
|---|---|
| Key missing (hooks) | allow + note |
| Key missing (scripts) | exit 1, remediation hint |
| File missing/unreadable | exit 1 before network |
| Guard hit | exit 2, file (+line) named, logged as refused |
| Body too large | exit 1, suggest fewer files |
| Curl timeout | exit 1, suggest splitting |
| HTTP/API error | exit 1, OpenRouter's message |
| Empty completion | exit 1, target untouched |
| Log unwritable | warn to stderr, still return the answer |

## 13. Rollout

1. Fabian uses it for a few days across the 4–6 concurrent sessions.
2. Check `tender-usage` and the hook deny rate; tune `TENDER_MIN_LINES`.
3. Share install instructions with the team; each member sets their own
   `OPENROUTER_API_KEY`.
4. Sub-project two (worker service, plugin `crew` or similar) joins the same
   marketplace.

Verified 2026-09-21: doctor ok with google/gemini-3.1-flash-lite, $0.000005; Read
hook denied a 900-line whole-file read in a live `claude -p` session, and Claude
recovered with a targeted offset/limit re-read of just the last lines instead of
delegating to tender-read.
