#!/usr/bin/env bash
# ==============================================================================
# PSManager Dangerous Git Interceptor for AI Agents
# Blocks destructive git commands before execution.
# ==============================================================================

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command": *"[^"]*"' | head -n 1 | cut -d'"' -f4)

if [ -z "$COMMAND" ]; then
    COMMAND="$INPUT"
fi

DANGEROUS_PATTERNS=(
  "git push.*--force"
  "git push.*-f"
  "git reset --hard"
  "git clean -fd"
  "git clean -f"
  "git branch -D"
  "git checkout \."
  "git restore \."
  "rm -rf \."
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    echo "BLOCKED: '$COMMAND' matches dangerous pattern '$pattern'. This operation is blocked by repository safety guardrails." >&2
    exit 2
  fi
done

exit 0
