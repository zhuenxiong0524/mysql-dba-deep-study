#!/usr/bin/env bash
set -euo pipefail

legacy=0
if [[ $# -eq 2 && "$1" == "--legacy" ]]; then
  legacy=1
  shift
elif [[ $# -ne 1 ]]; then
  echo "usage: $0 [--legacy] <topic-directory>" >&2
  exit 2
fi

topic=$1
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

if [[ ${#article_files[@]} -lt 1 ]]; then
  echo "ERROR: no topic article found at directory root"
  errors=$((errors + 1))
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
  if (( lines > 320 )); then
    echo "WARN: article is $lines lines (>320 review threshold): $article"
    warnings=$((warnings + 1))
  fi
done

if [[ -f "$topic/evidence/source-locations.txt" ]]; then
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
echo "OK: topic=$topic mode=$mode files=$files evidence_lines=$evidence_lines warnings=$warnings errors=$errors"
(( errors == 0 ))
