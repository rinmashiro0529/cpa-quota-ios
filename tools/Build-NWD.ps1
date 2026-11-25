param(
    [Parameter(Mandatory = $true)]
    [string]$Output
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $PSScriptRoot 'ios_build/nwd.py'
& python -I $tool prepare --source $projectRoot --output $Output
if ($LASTEXITCODE -ne 0) { throw "Source preparation failed (exit $LASTEXITCODE)." }
Write-Host 'Prepared sources only; no remote connection, compilation, packaging or signing was performed.'
