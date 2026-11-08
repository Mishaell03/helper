param([Parameter(Mandatory=$true)][string]$Executable)
# Interactive test: temporarily suspends ONLY the native window thread of the
# new Helper process started here. Never run while another Helper is active.
# It always resumes the thread in finally, then terminates only its own process.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HelperWatchdogTest {
    delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenThread(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint SuspendThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out uint value, int size);
    public static IntPtr Find(uint pid) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((hwnd, _) => {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            var name = new StringBuilder(256); GetClassName(hwnd, name, 256);
            if (owner == pid && name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW") { result = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

if (Get-Process helper -ErrorAction SilentlyContinue) { throw 'Exit all Helper instances before testing.' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$app = $null; $thread = [IntPtr]::Zero; $suspended = $false
try {
    $app = Start-Process -FilePath $Executable -ArgumentList '--capture-diagnostics' -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $hwnd = [IntPtr]::Zero
    while ($hwnd -eq [IntPtr]::Zero) {
        $hwnd = [HelperWatchdogTest]::Find($app.Id)
        if ($app.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Helper did not start.' }
        Start-Sleep -Milliseconds 100
    }
    Write-Output 'Waiting for first frame and heartbeat. Do not interact with Helper.'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not [HelperWatchdogTest]::IsWindowVisible($hwnd)) {
        if ($app.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'First frame did not show the panel.' }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Seconds 2
    $owner = [uint32]0
    $threadId = [HelperWatchdogTest]::GetWindowThreadProcessId($hwnd, [ref]$owner)
    if ($owner -ne $app.Id) { throw 'Window does not belong to the test process.' }
    $thread = [HelperWatchdogTest]::OpenThread(0x0002, $false, $threadId)
    if ($thread -eq [IntPtr]::Zero) { throw 'Could not open the test window thread. Run at the same integrity level.' }
    if ([HelperWatchdogTest]::SuspendThread($thread) -eq [uint32]::MaxValue) { throw 'Could not suspend the test window thread.' }
    $suspended = $true
    Start-Sleep -Seconds 9
    $cloak = [uint32]0
    $status = [HelperWatchdogTest]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloak, 4)
    if ($status -ne 0 -or ($cloak -band 1) -eq 0) { throw 'Independent watchdog did not DWM-cloak the unresponsive window.' }
    Write-Output 'PASS: window was cloaked while its native UI thread was suspended.'
    [void][HelperWatchdogTest]::ResumeThread($thread); $suspended = $false
    Start-Sleep -Seconds 3
    $cloak = [uint32]0
    [void][HelperWatchdogTest]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloak, 4)
    if (($cloak -band 1) -eq 0) { throw 'Recovery reopened the panel without user input.' }
    [void][HelperWatchdogTest]::PostMessage($hwnd, 0x8000 + 42, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Seconds 2
    [void][HelperWatchdogTest]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloak, 4)
    if (($cloak -band 1) -ne 0) { throw 'Explicit Show did not uncloak the responsive panel.' }
    Write-Output "PASS: explicit recovery. Log: $env:LOCALAPPDATA\Helper\Diagnostics\capture-*.log"
} finally {
    if ($suspended -and $thread -ne [IntPtr]::Zero) { [void][HelperWatchdogTest]::ResumeThread($thread) }
    if ($thread -ne [IntPtr]::Zero) { [void][HelperWatchdogTest]::CloseHandle($thread) }
    if ($app -and -not $app.HasExited) {
        [void][HelperWatchdogTest]::PostMessage([HelperWatchdogTest]::Find($app.Id), 0x8000 + 43, [IntPtr]::Zero, [IntPtr]::Zero)
        if (-not $app.WaitForExit(5000)) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
    }
}
