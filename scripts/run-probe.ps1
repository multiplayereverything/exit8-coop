# Runs one lab-only probe mod (tools\recon\<Mod>) in lab-host for $Seconds, then stops the copy and saves the log.
param([string]$Mod = 'Exit8Probe', [int]$Seconds = 120, [hashtable]$Env = @{}, [string]$Lab = 'host')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$w = Join-Path $root "private\lab-$Lab\Exit8\Binaries\Win64"
if (Test-Path "$w\ue4ss\UE4SS.dll") { $w = "$w\ue4ss" }   # UE4SS v4 keeps mods, settings and log under ue4ss\
$lock = Join-Path $root 'private\tour.lock'
if (Test-Path $lock) { throw "another tour holds $lock" }
New-Item -ItemType File -Force $lock | Out-Null
try {
    Get-ChildItem "$w\Mods" -Directory | Where-Object { $_.Name -like 'Exit8*' } | Remove-Item -Recurse -Force
    Copy-Item -Recurse -Force (Join-Path $root "tools\recon\$Mod") "$w\Mods\"
    Set-Content -Encoding ascii "$w\Mods\mods.txt" "$Mod : 1`r`nConsoleEnablerMod : 1`r`nBPModLoaderMod : 1`r`nKeybinds : 0"
    if (Test-Path "$w\UE4SS.log") { Remove-Item -Force "$w\UE4SS.log" }
    & "$PSScriptRoot\launch-lab.ps1" -Names $Lab -Env $Env
    Start-Sleep -Seconds $Seconds
} finally {
    & "$PSScriptRoot\stop-lab.ps1"
    Remove-Item -Force $lock -ErrorAction SilentlyContinue
}
$out = Join-Path $root "private\recon\$Mod-$(Get-Date -Format 'HHmmss').log"
Copy-Item "$w\UE4SS.log" $out
Write-Host "log: $out"
