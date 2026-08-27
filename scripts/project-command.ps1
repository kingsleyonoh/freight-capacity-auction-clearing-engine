[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('unit', 'integration', 'e2e', 'full', 'lint', 'format', 'build', 'replay-benchmark', 'solver-smoke')]
    [string]$Action,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
$dispatcher = Join-Path $PSScriptRoot 'project-command.mjs'
& node $dispatcher $Action @Arguments
exit $LASTEXITCODE
