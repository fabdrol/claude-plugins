#!/bin/bash
# Measures tokens Claude would spend reading fixture files versus the size of
# the delegated answer. Needs a real OPENROUTER_API_KEY.
TESTS="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$TESTS/../scripts" && pwd)"
FX="$TESTS/fixtures"

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "OPENROUTER_API_KEY not set; skipping benchmark"
  exit 0
fi

total_in=0; total_out=0
for f in "$FX"/*; do
  [ -f "$f" ] || continue
  in_tokens=$(( $(wc -c < "$f" | tr -d ' ') / 4 ))
  answer=$("$SCRIPTS/tender-read" --question "List every exported symbol with its type and the external calls it makes." --paths "$f" 2>/dev/null) || { echo "  $(basename "$f"): call failed"; continue; }
  out_tokens=$(( $(printf '%s' "$answer" | wc -c | tr -d ' ') / 4 ))
  total_in=$((total_in + in_tokens)); total_out=$((total_out + out_tokens))
  echo "  $(basename "$f"): ~$in_tokens tokens to read, ~$out_tokens tokens of answer"
done
if [ "$total_in" -gt 0 ]; then
  echo "  saving: ~$(( (total_in - total_out) * 100 / total_in ))% of context tokens across fixtures"
fi
