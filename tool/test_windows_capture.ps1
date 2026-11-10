param(
    [Parameter(Mandatory=$true)][string]$Executable,
    [ValidateRange(1,100)][int]$Cycles = 20
)
# Interactive desktop only. Compares real GDI display capture with a static
# background before/after repeated Helper show/hide. Does not simulate capture.
# OBS/WGC/other recorders must ALSO be tested using their actual recording output.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HelperCaptureTest {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int count);
    [DllImport("user32.dll", EntryPoint="IsWindowVisible")] static extern bool NativeIsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    public static bool IsWindowVisible(IntPtr hwnd) {
        // A Win10 hidden panel keeps its native surface alive off all monitors.
        return NativeIsWindowVisible(hwnd) && !IsIconic(hwnd) && MonitorFromWindow(hwnd, 0) != IntPtr.Zero;
    }
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr hwnd, out uint affinity);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
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
    public static void Shortcut(byte key) {
        keybd_event(0x11, 0, 0, UIntPtr.Zero); keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 0, UIntPtr.Zero); keybd_event(key, 0, 2, UIntPtr.Zero);
        keybd_event(0x10, 0, 2, UIntPtr.Zero); keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
}
'@
[void][HelperCaptureTest]::SetProcessDpiAwarenessContext([IntPtr](-4))

$Executable = (Resolve-Path -LiteralPath $Executable).Path
if (Get-Process helper -ErrorAction SilentlyContinue) { throw 'Exit Helper before running this test.' }
$bindings = Get-ItemPropertyValue 'HKCU:\Software\Helper\Hotkeys' 'BindingsV3' -ErrorAction SilentlyContinue
if (-not $bindings) { $bindings = Get-ItemPropertyValue 'HKCU:\Software\Helper\Hotkeys' 'BindingsV2' -ErrorAction SilentlyContinue }
if (-not $bindings) { $bindings = Get-ItemPropertyValue 'HKCU:\Software\Helper\Hotkeys' 'BindingsV1' -ErrorAction SilentlyContinue }
if ($bindings -and ([BitConverter]::ToUInt32($bindings, 0) -ne 6 -or
    [BitConverter]::ToUInt32($bindings, 4) -ne 0x7b -or
    [BitConverter]::ToUInt32($bindings, 8) -ne 6 -or
    [BitConverter]::ToUInt32($bindings, 12) -ne 0x73)) {
    throw 'This test requires default Ctrl+Shift+F12 toggle and Ctrl+Shift+F4 exit.'
}

function Pump([int]$Milliseconds) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 } while ([DateTime]::UtcNow -lt $deadline)
}
function Wait-For([scriptblock]$Condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (& $Condition)) {
        if ($app.HasExited) { throw 'Helper exited unexpectedly.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Window visibility did not change. Check hotkey conflicts/startup errors.' }
        Pump 20
    }
}
function Capture {
    $bitmap = New-Object Drawing.Bitmap($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size) } finally { $graphics.Dispose() }
    return $bitmap
}
function Compare-Capture([string]$Phase) {
    $actual = Capture
    try {
        $changed = 0; $samples = 0
        for ($iy = 2; $iy -lt $height; $iy += 4) {
            for ($ix = 2; $ix -lt $width; $ix += 4) {
                $a = $baseline.GetPixel($ix, $iy); $b = $actual.GetPixel($ix, $iy)
                if ([Math]::Abs([int]$a.R - $b.R) -gt 12 -or [Math]::Abs([int]$a.G - $b.G) -gt 12 -or [Math]::Abs([int]$a.B - $b.B) -gt 12) { $changed++ }
                $samples++
            }
        }
        if ($changed / [double]$samples -gt 0.02) {
            $directory = Join-Path ([IO.Path]::GetTempPath()) ('helper-capture-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($directory)
            $baseline.Save((Join-Path $directory 'expected.png'))
            $actual.Save((Join-Path $directory 'actual.png'))
            throw "$Phase changed the captured background. Diagnostics: $directory"
        }
    } finally { $actual.Dispose() }
}

$app = $null; $baseline = $null; $pattern = $null; $form = $null
try {
    Write-Output "Windows: $([Environment]::OSVersion.VersionString). Do not interact with the desktop during this test."
    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = 'None'; $form.WindowState = 'Maximized'
    $form.StartPosition = 'Manual'; $form.Bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $pattern = New-Object Drawing.Bitmap($form.Bounds.Width, $form.Bounds.Height)
    $g = [Drawing.Graphics]::FromImage($pattern)
    try {
        $g.Clear([Drawing.Color]::DeepSkyBlue)
        for ($px = 0; $px -lt $pattern.Width; $px += 64) {
            for ($py = 0; $py -lt $pattern.Height; $py += 64) {
                if ((($px / 64 + $py / 64) % 2) -eq 0) { $g.FillRectangle([Drawing.Brushes]::Orange, $px, $py, 64, 64) }
            }
        }
    } finally { $g.Dispose() }
    $form.BackgroundImage = $pattern; $form.Show(); $form.Activate(); Pump 500
    $app = Start-Process -FilePath $Executable -ArgumentList '--background', '--capture-diagnostics' -PassThru
    Write-Output "Native lifecycle logs: $env:LOCALAPPDATA\Helper\Diagnostics (latest capture-*.log)."
    $script:hwnd = [IntPtr]::Zero
    Wait-For { $script:hwnd = [HelperCaptureTest]::Find($app.Id); $script:hwnd -ne [IntPtr]::Zero }
    Pump 3000
    if ([HelperCaptureTest]::IsWindowVisible($hwnd)) { throw 'Background startup revealed Helper.' }
    $rect = New-Object HelperCaptureTest+Rect
    [void][HelperCaptureTest]::GetWindowRect($hwnd, [ref]$rect)
    $width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
    $x = $form.Bounds.Left + 20; $y = $form.Bounds.Top + 20
    if ($width + 40 -gt $form.Width -or $height + 40 -gt $form.Height) { throw 'Resize Helper smaller before testing.' }
    [void][HelperCaptureTest]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x15)
    Pump 200
    $baseline = Capture
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        [HelperCaptureTest]::Shortcut(0x7b)
        Wait-For { [HelperCaptureTest]::IsWindowVisible($hwnd) }
        $affinity = [uint32]0
        if (-not [HelperCaptureTest]::GetWindowDisplayAffinity($hwnd, [ref]$affinity) -or $affinity -ne 0x11) { throw 'Capture exclusion was lost.' }
        # Check both the first frames and the settled composition.
        Pump 40; Compare-Capture "Show cycle $cycle (early)"
        Pump 200; Compare-Capture "Show cycle $cycle (settled)"
        [HelperCaptureTest]::Shortcut(0x7b)
        Wait-For { -not [HelperCaptureTest]::IsWindowVisible($hwnd) }
        if ([HelperCaptureTest]::GetForegroundWindow() -eq $hwnd) { throw 'Hidden Helper retained keyboard focus.' }
        Pump 40; Compare-Capture "Hide cycle $cycle"
    }
    [HelperCaptureTest]::Shortcut(0x73)
    if (-not $app.WaitForExit(10000)) { throw 'Exit hotkey failed.' }
    Write-Output "PASS: $Cycles real show/hide cycles retained affinity and the GDI-captured background."
    Write-Output 'This does not certify OBS/WGC. Repeat with the actual recorder on the affected GPU/Windows build.'
} finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -ErrorAction SilentlyContinue }
    if ($baseline) { $baseline.Dispose() }
    if ($form) { $form.Dispose() }
    if ($pattern) { $pattern.Dispose() }
}
