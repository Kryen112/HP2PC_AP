# Terminal B: run the AP-aware client.
# - Connects to AP MultiServer at localhost:38282 (matches host_seed.ps1)
# - Listens for the HP2 mod on 127.0.0.1:38281

$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP'
$ap   = 'C:\Users\kryen\Documents\Archipelago-play\Archipelago'

Push-Location $ap
try {
    py -3.12 "$repo\client\hp2_ap_client.py" --name HP2_Test --connect localhost:38282
} finally {
    Pop-Location
}
