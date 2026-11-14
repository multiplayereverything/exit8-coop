# Finds The Exit 8 install: $env:EXIT8_GAME, else the Steam library folders.
function Get-Exit8Dir {
    if ($env:EXIT8_GAME -and (Test-Path "$env:EXIT8_GAME\Exit8\Binaries\Win64\Exit8-Win64-Shipping.exe")) { return $env:EXIT8_GAME }
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    $libs = @()
    if ($steam) {
        $libs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { $libs += (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"').Matches | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
    }
    foreach ($l in $libs) {
        $d = Join-Path $l 'steamapps\common\Exit8'
        if (Test-Path "$d\Exit8\Binaries\Win64\Exit8-Win64-Shipping.exe") { return (Resolve-Path $d).Path }
    }
    throw 'The Exit 8 not found; set EXIT8_GAME'
}
