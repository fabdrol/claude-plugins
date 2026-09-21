---
name: read
description: "Delegate bulk file reading to a cheap model via OpenRouter. Use when a file is over the tender threshold (default 350 lines), when a question spans 3+ files, or to summarise a large diff. Saves the tokens you would spend reading the files yourself."
---

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/tender-read --question "<what you need to know>" --paths <file1> [<file2> ...]
```

Ask a specific question: "which functions touch the database and what do they return", not "summarise this". The answer comes back as bullets led by names, types or line numbers.

Each call is one shot. For a follow-up, run it again with the same `--paths`; the files go to the worker, never into your context, so re-sending costs you nothing.

Verify exact line numbers or values with a targeted read (offset/limit) before using them in an edit.

If the call is refused with exit code 2, the secrets guard matched a file (dotenv, key material, gitignored, or a token-like string). Do not work around it; tell the user which file was refused.
