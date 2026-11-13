@echo off
setlocal
cd /d "%~dp0"
where git >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [WARN] Git not found in PATH.
    exit /b 0
)
git config core.hooksPath .agents/hooks
if %ERRORLEVEL% EQU 0 (
    echo [OK] Universal Git Hooks configured successfully (.agents/hooks)
) else (
    echo [FAIL] Failed to configure core.hooksPath.
    exit /b 1
)
