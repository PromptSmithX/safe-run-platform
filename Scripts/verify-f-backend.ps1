$ErrorActionPreference = "Stop"

$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -ne 22) { throw "Milestone F requires Node.js 22; found $(node --version)." }
if (-not (Get-Command java -ErrorAction SilentlyContinue)) { throw "Java is required for Firebase Emulator tests." }

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $repoRoot "Backend/functions")
try {
    npm ci --ignore-scripts
    npm run typecheck
    npm test
    npx firebase emulators:exec --config (Join-Path $repoRoot "firebase.json") --project demo-safe-run --only auth,firestore,functions "npm run test:emulator"
} finally { Pop-Location }
