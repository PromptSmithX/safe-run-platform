$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot "verify-c-backend.ps1")

Push-Location (Join-Path $repoRoot "Backend/functions")
try {
    npm run typecheck
    npm test
} finally {
    Pop-Location
}
