#!/bin/bash
# Task 14, шаг 4: проверка приватности tracked-источников.
# Дополнительная страховка, не доказательство безопасности.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
# 1. Не должно быть .reference/, auth.json, логов среди tracked files.
for pattern in ".reference/" "auth.json" "*.log" ".env"; do
  if [[ -n "$(git ls-files -- "$pattern")" ]]; then
    echo "FAIL: tracked files match '$pattern'" >&2
    fail=1
  fi
done

# 2. Тестовые секреты не должны встречаться вне тестовых файлов.
if git grep -q "kimi-at-123\|kimi-rt-secret" -- ':!*/Tests/*' ':!Tests/*' ':!scripts/check-privacy.sh' 2>/dev/null; then
  echo "FAIL: test secrets outside tests" >&2
  fail=1
fi

# 3. Privacy/Endpoint тесты должны проходить.
swift test --filter PrivacyTests >/dev/null
swift test --filter HTTPPolicyTests >/dev/null
swift test --filter CodexRPCTests >/dev/null

[[ $fail -eq 0 ]] && echo "OK: privacy checks passed"
exit $fail
