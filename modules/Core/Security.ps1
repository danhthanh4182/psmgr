#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Security Helpers
.DESCRIPTION
    Small, dependency-free helpers shared by the CLI harness and the TUI: passphrase
    comparison with zero-freed unmanaged buffers.
#>

function Test-PSManagerPassphrase {
    <#
    .SYNOPSIS
        Compares two SecureStrings without leaving plaintext on the unmanaged heap.
    .PARAMETER First
        First secure string.
    .PARAMETER Second
        Second secure string (confirmation).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][Security.SecureString]$First,
        [Parameter(Mandatory = $true)][Security.SecureString]$Second
    )

    $ptr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
    $ptr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
    try {
        $s1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1)
        $s2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2)
        return ($s1 -ceq $s2)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2)
    }
}
