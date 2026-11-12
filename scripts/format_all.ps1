[CmdletBinding()]
param(
    [switch]$Check,
    [string]$Since,
    [ValidateSet('all', 'dart', 'rust', 'javascript')]
    [string]$Language = 'all',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$FormatArguments = @('--language', $Language.ToLowerInvariant())
if ($Check) { $FormatArguments += '--check' }
if ($Since) { $FormatArguments += @('--since', $Since) }
if ($Help) { $FormatArguments += '--help' }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js 22+ is required. See scripts/README.md.'
}

# Native stderr is diagnostic output; the process exit code is the result.
$PreviousPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & node (Join-Path $PSScriptRoot 'format_all.cjs') @FormatArguments
    $FormatExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $PreviousPreference
}
exit $FormatExitCode
