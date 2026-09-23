#!/usr/bin/env bash
# token-budget.sh -- regression suite for pf-handoff v1.11.0:
#  - absolute-token thresholds (thresholds_tokens) in project/global
#    .agents/context-budget.json, precedence and validation parity with
#    the existing percent thresholds (thresholds);
#  - the global config file (~/.config/pf-handoff/context-budget.json,
#    path override PF_CONTEXT_BUDGET_CONFIG for tests), read after the
#    project file and before the 60/80/90% defaults, invalid = absent;
#  - the advisor-doubling fix in context-guard.sh's transcript fallback
#    (usage.iterations picker: last message/fallback_message, skipping
#    advisor_message/compaction and <synthetic> zero-usage lines);
#  - the "До автосжатия ~Nk токенов (autoCompactWindow Nk)." suffix on
#    every zone directive when autoCompactWindow is known;
#  - doctor.sh check 8 (WARN, never FAIL, for thresholds that can never
#    fire before compaction).
#
# Cases are labelled A-J; each group header says what it pins down.
#
# Bash 3.2 compatible (macOS system bash floor, same constraint as every
# other script in this family): no associative arrays, no ${var,,}, no
# mapfile, no $BASHPID. Self-contained: does not source threshold-parity.sh
# or run.sh, only copies their harness style.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
STATUSLINE="$HOOKS_DIR/statusline.sh"
GUARD="$HOOKS_DIR/context-guard.sh"
DOCTOR="$HOOKS_DIR/doctor.sh"
BASH_BIN="$(command -v bash)"
FULL_PATH="$PATH"

[ -f "$STATUSLINE" ] || { echo "cannot find statusline.sh at $STATUSLINE"; exit 90; }
[ -f "$GUARD" ] || { echo "cannot find context-guard.sh at $GUARD"; exit 90; }
[ -f "$DOCTOR" ] || { echo "cannot find doctor.sh at $DOCTOR"; exit 90; }

# --- tiny table-driven harness (style copied from threshold-parity.sh /
# tests/run.sh, not sourced -- see header note) ----------------------------
PASS=0
FAIL=0
FAIL_LABELS=()
CURRENT_GROUP=""
GROUP_PASS=0
GROUP_FAIL=0
GROUP_SUMMARY=()

group() {
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  CURRENT_GROUP="$1"; GROUP_PASS=0; GROUP_FAIL=0
  echo; echo "=== $1 ==="
}
pass() { PASS=$((PASS + 1)); GROUP_PASS=$((GROUP_PASS + 1)); echo "PASS  $1"; }
fail() {
  FAIL=$((FAIL + 1)); GROUP_FAIL=$((GROUP_FAIL + 1))
  echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"
  FAIL_LABELS+=("[$CURRENT_GROUP] $1")
}
finish() {
  if [ -n "$CURRENT_GROUP" ]; then
    GROUP_SUMMARY+=("$CURRENT_GROUP: $GROUP_PASS/$((GROUP_PASS + GROUP_FAIL))")
  fi
  echo; echo "=== SUMMARY ==="
  local line
  for line in "${GROUP_SUMMARY[@]+"${GROUP_SUMMARY[@]}"}"; do echo "$line"; done
  echo "TOTAL: $PASS/$((PASS + FAIL))"
  if [ "$FAIL" -gt 0 ]; then
    echo; echo "Failed:"
    local l
    for l in "${FAIL_LABELS[@]+"${FAIL_LABELS[@]}"}"; do echo "  - $l"; done
  fi
  if [ "$FAIL" -eq 0 ]; then echo "RESULT: GREEN"; exit 0; else echo "RESULT: RED"; exit 1; fi
}

# One suite-wide temp root, removed once on EXIT. mktempdir() below hands out
# subdirectories of it with a plain `mktemp -d` (no array bookkeeping): a
# per-call `CLEANUP_DIRS+=(...)` inside a function invoked as `x=$(mktempdir)`
# would run in the command-substitution subshell and be lost the instant that
# subshell exits, silently leaking every directory (caught empirically: a run
# left 1328 dirs behind under $TMPDIR before this fix).
SUITE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tok-budget.XXXXXXXX")"
cleanup() { [ -n "$SUITE_TMP" ] && [ -d "$SUITE_TMP" ] && rm -rf "$SUITE_TMP"; }
trap cleanup EXIT

mktempdir() { mktemp -d "$SUITE_TMP/d.XXXXXXXX"; }

echo "token-budget.sh -- context-hooks token-threshold regression suite"
echo "statusline: $STATUSLINE"
echo "guard:      $GUARD"
echo "doctor:     $DOCTOR"
echo "bash:       $BASH_BIN ($("$BASH_BIN" --version | head -1))"

# --- two minimal PATH sandboxes (jq-only / python3-only), same recipe as
# tests/run.sh's mkminpath -- isolates which JSON-reader branch each hook
# actually took instead of relying on whatever happens to be on this dev
# machine's PATH. ------------------------------------------------------
BASE_TOOLS="bash cat date dirname mkdir sed grep tr printf mv rm mktemp head tail sort wc find awk cut ls basename"
mkminpath() {
  local d="$1"; shift
  mkdir -p "$d"
  local t src
  for t in $BASE_TOOLS; do
    src="$(PATH="$FULL_PATH" command -v "$t" 2>/dev/null)" || { echo "harness setup: '$t' not found" >&2; exit 90; }
    ln -sf "$src" "$d/$t"
  done
  for t in "$@"; do
    src="$(PATH="$FULL_PATH" command -v "$t" 2>/dev/null)" || { echo "harness setup: '$t' not found, cannot build this PATH variant" >&2; exit 90; }
    ln -sf "$src" "$d/$t"
  done
}
MP_JQ="$(mktempdir)"; mkminpath "$MP_JQ" jq
MP_PY="$(mktempdir)"; mkminpath "$MP_PY" python3
mp_of() {
  case "$1" in
    jq) printf '%s' "$MP_JQ" ;;
    py) printf '%s' "$MP_PY" ;;
  esac
}

# --- small fixture / call helpers ------------------------------------------

# write_json path content -- writes $content verbatim to $path, creating
# the parent directory first (project .agents/ and global .config/pf-handoff/
# both need this).
write_json() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")" 2>/dev/null
  printf '%s' "$content" > "$path"
}

# write_settings path [acw] -- a settings.json with a 1M-window model
# ("opus[1m]" matches context-guard.sh's *'[1m]'* fallback rule) and,
# optionally, autoCompactWindow.
write_settings() {
  local path="$1" acw="${2:-}"
  if [ -n "$acw" ]; then
    printf '{"model":"opus[1m]","autoCompactWindow":%s}' "$acw" > "$path"
  else
    printf '{"model":"opus[1m]"}' > "$path"
  fi
}

# write_doctor_settings path [acw] -- like write_settings, but also carries
# the statusLine/hooks entries doctor.sh's checks 2-3 grep for (a fabricated
# path is fine; doctor.sh never executes it, only greps the text).
write_doctor_settings() {
  local path="$1" acw="${2:-}"
  if [ -n "$acw" ]; then
    printf '{"model":"opus[1m]","autoCompactWindow":%s,"statusLine":{"command":"/x/statusline.sh"},"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"/x/context-guard.sh"}]}],"PostToolUse":[{"hooks":[{"command":"/x/context-guard.sh"}]}],"SessionStart":[{"hooks":[{"command":"/x/sessionstart.sh"}]}],"PreCompact":[{"hooks":[{"command":"/x/precompact.sh"}]}]}}' "$acw" > "$path"
  else
    printf '{"model":"opus[1m]","statusLine":{"command":"/x/statusline.sh"},"hooks":{"UserPromptSubmit":[{"hooks":[{"command":"/x/context-guard.sh"}]}],"PostToolUse":[{"hooks":[{"command":"/x/context-guard.sh"}]}],"SessionStart":[{"hooks":[{"command":"/x/sessionstart.sh"}]}],"PreCompact":[{"hooks":[{"command":"/x/precompact.sh"}]}]}}' > "$path"
  fi
}

# seed_state home sid pct window tokens announced -- method (a): plant a
# fresh (age=0) state file so the guard trusts it instead of the transcript.
seed_state() {
  local home="$1" sid="$2" pct="$3" window="$4" tokens="$5" ann="$6"
  mkdir -p "$home/.claude/context-state"
  printf '{"pct": %s, "window": %s, "input_tokens": %s, "updated": %s, "announced": %s}' \
    "$pct" "$window" "$tokens" "$(date +%s)" "$ann" > "$home/.claude/context-state/$sid.json"
}

# write_transcript_n path N -- method (b): a one-line jsonl transcript whose
# top-level usage sums to N (input=2, cache_creation=1000, cache_read=N-1002).
write_transcript_n() {
  local path="$1" n="$2" cr
  cr=$(( n - 1002 ))
  printf '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%s,"output_tokens":10}}}\n' "$cr" > "$path"
}

# state_field state_file field -- pulls one integer field out of the state
# JSON (same grep idiom tests/run.sh uses for "announced").
state_field() {
  local file="$1" field="$2"
  grep -oE "\"${field}\":[[:space:]]*[0-9]+" "$file" 2>/dev/null | grep -oE '[0-9]+' | head -1
}

# zone_of guard_output -- classifies the additionalContext text by the
# THRESH_Z1/Z2/Z3 markers (context-guard.sh L13-15); "0" means silent.
zone_of() {
  case "$1" in
    *'немедленно полный'*) echo 3 ;;
    *'M/L-кусков'*) echo 2 ;;
    *'чекпоинт HANDOFF'*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# snap_path_of guard_output -- extracts the path out of THRESH_Z2_OK's
# "Авто-снимок состояния записан сам: <path>. Смысловой ..." suffix.
snap_path_of() {
  printf '%s' "$1" | sed -n 's/.*записан сам: \(.*\)\. Смысловой.*/\1/p'
}

# sl_zone_color statusline_output -- reads the ANSI colour ahead of the bar
# on the "Context:" line (31=red, 33=yellow, 32=green); only that line ever
# carries those three colours (labels/values are cyan, separators are dim).
sl_zone_color() {
  local ctxline
  ctxline=$(printf '%s\n' "$1" | grep 'Context:')
  case "$ctxline" in
    *$'\033[31m'*) echo red ;;
    *$'\033[33m'*) echo yellow ;;
    *$'\033[32m'*) echo green ;;
    *) echo unknown ;;
  esac
}

# guard_call sid transcript cwd home settings budget acw mp
# Invokes context-guard.sh with a UserPromptSubmit payload under the given
# PATH sandbox ($mp). acw="" means CLAUDE_CODE_AUTO_COMPACT_WINDOW is
# unset; non-empty sets it (and wins over settings.json, like the harness).
# Leaves the result in $GOUT / $GRC.
guard_call() {
  local sid="$1" transcript="$2" cwd="$3" home="$4" settings="$5" budget="$6" acw="$7" mp="$8"
  local stdin_json
  stdin_json=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' "$sid" "$transcript" "$cwd")
  if [ -n "$acw" ]; then
    GOUT=$(printf '%s' "$stdin_json" | env HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" CLAUDE_CODE_AUTO_COMPACT_WINDOW="$acw" PATH="$mp" "$mp/bash" "$GUARD" 2>&1)
  else
    GOUT=$(printf '%s' "$stdin_json" | env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" PATH="$mp" "$mp/bash" "$GUARD" 2>&1)
  fi
  GRC=$?
}

# Reused in cases A, B, C, F, G, H, I.
GLOBAL_TOK='{"thresholds_tokens":[400000,500000,550000]}'

# ===========================================================================
group "Case A: global tokens [400000,500000,550000], window 1M, seeded state"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")

  # 390k -> silent (below t1=400000)
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseA-390-$variant"; seed_state "$home" "$sid" 39 1000000 390000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "A($variant) 390k -> silent"
  else
    fail "A($variant) 390k -> silent" "rc=$GRC out=$GOUT"
  fi

  # 410k -> zone1, state records announced=400000
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseA-410-$variant"; seed_state "$home" "$sid" 41 1000000 410000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  ann=$(state_field "$home/.claude/context-state/$sid.json" announced)
  if [ "$GRC" = 0 ] && [ "$z" = 1 ] && [ "$ann" = 400000 ]; then
    pass "A($variant) 410k -> zone1, state announced=400000"
  else
    fail "A($variant) 410k -> zone1" "zone=$z announced=$ann out=$GOUT"
  fi

  # 510k -> zone2, autocheckpoint snapshot path exists
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseA-510-$variant"; seed_state "$home" "$sid" 51 1000000 510000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  snap=$(snap_path_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 2 ] && [ -n "$snap" ] && [ -f "$snap" ]; then
    pass "A($variant) 510k -> zone2, snapshot at $snap"
  else
    fail "A($variant) 510k -> zone2" "zone=$z snap=[$snap] out=$GOUT"
  fi

  # 560k -> zone3
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseA-560-$variant"; seed_state "$home" "$sid" 56 1000000 560000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 3 ]; then
    pass "A($variant) 560k -> zone3"
  else
    fail "A($variant) 560k -> zone3" "zone=$z out=$GOUT"
  fi
done

# ===========================================================================
group "Case B: one session via transcript fallback (updated=0 forces re-read)"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  transcript="$home/t.jsonl"
  sid="caseB-$variant"
  sf="$home/.claude/context-state/$sid.json"

  # call 1: 410k -> zone1; write_state's fallback branch must stamp updated=0
  write_transcript_n "$transcript" 410000
  guard_call "$sid" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  upd=$(state_field "$sf" updated)
  ann=$(state_field "$sf" announced)
  if [ "$GRC" = 0 ] && [ "$z" = 1 ] && [ "$upd" = 0 ] && [ "$ann" = 400000 ]; then
    pass "B($variant) call1 410k -> zone1, state updated=0 announced=400000"
  else
    fail "B($variant) call1 410k -> zone1" "rc=$GRC zone=$z updated=$upd announced=$ann out=$GOUT"
  fi

  # call 2: 420k -> same zone1 band as already announced -> silent, and since
  # updated=0 the guard must have re-read the (now rewritten) transcript
  # rather than trusting the stale state's 410k.
  write_transcript_n "$transcript" 420000
  guard_call "$sid" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "B($variant) call2 420k -> silent (still below t2, already announced t1)"
  else
    fail "B($variant) call2 420k -> silent" "rc=$GRC out=$GOUT"
  fi

  # call 3: 300k -> below t1 -> silent, announced resets to 0
  write_transcript_n "$transcript" 300000
  guard_call "$sid" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  ann2=$(state_field "$sf" announced)
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ] && [ "$ann2" = 0 ]; then
    pass "B($variant) call3 300k -> silent, announced reset to 0"
  else
    fail "B($variant) call3 300k -> silent, announced=0" "rc=$GRC out=$GOUT announced=$ann2"
  fi
done

# ===========================================================================
group "Case C: project vs global precedence"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")

  # project pct [30,40,50] beats global tokens [400000,500000,550000]:
  # the loop reads the project file first and stops there.
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  write_json "$proj/.agents/context-budget.json" '{"thresholds":[30,40,50]}'
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseC1-$variant"; seed_state "$home" "$sid" 41 1000000 410000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 2 ]; then
    pass "C($variant) project pct [30,40,50] beats global tokens -> zone2 at 41%"
  else
    fail "C($variant) project pct beats global tokens" "zone=$z out=$GOUT"
  fi

  # project tokens [420000,...] beat global tokens [400000,...]: silence at 410k
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  write_json "$proj/.agents/context-budget.json" '{"thresholds_tokens":[420000,500000,550000]}'
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseC2-$variant"; seed_state "$home" "$sid" 41 1000000 410000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "C($variant) project tokens [420000,...] beat global [400000,...] -> silent at 410k"
  else
    fail "C($variant) project tokens beat global tokens" "out=$GOUT"
  fi

  # invalid project file (percent-range values under the 1000 token floor)
  # is treated as absent and falls through to the valid global tokens file.
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  write_json "$proj/.agents/context-budget.json" '{"thresholds_tokens":[60,80,90]}'
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseC3-$variant"; seed_state "$home" "$sid" 41 1000000 410000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 1 ]; then
    pass "C($variant) invalid project file falls through to valid global tokens -> zone1 at 410k"
  else
    fail "C($variant) invalid project falls through to global" "zone=$z out=$GOUT"
  fi
done

# ===========================================================================
group "Case D: invalid thresholds_tokens configs fall back to defaults"
# ===========================================================================
# All seven use a 1000000-window, 41%/410000-token seed: the 60/80/90%
# defaults leave 41% silent, so a PASS here is evidence of rejection, not a
# coincidence of the numbers (same methodology as threshold-parity.sh's
# malformed-config group). [4e5,5e5,6e5] is deliberately included even
# though jq (4E+5) and python (400000.0) stringify it differently -- both
# forms contain a non-digit character, so budget_ok rejects both the same
# way; verified by hand (jq -1.7.1-apple) before relying on it here.
D_LABELS=(
  "percent-sized values [60,80,90] (below the 1000 token floor)"
  "non-ascending [500000,400000,550000]"
  "wrong length [400000,500000] (only 2 elements)"
  "space inside a string element"
  "float element [400000.5,...]"
  "exponent notation [4e5,5e5,6e5]"
  "string instead of an array"
)
D_CONTENTS=(
  '{"thresholds_tokens":[60,80,90]}'
  '{"thresholds_tokens":[500000,400000,550000]}'
  '{"thresholds_tokens":[400000,500000]}'
  '{"thresholds_tokens":["400000 ","500000","550000"]}'
  '{"thresholds_tokens":[400000.5,500000,550000]}'
  '{"thresholds_tokens":[4e5,5e5,6e5]}'
  '{"thresholds_tokens":"400000"}'
)
for variant in jq py; do
  mp=$(mp_of "$variant")
  i=0
  while [ "$i" -lt "${#D_CONTENTS[@]}" ]; do
    home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
    budget="$home/budget.json"; write_json "$budget" "${D_CONTENTS[$i]}"
    settings="$home/settings.json"; write_settings "$settings"
    sid="caseD-$i-$variant"; seed_state "$home" "$sid" 41 1000000 410000 0
    guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
    if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
      pass "D($variant) ${D_LABELS[$i]} -> invalid, defaults, silent at 41%"
    else
      fail "D($variant) ${D_LABELS[$i]}" "out=$GOUT config=${D_CONTENTS[$i]}"
    fi
    i=$((i + 1))
  done

  # A UTF-8 BOM ahead of an otherwise-valid config must still parse (jq
  # strips it natively; python3 via encoding="utf-8-sig").
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  budget="$home/budget.json"
  printf '\xEF\xBB\xBF{"thresholds_tokens":[400000,500000,550000]}' > "$budget"
  settings="$home/settings.json"; write_settings "$settings"
  sid="caseD-bom-$variant"; seed_state "$home" "$sid" 41 1000000 410000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 1 ]; then
    pass "D($variant) UTF-8 BOM ahead of a valid config -> zone1 at 410k"
  else
    fail "D($variant) UTF-8 BOM ahead of valid config" "zone=$z out=$GOUT"
  fi
done

# ===========================================================================
group "Case E: advisor-doubling fix (transcript fallback iterations picker)"
# ===========================================================================
# Fixture: a real transcript line (session
# 649a596e-9b2b-4bad-aa90-c5cdb204dcb1, reduced to type/model/usage) whose
# top-level usage is the doubled aggregate (input=4, cache_creation=3093,
# cache_read=222541, sum 225638) and whose iterations are
# [message 2/1441/110550 (sum 111993), advisor_message, message
# 2/1652/111991 (sum 113645)]. usage_pick must return the LAST message /
# fallback_message iteration (113645), skipping advisor_message/compaction.
# Literal heredocs, not harness-built JSON: the negative control below runs
# the mutated guard against these exact bytes, so they must be auditable.
E_BASE=$(cat <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":4,"cache_creation_input_tokens":3093,"cache_read_input_tokens":222541,"output_tokens":790,"output_tokens_details":{"thinking_tokens":596},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":1441,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","iterations":[{"input_tokens":2,"output_tokens":623,"cache_read_input_tokens":110550,"cache_creation_input_tokens":1441,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1441},"type":"message"},{"input_tokens":113780,"output_tokens":4864,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"type":"advisor_message","model":"claude-fable-5-1"},{"input_tokens":2,"output_tokens":167,"cache_read_input_tokens":111991,"cache_creation_input_tokens":1652,"cache_creation":{"ephemeral_5m_input_tokens":1652,"ephemeral_1h_input_tokens":0},"type":"message"}],"speed":"standard"}}}
EOF
)
# Control: same top-level aggregate, no iterations key at all -> the doubled
# 225638 must be used (this is the bug the fix targets).
E_CONTROL=$(cat <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":4,"cache_creation_input_tokens":3093,"cache_read_input_tokens":222541,"output_tokens":790,"output_tokens_details":{"thinking_tokens":596},"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":1441,"ephemeral_5m_input_tokens":0},"inference_geo":"not_available","speed":"standard"}}}
EOF
)
# (i) iterations truncated to [message, advisor_message]: the trailing entry
# is the advisor -- the picker must fall back to the earlier message
# (111993), not the advisor entry. Silence must be asserted exactly: this is
# the one variant the run.sh negative control (advisor_message ->
# advisor_messageX) actually flips, because it is the only case where the
# LAST array element is the one that must be skipped.
E_I=$(cat <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":4,"cache_creation_input_tokens":3093,"cache_read_input_tokens":222541,"output_tokens":790,"iterations":[{"input_tokens":2,"output_tokens":623,"cache_read_input_tokens":110550,"cache_creation_input_tokens":1441,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1441},"type":"message"},{"input_tokens":113780,"output_tokens":4864,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"type":"advisor_message","model":"claude-fable-5-1"}]}}}
EOF
)
# (ii) a trailing, well-formed compaction entry (all four counts present):
# still skipped, so the picker still lands on the same last message (113645).
E_II=$(cat <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":4,"cache_creation_input_tokens":3093,"cache_read_input_tokens":222541,"output_tokens":790,"iterations":[{"input_tokens":2,"output_tokens":623,"cache_read_input_tokens":110550,"cache_creation_input_tokens":1441,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1441},"type":"message"},{"input_tokens":113780,"output_tokens":4864,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"type":"advisor_message","model":"claude-fable-5-1"},{"input_tokens":2,"output_tokens":167,"cache_read_input_tokens":111991,"cache_creation_input_tokens":1652,"cache_creation":{"ephemeral_5m_input_tokens":1652,"ephemeral_1h_input_tokens":0},"type":"message"},{"input_tokens":5,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"type":"compaction"}]}}}
EOF
)
# (iii) a non-object last entry ("junk"): fails the object/type checks, so
# the picker must fall back to the top-level (doubled) aggregate, 225638.
E_III=$(cat <<'EOF'
{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":4,"cache_creation_input_tokens":3093,"cache_read_input_tokens":222541,"output_tokens":790,"iterations":[{"input_tokens":2,"output_tokens":623,"cache_read_input_tokens":110550,"cache_creation_input_tokens":1441,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1441},"type":"message"},{"input_tokens":113780,"output_tokens":4864,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"type":"advisor_message","model":"claude-fable-5-1"},{"input_tokens":2,"output_tokens":167,"cache_read_input_tokens":111991,"cache_creation_input_tokens":1652,"cache_creation":{"ephemeral_5m_input_tokens":1652,"ephemeral_1h_input_tokens":0},"type":"message"},"junk"]}}}
EOF
)
# A second, synthetic API-error line (all-zero usage): the guard's
# `grep -v '"model":"<synthetic>"'` must drop it before `tail -1`, so the
# real line above it is still the one used.
E_SYNTHETIC=$(cat <<'EOF'
{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
EOF
)
E_BUDGET_CONTENT='{"thresholds_tokens":[150000,200000,240000]}'
# (iv) uses its own, lower thresholds so the outcome (zone1 at 113645) is
# distinguishable from what the doubled 0 or 225638 would also produce.
E_BUDGET_IV_CONTENT='{"thresholds_tokens":[100000,200000,240000]}'

for variant in jq py; do
  mp=$(mp_of "$variant")

  # base: iterations present -> last message (113645) < 150000 -> silent
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$E_BUDGET_CONTENT"
  transcript="$home/t.jsonl"; printf '%s\n' "$E_BASE" > "$transcript"
  guard_call "caseE-base-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "E($variant) base: iterations present -> silent (113645, not doubled)"
  else
    fail "E($variant) base" "rc=$GRC out=$GOUT"
  fi

  # control: no iterations key -> top-level doubled aggregate (225638) -> zone2
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$E_BUDGET_CONTENT"
  transcript="$home/t.jsonl"; printf '%s\n' "$E_CONTROL" > "$transcript"
  guard_call "caseE-ctrl-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 2 ]; then
    pass "E($variant) control: no iterations key -> zone2 (225638, doubled aggregate)"
  else
    fail "E($variant) control" "zone=$z out=$GOUT"
  fi

  # (i) trailing advisor entry -> earlier message (111993) used; must be silent exactly
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$E_BUDGET_CONTENT"
  transcript="$home/t.jsonl"; printf '%s\n' "$E_I" > "$transcript"
  guard_call "caseE-i-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "E($variant) (i) trailing advisor_message -> silent exactly (111993)"
  else
    fail "E($variant) (i) trailing advisor_message" "rc=$GRC out=[$GOUT]"
  fi

  # (ii) trailing well-formed compaction entry -> still 113645, silent
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$E_BUDGET_CONTENT"
  transcript="$home/t.jsonl"; printf '%s\n' "$E_II" > "$transcript"
  guard_call "caseE-ii-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "E($variant) (ii) trailing compaction entry -> silent (113645)"
  else
    fail "E($variant) (ii) trailing compaction entry" "rc=$GRC out=$GOUT"
  fi

  # (iii) non-object last entry ("junk") -> falls back to top-level, zone2
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$E_BUDGET_CONTENT"
  transcript="$home/t.jsonl"; printf '%s\n' "$E_III" > "$transcript"
  guard_call "caseE-iii-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 2 ]; then
    pass "E($variant) (iii) non-object last entry -> top-level used, zone2"
  else
    fail "E($variant) (iii) non-object last entry" "zone=$z out=$GOUT"
  fi

  # (iv) synthetic zero-usage line appended after the real line -> the real
  # line is still used (113645); own lower thresholds put it in zone1, and
  # the state file must record the real (undoubled) token count.
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget-iv.json"; write_json "$budget" "$E_BUDGET_IV_CONTENT"
  transcript="$home/t.jsonl"; printf '%s\n%s\n' "$E_BASE" "$E_SYNTHETIC" > "$transcript"
  sidiv="caseE-iv-$variant"
  guard_call "$sidiv" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  tok=$(state_field "$home/.claude/context-state/$sidiv.json" input_tokens)
  if [ "$GRC" = 0 ] && [ "$z" = 1 ] && [ "$tok" = 113645 ]; then
    pass "E($variant) (iv) synthetic zero line after real line -> real used (113645), zone1"
  else
    fail "E($variant) (iv) synthetic line after real line" "zone=$z state_tokens=$tok out=$GOUT"
  fi
done

# ===========================================================================
group "Case F: statusline --preview <-> guard parity on token thresholds"
# ===========================================================================
# --preview hardcodes total_input_tokens=410000, used_percentage=41: the
# config is the lever, not the percentage (same methodology as
# threshold-parity.sh's sl_zone/guard_zone pair). Run from a non-git temp
# dir on purpose (seg_branch's +N/-N counters are also green/red and would
# confound the zone read).
f_case() {
  local label="$1" content="$2" exp_color="$3" exp_zone="$4"
  local variant mp home proj budget settings sid sl_out sl_color g_zone
  for variant in jq py; do
    mp=$(mp_of "$variant")
    home=$(mktempdir); proj=$(mktempdir)
    budget="$home/budget.json"; write_json "$budget" "$content"
    settings="$home/settings.json"; write_settings "$settings"
    sl_out=$(cd "$proj" && env HOME="$home" PF_CONTEXT_BUDGET_CONFIG="$budget" PF_STATUSLINE_CONFIG=/nonexistent PATH="$mp" "$mp/bash" "$STATUSLINE" --preview 2>/dev/null)
    sl_color=$(sl_zone_color "$sl_out")
    sid="caseF-$variant-$RANDOM"
    seed_state "$home" "$sid" 41 1000000 410000 0
    guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
    g_zone=$(zone_of "$GOUT")
    if [ "$sl_color" = "$exp_color" ] && [ "$g_zone" = "$exp_zone" ]; then
      pass "F($variant) $label -> statusline=$sl_color guard=zone$g_zone"
    else
      fail "F($variant) $label" "expected color=$exp_color zone=$exp_zone; got statusline=$sl_color guard=zone$g_zone; sl_out=$sl_out g_out=$GOUT"
    fi
  done
}
f_case "[400000,500000,550000] yellow/zone1"          '{"thresholds_tokens":[400000,500000,550000]}' yellow 1
f_case "[300000,400000,550000] red/zone2"              '{"thresholds_tokens":[300000,400000,550000]}' red 2
f_case "[420000,500000,550000] green/silent"           '{"thresholds_tokens":[420000,500000,550000]}' green 0
f_case "boundary [410000,500000,550000] yellow/zone1"  '{"thresholds_tokens":[410000,500000,550000]}' yellow 1
f_case "boundary [410001,500000,550000] green/silent"  '{"thresholds_tokens":[410001,500000,550000]}' green 0

for variant in jq py; do
  mp=$(mp_of "$variant")
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  write_json "$proj/.agents/context-budget.json" '{"thresholds_tokens":[400000,500000,550000]}'
  budget="$home/budget.json"; write_json "$budget" '{"thresholds_tokens":[420000,500000,550000]}'
  settings="$home/settings.json"; write_settings "$settings"
  sl_out=$(cd "$proj" && env HOME="$home" PF_CONTEXT_BUDGET_CONFIG="$budget" PF_STATUSLINE_CONFIG=/nonexistent PATH="$mp" "$mp/bash" "$STATUSLINE" --preview 2>/dev/null)
  sl_color=$(sl_zone_color "$sl_out")
  sid="caseF-override-$variant"
  seed_state "$home" "$sid" 41 1000000 410000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  g_zone=$(zone_of "$GOUT")
  if [ "$sl_color" = yellow ] && [ "$g_zone" = 1 ]; then
    pass "F($variant) project tokens [400000,...] override global [420000,...] -> yellow/zone1"
  else
    fail "F($variant) project tokens override global" "statusline=$sl_color guard_zone=$g_zone sl_out=$sl_out g_out=$GOUT"
  fi
done

# ===========================================================================
group "Case G: autoCompactWindow countdown suffix on zone directives"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")

  # settings acw=600000 -> left = min(600000,1000000) - 33000 - 410000 = 157000
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings" 600000
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  transcript="$home/t.jsonl"; write_transcript_n "$transcript" 410000
  guard_call "caseG1-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  case "$GOUT" in
    *'До автосжатия ~157k токенов (autoCompactWindow 600k).'*)
      pass "G($variant) settings autoCompactWindow=600000 -> ~157k tail" ;;
    *)
      fail "G($variant) settings autoCompactWindow=600000" "out=$GOUT" ;;
  esac

  # env CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000 wins over settings' 600000 ->
  # left = min(500000,1000000) - 33000 - 410000 = 57000
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings" 600000
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  transcript="$home/t.jsonl"; write_transcript_n "$transcript" 410000
  guard_call "caseG2-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" 500000 "$mp"
  case "$GOUT" in
    *'До автосжатия ~57k токенов (autoCompactWindow 500k).'*)
      pass "G($variant) env CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000 wins over settings 600000 -> ~57k tail" ;;
    *)
      fail "G($variant) env acw wins over settings" "out=$GOUT" ;;
  esac

  # no acw anywhere (settings has none, env unset) -> zone1 directive, but
  # no countdown tail at all.
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  settings="$home/settings.json"; write_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  transcript="$home/t.jsonl"; write_transcript_n "$transcript" 410000
  guard_call "caseG3-$variant" "$transcript" "$proj" "$home" "$settings" "$budget" "" "$mp"
  z=$(zone_of "$GOUT")
  case "$GOUT" in
    *'До автосжатия'*)
      fail "G($variant) no acw anywhere" "unexpected countdown tail present: out=$GOUT" ;;
    *)
      if [ "$z" = 1 ]; then
        pass "G($variant) no acw anywhere -> zone1, no countdown tail"
      else
        fail "G($variant) no acw anywhere" "zone=$z out=$GOUT"
      fi ;;
  esac
done

# ===========================================================================
group "Case H: doctor.sh check 8 (WARN, never FAIL, for unreachable thresholds)"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")

  # H1: global [400000,500000,580000] + acw 600000 -> compact_at=567000;
  # 580000 >= 567000 -> WARN naming 580000, rc=0, no FAIL.
  home=$(mktempdir); cwd=$(mktempdir)
  settings="$home/settings.json"; write_doctor_settings "$settings" 600000
  budget="$home/budget.json"; write_json "$budget" '{"thresholds_tokens":[400000,500000,580000]}'
  out=$(cd "$cwd" && env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" PATH="$mp" "$mp/bash" "$DOCTOR" 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qE '^WARN.*580000' && ! printf '%s\n' "$out" | grep -q '^FAIL'; then
    pass "H($variant) global [400000,500000,580000] acw=600000 -> WARN naming 580000, rc=0, no FAIL"
  else
    fail "H($variant) H1 unreachable threshold" "rc=$rc out=$out"
  fi

  # H2: tokens configured, autoCompactWindow unset anywhere -> WARN
  # ("cannot be told whether they fire in time").
  home=$(mktempdir); cwd=$(mktempdir)
  settings="$home/settings.json"; write_doctor_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  out=$(cd "$cwd" && env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" PATH="$mp" "$mp/bash" "$DOCTOR" 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^WARN'; then
    pass "H($variant) tokens without autoCompactWindow -> WARN, rc=0"
  else
    fail "H($variant) H2 tokens without acw" "rc=$rc out=$out"
  fi

  # H3: [400000,500000,550000] with acw 600000 -> compact_at=567000, all
  # three thresholds clear it -> no WARN, no FAIL.
  home=$(mktempdir); cwd=$(mktempdir)
  settings="$home/settings.json"; write_doctor_settings "$settings" 600000
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  out=$(cd "$cwd" && env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" PATH="$mp" "$mp/bash" "$DOCTOR" 2>&1); rc=$?
  if [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q '^WARN' && ! printf '%s\n' "$out" | grep -q '^FAIL'; then
    pass "H($variant) [400000,500000,550000] acw=600000 -> no WARN, no FAIL"
  else
    fail "H($variant) H3 all thresholds clear compact_at" "rc=$rc out=$out"
  fi

  # H4: settings acw=50000 (below the documented minimum 100000; the guard's
  # acw_read drops such a value) -> doctor must NOT derive a
  # 17000 compaction point from it: no "compaction point ~17000" WARN, the
  # tokens file gets the "unset or outside the documented range" WARN instead,
  # rc=0, no FAIL.
  home=$(mktempdir); cwd=$(mktempdir)
  settings="$home/settings.json"; write_doctor_settings "$settings" 50000
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  out=$(cd "$cwd" && env -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" PATH="$mp" "$mp/bash" "$DOCTOR" 2>&1); rc=$?
  if [ "$rc" = 0 ] && ! printf '%s\n' "$out" | grep -q 'compaction point ~17000' && printf '%s\n' "$out" | grep -q '^WARN.*outside the documented range' && ! printf '%s\n' "$out" | grep -q '^FAIL'; then
    pass "H($variant) settings acw=50000 (below minimum) -> no 17000 compaction point, range WARN, rc=0"
  else
    fail "H($variant) H4 acw below the documented minimum" "rc=$rc out=$out"
  fi

  # H5: env CLAUDE_CODE_AUTO_COMPACT_WINDOW=0600000 (leading zero; invalid as
  # a JSON number, so it can only arrive via the env) must read as 600000,
  # not as an octal literal: compact_at=567000, all three thresholds clear it.
  home=$(mktempdir); cwd=$(mktempdir)
  settings="$home/settings.json"; write_doctor_settings "$settings"
  budget="$home/budget.json"; write_json "$budget" "$GLOBAL_TOK"
  out=$(cd "$cwd" && env HOME="$home" CLAUDE_SETTINGS_PATH="$settings" PF_CONTEXT_BUDGET_CONFIG="$budget" CLAUDE_CODE_AUTO_COMPACT_WINDOW=0600000 PATH="$mp" "$mp/bash" "$DOCTOR" 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'all fire before compaction (~567000)' && ! printf '%s\n' "$out" | grep -q '^WARN' && ! printf '%s\n' "$out" | grep -q '^FAIL'; then
    pass "H($variant) env acw=0600000 (leading zero) -> read as 600000, compact_at 567000, no WARN"
  else
    fail "H($variant) H5 leading-zero acw" "rc=$rc out=$out"
  fi
done

# ===========================================================================
group "Case I: PF_EFFECTIVE_HOME defaulting (env -u HOME, TMPDIR-based global config)"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")
  sbt=$(mktempdir)
  write_json "$sbt/.config/pf-handoff/context-budget.json" "$GLOBAL_TOK"
  settings="$sbt/settings.json"; write_settings "$settings"
  transcript="$sbt/t.jsonl"; write_transcript_n "$transcript" 410000
  proj=$(mktempdir); mkdir -p "$proj/.agents"
  sid="caseI-$variant"
  stdin_json=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","transcript_path":"%s","cwd":"%s"}' "$sid" "$transcript" "$proj")
  # HOME unset AND PF_CONTEXT_BUDGET_CONFIG unset: PF_EFFECTIVE_HOME falls
  # back to TMPDIR, and the global config path is derived from it
  # ($PF_EFFECTIVE_HOME/.config/pf-handoff/context-budget.json).
  GOUT=$(printf '%s' "$stdin_json" | env -u HOME -u PF_CONTEXT_BUDGET_CONFIG -u CLAUDE_CODE_AUTO_COMPACT_WINDOW TMPDIR="$sbt" CLAUDE_SETTINGS_PATH="$settings" PATH="$mp" "$mp/bash" "$GUARD" 2>&1)
  GRC=$?
  z=$(zone_of "$GOUT")
  if [ "$GRC" = 0 ] && [ "$z" = 1 ]; then
    pass "I($variant) env -u HOME, TMPDIR-derived global config -> zone1 at 410k"
  else
    fail "I($variant) PF_EFFECTIVE_HOME default path" "rc=$GRC zone=$z out=$GOUT"
  fi
done

# ===========================================================================
group "Case J: garbage global config file -> both hooks fall back to defaults"
# ===========================================================================
for variant in jq py; do
  mp=$(mp_of "$variant")
  home=$(mktempdir); proj=$(mktempdir); mkdir -p "$proj/.agents"
  budget="$home/budget.json"; write_json "$budget" 'not json {'
  settings="$home/settings.json"; write_settings "$settings"

  sid="caseJ-$variant"
  seed_state "$home" "$sid" 41 200000 82000 0
  guard_call "$sid" /nonexistent.jsonl "$proj" "$home" "$settings" "$budget" "" "$mp"
  if [ "$GRC" = 0 ] && [ -z "$GOUT" ]; then
    pass "J($variant) guard: garbage global config -> defaults, silent at 41%"
  else
    fail "J($variant) guard garbage config" "rc=$GRC out=$GOUT"
  fi

  sl_out=$(cd "$proj" && env HOME="$home" PF_CONTEXT_BUDGET_CONFIG="$budget" PF_STATUSLINE_CONFIG=/nonexistent PATH="$mp" "$mp/bash" "$STATUSLINE" --preview 2>&1)
  sl_rc=$?
  sl_color=$(sl_zone_color "$sl_out")
  if [ "$sl_rc" = 0 ] && [ "$sl_color" = green ] && printf '%s\n' "$sl_out" | grep -q 'Context:'; then
    pass "J($variant) statusline: garbage global config -> defaults, green Context line"
  else
    fail "J($variant) statusline garbage config" "rc=$sl_rc color=$sl_color out=$sl_out"
  fi
done

finish
