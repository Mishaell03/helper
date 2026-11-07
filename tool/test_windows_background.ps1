param(
    [string]$Executable,
    [switch]$HoldConflict
)

# Run on an interactive Windows 10/11 desktop, at the same integrity level as
# Helper. This sends REAL keyboard input; do not type while the test is running.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HelperWinTest {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowEx(
        uint exStyle, string cls, string name, uint style, int x, int y,
        int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    public static IntPtr WindowFor(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, data) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            var name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            if (owner == pid && name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW") {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static void Shortcut(byte key) {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
        keybd_event(0x10, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
}
'@

if ($HoldConflict) {
    # Keep a real Ctrl+Alt+F8 registration owned by this PowerShell thread.
    if (-not [HelperWinTest]::RegisterHotKey([IntPtr]::Zero, 777, 0x4003, 0x77)) {
        throw "Ctrl+Alt+F8 is already occupied. Win32: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
    try {
        Read-Host 'Ctrl+Alt+F8 is reserved. Assign it in Helper and verify a conflict message. Press Enter to release'
    } finally {
        [void][HelperWinTest]::UnregisterHotKey([IntPtr]::Zero, 777)
    }
    return
}

if (-not $Executable) { throw 'Specify -Executable with the built helper.exe path.' }
$Executable = (Resolve-Path $Executable).Path
if (Get-Process helper -ErrorAction SilentlyContinue) {
    throw 'Exit all Helper instances before running this test.'
}
$saved = Get-ItemPropertyValue 'HKCU:\Software\Helper\Hotkeys' 'BindingsV2' -ErrorAction SilentlyContinue
if (-not $saved) {
    $saved = Get-ItemPropertyValue 'HKCU:\Software\Helper\Hotkeys' 'BindingsV1' -ErrorAction SilentlyContinue
}
if ($saved -and ([BitConverter]::ToUInt32($saved, 0) -ne 6 -or
                 [BitConverter]::ToUInt32($saved, 4) -ne 0x7b -or
                 [BitConverter]::ToUInt32($saved, 8) -ne 6 -or
                 [BitConverter]::ToUInt32($saved, 12) -ne 0x73)) {
    throw 'Restore default shortcuts in Helper before running this test.'
}

function Wait-For([scriptblock]$Condition, [string]$Failure) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw $Failure }
        Start-Sleep -Milliseconds 100
    }
}

$app = $null
$probe = [IntPtr]::Zero
try {
    $app = Start-Process $Executable -PassThru
    $script:hwnd = [IntPtr]::Zero
    Wait-For {
        $script:hwnd = [HelperWinTest]::WindowFor($app.Id)
        $script:hwnd -ne [IntPtr]::Zero -and [HelperWinTest]::IsWindowVisible($script:hwnd)
    } 'Application did not launch visibly. Check startup errors and shortcut conflicts.'
    $styles = [HelperWinTest]::GetWindowLong($script:hwnd, -20)
    if (($styles -band 0x80) -eq 0 -or ($styles -band 0x40000) -ne 0) {
        throw 'Expected WS_EX_TOOLWINDOW and no WS_EX_APPWINDOW.'
    }

    # A real, independent native window holds focus while shortcuts are tested.
    $probe = [HelperWinTest]::CreateWindowEx(0, 'STATIC', 'Global hotkey test',
        0x10CF0000, 100, 100, 400, 200, [IntPtr]::Zero, [IntPtr]::Zero,
        [IntPtr]::Zero, [IntPtr]::Zero)
    if ($probe -eq [IntPtr]::Zero) { throw 'Could not create the focus test window.' }
    [void][HelperWinTest]::SetForegroundWindow($probe)
    if ([HelperWinTest]::GetForegroundWindow() -ne $probe) {
        throw 'Could not focus the other window; rerun from an interactive desktop.'
    }
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { -not [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not hide Helper.'
    if ($app.HasExited) { throw 'Hiding terminated Helper.' }
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not restore Helper.'

    [void][HelperWinTest]::PostMessage($script:hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    Wait-For { -not [HelperWinTest]::IsWindowVisible($script:hwnd) } 'WM_CLOSE did not hide Helper.'
    if ($app.HasExited) { throw 'WM_CLOSE terminated Helper.' }
    $second = Start-Process $Executable -PassThru
    if (-not $second.WaitForExit(10000)) { throw 'A second application instance remained alive.' }
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'Second launch did not restore the existing window.'

    [void][HelperWinTest]::SetForegroundWindow($probe)
    [HelperWinTest]::Shortcut(0x73)
    if (-not $app.WaitForExit(10000)) { throw 'Ctrl+Shift+F4 did not exit Helper.' }

    $app = Start-Process $Executable -ArgumentList '--background' -PassThru
    Wait-For {
        $script:hwnd = [HelperWinTest]::WindowFor($app.Id)
        $script:hwnd -ne [IntPtr]::Zero
    } 'Background startup did not create a native window.'
    Start-Sleep -Seconds 3
    if ([HelperWinTest]::IsWindowVisible($script:hwnd)) { throw 'Background startup showed the window.' }
    [void][HelperWinTest]::SetForegroundWindow($probe)
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not show the background-started window.'
    [HelperWinTest]::Shortcut(0x73)
    if (-not $app.WaitForExit(10000)) { throw 'Background-started application did not exit.' }
    Write-Output 'PASS: native launch, styles, global toggle/exit, close-to-hide, single instance and background launch.'
    Write-Output 'Manual checks are still required: Task View/Alt+Tab/taskbar, OBS focus, resizing, logon autostart, persistence and conflicts.'
} finally {
    if ($probe -ne [IntPtr]::Zero) { [void][HelperWinTest]::DestroyWindow($probe) }
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
}
