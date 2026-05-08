# Mirror the mod source into Program Files, then run UCC.exe make.
# REQUIRES AN ELEVATED PowerShell (admin) - writing to Program Files needs it.

$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP'
$dst  = 'C:\Program Files (x86)\Harry Potter 2\Modded\HPArchipelago'
$sys  = 'C:\Program Files (x86)\Harry Potter 2\Modded\system'

Write-Host "== robocopy mod -> Program Files =="
robocopy "$repo\mod\HPArchipelago" $dst /MIR /XF .gitkeep
# robocopy returns 0-7 for success (1 = files copied, 3 = files copied + extras present, etc.)
# 8+ is genuine failure. ErrorActionPreference=Stop would bail on 1, so check explicitly.
if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with exit code $LASTEXITCODE"
}

Write-Host "`n== ucc make =="
Push-Location $sys
try {
    & .\UCC.exe make
    if ($LASTEXITCODE -ne 0) {
        throw "ucc make failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
