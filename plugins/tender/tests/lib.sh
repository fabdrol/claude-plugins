#!/bin/bash
# Assertion helpers shared by hooks.sh and scripts.sh. Source, don't run.

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $1"
  [ -n "${2:-}" ] && echo "       $2"
}

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}

assert_contains() { # name haystack needle
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing: $3 | in: $(printf '%s' "$2" | head -c 300)" ;;
  esac
}

assert_not_contains() { # name haystack needle
  case "$2" in
    *"$3"*) fail "$1" "unexpected: $3" ;;
    *) pass "$1" ;;
  esac
}

assert_exit() { # name expected actual
  if [ "$2" -eq "$3" ]; then pass "$1"; else fail "$1" "expected exit $2, got $3"; fi
}

report() {
  echo
  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
