---
name: write
description: "Delegate boilerplate code generation to a cheap model via OpenRouter. Use for tests, config, type stubs, docstrings, or any file where 80%+ is predictable from an existing reference file. The generated code goes straight to disk and never enters your context."
---

```bash
# Generate and write directly to the target file
${CLAUDE_PLUGIN_ROOT}/scripts/tender-write --spec "<what to generate>" --reference <reference-file> --target <output-path>

# Print to stdout instead (omit --target)
${CLAUDE_PLUGIN_ROOT}/scripts/tender-write --spec "<what to generate>" --reference <reference-file>
```

`--reference` is required: pass the file whose patterns, naming and style the output must match (the sibling test file, the neighbouring config). Without it the worker generates code that fits nothing.

Each call is one shot. To build on what was just generated, pass that file as the `--reference` of the next call.

Review the result and make surgical edits for the 5 to 20 percent that needs your judgement. Do not use this for logic that requires reasoning about the rest of the codebase.
