# claude-plugins

Marketplace repo for Claude Code plugins. Each plugin lives under `plugins/<name>`
and is listed in `.claude-plugin/marketplace.json`.

## Conventions

- Shell only, bash 3.2 compatible (macOS default). Runtime deps: `jq`, `curl`.
- Tests in `plugins/<name>/tests/`, run with `bash plugins/<name>/tests/run.sh`.
  `evals/` is reserved by `claude plugin eval`; don't use it for shell tests.
- Conventional commits scoped by plugin: `feat(tender): …`.
- Branches: `feature/…` off `development`; `development → main`; tag `vX.Y.Z`.

## Checks before committing

```bash
bash plugins/tender/tests/run.sh
claude plugin validate .
claude plugin validate plugins/tender
```

## Releasing

1. Bump `version` in `plugins/<name>/.claude-plugin/plugin.json` and in the
   matching entry of `.claude-plugin/marketplace.json`.
2. Merge `development → main`, tag `vX.Y.Z`, `gh release create vX.Y.Z --generate-notes`.
3. Users get the update with `claude plugin marketplace update fabdrol` then
   `claude plugin update tender@fabdrol`.

## Local install for testing

```bash
claude plugin marketplace add "$PWD"
claude plugin install tender@fabdrol
```
