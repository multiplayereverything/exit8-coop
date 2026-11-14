# Starts lab copies the house way: minimized without activation, 640x360 windowed, lowest quality, 30 fps,
# BelowNormal priority, stacked at the right edge when restored. PIDs go to private\lab-pids.txt.
# Refuses to start while the user's own Exit 8 runs or another lab holds private\tour.lock.
param([string[]]$Names = @('host'), [string]$ExtraArgs = '', [hashtable]$Env = @{})
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$labRoot = Join-Path $root 'private'
$own = Get-CimInstance Win32_Process -Filter "Name='Exit8-Win64-Shipping.exe'" | Where-Object { $_.ExecutablePath -notlike "$labRoot*" }
if ($own) { throw "The user's own Exit 8 is running (PID $($own.ProcessId)); not starting a lab." }

Add-Type -Namespace E8 -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct STARTUPINFO { public int cb; public string r; public string d; public string t;
  public int x; public int y; public int xs; public int ys; public int xc; public int yc; public int fa; public int flags;
  public short show; public short r2; public IntPtr r3; public IntPtr i; public IntPtr o; public IntPtr e; }
[StructLayout(LayoutKind.Sequential)] public struct PROCINFO { public IntPtr hp; public IntPtr ht; public int pid; public int tid; }
[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd,
  IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCINFO pi);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
[StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT { public int length; public int flags; public int show; public POINT min; public POINT max; public RECT normal; }
[DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
[DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
'@

$pidFile = Join-Path $labRoot 'lab-pids.txt'
$scrW = (Get-CimInstance Win32_VideoController | Select-Object -First 1).CurrentHorizontalResolution
if (-not $scrW) { $scrW = 1920 }
$slot = 0
foreach ($n in $Names) {
    $exe = Join-Path $labRoot "lab-$n\Exit8\Binaries\Win64\Exit8-Win64-Shipping.exe"
    if (-not (Test-Path $exe)) { throw "no lab copy $n (run setup-lab.ps1)" }
    foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$Env[$k], 'Process') }
    [Environment]::SetEnvironmentVariable('E8T_LAB_NAME', $n, 'Process')
    [Environment]::SetEnvironmentVariable('SteamAppId', '2653790', 'Process')
    [Environment]::SetEnvironmentVariable('SteamGameId', '2653790', 'Process')
    $cmd = "`"$exe`" Exit8 -windowed -ResX=640 -ResY=360 -nosplash -nosound -ExecCmds=`"t.MaxFPS 30,sg.ViewDistanceQuality 0,sg.ShadowQuality 0,sg.PostProcessQuality 0,sg.TextureQuality 0,sg.EffectsQuality 0,r.ScreenPercentage 50`" $ExtraArgs"
    $si = New-Object E8.Win+STARTUPINFO
    $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si); $si.flags = 1; $si.show = 7   # STARTF_USESHOWWINDOW, SW_SHOWMINNOACTIVE
    $pi = New-Object E8.Win+PROCINFO
    $ok = [E8.Win]::CreateProcessW($exe, (New-Object Text.StringBuilder $cmd), [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x4000, [IntPtr]::Zero, (Split-Path $exe), [ref]$si, [ref]$pi)  # BELOW_NORMAL_PRIORITY_CLASS
    if (-not $ok) { throw "CreateProcess failed for $n" }
    [E8.Win]::CloseHandle($pi.hp) | Out-Null; [E8.Win]::CloseHandle($pi.ht) | Out-Null
    Add-Content $pidFile "$($pi.pid) $n"
    Write-Host "started $n pid $($pi.pid)"
    # Place the window once: minimized, restoring to 640x360 at the right edge, never activated.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        $h = [IntPtr]::Zero; $found = [IntPtr]::Zero
        while (($h = [E8.Win]::FindWindowEx([IntPtr]::Zero, $h, 'UnrealWindow', $null)) -ne [IntPtr]::Zero) {
            $wp = 0; [E8.Win]::GetWindowThreadProcessId($h, [ref]$wp) | Out-Null
            if ($wp -eq $pi.pid) { $found = $h; break }
        }
        if ($found -ne [IntPtr]::Zero) {
            $p = New-Object E8.Win+WINDOWPLACEMENT
            $p.length = [Runtime.InteropServices.Marshal]::SizeOf($p); $p.show = 7
            $p.normal.l = $scrW - 660; $p.normal.t = 20 + 380 * $slot; $p.normal.r = $scrW - 20; $p.normal.b = $p.normal.t + 360
            [E8.Win]::SetWindowPlacement($found, [ref]$p) | Out-Null
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $slot++
}
