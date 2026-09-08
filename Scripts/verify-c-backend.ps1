$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$functionsRoot = Join-Path $repoRoot "Backend/functions"

foreach ($command in @("node", "npm", "java")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required; this script does not install dependencies."
    }
}

$nodeMajor = [int]((node --version).TrimStart("v").Split(".")[0])
if ($nodeMajor -ne 22) {
    throw "Node.js 22 is required to match the Cloud Functions runtime. Found Node.js $nodeMajor."
}

Push-Location $functionsRoot
try {
    npm ci
    npm run typecheck
    npm test
    npx firebase emulators:exec --config (Join-Path $repoRoot "firebase.json") --project demo-safe-run --only auth,firestore,functions "npm run test:emulator"
} finally {
    Pop-Location
}
