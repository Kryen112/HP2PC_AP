# Terminal A, step 2: host the most recent HP2 seed on port 38282.
# Port 38282 (not the AP default 38281) so the game-side TCP listener
# in the sidecar - which binds 127.0.0.1:38281 - doesn't clash.

$ErrorActionPreference = 'Stop'
$ap = 'C:\Users\kryen\Documents\Archipelago-play\Archipelago'

$latest = Get-ChildItem "$ap\output\hp2_test\AP_*.zip" | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $latest) {
    throw "No seed found under $ap\output\hp2_test - run gen_seed.ps1 first."
}

Write-Host "Hosting: $($latest.Name) on port 38282"
Push-Location $ap
try {
    py -3.12 MultiServer.py $latest.FullName --port 38282
} finally {
    Pop-Location
}
