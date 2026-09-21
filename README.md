# claude-plugins

Fabian Droll's Claude Code plugins, published as a marketplace.

```bash
claude plugin marketplace add fabdrol/claude-plugins
claude plugin install tender@fabdrol
```

| Plugin | What it does |
|---|---|
| [tender](plugins/tender) | Shunts large file reads and boilerplate generation to a cheap model via OpenRouter, with a secrets guard and a cost log. |

## Development

```bash
git clone https://github.com/fabdrol/claude-plugins
cd claude-plugins
bash plugins/tender/tests/run.sh          # offline tests
claude plugin validate .                   # manifests
claude plugin marketplace add "$PWD"       # install from the working copy
claude plugin install tender@fabdrol
```

The thinking behind these plugins is in
[docs/agent-delegation-concept.md](docs/agent-delegation-concept.md).

Licensed under Apache 2.0. `tender` is derived from Spotify's
[shunt](https://github.com/spotify/portal-ai-plugins); see `NOTICE`.
