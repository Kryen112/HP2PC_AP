# Terminal A, step 1: regenerate the apworld + generate a fresh AP seed.
# Output lands in <Archipelago>\output\hp2_test\AP_*.zip
# Run from anywhere; the script uses absolute paths.

$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP'
$ap   = 'C:\Users\kryen\Documents\Archipelago-play\Archipelago'

Write-Host "== gen_apworld =="
py -3.12 "$repo\scripts\gen_apworld.py"

Write-Host "`n== Generate seed =="
Push-Location $ap
try {
    py -3.12 Generate.py --player_files_path "$repo\tests" --outputpath "output\hp2_test"
} finally {
    Pop-Location
}

$latest = Get-ChildItem "$ap\output\hp2_test\AP_*.zip" | Sort-Object LastWriteTime | Select-Object -Last 1
Write-Host "`nLatest seed: $($latest.FullName)"
