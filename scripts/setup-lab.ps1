# Makes lab copies of The Exit 8 in private\lab-<name>: hardlinked binaries (same drive as the game), junctions for
# Content and Engine, UE4SS in the copy's Binaries\Win64, steam_appid.txt (lab copies only). Never writes to the game.
param([string[]]$Names = @('host', 'client'), [string]$Ue4ss = 'v4.0.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\paths.ps1"
$game = Get-Exit8Dir
$ue = Join-Path $root "deps\ue4ss-$Ue4ss\extracted"
if (-not (Test-Path $ue)) { throw "UE4SS $Ue4ss not in deps (see handoff: deps setup)" }
foreach ($n in $Names) {
    $lab = Join-Path $root "private\lab-$n"
    $win = Join-Path $lab 'Exit8\Binaries\Win64'
    New-Item -ItemType Directory -Force $win, "$win\D3D12" | Out-Null
    foreach ($f in Get-ChildItem "$game\Exit8\Binaries\Win64" -Recurse -File) {
        $rel = $f.FullName.Substring("$game\Exit8\Binaries\Win64".Length + 1)
        $dst = Join-Path $win $rel
        if (-not (Test-Path $dst)) { New-Item -ItemType HardLink -Path $dst -Target $f.FullName | Out-Null }
    }
    foreach ($j in @(@("$lab\Exit8\Content", "$game\Exit8\Content"), @("$lab\Engine", "$game\Engine"))) {
        if (-not (Test-Path $j[0])) { New-Item -ItemType Junction -Path $j[0] -Target $j[1] | Out-Null }
    }
    Copy-Item -Recurse -Force "$ue\*" $win -Exclude '*.md'
    Set-Content -Encoding ascii "$win\steam_appid.txt" '2653790'
    Write-Host "lab-$n ready: $win"
}
