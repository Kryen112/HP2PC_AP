# Build a standalone hp2_ap_client.exe via PyInstaller, bundling the
# Archipelago framework + our apworld so end users don't need a Python install.
#
# One-time deps in your dev Python:
#   py -3.12 -m pip install pyinstaller
#
# Output: dist\hp2_ap_client.exe  (~85-100 MB single-file)

$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\kryen\Documents\Archipelago-play\Harry Potter 2 PC\HP2PC_AP'
$ap   = 'C:\Users\kryen\Documents\Archipelago-play\Archipelago'

if (-not (Test-Path "$ap\CommonClient.py")) {
    throw "Archipelago framework not found at $ap. Edit `$ap` in this script if your install lives elsewhere."
}

# 1. Stage a minimal `worlds\` tree. AP's `worlds\__init__.py` does an
#    `os.scandir` on the directory to discover game worlds at runtime; we
#    bundle just what's needed to satisfy that scan (bootstrap files +
#    our apworld), instead of dragging in the full ~100 MB of every other
#    AP world's source.
$staging = "$repo\dist\staging"
$wstage  = "$staging\worlds"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force -Path $wstage | Out-Null

Write-Host "== Stage minimal worlds\ ==" -ForegroundColor Cyan
@('__init__.py', 'AutoWorld.py', 'Files.py', 'LauncherComponents.py') | ForEach-Object {
    $src = Join-Path "$ap\worlds" $_
    if (Test-Path $src) { Copy-Item $src $wstage }
}
if (Test-Path "$ap\worlds\generic") {
    Copy-Item -Recurse "$ap\worlds\generic" "$wstage\generic"
}
Copy-Item -Recurse "$repo\apworld" "$wstage\harry_potter_2_pc"

Write-Host "Staged worlds\ contents:"
Get-ChildItem $wstage | ForEach-Object { Write-Host "  $($_.Name)" }

# 2. Run PyInstaller. --add-data with the staging dir so `_MEIPASS\worlds\`
#    exists at runtime (AP's scandir target). Hidden-imports cover modules
#    PyInstaller's static analysis can miss because they're discovered via
#    AutoWorldRegister at runtime.
Write-Host "`n== PyInstaller ==" -ForegroundColor Cyan
Push-Location $repo
try {
    $env:PYTHONDONTWRITEBYTECODE = '1'
    py -3.12 -m PyInstaller `
        --name hp2_ap_client `
        --onefile `
        --console `
        --noconfirm `
        --paths "$ap" `
        --add-data "$staging\worlds;worlds" `
        --hidden-import worlds.harry_potter_2_pc `
        --hidden-import worlds.harry_potter_2_pc.locations `
        --hidden-import worlds.harry_potter_2_pc.items `
        --hidden-import worlds.harry_potter_2_pc.regions `
        --hidden-import worlds.harry_potter_2_pc.rules `
        --hidden-import worlds.AutoWorld `
        --distpath "$repo\dist" `
        --workpath "$repo\dist\build" `
        --specpath "$repo\dist" `
        "$repo\client\hp2_ap_client.py"
} finally {
    Pop-Location
}

$exe = "$repo\dist\hp2_ap_client.exe"
if (Test-Path $exe) {
    $sizeMB = [Math]::Round((Get-Item $exe).Length / 1MB, 1)
    Write-Host "`nBuilt: $exe  ($sizeMB MB)" -ForegroundColor Green
} else {
    throw "Build failed - $exe not present"
}
