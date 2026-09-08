$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -ne 22) { Write-Warning "Source checks are running on Node $(node --version); deployment runtime Node 22 is not verified." }

Push-Location (Join-Path $repoRoot "Backend/functions")
try {
    npm run typecheck
    npm test
    node -e "const fs=require('fs'),path=require('path'),yaml=require('yaml'); JSON.parse(fs.readFileSync('../../firestore.indexes.json','utf8')); for(const file of fs.readdirSync('../../safe_run_mvp_docs/schemas')) if(file.endsWith('.json')) JSON.parse(fs.readFileSync(path.join('../../safe_run_mvp_docs/schemas',file),'utf8')); yaml.parse(fs.readFileSync('../../safe_run_mvp_docs/openapi.yaml','utf8')); yaml.parse(fs.readFileSync('../../project.yml','utf8')); console.log('contracts/config parse passed')"
} finally { Pop-Location }

$forbidden = rg -n "console\.(log|info|error|warn)|print\(|NSLog|debugPrint" (Join-Path $repoRoot "Apps") (Join-Path $repoRoot "Backend/functions/src") -g "*.swift" -g "*.ts" | Where-Object { $_ -notmatch "privacy\.ts" -and $_ -notmatch "tests" }
if ($forbidden) { throw "Direct production logging bypasses the privacy allowlist:`n$forbidden" }

Push-Location $repoRoot
try { git diff --check } finally { Pop-Location }
