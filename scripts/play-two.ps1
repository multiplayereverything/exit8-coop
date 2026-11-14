# Opens two visible copies of the lab install side by side to play/watch by hand: left = host, right = client
# (joins 127.0.0.1). No lab bot. The client copy is muted so the sound isn't doubled. Stop with stop-lab.ps1.
param([int]$Width = 960, [int]$Height = 540, [int]$Port = 27180)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$labRoot = Join-Path $root 'private'
if (Test-Path (Join-Path $labRoot 'tour.lock')) { throw 'a lab tour is running' }
& "$PSScriptRoot\build.ps1" | Out-Null
foreach ($n in 'host', 'client') {
    $w = Join-Path $labRoot "lab-$n\Exit8\Binaries\Win64\ue4ss"
    Get-ChildItem "$w\Mods" -Directory | Where-Object { $_.Name -like 'Exit8*' } | Remove-Item -Recurse -Force
    Copy-Item -Recurse -Force (Join-Path $root 'artifacts\mod\Exit8Together') "$w\Mods\"
    Set-Content -Encoding ascii "$w\Mods\mods.txt" "Exit8Together : 1`r`nKeybinds : 0"
}
$pidFile = Join-Path $labRoot 'lab-pids.txt'
$x = 0
foreach ($n in 'host', 'client') {
    $exe = Join-Path $labRoot "lab-$n\Exit8\Binaries\Win64\Exit8-Win64-Shipping.exe"
    $env:SteamAppId = '2653790'; $env:SteamGameId = '2653790'
    $env:E8T_LAB = ''; $env:E8T_TOUR = ''; $env:E8T_MUTANT = ''; $env:E8T_PORT = "$Port"
    $env:E8T_MODE = if ($n -eq 'host') { 'host' } else { 'join' }
    $env:E8T_NAME = if ($n -eq 'host') { 'Host' } else { 'Client' }
    $env:E8T_ADDRESS = '127.0.0.1'
    $args = @('Exit8', '-windowed', "-ResX=$Width", "-ResY=$Height", "-WinX=$x", '-WinY=40')
    if ($n -eq 'client') { $args += '-nosound' }
    $p = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory (Split-Path $exe) -PassThru
    Add-Content $pidFile "$($p.Id) $n"
    Write-Host "started $n pid $($p.Id)"
    $x += $Width
    Start-Sleep -Seconds 6
}
