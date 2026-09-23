#!/bin/bash
# Пороговые вбросы контекста — одно тело на два события: UserPromptSubmit и
# PostToolUse (какое именно сработало, берём из .hook_event_name входа).
# Контракт: НИКОГДА не падать и не блокировать сессию (see statusline.sh header).
set -u
# Контракт «никогда не мешать сессии»: без HOME не выключаемся молча, а
# уходим во временный каталог (та же страховка, что в statusline.sh).
# $HOME САМ не переопределяем (F-20) — весь внутренний state живёт под
# PF_EFFECTIVE_HOME (см. statusline.sh, тот же контракт).
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"
HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

THRESH_Z1='[Контекст: занято %s%%, свободно ~%sk токенов. §13: сделай чекпоинт HANDOFF; новые крупные куски — субагентам или в новую сессию.]'
THRESH_Z2='[Контекст: занято %s%%, свободно ~%sk токенов. §13: новых M/L-кусков не начинать; доведи текущий до проверяемой точки и обнови HANDOFF.]'
THRESH_Z3='[Контекст: занято %s%%. §13: немедленно полный pf-handoff (сверка → перезапись → журнал → статусы). Автокомпакт близок — HANDOFF должен быть свежим.]'
# Хвосты второй зоны (T-031): на пороге t2 снимок состояния пишется САМ
# (autocheckpoint.sh), и агенту сообщается ФАКТ — записан или нет. Сжатие хук
# инициировать не может ни в каком виде (у хуков нет такого поля вывода), его
# на 80% запускает сам харнесс по настройке autoCompactWindow; задача этого
# сообщения — чтобы сжатие не застало состояние несохранённым.
THRESH_Z2_OK=' Авто-снимок состояния записан сам: %s. Смысловой чекпоинт всё равно за тобой: сделай pf-handoff — снимок собран скриптом и не отличает доказанное от заявленного.'
THRESH_Z2_FAIL=' ВНИМАНИЕ: авто-снимок состояния записать НЕ УДАЛОСЬ. Сжимать контекст нельзя (/compact и /clear запрещены), пока состояние не сохранено руками через pf-handoff: сжатие с потерей состояния хуже, чем его отсутствие (I-036). PreCompact заблокирует автосжатие до починки записи.'
# Хвост «до автосжатия» (v1.11.0): харнесс запускает сжатие примерно на 33k
# токенов НИЖЕ autoCompactWindow (резерв под ответ модели: 20k вывода плюс
# 13k, снято с бинарника Claude Code 2.1.280). Показываем, сколько осталось до
# этой точки, чтобы агент не считал «свободно ~600k» за реальный запас.
COMPACT_RESERVE=33000
THRESH_ACW=' До автосжатия ~%sk токенов (autoCompactWindow %sk).'

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id event transcript_path agent_id cwd_in
  if [ "$has_jq" = 1 ]; then
    # Каталог проекта — по той же формуле, что в statusline.sh (сперва
    # workspace.current_dir, потом cwd): иначе два хука читали бы
    # .agents/context-budget.json из разных каталогов.
    # Разделитель U+001F (unit separator), НЕ таб: таб для bash-read — «IFS-пробел»,
    # последовательные табы схлопываются, и пустые поля (например, отсутствующий
    # agent_id) сдвигали бы соседние значения на их место.
    row=$(printf '%s' "$input" | jq -r '[(.session_id // ""), (.hook_event_name // ""), (.transcript_path // ""), (.agent_id // ""), (if (.workspace|type) == "object" and ((.workspace.current_dir // "") != "") then .workspace.current_dir else (.cwd // "") end)] | join("\u001f")' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
ws = d.get("workspace")
cwd = (ws.get("current_dir") if isinstance(ws, dict) else None) or d.get("cwd") or ""
print("\x1f".join([str(d.get("session_id") or ""), str(d.get("hook_event_name") or ""), str(d.get("transcript_path") or ""), str(d.get("agent_id") or ""), str(cwd)]))
' 2>/dev/null)
  fi
  IFS=$'\x1f' read -r session_id event transcript_path agent_id cwd_in <<< "$row"
  [ -z "$session_id" ] && return 0
  [ -z "$event" ] && event="UserPromptSubmit"
  # session_id и agent_id становятся именами файлов — только безопасные символы.
  case "$session_id" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  case "${agent_id:-}" in *[!A-Za-z0-9._-]*) return 0 ;; esac

  # Субагентский вызов (во входе есть agent_id): процент РОДИТЕЛЯ для субагента —
  # дезинформация (у него своё, отдельное окно), а расход родительского
  # `announced` прятал бы предупреждение от самого родителя. Поэтому: считаем
  # собственное окно субагента по его транскрипту (путь вычислим по шаблону
  # <каталог>/<session_id>/subagents/agent-<agent_id>.jsonl) и ведём отдельный
  # state-ключ agent-<id>.json. Родительское состояние не читаем и не пишем.
  # Оговорка: окно для fallback берётся по модели из settings.json — если
  # субагент на другой модели (например haiku, 200k), оценка приблизительная.
  if [ -n "$agent_id" ]; then
    local sub_tp
    sub_tp="$(dirname "$transcript_path")/$session_id/subagents/agent-$agent_id.jsonl"
    if [ ! -r "$sub_tp" ]; then
      # Страховка на случай смены структуры каталогов harness'ом: сегодня ВСЕ
      # уровни вложенности (сын, внук, …) лежат плоско в subagents/ главной
      # сессии — проверено экспериментом с внуком 2026-08-10.
      sub_tp=$(find "$(dirname "$transcript_path")/$session_id" -maxdepth 4 -name "agent-$agent_id.jsonl" 2>/dev/null | head -n 1)
    fi
    { [ -n "$sub_tp" ] && [ -r "$sub_tp" ]; } || return 0
    transcript_path="$sub_tp"
    session_id="agent-$agent_id"
  fi

  # Пороги зон (v1.11.0): по умолчанию 60/80/90% окна. Переопределение: файл
  # .agents/context-budget.json, сперва проектный (<cwd>), потом глобальный
  # (~/.config/pf-handoff/, путь для тестов: PF_CONTEXT_BUDGET_CONFIG).
  # Форматы: {"thresholds_tokens": [400000, 500000, 530000]}, абсолютные токены
  # (три целых 1000..999999999 по возрастанию), сравнение идёт с занятыми
  # токенами, а не с процентом; {"thresholds": [50, 70, 85]}, проценты (три
  # целых 1..99 по возрастанию). Невалидный файл = отсутствующий (падаем к
  # следующему источнику). Разбор: budget_parse ниже, та же функция в
  # statusline.sh: бар обязан краснеть там же, где guard шлёт директивы.
  local t1=60 t2=80 t3=90
  local bmode=pct brow="" bfile
  for bfile in "${cwd_in:+$cwd_in/.agents/context-budget.json}" \
               "${PF_CONTEXT_BUDGET_CONFIG:-$PF_EFFECTIVE_HOME/.config/pf-handoff/context-budget.json}"; do
    { [ -n "$bfile" ] && [ -f "$bfile" ] && [ -r "$bfile" ]; } || continue
    brow=$(budget_parse "$bfile" "$has_jq")
    [ -n "$brow" ] && break
  done
  if [ -n "$brow" ]; then
    IFS=$'\t' read -r bmode t1 t2 t3 <<< "$brow"
  fi

  local state_dir state_file
  state_dir="$PF_EFFECTIVE_HOME/.claude/context-state"
  state_file="$state_dir/$session_id.json"

  # Значения, которые в итоге пойдут в формулу/сообщение.
  local pct="" window="" used_tokens="" announced=0
  local s_pct="null" s_window="null" s_tokens="null" s_updated="null" s_announced=0

  if [ -f "$state_file" ]; then
    if [ "$has_jq" = 1 ]; then
      row=$(jq -r '[(.pct // "null"), (.window // "null"), (.input_tokens // "null"), (.updated // "null"), (.announced // 0)] | @tsv' "$state_file" 2>/dev/null)
    else
      row=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
def g(v):
    return "null" if v is None else v
print("\t".join([str(g(d.get("pct"))), str(g(d.get("window"))), str(g(d.get("input_tokens"))), str(g(d.get("updated"))), str(d.get("announced") or 0)]))
' "$state_file" 2>/dev/null)
    fi
    IFS=$'\t' read -r s_pct s_window s_tokens s_updated s_announced <<< "$row"
    [ -z "${s_announced:-}" ] && s_announced=0
    [ "$s_announced" = "null" ] && s_announced=0

    if [ "${s_pct:-null}" != "null" ] && [ -n "${s_pct:-}" ]; then
      local now age
      now=$(date +%s)
      age=$(( now - ${s_updated:-0} ))
      if [ "$age" -le 300 ] 2>/dev/null; then
        pct="$s_pct"; window="$s_window"; used_tokens="$s_tokens"
      fi
    fi
    announced="$s_announced"
  fi

  local fallback_used=0
  if [ -z "$pct" ]; then
    # Состояние отсутствует или устарело (>300с) — резервная эвристика: оценить
    # pct по хвосту транскрипта (последние ~200 КБ, последний блок usage).
    fallback_used=1
    local in_tok=0 cache_creation=0 cache_read=0
    if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
      local usage_line
      # Строки API-ошибок ("model":"<synthetic>") несут нулевой usage: попав
      # последними, они обнуляли оценку и сбрасывали announced: пропускаем.
      usage_line=$(tail -c 200000 -- "$transcript_path" 2>/dev/null | grep '"cache_read_input_tokens"' | grep -v '"model":"<synthetic>"' | tail -1)
      if [ -n "$usage_line" ]; then
        local m picked="" p_in="" p_cc="" p_cr=""
        # После вызова радника (advisor) верхнеуровневый usage: СУММА по
        # итерациям, и cache_read исполнителя входит в неё дважды: контекст
        # выглядел вдвое больше реального. Есть массив iterations: берём
        # последнюю итерацию самого исполнителя (usage_pick ниже); нет jq и
        # python3 или мусор: старые grep по верхнему уровню.
        case "$usage_line" in
          *'"iterations":['*)
            picked=$(printf '%s\n' "$usage_line" | usage_pick "$has_jq")
            IFS=$'\t' read -r p_in p_cc p_cr <<< "$picked"
            case "$p_in$p_cc$p_cr" in
              *[!0-9]*|'') picked="" ;;
              *) { [ -n "$p_in" ] && [ -n "$p_cc" ] && [ -n "$p_cr" ]; } || picked="" ;;
            esac ;;
        esac
        if [ -n "$picked" ]; then
          in_tok=$(( 10#$p_in )); cache_creation=$(( 10#$p_cc )); cache_read=$(( 10#$p_cr ))
        else
          m=$(printf '%s' "$usage_line" | grep -oE '"input_tokens":[0-9]+' | head -1); in_tok=${m#*:}
          m=$(printf '%s' "$usage_line" | grep -oE '"cache_creation_input_tokens":[0-9]+' | head -1); cache_creation=${m#*:}
          m=$(printf '%s' "$usage_line" | grep -oE '"cache_read_input_tokens":[0-9]+' | head -1); cache_read=${m#*:}
        fi
      fi
    fi
    [ -z "$in_tok" ] && in_tok=0
    [ -z "$cache_creation" ] && cache_creation=0
    [ -z "$cache_read" ] && cache_read=0

    # Окно: если в (пусть устаревшем) state-файле оно было — используем его;
    # иначе резервная эвристика по имени модели. UserPromptSubmit/PostToolUse не
    # получают поле model в stdin (его отдаёт только SessionStart), поэтому
    # смотрим на статически сконфигурированную модель в settings.json — это
    # приближение, а не факт текущей сессии.
    if [ "${s_window:-null}" != "null" ] && [ -n "${s_window:-}" ]; then
      window="$s_window"
    else
      window=200000
      local settings_path model_name lc_model
      settings_path="${CLAUDE_SETTINGS_PATH:-$PF_EFFECTIVE_HOME/.claude/settings.json}"
      model_name=""
      if [ -r "$settings_path" ]; then
        if [ "$has_jq" = 1 ]; then
          model_name=$(jq -r '.model // ""' "$settings_path" 2>/dev/null)
        else
          model_name=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
print(d.get("model") or "")
' "$settings_path" 2>/dev/null)
        fi
      fi
      lc_model=$(printf '%s' "${model_name:-}" | tr '[:upper:]' '[:lower:]')
      case "$lc_model" in
        *'[1m]'*|*fable*|*opus-5*|*sonnet-5*) window=1000000 ;;
        *) window=200000 ;;
      esac
    fi

    used_tokens=$(( in_tok + cache_creation + cache_read ))
    if [ "$window" -gt 0 ] 2>/dev/null; then
      pct=$(( used_tokens * 100 / window ))
    else
      pct=0
    fi
  fi

  [ -z "${pct:-}" ] && return 0

  # Метрика сравнения с порогами: процент окна (режим pct, по умолчанию) или
  # занятые токены (режим tok, thresholds_tokens). announced хранит значение
  # пересечённого порога (60 или 400000): в режиме tok оно больше 99, и при
  # возврате к процентам считается «ничего не объявлено», чтобы порог
  # объявился заново, а не молчал до конца сессии.
  local metric="$pct"
  if [ "$bmode" = tok ]; then
    case "${used_tokens:-}" in ''|*[!0-9]*) return 0 ;; esac
    metric="$used_tokens"
  elif [ "${announced:-0}" -gt 99 ] 2>/dev/null; then
    announced=0
  fi

  local new_announced=0 zone=0
  if [ "$metric" -ge "$t3" ] 2>/dev/null; then new_announced=$t3; zone=3
  elif [ "$metric" -ge "$t2" ] 2>/dev/null; then new_announced=$t2; zone=2
  elif [ "$metric" -ge "$t1" ] 2>/dev/null; then new_announced=$t1; zone=1
  fi

  if [ "$new_announced" -gt 0 ] 2>/dev/null && [ "$new_announced" -gt "${announced:-0}" ] 2>/dev/null; then
    local free_tokens xk msg acw acw_tail="" cap left reason
    free_tokens=$(( window - used_tokens ))
    [ "$free_tokens" -lt 0 ] && free_tokens=0
    xk=$(( free_tokens / 1000 ))
    # Хвост «до автосжатия»: запас до точки, где харнесс реально сжимает
    # (min(autoCompactWindow, окно) минус резерв COMPACT_RESERVE). Нет
    # autoCompactWindow ни в env, ни в settings.json: хвоста нет, сообщение
    # байт в байт как в v1.10.0.
    acw=$(acw_read "$has_jq")
    if [ -n "$acw" ]; then
      case "${used_tokens:-}" in
        ''|*[!0-9]*) : ;;
        *) cap="$acw"
           [ "$window" -gt 0 ] 2>/dev/null && [ "$window" -lt "$cap" ] 2>/dev/null && cap="$window"
           left=$(( cap - COMPACT_RESERVE - used_tokens )); [ "$left" -lt 0 ] && left=0
           acw_tail=$(printf "$THRESH_ACW" "$(( left / 1000 ))" "$(( acw / 1000 ))") ;;
      esac
    fi
    reason="порог t2 ($pct%)"
    [ "$bmode" = tok ] && reason="порог t2 (${used_tokens} токенов)"
    case "$zone" in
      1) msg=$(printf "$THRESH_Z1" "$pct" "$xk")$acw_tail ;;
      2) msg=$(printf "$THRESH_Z2" "$pct" "$xk")$acw_tail
         # Порог t2 — единственная точка, где чекпоинт выполняется без спроса.
         # Порог берётся из .agents/context-budget.json проекта, если он там
         # переопределён, поэтому снимок следует за настройкой проекта (в
         # отличие от autoCompactWindow, который глобален и задан в токенах).
         local snap ac_rc ac
         ac="$HOOK_DIR/autocheckpoint.sh"
         snap=""; ac_rc=1
         if [ -f "$ac" ] && [ -r "$ac" ]; then
           snap=$(bash "$ac" --session "$session_id" --cwd "${cwd_in:-}" \
                    --transcript "${transcript_path:-}" \
                    --reason "$reason" 2>/dev/null)
           ac_rc=$?
         fi
         if [ "$ac_rc" -eq 0 ] && [ -n "$snap" ]; then
           msg="$msg$(printf "$THRESH_Z2_OK" "$snap")"
         elif [ "$ac_rc" -eq 0 ]; then
           : # осознанный пропуск (субагент) — молча, это не отказ
         else
           msg="$msg$THRESH_Z2_FAIL"
         fi ;;
      3) msg=$(printf "$THRESH_Z3" "$pct")$acw_tail ;;
    esac
    emit_json "$event" "$msg" "$has_jq"
    write_state "$state_dir" "$state_file" "$has_jq" "$fallback_used" "$new_announced" "$pct" "$window" "$used_tokens" "$s_pct" "$s_window" "$s_tokens" "$s_updated"
  elif [ "$metric" -lt "$t1" ] 2>/dev/null && [ "${announced:-0}" != 0 ]; then
    write_state "$state_dir" "$state_file" "$has_jq" "$fallback_used" 0 "$pct" "$window" "$used_tokens" "$s_pct" "$s_window" "$s_tokens" "$s_updated"
  fi
  return 0
}

emit_json() {
  local event="$1" msg="$2" has_jq="$3"
  if [ "$has_jq" = 1 ]; then
    jq -n --arg name "$event" --arg ctx "$msg" '{hookSpecificOutput: {hookEventName: $name, additionalContext: $ctx}}'
  else
    EAC_EVENT="$event" EAC_MSG="$msg" python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {"hookEventName": os.environ["EAC_EVENT"], "additionalContext": os.environ["EAC_MSG"]}}, ensure_ascii=False))
'
  fi
}

# write_state — точечно обновляет announced, сохраняя остальные поля состояния.
# Если использовался fallback (state не было/устарело) — пишем свежие
# pct/window/input_tokens/updated; иначе — переносим их из уже прочитанного
# state без изменений (их актуальность — забота statusline.sh).
write_state() {
  local state_dir="$1" state_file="$2" has_jq="$3" fallback_used="$4" ann="$5"
  local fresh_pct="$6" fresh_window="$7" fresh_used="$8"
  local s_pct="$9" s_window="${10}" s_tokens="${11}" s_updated="${12}"
  local out_pct out_window out_tokens out_updated tmp

  if [ "$fallback_used" = 1 ]; then
    # updated=0, а не «сейчас»: оценка по транскрипту это НЕ показание
    # сенсора (statusline.sh). С меткой «сейчас» следующие 300 с guard верил
    # бы собственной устаревшей цифре и опаздывал с зонами 2/3 до 5 минут
    # (в десктопном приложении сенсора нет вовсе, там это был каждый вызов).
    out_pct="$fresh_pct"; out_window="$fresh_window"; out_tokens="$fresh_used"; out_updated=0
  else
    out_pct="$s_pct"; out_window="$s_window"; out_tokens="$s_tokens"; out_updated="${s_updated:-$(date +%s)}"
  fi
  [ "$out_updated" = "null" ] && out_updated=$(date +%s)

  mkdir -p "$state_dir" 2>/dev/null
  tmp="$state_dir/.tmp.$$.$RANDOM"
  if [ "$has_jq" = 1 ]; then
    jq -n --argjson pct "$out_pct" --argjson window "$out_window" --argjson input_tokens "$out_tokens" \
          --argjson updated "$out_updated" --argjson announced "$ann" \
      '{pct: $pct, window: $window, input_tokens: $input_tokens, updated: $updated, announced: $announced}' \
      > "$tmp" 2>/dev/null
  else
    python3 -c '
import json, sys
p, w, t, u, a = sys.argv[1:6]
print(json.dumps({"pct": int(p), "window": int(w), "input_tokens": int(t), "updated": int(u), "announced": int(a)}))
' "$out_pct" "$out_window" "$out_tokens" "$out_updated" "$ann" > "$tmp" 2>/dev/null
  fi
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$state_file"
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# budget_ok lo hi a b c: три значения из одних цифр (не длиннее 9 знаков) по
# строгому возрастанию в пределах [lo, hi]. Одна проверка для процентов и токенов.
budget_ok() {
  local lo="$1" hi="$2" a="$3" b="$4" c="$5"
  case "$a$b$c" in *[!0-9]*|'') return 1 ;; esac
  { [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ]; } || return 1
  { [ "${#a}" -le 9 ] && [ "${#b}" -le 9 ] && [ "${#c}" -le 9 ]; } || return 1
  [ "$a" -ge "$lo" ] 2>/dev/null && [ "$a" -lt "$b" ] 2>/dev/null \
    && [ "$b" -lt "$c" ] 2>/dev/null && [ "$c" -le "$hi" ] 2>/dev/null
}

# budget_parse file has_jq: печатает "tok<TAB>a<TAB>b<TAB>c" (пороги в токенах,
# ключ thresholds_tokens, 1000..999999999) или "pct<TAB>a<TAB>b<TAB>c" (проценты,
# ключ thresholds, 1..99), или ничего, если файл не даёт валидной тройки.
# При обоих ключах верх берут токены. Ветки jq и python3 обязаны совпадать:
# дробные, экспоненты (4e5), строки с пробелом или знаком отвергаются одинаково
# (число и строка из одних цифр трактуются как одно и то же). Копия функции
# живёт в statusline.sh: бар обязан краснеть там же, где guard шлёт директивы.
budget_parse() {
  local f="$1" has_jq="$2" raw="" tok="" pct="" a="" b="" c=""
  if [ "$has_jq" = 1 ]; then
    raw=$(jq -r 'def p(k): if (.[k]|type) == "array" and (.[k]|length) == 3 then (.[k]|map(tostring)|join("\t")) else "" end; p("thresholds_tokens") + "\u001f" + p("thresholds")' "$f" 2>/dev/null)
  else
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

# acw_read has_jq: порог автосжатия харнесса. Сперва env
# CLAUDE_CODE_AUTO_COMPACT_WINDOW (харнесс читает его первым), иначе
# autoCompactWindow из settings.json (путь: CLAUDE_SETTINGS_PATH или
# ~/.claude/settings.json). Только цифры, не короче 100000 (минимум харнесса)
# и не длиннее 9 знаков; иначе пусто, и хвоста «до автосжатия» не будет.
acw_read() {
  local has_jq="$1" v="${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" sp
  if [ -z "$v" ]; then
    sp="${CLAUDE_SETTINGS_PATH:-$PF_EFFECTIVE_HOME/.claude/settings.json}"
    if [ -r "$sp" ]; then
      if [ "$has_jq" = 1 ]; then
        v=$(jq -r '.autoCompactWindow // "" | tostring' "$sp" 2>/dev/null)
      else
        v=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    v = d.get("autoCompactWindow") if isinstance(d, dict) else None
    print("" if v is None else str(v))
except Exception:
    print("")
' "$sp" 2>/dev/null)
      fi
    fi
  fi
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#v}" -le 9 ] || return 0
  [ "$v" -ge 100000 ] 2>/dev/null || return 0
  printf '%s\n' "$(( 10#$v ))"
}

# usage_pick has_jq: читает одну строку транскрипта со stdin и печатает
# "input<TAB>cache_creation<TAB>cache_read" из ПОСЛЕДНЕЙ итерации типа
# message / fallback_message в usage.iterations, пропуская advisor_message и
# compaction (это чужие запросы: радник и сжатие). Итерации нет или она
# невалидна (не объект, не тот тип, поле не число, нулевая): печатает
# верхнеуровневые числа; строка не разбирается: ничего. Обе ветки (jq и
# python3) обязаны давать одинаковый результат на одном входе.
usage_pick() {
  local has_jq="$1"
  if [ "$has_jq" = 1 ]; then
    jq -r '
      def n: type == "number" and . >= 0;
      def sum3: (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0);
      .message.usage as $u
      | if ($u|type) != "object" then empty else
          ([ ($u.iterations // [])[]?
             | select((if type == "object" then .type else null end) as $t
                      | $t != "advisor_message" and $t != "compaction") ] | last) as $r
          | if ($u.iterations|type) == "array" and ($r|type) == "object"
               and ($r.type == "message" or $r.type == "fallback_message")
               and ($r.input_tokens|n) and ($r.output_tokens|n)
               and ($r.cache_creation_input_tokens|n) and ($r.cache_read_input_tokens|n)
               and ($r|sum3) > 0 and ($u|sum3) > 0
            then [$r.input_tokens, $r.cache_creation_input_tokens, $r.cache_read_input_tokens]
            else [($u.input_tokens // 0), ($u.cache_creation_input_tokens // 0), ($u.cache_read_input_tokens // 0)]
            end
          | map(tostring) | join("\t")
        end' 2>/dev/null
  else
    python3 -c '
import json, sys
K = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0
def sum3(d):
    return sum((d.get(k) or 0) for k in K)
try:
    u = json.loads(sys.stdin.readline())["message"]["usage"]
    if not isinstance(u, dict):
        raise SystemExit(0)
    it = u.get("iterations")
    r = None
    if isinstance(it, list):
        for x in reversed(it):
            if isinstance(x, dict) and x.get("type") in ("advisor_message", "compaction"):
                continue
            r = x
            break
    if (isinstance(it, list) and isinstance(r, dict)
            and r.get("type") in ("message", "fallback_message")
            and all(num(r.get(k)) for k in K + ("output_tokens",))
            and sum3(r) > 0 and sum3(u) > 0):
        vals = [r[k] for k in K]
    else:
        vals = [(u.get(k) or 0) for k in K]
    print("\t".join(str(v) for v in vals))
except Exception:
    pass
' 2>/dev/null
  fi
}

( run ) 2>/dev/null
exit 0
