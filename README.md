# claude-plugins

A small marketplace of Claude Code plugins built around one idea: keep the
expensive frontier model for the work that needs its judgement, and hand the
mechanical work to something cheaper.

```bash
claude plugin marketplace add fabdrol/claude-plugins
claude plugin install tender@fabdrol
```

## Why this exists

Most of what a coding agent does in a session is not thinking. It reads five
files to answer a question about one method, generates a test file that looks
like the twenty next to it, and re-reads code it saw an hour ago. Every one of
those tokens goes through the same frontier model at the same price, and on a
subscription plan they count against the same weekly allowance as the planning
and debugging that actually need a strong model.

The architecture behind these plugins separates the two. The frontier model
stays in charge as planner, architect and reviewer. Cheap open-weight models
do the reading, the boilerplate, and eventually the well-specified
implementation work. The full concept, including the phases beyond what is
built so far, is in [docs/agent-delegation-concept.md](docs/agent-delegation-concept.md).

## Plugins

| Plugin | Status | What it does |
|---|---|---|
| [tender](plugins/tender) | v0.1.0 | Blocks large file reads and boilerplate generation from reaching the premium model and sends them to a cheap model on OpenRouter instead. Includes a secrets guard and a per-call cost log. |

A tender is the small boat that runs errands so the yacht doesn't have to move.

Planned next, as separate plugins in this same marketplace: a worker service
that runs headless Claude Code sessions on cheap models in isolated git
worktrees, and usage-aware routing that decides per task whether to use the
subscription's own models or an external one.

## How tender works in a session

1. Claude tries to read a 900-line file. A hook denies the read and tells
   Claude to run `tender-read` with a question instead.
2. `tender-read` sends the file to the configured cheap model and returns a
   short bulleted answer. The file contents never enter Claude's context.
3. For boilerplate, Claude runs `tender-write` with a spec and a reference
   file. The generated code goes straight to disk.
4. Every call is logged with tokens and cost. `tender-usage` shows today's and
   this week's spend by model and by repository.

Targeted reads with an offset and limit always pass, so editing is never
blocked. On everything the hooks don't deny they stay silent, so your own
permission prompts and settings rules apply unchanged.

Anything that leaves the machine passes a secrets guard first: dotenv files,
key material, gitignored files and anything that looks like it contains a
token are refused before any network call.

See [plugins/tender/README.md](plugins/tender/README.md) for configuration,
the full command reference, and what the plugin deliberately does not do.

## Requirements

- Claude Code 2.1 or newer.
- `jq` and `curl`.
- An OpenRouter API key in `OPENROUTER_API_KEY`. Without it the plugins are
  inert: nothing is blocked and nothing is sent.
- bash 3.2 or newer. Everything runs on the stock macOS shell and on Linux.

## Development

```bash
git clone https://github.com/fabdrol/claude-plugins
cd claude-plugins
bash plugins/tender/tests/run.sh          # offline tests, python3 for the stub
claude plugin validate .                   # manifests
claude plugin marketplace add "$PWD"       # install from the working copy
claude plugin install tender@fabdrol
```

Branches follow git-flow: `feature/…` off `development`, `development` into
`main`, releases tagged `vX.Y.Z`. Design documents live under
`docs/superpowers/`.

## License and attribution

Apache 2.0. `tender` is derived from Spotify's
[shunt](https://github.com/spotify/portal-ai-plugins), specifically
[the `add-shunt-claude` branch](https://github.com/sorantis/portal-ai-plugins/tree/add-shunt-claude/plugins/shunt),
with the Portal transport replaced by a direct OpenRouter client. See
`NOTICE`.
