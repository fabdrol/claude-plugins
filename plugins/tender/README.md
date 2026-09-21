# tender

A tender is the small boat that runs errands so the yacht doesn't have to move.

Most of what a coding agent does is I/O, not reasoning. Tender stops Claude Code
from reading large files into a frontier model's context and instead sends them
to a cheap model on OpenRouter that answers the question, or writes the
boilerplate, for a fraction of the cost.

## How it works

1. **Hooks** deny whole-file reads (`Read`, `cat`, `head`, `tail`, `less`,
   `more`, `sed -n`) over 350 lines and point at the skill. Targeted reads with
   an offset/limit always pass, so edits are never blocked. On everything else
   the hooks stay silent — they express no opinion rather than approving the
   call — so your own permission prompts and settings rules still apply.
2. **Scripts** `tender-read` and `tender-write` send the files to OpenRouter and
   return bullets or code. Claude never sees the file contents.
3. **Skills** `/tender:read` and `/tender:write` tell Claude when and how to
   call the scripts.
4. **A secrets guard** refuses to send dotenv files, key material, gitignored
   files, or anything that looks like it contains a token.
5. **A cost log** records tokens and cost per call; `tender-usage` sums it up.

## Setup

```bash
claude plugin marketplace add fabdrol/claude-plugins
claude plugin install tender@fabdrol
export OPENROUTER_API_KEY=...        # https://openrouter.ai/keys, in your shell profile
~/.claude/plugins/cache/fabdrol/tender/0.1.0/scripts/tender-doctor
# find the exact path with: claude plugin details tender@fabdrol (or ls ~/.claude/plugins/cache/fabdrol/tender/)
```

Requires `jq` and `curl`. Without the key the plugin is inert: hooks allow
everything and mention once per session that it is unconfigured.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `OPENROUTER_API_KEY` | — | Required for any call. |
| `TENDER_MIN_LINES` | `350` | Files at or below this pass the hooks. |
| `TENDER_READER_MODEL` | `google/gemini-3.1-flash-lite` | Model for `read`. |
| `TENDER_WRITER_MODEL` | `deepseek/deepseek-v4.1-flash` | Model for `write`. |
| `TENDER_MAX_PAYLOAD_BYTES` | `2000000` | Refuse larger request bodies. |
| `TENDER_TIMEOUT` | `180` | Request timeout in seconds. |
| `TENDER_LOG` | `~/.local/state/tender/usage.jsonl` | Cost log path. |
| `TENDER_DENY_GLOBS` | empty | Extra colon-separated filename globs to refuse. |
| `TENDER_ALLOW_SECRETS` | unset | `1` disables the secrets guard. |
| `TENDER_DISABLED` | unset | `1` makes hooks allow everything. |

Set them in your shell profile or in `.claude/settings.json` under `"env"`.

## Usage

```bash
tender-read --question "Which methods call the database?" --paths src/UserService.ts src/Handler.ts
tender-write --spec "Write tests for UserService" --reference tests/OrderService.test.ts --target tests/UserService.test.ts
tender-usage
tender-doctor
```

Scripts live under the plugin root; in a session Claude uses
`${CLAUDE_PLUGIN_ROOT}/scripts/…`. To call them by name from your own shell,
put that directory on `PATH` (or invoke them by full path):

```bash
export PATH="$HOME/.claude/plugins/cache/fabdrol/tender/0.1.0/scripts:$PATH"
# substitute the installed version; ls ~/.claude/plugins/cache/fabdrol/tender/
```

Exit codes: 0 ok, 1 error, 2 refused by the secrets guard.

## What it doesn't do

- **Editing.** The worker's answers have no reliable line numbers. Claude
  still reads the exact section it edits.
- **Reasoning.** Debugging, architecture and security review stay with the
  premium model.
- **Privacy magic.** Files you send go to OpenRouter and the model's provider.
  Requests set `provider.data_collection: deny`, and the guard blocks the
  obvious secrets, but review what you delegate in sensitive repos.

## Tests

```bash
bash tests/run.sh               # hooks + scripts, offline (python3 for the stub)
bash tests/run.sh --benchmark   # needs OPENROUTER_API_KEY; measures token saving
```

Derived from Spotify's [shunt](https://github.com/spotify/portal-ai-plugins)
(Apache 2.0), specifically
[the `add-shunt-claude` branch](https://github.com/sorantis/portal-ai-plugins/tree/add-shunt-claude/plugins/shunt).
The Portal transport was replaced with a direct OpenRouter client.
