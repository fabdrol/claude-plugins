#!/bin/bash
# Runs every tender test suite. Usage: bash tests/run.sh [--benchmark]
set -e
TESTS="$(cd "$(dirname "$0")" && pwd)"
status=0
for suite in hooks scripts; do
  if [ -f "$TESTS/$suite.sh" ]; then
    echo "== $suite"
    bash "$TESTS/$suite.sh" || status=1
    echo
  fi
done
if [ "${1:-}" = "--benchmark" ] && [ -f "$TESTS/benchmark.sh" ]; then
  echo "== benchmark"
  bash "$TESTS/benchmark.sh" || status=1
fi
if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck"
  files=""
  for f in "$TESTS"/../hooks/check-* "$TESTS"/../hooks/common.sh "$TESTS"/../scripts/tender-* "$TESTS"/../scripts/lib/*.sh "$TESTS"/*.sh; do
    [ -f "$f" ] && files="$files $f"
  done
  # shellcheck disable=SC2086
  shellcheck -s bash $files && echo "  ok"
else
  echo "== shellcheck skipped (not installed; brew install shellcheck)"
fi
exit $status
