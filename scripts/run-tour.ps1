# Two-copy lab: builds, installs the mod into private\lab-host and private\lab-client, starts both hidden/small/low
# priority (launch-lab.ps1 defaults), lets the in-mod tour run, stops them and runs the verifier.
#   .\scripts\run-tour.ps1 [-Tour loop] [-Seconds 210] [-Mutant noanomalysync] [-Plan forward,forward,back,forward]
param([string]$Tour = 'loop', [int]$Seconds = 210, [string]$Mutant = '', [string]$Plan = 'smart,smart,smart,smart,smart', [int]$Port = 27180, [switch]$NoBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$lock = Join-Path $root 'private\tour.lock'
if (Test-Path $lock) { throw "another tour holds $lock" }
if (-not $NoBuild) { & "$PSScriptRoot\build.ps1" | Out-Null }
$mod = Join-Path $root 'artifacts\mod\Exit8Together'
$saves = Join-Path $env:LOCALAPPDATA 'Exit8\Saved\SaveGames'
$backup = Join-Path $root "private\save-backup\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
# UE4SS v4 keeps mods, settings and its log under Win64\ue4ss (v3: directly in Win64).
function Ue4ssDir([string]$n) {
    $w = Join-Path $root "private\lab-$n\Exit8\Binaries\Win64"
    if (Test-Path "$w\ue4ss\UE4SS.dll") { return "$w\ue4ss" }
    return $w
}
New-Item -ItemType File -Force $lock | Out-Null
try {
    if (Test-Path $saves) { New-Item -ItemType Directory -Force $backup | Out-Null; Copy-Item "$saves\*" $backup -ErrorAction SilentlyContinue }
    foreach ($n in 'host', 'client') {
        $w = Ue4ssDir $n
        Get-ChildItem "$w\Mods" -Directory | Where-Object { $_.Name -like 'Exit8*' } | Remove-Item -Recurse -Force
        Copy-Item -Recurse -Force $mod "$w\Mods\"
        Set-Content -Encoding ascii "$w\Mods\mods.txt" "Exit8Together : 1`r`nKeybinds : 0"
        if (Test-Path "$w\UE4SS.log") { Remove-Item -Force "$w\UE4SS.log" }
    }
    $common = @{ E8T_LAB = '1'; E8T_TOUR = $Tour; E8T_MUTANT = $Mutant; E8T_PLAN = $Plan; E8T_PORT = "$Port" }
    $h = $common.Clone(); $h.E8T_MODE = 'host'; $h.E8T_NAME = 'LabHost'
    & "$PSScriptRoot\launch-lab.ps1" -Names host -Env $h
    Start-Sleep -Seconds 8
    $c = $common.Clone(); $c.E8T_MODE = 'join'; $c.E8T_NAME = 'LabClient'; $c.E8T_ADDRESS = '127.0.0.1'
    & "$PSScriptRoot\launch-lab.ps1" -Names client -Env $c
    Start-Sleep -Seconds $Seconds
} finally {
    & "$PSScriptRoot\stop-lab.ps1"
    Remove-Item -Force $lock -ErrorAction SilentlyContinue
    if (Test-Path $backup) { Copy-Item -Force "$backup\*" $saves -ErrorAction SilentlyContinue }
}
$out = Join-Path $root "private\runs\$Tour$(if ($Mutant) { "-$Mutant" })-$(Get-Date -Format 'HHmmss')"
New-Item -ItemType Directory -Force $out | Out-Null
foreach ($n in 'host', 'client') {
    $w = Ue4ssDir $n
    try { Copy-Item "$w\UE4SS.log" "$out\$n.log" } catch { Start-Sleep 3; Copy-Item "$w\UE4SS.log" "$out\$n.log" -ErrorAction SilentlyContinue }
    try { Copy-Item "$w\Mods\Exit8Together\e8net.log" "$out\$n-net.log" } catch { Write-Host "net log still locked for $n" }
}
$va = @((Join-Path $root 'tests\verify-lab.py'), $out, '--tour', $Tour)
if ($Mutant) { $va += @('--mutant', $Mutant) }
python -I @va
exit $LASTEXITCODE
