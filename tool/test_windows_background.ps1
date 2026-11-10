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
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref Point point);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    public static void AssertFrameless(IntPtr hwnd) {
        int style = GetWindowLong(hwnd, -16);
        if ((style & 0x00C00000) != 0 || (style & 0x00040000) == 0)
            throw new Exception("Native caption returned or resizing was disabled.");
        Rect outer, client;
        Point origin = new Point();
        if (!GetWindowRect(hwnd, out outer) || !GetClientRect(hwnd, out client) || !ClientToScreen(hwnd, ref origin))
            throw new Exception("Could not inspect native frame geometry.");
        if (origin.X != outer.Left || origin.Y != outer.Top ||
            client.Right != outer.Right - outer.Left || client.Bottom != outer.Bottom - outer.Top)
            throw new Exception("Native non-client frame/title bar occupies space around Flutter.");
    }
    public static void CheckResizeFrame(IntPtr hwnd) {
        Rect original;
        if (!GetWindowRect(hwnd, out original)) throw new Exception("Missing window rectangle.");
        try {
            for (int step = 0; step < 12; ++step) {
                // SWP_FRAMECHANGED forces both native frame calculation and paint.
                if (!SetWindowPos(hwnd, IntPtr.Zero, 0, 0,
                    original.Right - original.Left + step, original.Bottom - original.Top + step, 0x0036))
                    throw new Exception("Native resize failed.");
                AssertFrameless(hwnd);
            }
        } finally {
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0,
                original.Right - original.Left, original.Bottom - original.Top, 0x0036);
        }
    }
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", EntryPoint="IsWindowVisible")] static extern bool NativeIsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    public static bool IsWindowVisible(IntPtr hwnd) {
        return NativeIsWindowVisible(hwnd) && !IsIconic(hwnd) && MonitorFromWindow(hwnd, 0) != IntPtr.Zero;
    }
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wp, IntPtr lp);
    public static void AssertNonActivating(IntPtr hwnd, IntPtr foreground) {
        if ((GetWindowLong(hwnd, -20) & 0x08000000) == 0)
            throw new Exception("WS_EX_NOACTIVATE is missing.");
        IntPtr child = GetWindow(hwnd, 5); // GW_CHILD: Flutter view.
        if (child == IntPtr.Zero) throw new Exception("Flutter child HWND is missing.");
        foreach (IntPtr target in new[] { hwnd, child }) {
            if (SendMessage(target, 0x21, hwnd, new IntPtr(0x02010001)).ToInt64() != 3)
                throw new Exception("WM_MOUSEACTIVATE must return MA_NOACTIVATE without eating the click.");
        }
        if (GetForegroundWindow() != foreground)
            throw new Exception("Helper stole foreground focus.");
    }
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
    public static void TaskView() {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero);
        keybd_event(0x09, 0, 0, UIntPtr.Zero);
        keybd_event(0x09, 0, 2, UIntPtr.Zero);
        keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }
    public static void Escape() {
        keybd_event(0x1B, 0, 0, UIntPtr.Zero);
        keybd_event(0x1B, 0, 2, UIntPtr.Zero);
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

function Assert-StaysHidden([int]$Milliseconds) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($app.HasExited) { throw 'Background process exited unexpectedly.' }
        $window = [HelperWinTest]::WindowFor($app.Id)
        if ($window -ne [IntPtr]::Zero -and [HelperWinTest]::IsWindowVisible($window)) {
            throw 'Background launch revealed the window without a hotkey.'
        }
        if ([HelperWinTest]::GetForegroundWindow() -ne $probe) {
            throw 'Background initialization stole focus from the other window.'
        }
        Start-Sleep -Milliseconds 10
    }
}

$app = $null
$probe = [IntPtr]::Zero
try {
    $probe = [HelperWinTest]::CreateWindowEx(0, 'STATIC', 'Global hotkey test',
        0x10CF0000, 100, 100, 400, 200, [IntPtr]::Zero, [IntPtr]::Zero,
        [IntPtr]::Zero, [IntPtr]::Zero)
    if ($probe -eq [IntPtr]::Zero) { throw 'Could not create the focus test window.' }
    [void][HelperWinTest]::SetForegroundWindow($probe)
    if ([HelperWinTest]::GetForegroundWindow() -ne $probe) {
        throw 'Could not focus the other window; rerun from an interactive desktop.'
    }
    $app = Start-Process $Executable -PassThru
    $script:hwnd = [IntPtr]::Zero
    Wait-For {
        $script:hwnd = [HelperWinTest]::WindowFor($app.Id)
        $script:hwnd -ne [IntPtr]::Zero -and [HelperWinTest]::IsWindowVisible($script:hwnd)
    } 'Application did not launch visibly. Check startup errors and shortcut conflicts.'
    [HelperWinTest]::AssertNonActivating($script:hwnd, $probe)
    $styles = [HelperWinTest]::GetWindowLong($script:hwnd, -20)
    if (($styles -band 0x80) -eq 0 -or ($styles -band 0x40000) -ne 0) {
        throw 'Expected WS_EX_TOOLWINDOW and no WS_EX_APPWINDOW.'
    }
    [HelperWinTest]::AssertFrameless($script:hwnd)
    [HelperWinTest]::CheckResizeFrame($script:hwnd)

    [HelperWinTest]::AssertNonActivating($script:hwnd, $probe)
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { -not [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not hide Helper.'
    if ($app.HasExited) { throw 'Hiding terminated Helper.' }
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not restore Helper.'
    [HelperWinTest]::AssertFrameless($script:hwnd)
    [HelperWinTest]::AssertNonActivating($script:hwnd, $probe)
    for ($cycle = 0; $cycle -lt 10; ++$cycle) {
        [HelperWinTest]::Shortcut(0x7b)
        Wait-For { -not [HelperWinTest]::IsWindowVisible($script:hwnd) } 'Repeated hide failed.'
        [HelperWinTest]::Shortcut(0x7b)
        Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'Repeated show failed.'
        [HelperWinTest]::AssertNonActivating($script:hwnd, $probe)
    }

    [void][HelperWinTest]::PostMessage($script:hwnd, 0x10, [IntPtr]::Zero, [IntPtr]::Zero)
    Wait-For { -not [HelperWinTest]::IsWindowVisible($script:hwnd) } 'WM_CLOSE did not hide Helper.'
    if ($app.HasExited) { throw 'WM_CLOSE terminated Helper.' }
    $second = Start-Process $Executable -PassThru
    if (-not $second.WaitForExit(10000)) { throw 'A second application instance remained alive.' }
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'Second launch did not restore the existing window.'
    [HelperWinTest]::AssertNonActivating($script:hwnd, $probe)

    [HelperWinTest]::TaskView()
    Wait-For { -not [HelperWinTest]::IsWindowVisible($script:hwnd) } 'Win+Tab did not hide Helper.'
    if ($app.HasExited) { throw 'Win+Tab terminated Helper.' }
    Start-Sleep -Milliseconds 700
    [HelperWinTest]::Escape()
    Start-Sleep -Milliseconds 300
    if ([HelperWinTest]::IsWindowVisible($script:hwnd)) { throw 'Leaving Task View reopened Helper automatically.' }
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not restore Helper after Win+Tab.'

    [void][HelperWinTest]::SetForegroundWindow($probe)
    [HelperWinTest]::Shortcut(0x73)
    if (-not $app.WaitForExit(10000)) { throw 'Ctrl+Shift+F4 did not exit Helper.' }

    [void][HelperWinTest]::SetForegroundWindow($probe)
    $app = Start-Process $Executable -ArgumentList '--background' -PassThru
    # Observe initialization, not only the settled state three seconds later.
    Assert-StaysHidden 5000
    Wait-For {
        $script:hwnd = [HelperWinTest]::WindowFor($app.Id)
        $script:hwnd -ne [IntPtr]::Zero
    } 'Background startup did not create a native window.'
    $backgroundSecond = Start-Process $Executable -ArgumentList '--background' -PassThru
    if (-not $backgroundSecond.WaitForExit(10000)) { throw 'Second background instance remained alive.' }
    Assert-StaysHidden 2000
    [void][HelperWinTest]::SetForegroundWindow($probe)
    [HelperWinTest]::Shortcut(0x7b)
    Wait-For { [HelperWinTest]::IsWindowVisible($script:hwnd) } 'F12 did not show the background-started window.'
    [HelperWinTest]::AssertNonActivating($script:hwnd, $probe)
    [HelperWinTest]::Shortcut(0x73)
    if (-not $app.WaitForExit(10000)) { throw 'Background-started application did not exit.' }
    Write-Output 'PASS: native launch, styles, global toggle/exit, close-to-hide, single instance, hidden background initialization and no focus stealing.'
    Write-Output 'Manual checks are still required: Task View/Alt+Tab/taskbar, OBS focus, resizing, logon autostart, persistence and conflicts.'
} finally {
    if ($probe -ne [IntPtr]::Zero) { [void][HelperWinTest]::DestroyWindow($probe) }
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
}
