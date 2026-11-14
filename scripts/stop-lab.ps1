# Stops only lab copies: PIDs listed in private\lab-pids.txt whose exe lives under private\. Never touches the user's game.
$root = Split-Path $PSScriptRoot -Parent
$labRoot = Join-Path $root 'private'
$pidFile = Join-Path $labRoot 'lab-pids.txt'
if (Test-Path $pidFile) {
    foreach ($line in Get-Content $pidFile) {
        $id = [int]($line -split ' ')[0]
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if ($p -and $p.ExecutablePath -like "$labRoot*") {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $id -Timeout 15 -ErrorAction SilentlyContinue   # logs stay locked until it is gone
        }
    }
    Remove-Item -Force $pidFile
}
Start-Sleep -Milliseconds 500
