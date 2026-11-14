# Builds native\e8net.dll (x64, static CRT) and assembles the mod folder in artifacts\mod\Exit8Together.
param([switch]$NoStage)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ build tools (x64) not found' }
$out = Join-Path $root 'artifacts\build'
New-Item -ItemType Directory -Force $out | Out-Null
$src = Join-Path $root 'native\e8net.cpp'
$env:PATH = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer;$env:PATH"
$cmd = "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && cl /nologo /std:c++17 /O2 /MT /EHsc /W3 /LD `"$src`" /Fo`"$out\\`" /Fe`"$out\e8net.dll`" /link /NOLOGO"
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "native build failed ($LASTEXITCODE)" }
if ($NoStage) { return }
$mod = Join-Path $root 'artifacts\mod\Exit8Together'
if (Test-Path $mod) { Remove-Item -Recurse -Force $mod }
New-Item -ItemType Directory -Force "$mod\Scripts", "$mod\native" | Out-Null
Copy-Item "$root\src\Scripts\*.lua" "$mod\Scripts\"
Copy-Item "$out\e8net.dll" "$mod\native\"
Copy-Item "$root\src\config.txt" "$mod\config.txt"
Set-Content -Encoding ascii "$mod\enabled.txt" ''
Write-Host "staged $mod"
