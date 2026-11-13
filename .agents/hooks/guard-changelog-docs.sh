#!/usr/bin/env bash
# ==============================================================================
# PSManager Agent Guardrail: Changelog & Documentation Sync
# Intercepts agent Bash tool calls before 'git commit' and 'git push' to ensure
# CHANGELOG.md and documentation are kept in sync with code changes.
# ==============================================================================

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
fi
if [ -z "$COMMAND" ]; then
    COMMAND=$(echo "$INPUT" | grep -o '"command": *"[^"]*"' | head -n 1 | cut -d'"' -f4)
fi
if [ -z "$COMMAND" ]; then
    COMMAND="$INPUT"
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# ==============================================================================
# 1. Gate 'git commit': enforce CHANGELOG.md update on feat/fix touching code
# ==============================================================================
if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])(rtk )?git[[:space:]]+commit'; then
    # Detect if commit message is feat or fix (supports -m, -am, --message, etc.)
    if echo "$COMMAND" | grep -qE '(-[a-zA-Z]*m|--message)[[:space:]=]*["'"'"']?(feat|fix)(\([a-zA-Z0-9._-]+\))?!?:'; then
        STAGED_FILES=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null)
        HAS_CODE=$(echo "$STAGED_FILES" | grep -E '\.(ps1|psm1|psd1|json)$')
        if [ -n "$HAS_CODE" ]; then
            if ! echo "$STAGED_FILES" | grep -q "CHANGELOG.md"; then
                echo "❌ BLOCKED BY AGENT GUARDRAIL:" >&2
                echo "  Command: $COMMAND" >&2
                echo "  Reason:  Your commit modifies code (feat/fix) without updating 'CHANGELOG.md'." >&2
                echo "" >&2
                echo "  Mandate in AGENTS.md:" >&2
                echo "    - You MUST update CHANGELOG.md under [Unreleased] and stage it ('git add CHANGELOG.md') before committing." >&2
                echo "    - Synchronize relevant docs (README.md, docs/) in the same commit." >&2
                echo "" >&2
                echo "  Staged code files:" >&2
                echo "$HAS_CODE" | sed 's/^/      * /' >&2
                exit 2
            fi
        fi
    fi
fi

# ==============================================================================
# 2. Gate 'git push': enforce CHANGELOG.md exists and is tracked in git
# ==============================================================================
if echo "$COMMAND" | grep -qE '(^|[;&|[:space:]])(rtk )?git[[:space:]]+push'; then
    if [ ! -f "$PROJECT_DIR/CHANGELOG.md" ] || ! git -C "$PROJECT_DIR" ls-files --error-unmatch CHANGELOG.md >/dev/null 2>&1; then
        echo "❌ BLOCKED BY AGENT GUARDRAIL:" >&2
        echo "  Command: $COMMAND" >&2
        echo "  Reason:  'CHANGELOG.md' is missing or untracked in git. Cannot push without synchronized changelog." >&2
        exit 2
    fi
fi

exit 0
