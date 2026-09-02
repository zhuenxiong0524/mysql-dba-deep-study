#!/usr/bin/env bash
set -euo pipefail

legacy=0
level_override=
topic=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --legacy)
      legacy=1
      shift
      ;;
    --level)
      [[ $# -ge 2 ]] || { echo "ERROR: --level requires S, D, R or M" >&2; exit 2; }
      level_override=${2^^}
      shift 2
      ;;
    -* )
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
    *)
      [[ -z "$topic" ]] || { echo "ERROR: multiple topic directories" >&2; exit 2; }
      topic=$1
      shift
      ;;
  esac
done

if [[ -z "$topic" ]]; then
  echo "usage: $0 [--legacy] [--level S|D|R|M] <topic-directory>" >&2
  exit 2
fi

if [[ -n "$level_override" && ! "$level_override" =~ ^[SDRM]$ ]]; then
  echo "ERROR: invalid research level: $level_override (expected S, D, R or M)" >&2
  exit 2
fi
if [[ ! -d "$topic" ]]; then
  echo "ERROR: topic directory not found: $topic" >&2
  exit 2
fi

errors=0
warnings=0

mapfile -t idx_files < <(find "$topic" -maxdepth 1 -type f -name '*.idx.md' -print)
mapfile -t article_files < <(
  find "$topic" -maxdepth 1 -type f -name '*.md' ! -name '*.idx.md' -print
)

if [[ ${#idx_files[@]} -ne 1 ]]; then
  echo "ERROR: expected exactly one *.idx.md, found ${#idx_files[@]}"
  errors=$((errors + 1))
fi

level=D
if [[ ${#idx_files[@]} -eq 1 ]]; then
  declared_level=$(sed -nE 's/^- 研究级别[：:][[:space:]]*`?([SDRM])`?.*/\1/p' "${idx_files[0]}" | head -1)
  [[ -z "$declared_level" ]] || level=$declared_level
fi
[[ -z "$level_override" ]] || level=$level_override

if [[ ${#article_files[@]} -lt 1 ]]; then
  echo "ERROR: no topic article found at directory root"
  errors=$((errors + 1))
fi

if (( legacy == 0 )) && [[ "$level" == "S" && ${#article_files[@]} -gt 0 ]]; then
  all_articles=$(awk 'FNR==1 { print "\nFILE: " FILENAME } { print }' "${article_files[@]}")

  declare -A s_requirements=(
    ["完整调用链"]='^## .*完整调用链|^## 完整调用链'
    ["核心数据结构"]='^## .*核心数据结构|^## 核心数据结构'
    ["状态变化与关键分支"]='^## .*状态(变化|转换).*分支|^## .*关键分支'
    ["行为实验"]='^#{2,4} .*行为实验'
    ["路径实验"]='^#{2,4} .*路径实验'
    ["源码—实验—生产映射"]='^## .*源码.*实验.*生产.*映射'
  )

  for label in "${!s_requirements[@]}"; do
    if ! rg -q "${s_requirements[$label]}" <<<"$all_articles"; then
      echo "ERROR: S-level article missing recognizable section: $label"
      errors=$((errors + 1))
    fi
  done

  source_blocks=$(rg -c '^```(c|cc|cpp|c\+\+)([[:space:]].*)?$' <<<"$all_articles" || true)
  source_blocks=${source_blocks:-0}
  if (( source_blocks < 2 )); then
    echo "ERROR: S-level article needs at least two C/C++ source blocks, found $source_blocks"
    errors=$((errors + 1))
  fi

  if ! rg -q 'struct|class|enum|typedef' <<<"$all_articles"; then
    echo "ERROR: S-level article does not explain a recognizable core data structure"
    errors=$((errors + 1))
  fi

  if ! rg -q '未实测|未验证|验证边界|证据边界' <<<"$all_articles"; then
    echo "ERROR: S-level article must state untested scope or evidence boundary"
    errors=$((errors + 1))
  fi

  source_file="$topic/evidence/source-locations.txt"
  if [[ ! -f "$source_file" ]]; then
    echo "ERROR: S-level topic requires evidence/source-locations.txt"
    errors=$((errors + 1))
  else
    if ! rg -qi 'mysql|innodb|storage/' "$source_file"; then
      echo "ERROR: S-level source evidence lacks a recognizable MySQL source chain"
      errors=$((errors + 1))
    fi
    if ! rg -qi 'postgres|src/backend|src/include' "$source_file"; then
      echo "ERROR: S-level source evidence lacks a recognizable PostgreSQL source chain"
      errors=$((errors + 1))
    fi
  fi
fi

if (( legacy == 0 )) && [[ ${#article_files[@]} -gt 0 ]]; then
  mysql_section_found=0
  mysql_code_found=0
  mysql_prepare_found=0
  mysql_result_found=0
  mysql_cleanup_found=0

  for article in "${article_files[@]}"; do
    if rg -q '^## MySQL 实操：命令与 SQL$' "$article"; then
      mysql_section_found=1
      section=$(awk '
        /^## MySQL 实操：命令与 SQL$/ { active=1; next }
        active && /^## / { exit }
        active { print }
      ' "$article")

      if rg -q '^```(sql|bash|shell|console)([[:space:]].*)?$' <<<"$section"; then
        mysql_code_found=1
      fi
      if rg -q '连接|前置|准备' <<<"$section"; then
        mysql_prepare_found=1
      fi
      if rg -q '预期|结果|判断|错误码|SQLSTATE' <<<"$section"; then
        mysql_result_found=1
      fi
      if rg -q '清理|还原|回滚|无需清理' <<<"$section"; then
        mysql_cleanup_found=1
      fi
    fi
  done

  if (( mysql_section_found == 0 )); then
    echo "ERROR: missing required article section: ## MySQL 实操：命令与 SQL"
    errors=$((errors + 1))
  elif (( mysql_code_found == 0 )); then
    echo "ERROR: MySQL practice section has no executable sql/bash/shell/console block"
    errors=$((errors + 1))
  fi

  if (( mysql_section_found == 1 && mysql_prepare_found == 0 )); then
    echo "ERROR: MySQL practice section must state connection/prerequisites/setup"
    errors=$((errors + 1))
  fi
  if (( mysql_section_found == 1 && mysql_result_found == 0 )); then
    echo "ERROR: MySQL practice section must state expected result/judgement/error code"
    errors=$((errors + 1))
  fi
  if (( mysql_section_found == 1 && mysql_cleanup_found == 0 )); then
    echo "ERROR: MySQL practice section must state cleanup/restore/rollback or no cleanup"
    errors=$((errors + 1))
  fi
fi

if [[ ! -d "$topic/evidence" ]] || ! find "$topic/evidence" -type f -print -quit | grep -q .; then
  echo "ERROR: evidence directory is missing or empty"
  errors=$((errors + 1))
fi

if whitespace=$(rg -n '[[:blank:]]+$' "$topic" 2>/dev/null); then
  echo "ERROR: trailing whitespace found"
  echo "$whitespace"
  errors=$((errors + 1))
fi

while IFS= read -r -d '' file; do
  fences=$(awk '{ line=$0; while (match(line, /```/)) { count++; line=substr(line, RSTART+RLENGTH) } } END { print count+0 }' "$file")
  if (( fences % 2 != 0 )); then
    echo "ERROR: unmatched Markdown fence in $file"
    errors=$((errors + 1))
  fi
done < <(find "$topic" -type f -name '*.md' -print0)

for article in "${article_files[@]}"; do
  lines=$(wc -l < "$article")
  if [[ "$level" != "S" ]] && (( lines > 320 )); then
    echo "WARN: article is $lines lines (>320 review threshold): $article"
    warnings=$((warnings + 1))
  fi
done

if [[ "$level" != "S" && -f "$topic/evidence/source-locations.txt" ]]; then
  source_lines=$(wc -l < "$topic/evidence/source-locations.txt")
  if (( source_lines > 300 )); then
    echo "WARN: source evidence is $source_lines lines (>300 target)"
    warnings=$((warnings + 1))
  fi
fi

files=$(find "$topic" -type f | wc -l)
evidence_lines=$(find "$topic/evidence" -type f -exec wc -l {} + 2>/dev/null | awk 'END { print $1+0 }')

mode=depth-fast
(( legacy == 1 )) && mode=legacy
result=OK
(( errors == 0 )) || result=FAIL
echo "$result: topic=$topic mode=$mode level=$level files=$files evidence_lines=$evidence_lines warnings=$warnings errors=$errors"
(( errors == 0 ))
