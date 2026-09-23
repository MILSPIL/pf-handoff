#!/bin/bash
# statusLine-обёртка Claude Code.
# Контракт: НИКОГДА не падать (set -u, но без set -e; вся логика — в подоболочке,
# чтобы даже фатальная ошибка "unbound variable" не уронила финальный exit 0).
# 1) прочитать stdin один раз; 2) прогнать его через орковский statusline (для
#    его собственной телеметрии, вывод подавляем); 3) распарсить context_window
#    и напечатать свою строку; 4) атомарно сохранить состояние сессии для
#    context-guard.sh.
set -u
# Контракт «всегда exit 0»: без HOME не падаем (QA №3), числа — с точкой (не запятой).
# $HOME САМ не переопределяем (F-20): чужой код ниже по стеку (дочерние
# команды, будущие правки) не должен принять временный каталог за настоящий
# домашний. Весь внутренний state живёт под PF_EFFECTIVE_HOME — либо
# настоящий $HOME, либо, при его отсутствии, TMPDIR/tmp.
PF_EFFECTIVE_HOME="${HOME:-${TMPDIR:-/tmp}}"
export LC_ALL=C

# Путь переопределяем только для тестов (фикстура "орковский скрипт отсутствует"
# без переименования реального файла Orca — чужие файлы ~/.orca/agent-hooks/*
# не трогаем). По умолчанию — стандартный путь Orca; нет Orca — условие ниже
# просто пропустит вызов, наша часть работает без изменений.
ORCA_STATUSLINE="${CONTEXT_HOOKS_ORCA_STATUSLINE:-$PF_EFFECTIVE_HOME/.orca/agent-hooks/claude-statusline.sh}"

# "4hr 56m" / "4d 12hr 6m" / "0m" из epoch-времени сброса; мусор -> "—".
fmt_reset() {
  local ep="${1%%.*}" now delta d h m
  case "$ep" in ''|*[!0-9]*) printf '%s' '—'; return 0 ;; esac
  now=$(date +%s)
  delta=$(( ep - now )); [ "$delta" -lt 0 ] && delta=0
  d=$(( delta / 86400 )); h=$(( (delta % 86400) / 3600 )); m=$(( (delta % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd %dhr %dm' "$d" "$h" "$m"
  elif [ "$h" -gt 0 ]; then printf '%dhr %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
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
# живёт в context-guard.sh: бар обязан краснеть там же, где guard шлёт директивы.
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

run() {
  local input
  input=$(cat)
  [ -z "$input" ] && return 0

  # Орковский statusline вызываем тем же защитным условием, что и в settings.json
  # (существует/читаем/исполняем — иначе пропустить). Его stdout/stderr подавляем:
  # он используется только ради побочного эффекта (телеметрия rate_limits в Orca),
  # печатать свою строку статуса — наша задача.
  if [ -f "$ORCA_STATUSLINE" ] && [ -r "$ORCA_STATUSLINE" ] && [ -x "$ORCA_STATUSLINE" ]; then
    printf '%s' "$input" | /bin/sh "$ORCA_STATUSLINE" >/dev/null 2>&1
  fi

  local has_jq=0
  command -v jq >/dev/null 2>&1 && has_jq=1

  local row session_id pct_raw window_raw tokens_raw model_name effort_lvl
  local lines_add lines_del cost_usd dur_ms five_pct five_reset seven_pct seven_reset cwd_in
  if [ "$has_jq" = 1 ]; then
    row=$(printf '%s' "$input" | jq -r '
      [
        (.session_id // ""),
        (if (.context_window|type) == "object" then (.context_window.used_percentage // "null") else "null" end),
        (if (.context_window|type) == "object" then (.context_window.context_window_size // "null") else "null" end),
        (if (.context_window|type) == "object" then (.context_window.total_input_tokens // "null") else "null" end),
        (if (.model|type) == "object" then (.model.display_name // "") else "" end),
        (if (.effort|type) == "object" then (.effort.level // "") else "" end),
        (if (.cost|type) == "object" then (.cost.total_lines_added // 0) else 0 end),
        (if (.cost|type) == "object" then (.cost.total_lines_removed // 0) else 0 end),
        (if (.cost|type) == "object" then (.cost.total_cost_usd // "null") else "null" end),
        (if (.cost|type) == "object" then (.cost.total_duration_ms // "null") else "null" end),
        (if (.rate_limits|type) == "object" and (.rate_limits.five_hour|type) == "object" then (.rate_limits.five_hour.used_percentage // "null") else "null" end),
        (if (.rate_limits|type) == "object" and (.rate_limits.five_hour|type) == "object" then (.rate_limits.five_hour.resets_at // "null") else "null" end),
        (if (.rate_limits|type) == "object" and (.rate_limits.seven_day|type) == "object" then (.rate_limits.seven_day.used_percentage // "null") else "null" end),
        (if (.rate_limits|type) == "object" and (.rate_limits.seven_day|type) == "object" then (.rate_limits.seven_day.resets_at // "null") else "null" end),
        (if (.workspace|type) == "object" and ((.workspace.current_dir // "") != "") then .workspace.current_dir else (.cwd // "") end)
      ] | map(tostring) | map(gsub("[\u0000-\u001F\u007F]"; " ")) | join("\u001f")
    ' 2>/dev/null)
  else
    row=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cw = d.get("context_window") if isinstance(d.get("context_window"), dict) else {}
cost = d.get("cost") if isinstance(d.get("cost"), dict) else {}
rl = d.get("rate_limits") if isinstance(d.get("rate_limits"), dict) else {}
fh = rl.get("five_hour") if isinstance(rl.get("five_hour"), dict) else {}
sd = rl.get("seven_day") if isinstance(rl.get("seven_day"), dict) else {}
ws = d.get("workspace") if isinstance(d.get("workspace"), dict) else {}
def g(src, key, default="null"):
    v = src.get(key)
    return default if v is None else v
row = [str(d.get("session_id") or ""),
       str(g(cw, "used_percentage")), str(g(cw, "context_window_size")), str(g(cw, "total_input_tokens")),
       str(d.get("model", {}).get("display_name") or "") if isinstance(d.get("model"), dict) else "",
       str(d.get("effort", {}).get("level") or "") if isinstance(d.get("effort"), dict) else "",
       str(g(cost, "total_lines_added", "0")), str(g(cost, "total_lines_removed", "0")),
       str(g(cost, "total_cost_usd")), str(g(cost, "total_duration_ms")),
       str(g(fh, "used_percentage")), str(g(fh, "resets_at")),
       str(g(sd, "used_percentage")), str(g(sd, "resets_at")),
       str(ws.get("current_dir") or d.get("cwd") or "")]
import re
row = [re.sub(r"[\x00-\x1f\x7f]", " ", x) for x in row]
print("\x1f".join(row))' 2>/dev/null)
  fi

  IFS=$'\x1f' read -r session_id pct_raw window_raw tokens_raw model_name effort_lvl lines_add lines_del cost_usd dur_ms five_pct five_reset seven_pct seven_reset cwd_in <<< "$row"
  # effort.level — только известные значения (поле опционально: старые CLI/модели без effort его не шлют).
  case "${effort_lvl:-}" in low|medium|high|xhigh|max) : ;; *) effort_lvl="" ;; esac

  # Числовая гигиена (QA №1/№4): нечисловые used_percentage/window → «нет контекста»,
  # нечисловые tokens → 0. Иначе строка вроде "true" доходит до bash-арифметики
  # и под set -u убивает подоболочку до printf (пустой вывод и потеря state).
  case "${pct_raw:-null}" in ''|*[!0-9.]*) pct_raw="null" ;; esac
  case "${window_raw:-null}" in ''|*[!0-9.]*) window_raw="null" ;; esac
  window_raw="${window_raw%%.*}"; [ -z "$window_raw" ] && window_raw="null"
  case "${tokens_raw:-0}" in ''|*[!0-9.]*) tokens_raw=0 ;; esac

  # ---------- РЕНДЕР: конфигурируемый, стиль ccstatusline;
  # сам ccstatusline не ставим — §12 supply-chain, у нас ноль зависимостей.
  # Конфиг (опционален): ~/.config/pf-handoff/statusline.json — раскладка строк,
  # бар, разделитель, цвета. Нет файла или он кривой — дефолты (вид без конфига
  # идентичен v1.5.0). Env-переопределение пути — для тестов.
  local cfg_file="${PF_STATUSLINE_CONFIG:-$PF_EFFECTIVE_HOME/.config/pf-handoff/statusline.json}"
  local cfg_l1="model,effort,context,branch" cfg_l2="session,weekly"
  local cfg_bw=20 cfg_bf="█" cfg_be="░" cfg_sep=" | " cfg_colors=1
  if [ -f "$cfg_file" ] && [ -r "$cfg_file" ]; then
    local crow=""
    if [ "$has_jq" = 1 ]; then
      crow=$(sed '1s/^\xef\xbb\xbf//' "$cfg_file" 2>/dev/null | jq -r '
        def names: if type=="array" then (map(tostring|gsub(",";" "))|join(",")) else "__absent__" end;
        [ (.line1|names), (.line2|names),
          (.bar_width // 20|tostring), (.bar_filled // "█"), (.bar_empty // "░"),
          (if has("separator") then (.separator|tostring) else "__absent__" end),
          (if .colors == false then "0" else "1" end)
        ] | map(gsub("[\u0000-\u001F\u007F]"; " ")) | join("\u001f")' 2>/dev/null)
    else
      crow=$(python3 -c '
import json, sys, re
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    d = {}
def names(v):
    return ",".join(str(x).replace(",", " ") for x in v) if isinstance(v, list) else "__absent__"
row = [names(d.get("line1")), names(d.get("line2")),
       str(d.get("bar_width") or 20), str(d.get("bar_filled") or "█"), str(d.get("bar_empty") or "░"),
       (str(d.get("separator")) if "separator" in d and d.get("separator") is not None else "__absent__"),
       "0" if d.get("colors") is False else "1"]
print("\x1f".join(re.sub(r"[\x00-\x1f\x7f]", " ", x) for x in row))' "$cfg_file" 2>/dev/null)
    fi
    if [ -n "$crow" ]; then
      local c1 c2 cb cf ce cs cc
      IFS=$'\x1f' read -r c1 c2 cb cf ce cs cc <<< "$crow"
      # «__absent__» = ключа нет (оставляем дефолт); пустая строка = ключ задан
      # ПУСТЫМ списком — уважаем: строка отключена намеренно.
      [ "$c1" != "__absent__" ] && cfg_l1="$c1"
      [ "$c2" != "__absent__" ] && cfg_l2="$c2"
      case "$cb" in *[!0-9]*|''|0*) : ;; *) [ "$cb" -ge 5 ] && [ "$cb" -le 60 ] && cfg_bw="$cb" ;; esac
      [ -n "$cf" ] && cfg_bf="$cf"
      [ -n "$ce" ] && cfg_be="$ce"
      [ "$cs" != "__absent__" ] && cfg_sep="$cs"
      [ "$cc" = "0" ] && cfg_colors=0
    fi
  fi

  local C_RST=$'\033[0m' C_DIM=$'\033[2m' C_LBL=$'\033[1;36m' C_VAL=$'\033[36m'
  local C_GRN=$'\033[32m' C_YLW=$'\033[33m' C_RED=$'\033[31m' C_BLU=$'\033[1;34m'
  if [ "$cfg_colors" = 0 ]; then
    C_RST=""; C_DIM=""; C_LBL=""; C_VAL=""; C_GRN=""; C_YLW=""; C_RED=""; C_BLU=""
  fi
  local SEP="${C_DIM}${cfg_sep}${C_RST}"

  # Числа контекста (валидность pct/window уже проверена выше; null → сегмент пуст)
  local ctx_ok=1 pct_int=0 tokens_int=0 tokens_k=0 win_label="" filled=0 bar="" zone=""
  if [ "${pct_raw:-null}" = "null" ] || [ "${window_raw:-null}" = "null" ]; then
    ctx_ok=0
  else
    pct_int=$(printf '%s' "$pct_raw" | cut -d. -f1); [ -z "$pct_int" ] && pct_int=0
    pct_int=$(( 10#$pct_int ))
    tokens_int=$(printf '%s' "${tokens_raw:-0}" | cut -d. -f1); [ -z "$tokens_int" ] && tokens_int=0
    tokens_int=$(( 10#$tokens_int ))
    tokens_k=$(( tokens_int / 1000 ))
    case "$window_raw" in
      1000000) win_label="1.0M" ;;
      200000)  win_label="200k" ;;
      *) win_label=$(awk -v w="$window_raw" 'BEGIN{ if (w>=1000000) printf "%.1fM", w/1000000; else printf "%dk", int(w/1000) }') ;;
    esac
    # Границы цветовых зон: те же источники и тот же разбор (budget_parse), что
    # у context-guard.sh: сперва проектный .agents/context-budget.json в cwd,
    # потом глобальный ~/.config/pf-handoff/context-budget.json (путь для
    # тестов: PF_CONTEXT_BUDGET_CONFIG); бар обязан краснеть там же, где guard
    # шлёт директивы. Нет конфига: 60/80. Пороги в токенах (thresholds_tokens)
    # сравниваются с токенами напрямую, а не с округлённым процентом, иначе на
    # границе зона бара и зона guard расходились бы на 1%. Заливка бара при
    # этом остаётся процентной.
    local z1=60 z2=80 zrow=""
    local zmode=pct zmetric="$pct_int" zfile
    for zfile in "${cwd_in:+$cwd_in/.agents/context-budget.json}" \
                 "${PF_CONTEXT_BUDGET_CONFIG:-$PF_EFFECTIVE_HOME/.config/pf-handoff/context-budget.json}"; do
      { [ -n "$zfile" ] && [ -f "$zfile" ] && [ -r "$zfile" ]; } || continue
      zrow=$(budget_parse "$zfile" "$has_jq")
      [ -n "$zrow" ] && break
    done
    if [ -n "$zrow" ]; then
      IFS=$'\t' read -r zmode z1 z2 _ <<< "$zrow"
      [ "$zmode" = tok ] && zmetric="$tokens_int"
    fi
    filled=$(( pct_int * cfg_bw / 100 )); [ "$filled" -gt "$cfg_bw" ] && filled="$cfg_bw"; [ "$filled" -lt 0 ] && filled=0
    bar=$(PF_BF="$cfg_bf" PF_BE="$cfg_be" awk -v f="$filled" -v w="$cfg_bw" 'BEGIN{bf=ENVIRON["PF_BF"]; be=ENVIRON["PF_BE"]; for(i=1;i<=w;i++) printf "%s", (i<=f ? bf : be)}')
    if [ "$zmetric" -ge "$z2" ]; then zone="$C_RED"
    elif [ "$zmetric" -ge "$z1" ]; then zone="$C_YLW"
    else zone="$C_GRN"; fi
  fi

  # Ветка git и счётчик строк сессии
  local branch=""
  if [ -n "${cwd_in:-}" ] && [ -d "${cwd_in:-/nonexistent}" ]; then
    branch=$(git -C "$cwd_in" symbolic-ref --short HEAD 2>/dev/null | tr -d '\000-\037\177')
  fi
  case "${lines_add:-}" in ''|null|*[!0-9]*) lines_add=0 ;; esac
  case "${lines_del:-}" in ''|null|*[!0-9]*) lines_del=0 ;; esac

  # Виджеты. Каждый печатает свой текст или ничего (данных нет — сегмент исчезает).
  seg_model()   { [ -n "${model_name:-}" ] && printf '%s' "${C_LBL}Model:${C_RST} ${C_VAL}${model_name}${C_RST}"; }
  seg_effort()  { [ -n "${effort_lvl:-}" ] && printf '%s' "${C_LBL}Effort:${C_RST} ${C_VAL}${effort_lvl}${C_RST}"; }
  seg_context() { [ "$ctx_ok" = 1 ] && printf '%s' "${C_LBL}Context:${C_RST} ${zone}[${bar}]${C_RST} ${tokens_k}k/${win_label} (${zone}${pct_int}%${C_RST})"; }
  seg_branch()  { [ -n "$branch" ] && printf '%s' "${C_YLW}⎇ ${branch}${C_RST}(${C_GRN}+${lines_add}${C_RST},${C_RED}-${lines_del}${C_RST})"; }
  seg_session() {
    [ "${five_pct:-null}" = "null" ] && return 0
    local s; s=$(awk -v v="$five_pct" 'BEGIN{printf "%.1f", v+0}')
    printf '%s' "${C_BLU}Session:${C_RST} ${s}%"
    [ "${five_reset:-null}" != "null" ] && printf '%s' "${SEP}${C_BLU}Reset:${C_RST} $(fmt_reset "$five_reset")"
  }
  seg_weekly() {
    [ "${seven_pct:-null}" = "null" ] && return 0
    local s; s=$(awk -v v="$seven_pct" 'BEGIN{printf "%.1f", v+0}')
    printf '%s' "${C_BLU}Weekly:${C_RST} ${s}%"
    [ "${seven_reset:-null}" != "null" ] && printf '%s' "${SEP}${C_BLU}Weekly Reset:${C_RST} $(fmt_reset "$seven_reset")"
  }
  seg_cost() {
    case "${cost_usd:-null}" in null|''|*[!0-9.]*) return 0 ;; esac
    printf '%s' "${C_BLU}Cost:${C_RST} \$$(awk -v v="$cost_usd" 'BEGIN{printf "%.2f", v+0}')"
  }
  seg_duration() {
    case "${dur_ms:-null}" in null|''|*[!0-9.]*) return 0 ;; esac
    local d_int="${dur_ms%%.*}"; [ -z "$d_int" ] && return 0
    [ "${#d_int}" -gt 12 ] && return 0
    local secs; secs=$(( 10#$d_int / 1000 ))
    local h=$(( secs / 3600 )) m=$(( (secs % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then printf '%s' "${C_BLU}Time:${C_RST} ${h}hr ${m}m"; else printf '%s' "${C_BLU}Time:${C_RST} ${m}m"; fi
  }

  # Сборка строки из списка имён виджетов (белый список; неизвестные — молча мимо).
  build_line() {
    local names="$1" out="" seg="" n
    local IFS=','
    set -f
    for n in $names; do
      case "$n" in
        model) seg=$(seg_model) ;;
        effort) seg=$(seg_effort) ;;
        context) seg=$(seg_context) ;;
        branch) seg=$(seg_branch) ;;
        session) seg=$(seg_session) ;;
        weekly) seg=$(seg_weekly) ;;
        cost) seg=$(seg_cost) ;;
        duration) seg=$(seg_duration) ;;
        *) seg="" ;;
      esac
      if [ -n "$seg" ]; then
        if [ -n "$out" ]; then out="${out}${SEP}${seg}"; else out="$seg"; fi
      fi
    done
    set +f
    printf '%s' "$out"
  }

  local line1 line2
  line1=$(build_line "$cfg_l1")
  line2=$(build_line "$cfg_l2")
  [ -n "$line1" ] && printf '%s\n' "$line1"
  [ -n "$line2" ] && printf '%s\n' "$line2"
  [ "$ctx_ok" = 0 ] && return 0

  [ -z "$session_id" ] && return 0
  # session_id — только безопасные символы: он становится именем файла.
  case "$session_id" in
    *[!A-Za-z0-9._-]*) return 0 ;;
  esac
  [ "${#session_id}" -gt 200 ] && return 0

  local state_dir tmp now
  state_dir="$PF_EFFECTIVE_HOME/.claude/context-state"
  mkdir -p "$state_dir" 2>/dev/null
  now=$(date +%s)
  tmp="$state_dir/.tmp.$$.$RANDOM"

  # Поле announced (последний объявленный порог) принадлежит context-guard.sh —
  # при перезаписи state его обязательно ПЕРЕНОСИМ, иначе каждое обновление
  # статус-строки сбрасывало бы «уже объявлено» и guard спамил бы директивы.
  # Файл есть, но нечитаем (права/гонка) — не перезаписываем: потеряли бы announced,
  # и guard объявил бы порог повторно (QA №7).
  if [ -f "$state_dir/$session_id.json" ] && [ ! -r "$state_dir/$session_id.json" ]; then
    return 0
  fi
  local prev_announced
  prev_announced=$(grep -oE '"announced":[[:space:]]*[0-9]+' "$state_dir/$session_id.json" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  [ -z "${prev_announced:-}" ] && prev_announced=0

  if [ "$has_jq" = 1 ]; then
    jq -n --argjson pct "$pct_int" --argjson window "$window_raw" \
          --argjson input_tokens "$tokens_int" --argjson updated "$now" \
          --argjson announced "$prev_announced" \
      '{pct: $pct, window: $window, input_tokens: $input_tokens, updated: $updated, announced: $announced}' \
      > "$tmp" 2>/dev/null
  else
    python3 -c '
import json, sys
pct, window, tok, upd, ann = sys.argv[1:6]
print(json.dumps({"pct": int(pct), "window": int(window), "input_tokens": int(tok), "updated": int(upd), "announced": int(ann)}))
' "$pct_int" "$window_raw" "$tokens_int" "$now" "$prev_announced" > "$tmp" 2>/dev/null
  fi

  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$state_dir/$session_id.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# Предпросмотр: bash statusline.sh --preview — рендер с примерными данными
# (реальная ветка из текущего каталога), без Orca-телеметрии и без записи state
# (пустой session_id). Меняешь конфиг → сразу видишь результат.
if [ "${1:-}" = "--preview" ]; then
  ORCA_STATUSLINE="/nonexistent-preview-skip"
  __pv_now=$(date +%s)
  __pv_dir=$(printf '%s' "$PWD" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"session_id":"","model":{"display_name":"Fable 5"},"effort":{"level":"medium"},"context_window":{"used_percentage":41,"context_window_size":1000000,"total_input_tokens":410000},"cost":{"total_lines_added":12,"total_lines_removed":3,"total_cost_usd":1.23,"total_duration_ms":4500000},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":%s},"seven_day":{"used_percentage":42.0,"resets_at":%s}},"workspace":{"current_dir":"%s"},"cwd":"%s"}' \
    "$(( __pv_now + 13620 ))" "$(( __pv_now + 282600 ))" "$__pv_dir" "$__pv_dir" | ( run ) 2>/dev/null
  exit 0
fi

( run ) 2>/dev/null
exit 0
