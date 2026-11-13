@{
    # Severity of issues to report: Error, Warning, Information
    Severity = @('Error', 'Warning')

    # Include default best-practice rules
    IncludeDefaultRules = $true

    # Specific rule overrides tailored for PSManager (Interactive CLI & TUI Dashboard)
    ExcludeRules = @(
        # PSManager is an interactive CLI/TUI application that writes color-formatted dashboard output
        'PSAvoidUsingWriteHost',

        # Starship prompt and fnm Node hooks require Invoke-Expression by design
        'PSAvoidUsingInvokeExpression',

        # P/Invoke and low-level console encoding setup requires native interop
        'PSUseBypassLocalVariable',

        # Internal helper functions in modules are scoped to execution harness
        'PSUseDeclaredVarsMoreThanAssignments',

        # Plural nouns are intentionally used for collection endpoints (Get-PSManagerLogs, Get-PSManagerBackups)
        'PSUseSingularNouns',

        # CLI commands and TUI actions handle confirmation through interactive prompts
        'PSUseShouldProcessForStateChangingFunctions',

        # Safe error suppression on non-fatal console operations (e.g. ReadKey, Clear-Host)
        'PSAvoidUsingEmptyCatchBlock',

        # Reserved parameters for CLI extensibility
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSAvoidUsingCmdletAliases = @{
            Enable = $true
        }
        PSUseApprovedVerbs = @{
            Enable = $true
        }
    }
}
