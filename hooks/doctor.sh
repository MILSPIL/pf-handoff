#!/bin/bash
# Health check for the context-hooks install. Prints OK/FAIL per check,
# exit 1 on any FAIL. Operator tool (not a hook) — like install.sh,
# errors are exit 1, not a silent exit 0.
set -u
# $HOME САМ не переопределяем (F-20) — весь внутренний state живёт под
# PF_EFFECTIVE_HOME (тот же контракт, что в statusline.sh/context-guard.sh).
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"

SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$PF_EFFECTIVE_HOME/.claude/settings.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATE_DIR="$PF_EFFECTIVE_HOME/.claude/context-state"
# The harness compacts ~33k tokens BELOW autoCompactWindow: its reply reserve
# (20k output cap + 13k), read off the Claude Code 2.1.280 binary. Same
# constant as in context-guard.sh.
COMPACT_RESERVE=33000

FAIL=0

ok()   { printf 'OK   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }
# WARN: the install works, but a setting makes part of it useless (a
# threshold that can never fire). Never sets FAIL: rc stays 0.
warn() { printf 'WARN %s\n' "$1"; }

# 1) all seven scripts exist and are executable (autocheckpoint.sh is not a
# registered hook: precompact.sh calls it and blocks compaction when it cannot
# produce a snapshot, so its absence is a real failure, not cosmetic — T-031)
for name in statusline.sh context-guard.sh sessionstart.sh precompact.sh autocheckpoint.sh install.sh doctor.sh; do
  if [ -x "$SCRIPT_DIR/$name" ]; then
    ok "script $name exists and is executable"
  else
    fail "script $name is missing or not executable ($SCRIPT_DIR/$name)"
  fi
done

# 2) settings.json is valid
JSON_READER="none"
if command -v python3 >/dev/null 2>&1; then
  JSON_READER="python3"; json_valid() { python3 -m json.tool "$1" > /dev/null 2>&1; }
elif command -v jq >/dev/null 2>&1; then
  JSON_READER="jq"; json_valid() { jq -e . "$1" > /dev/null 2>&1; }
else
  json_valid() { return 1; }
fi
if [ "$JSON_READER" = "none" ]; then
  fail "cannot check settings.json — neither python3 nor jq is available"
elif json_valid "$SETTINGS_PATH"; then
  ok "settings.json is valid ($SETTINGS_PATH)"
else
  fail "settings.json is invalid or missing ($SETTINGS_PATH)"
fi

# 3) it contains all 5 of our entries (statusLine + 4 hooks).
# Patterns match the file name only, not the directory: the canon keeps the
# scripts in context-hooks/, the public distribution — in hooks/.
if grep -q "/statusline.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "statusLine points at our statusline.sh"
else
  fail "statusLine missing / not pointing at our statusline.sh"
fi

if [ "$(grep -o "/context-guard.sh" "$SETTINGS_PATH" 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] 2>/dev/null; then
  ok "context-guard.sh registered in UserPromptSubmit and PostToolUse"
else
  fail "context-guard.sh not registered (2 occurrences needed: UserPromptSubmit + PostToolUse)"
fi

if grep -q "/sessionstart.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "sessionstart.sh registered in SessionStart"
else
  fail "sessionstart.sh not registered in SessionStart"
fi

if grep -q "/precompact.sh" "$SETTINGS_PATH" 2>/dev/null; then
  ok "precompact.sh registered in PreCompact"
else
  fail "precompact.sh not registered in PreCompact"
fi

# 4) Orca compatibility — checked ONLY if Orca is installed on this machine
# (~/.orca/agent-hooks exists). No Orca is not an error: the statusline
# wrapper simply skips the missing script.
if [ -d "$PF_EFFECTIVE_HOME/.orca/agent-hooks" ]; then
  # -o | wc -l, не grep -c: в однострочном settings.json все записи лежат в
  # одной строке, и счётчик строк занижал бы их до 1.
  orca_hook_count=$(grep -o 'claude-hook.sh' "$SETTINGS_PATH" 2>/dev/null | wc -l | tr -d ' ')
  [ -z "$orca_hook_count" ] && orca_hook_count=0
  if [ "$orca_hook_count" -ge 1 ] 2>/dev/null; then
    ok "Orca hooks are in place (claude-hook.sh occurs $orca_hook_count times)"
  else
    fail "Orca is installed but its hooks are absent from settings.json (claude-hook.sh: 0) — check they were not wiped"
  fi
  if [ -f "$SCRIPT_DIR/statusline.sh" ] && grep -q "claude-statusline.sh" "$SCRIPT_DIR/statusline.sh" 2>/dev/null; then
    ok "our statusline.sh still calls Orca's claude-statusline.sh"
  else
    fail "our statusline.sh does not reference Orca's claude-statusline.sh"
  fi
else
  ok "Orca not installed — compatibility checks skipped (that is normal)"
fi

# 5) ~/.claude/context-state/ can be created and written to
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  probe="$STATE_DIR/.doctor-probe.$$"
  if printf 'probe' > "$probe" 2>/dev/null; then
    rm -f "$probe" 2>/dev/null
    ok "$STATE_DIR is creatable and writable"
  else
    fail "$STATE_DIR exists but is not writable"
  fi
else
  fail "$STATE_DIR could not be created"
fi

# 6) status-bar config (optional): present but broken is the one case where
# the user silently gets the defaults and cannot tell why.
SL_CFG="${PF_STATUSLINE_CONFIG:-$PF_EFFECTIVE_HOME/.config/pf-handoff/statusline.json}"
if [ -e "$SL_CFG" ]; then
  if [ "$JSON_READER" = "none" ]; then
    fail "status-bar config exists but cannot be checked — neither python3 nor jq is available ($SL_CFG)"
  elif [ -f "$SL_CFG" ] && json_valid "$SL_CFG"; then
    ok "status-bar config is valid ($SL_CFG)"
  else
    fail "status-bar config exists but does not parse as JSON — statusline silently falls back to defaults; check the syntax with python3 -m json.tool or jq: '$SL_CFG'"
  fi
else
  ok "status-bar config absent — default look (that is normal)"
fi

# 7) auto-compact window (T-031): informational, never a failure. A hook cannot
# start compaction — no such output field exists — so the "compact at 80%" half
# of the design is the harness setting `autoCompactWindow` (tokens, capped at
# the model's context window). Unset is legitimate: the session then compacts
# at the model's limit, and the PreCompact gate still guards that moment.
acw=""
if [ "$JSON_READER" = "python3" ]; then
  acw=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
print(d.get("autoCompactWindow") or "")
' "$SETTINGS_PATH" 2>/dev/null)
elif [ "$JSON_READER" = "jq" ]; then
  acw=$(jq -r '.autoCompactWindow // ""' "$SETTINGS_PATH" 2>/dev/null)
fi
if [ -n "$acw" ]; then
  case "$acw" in
    *[!0-9]*) ok "autoCompactWindow = $acw (not a plain number: the harness ignores it)" ;;
    *) # Same floor and base-10 normalisation as acw_read in context-guard.sh:
       # outside the documented range (100000..1000000 tokens; the harness
       # clamps the env var to the minimum, settings.json is undocumented)
       # the guard does not apply the value, and a leading zero must not
       # reach bash arithmetic as an octal literal.
       if [ "${#acw}" -gt 9 ] || [ "$acw" -lt 100000 ] 2>/dev/null; then
         ok "autoCompactWindow = $acw (outside the documented range 100000..1000000: the guard does not apply it, so the compaction point is unknown; the harness clamps an env value to 100000)"
       else
         ok "autoCompactWindow = $(( 10#$acw )) tokens (compaction fires ~${COMPACT_RESERVE} below it, at ~$(( 10#$acw - COMPACT_RESERVE )): the harness keeps that much for its reply)"
       fi ;;
  esac
else
  ok "autoCompactWindow unset: compaction at the model's limit (that is the harness default)"
fi

# 8) context budgets (v1.11.0). The thresholds that apply in $PWD come from
# the project file (.agents/context-budget.json), else the global one
# (~/.config/pf-handoff/context-budget.json), else the 60/80/90% defaults.
# A threshold at or above the compaction point (autoCompactWindow minus the
# reply reserve) can never fire: with a 400k autoCompactWindow the 60/80/90%
# defaults of a 1M window sat above it for a month and the hooks stayed
# silent. WARN, never FAIL: the hooks still run, they just cannot warn.
BUDGET_GLOBAL="${PF_CONTEXT_BUDGET_CONFIG:-$PF_EFFECTIVE_HOME/.config/pf-handoff/context-budget.json}"
BUDGET_PROJECT="$PWD/.agents/context-budget.json"

# Model window: the same rule context-guard.sh uses for its fallback.
model_name=""
if [ "$JSON_READER" = "python3" ]; then
  model_name=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
print((d.get("model") or "") if isinstance(d, dict) else "")
' "$SETTINGS_PATH" 2>/dev/null)
elif [ "$JSON_READER" = "jq" ]; then
  model_name=$(jq -r '.model // ""' "$SETTINGS_PATH" 2>/dev/null)
fi
case "$(printf '%s' "$model_name" | tr '[:upper:]' '[:lower:]')" in
  *'[1m]'*|*fable*|*opus-5*|*sonnet-5*) win=1000000 ;;
  *) win=200000 ;;
esac
# The env var wins over settings.json, exactly as in the harness.
acw_eff="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-$acw}"
case "$acw_eff" in ''|*[!0-9]*) acw_eff="" ;; esac
[ -n "$acw_eff" ] && [ "${#acw_eff}" -gt 9 ] && acw_eff=""
# Same floor and base-10 normalisation as acw_read in context-guard.sh: below
# the documented minimum 100000 the guard does not apply the value, so no
# compaction point may be derived from it here either (a 50000 used to yield
# a 17000 point and a WARN for every threshold), and a leading zero must not
# reach bash arithmetic as an octal literal.
[ -n "$acw_eff" ] && { [ "$acw_eff" -ge 100000 ] 2>/dev/null || acw_eff=""; }
[ -n "$acw_eff" ] && acw_eff=$(( 10#$acw_eff ))
compact_at=""
if [ -n "$acw_eff" ]; then
  cap="$acw_eff"; [ "$win" -lt "$cap" ] && cap="$win"
  compact_at=$(( cap - COMPACT_RESERVE ))
fi

# Same validation as budget_ok / budget_parse in the hooks (kept in sync by
# tests/token-budget.sh): three digit-only values, ascending, within [lo, hi].
budget_ok() {
  local lo="$1" hi="$2" a="$3" b="$4" c="$5"
  case "$a$b$c" in *[!0-9]*|'') return 1 ;; esac
  { [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ]; } || return 1
  { [ "${#a}" -le 9 ] && [ "${#b}" -le 9 ] && [ "${#c}" -le 9 ]; } || return 1
  [ "$a" -ge "$lo" ] 2>/dev/null && [ "$a" -lt "$b" ] 2>/dev/null \
    && [ "$b" -lt "$c" ] 2>/dev/null && [ "$c" -le "$hi" ] 2>/dev/null
}
budget_read() {
  local f="$1" raw="" tok="" pct="" a="" b="" c=""
  if [ "$JSON_READER" = "python3" ]; then
    raw=$(python3 -c '
import json, sys
def p(d, k):
    t = d.get(k) if isinstance(d, dict) else None
    return "\t".join(str(x) for x in t) if isinstance(t, list) and len(t) == 3 else ""
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    print(p(d, "thresholds_tokens") + "\x1f" + p(d, "thresholds"))
except Exception:
    print("")
' "$f" 2>/dev/null)
  elif [ "$JSON_READER" = "jq" ]; then
    raw=$(jq -r 'def p(k): if (.[k]|type) == "array" and (.[k]|length) == 3 then (.[k]|map(tostring)|join("\t")) else "" end; p("thresholds_tokens") + "\u001f" + p("thresholds")' "$f" 2>/dev/null)
  fi
  [ -n "$raw" ] || return 0
  IFS=$'\x1f' read -r tok pct <<< "$raw"
  IFS=$'\t' read -r a b c <<< "$tok"
  if budget_ok 1000 999999999 "$a" "$b" "$c"; then
    printf 'tok\t%s\t%s\t%s\n' "$(( 10#$a ))" "$(( 10#$b ))" "$(( 10#$c ))"; return 0
  fi
  IFS=$'\t' read -r a b c <<< "$pct"
  if budget_ok 1 99 "$a" "$b" "$c"; then
    printf 'pct\t%s\t%s\t%s\n' "$(( 10#$a ))" "$(( 10#$b ))" "$(( 10#$c ))"
  fi
  return 0
}
# budget_judge label source mode a b c: one OK or WARN line for a threshold triple.
budget_judge() {
  local label="$1" src="$2" mode="$3" a="$4" b="$5" c="$6" v t unit="%"
  [ "$mode" = tok ] && unit=" tokens"
  if [ -z "$compact_at" ]; then
    if [ "$mode" = tok ]; then
      warn "$label thresholds_tokens [$a, $b, $c] with autoCompactWindow unset or outside the documented range: compaction then happens at the model's limit, so whether they fire in time cannot be told ($src)"
    else
      ok "$label thresholds [$a, $b, $c]% ($src)"
    fi
    return 0
  fi
  for v in "$a" "$b" "$c"; do
    t="$v"; [ "$mode" = pct ] && t=$(( v * win / 100 ))
    if [ "$t" -ge "$compact_at" ]; then
      warn "$label threshold $v$unit (~$t tokens) is at or above the compaction point ~$compact_at (autoCompactWindow $acw_eff minus the ${COMPACT_RESERVE} reply reserve): it can never fire; lower it or raise autoCompactWindow ($src)"
      return 0
    fi
  done
  ok "$label thresholds [$a, $b, $c]$unit all fire before compaction (~$compact_at) ($src)"
}
budget_applied=0
for pair in "project|$BUDGET_PROJECT" "global|$BUDGET_GLOBAL"; do
  label="${pair%%|*}"; f="${pair#*|}"
  if [ ! -e "$f" ]; then
    ok "$label context-budget absent ($f)"
    continue
  fi
  if [ "$JSON_READER" = "none" ]; then
    warn "$label context-budget exists but cannot be checked: neither python3 nor jq is available ($f)"
    continue
  fi
  row=$(budget_read "$f")
  if [ -z "$row" ]; then
    warn "$label context-budget exists but holds no valid thresholds: the hooks ignore it and the next source applies ($f)"
    continue
  fi
  IFS=$'\t' read -r mode a b c <<< "$row"
  budget_judge "$label" "$f" "$mode" "$a" "$b" "$c"
  budget_applied=1
done
if [ "$budget_applied" = 0 ] && [ -n "$compact_at" ]; then
  budget_judge "default" "no context-budget file, 60/80/90% of a ${win} window" pct 60 80 90
fi

exit "$FAIL"
