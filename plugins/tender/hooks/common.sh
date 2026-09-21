# Shared plumbing for tender's PreToolUse hooks. Source it after reading stdin
# into $input; don't run it.
#
#   input=$(cat)
#   . "$(dirname "$0")/common.sh"
#   tender_hook_preamble

# allow: express NO opinion — exit 0 with no output at all.
#
# A hook must never answer with an "allow" permissionDecision. That value is not
# "carry on": it short-circuits the permission flow, skipping the user's
# approval prompt and any deny rule in their settings. Tender only ever has an
# opinion about files that are too large to read; on everything else it must
# leave the user's own rules in charge, and silence is the only output that
# does that. Fail-open paths use allow_note, which carries a note but still no
# decision.
allow() { exit 0; }

command -v jq >/dev/null 2>&1 || allow

# allow_note <msg>: no opinion, plus one line of context for the model.
allow_note() {
  jq -cn --arg c "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
  exit 0
}

# deny <reason>: block the call and tell Claude what to do instead.
deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# shell_quote <string>: single-quoted for safe pasting into a shell command,
# so a hostile filename cannot inject into the command Claude is told to run.
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# shellcheck disable=SC2034  # both are read by the sourcing hook
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_LINES="${TENDER_MIN_LINES:-350}"
case "$MIN_LINES" in ''|*[!0-9]*) MIN_LINES=350 ;; esac

# tender_hook_preamble: reads $input. Exits (allowing) when tender is switched
# off or unconfigured; the unconfigured note is emitted once per session.
# shellcheck disable=SC2154  # $input is set by the sourcing hook
tender_hook_preamble() {
  local session marker
  [ "${TENDER_DISABLED:-}" = "1" ] && allow
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    session=$(printf '%s' "$input" | jq -r '.session_id // "nosession"')
    marker="${TMPDIR:-/tmp}/tender-unconfigured-$session"
    if [ -e "$marker" ]; then allow; fi
    touch "$marker" 2>/dev/null
    allow_note "tender is installed but OPENROUTER_API_KEY is unset, so large reads are not being delegated. Export the key (https://openrouter.ai/keys) and restart Claude Code to enable it."
  fi
  return 0
}
