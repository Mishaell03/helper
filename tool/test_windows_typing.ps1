# Interactive Windows integration test. The helper must already be running at
# the same integrity level with default automation hotkeys F6/F7/F8 + Ctrl+Shift.
# This creates a REAL separate-process WinForms text field and sends REAL keys.
# Do not type, click, switch windows or move focus while this test is running.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TypingProbe {
    public const string Sample = "\u041F\u0440\u0438\u0432\u0435\u0442 English \uD83D\uDE00!\r\n\r\n  \u0422\u0435\u043A\u0441\u0442\t@#%";
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void Key(byte key) {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
    public static void Hotkey(byte key) {
        keybd_event(0x11, 0, 0, UIntPtr.Zero);
        keybd_event(0x10, 0, 0, UIntPtr.Zero);
        Key(key);
        keybd_event(0x10, 0, 2, UIntPtr.Zero);
        keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
    public static void TaskView() {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero);
        Key(0x09);
        keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }
}
'@

$bindings = Get-ItemPropertyValue 'HKCU:\Software\Helper\Hotkeys' 'BindingsV2' -ErrorAction SilentlyContinue
if ($bindings) {
    if ($bindings.Length -ne 40) { throw 'Unexpected hotkey data. Fix shortcuts in Helper first.' }
    for ($i = 2; $i -lt 5; $i++) {
        if ([BitConverter]::ToUInt32($bindings, $i * 8) -ne 6 -or
            [BitConverter]::ToUInt32($bindings, $i * 8 + 4) -ne (0x75 + $i - 2)) {
            throw 'This test requires Ctrl+Shift+F6/F7/F8 automation shortcuts.'
        }
    }
}

$directory = Join-Path ([IO.Path]::GetTempPath()) ('helper-typing-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$fixture = Join-Path $directory 'automation-test.md'
[IO.File]::WriteAllText($fixture, "# Automation test`n" + [TypingProbe]::Sample,
    (New-Object Text.UTF8Encoding($false)))
Write-Output "Import this file in Helper and SELECT its block: $fixture"
Write-Output 'Set typing speed to 300 CPM or faster. Ensure emergency Stop has no registration conflict.'
Write-Output 'Stop any existing task before this test; its first action is an emergency Stop.'
[void](Read-Host 'Press Enter AFTER importing and selecting the test block')
[TypingProbe]::Hotkey(0x77)

$targetForm = New-Object Windows.Forms.Form
$targetForm.Text = 'Native text automation integration test - do not interact'
$targetForm.Width = 650
$targetForm.Height = 400
$target = New-Object Windows.Forms.TextBox
$target.Multiline = $true
$target.AcceptsReturn = $true
$target.AcceptsTab = $true
$target.MaxLength = 0
$target.Dock = [Windows.Forms.DockStyle]::Fill
$targetForm.Controls.Add($target)

function Pump-For([int]$Milliseconds) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}
function Wait-For([scriptblock]$Condition, [string]$Failure) {
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw $Failure }
        Pump-For 20
    }
}
function Start-Input {
    $target.Clear()
    $targetForm.Activate()
    [void]$target.Focus()
    Pump-For 200
    [TypingProbe]::Hotkey(0x75)
}

try {
    $targetForm.Show()
    Start-Input
    Pump-For 600
    if ($target.Text.Length -ne 0) { throw 'Text was inserted before the countdown finished.' }
    Wait-For { $target.Text.Length -ge 5 } 'Typing did not start. Check selected block, focus, hotkey conflicts and UIPI.'
    [TypingProbe]::Hotkey(0x76)
    Pump-For 300
    $paused = $target.Text
    Pump-For 1500
    if ($target.Text -ne $paused) { throw 'Text changed while paused.' }
    [TypingProbe]::Hotkey(0x76)
    Pump-For 600
    if ($target.Text -ne $paused) { throw 'Resume did not provide a new countdown.' }
    Wait-For { $target.Text -eq [TypingProbe]::Sample } 'Resume did not preserve the Unicode text position or formatting.'

    Start-Input
    Wait-For { $target.Text.Length -ge 4 } 'Second start failed.'
    [TypingProbe]::Hotkey(0x77)
    Pump-For 300
    $stopped = $target.Text
    Pump-For 1500
    if ($target.Text -ne $stopped) { throw 'Text kept changing after Stop.' }
    Start-Input
    Wait-For { $target.Text -eq [TypingProbe]::Sample } 'Start after Stop did not restart from the beginning.'

    Start-Input
    Pump-For 300
    [TypingProbe]::Hotkey(0x77)
    Pump-For 5500
    if ($target.Text.Length -ne 0) { throw 'Stop during countdown still allowed text insertion.' }

    Start-Input
    Wait-For { $target.Text.Length -ge 3 } 'Win+Tab check did not start.'
    [TypingProbe]::TaskView()
    Pump-For 700
    [TypingProbe]::Key(0x1B) # Close actual Task View; typing must stay paused.
    Pump-For 300
    $taskViewPaused = $target.Text
    Pump-For 1200
    if ($target.Text -ne $taskViewPaused) { throw 'Win+Tab did not pause typing.' }
    $targetForm.Activate(); [void]$target.Focus()
    [TypingProbe]::Hotkey(0x76)
    Wait-For { $target.Text -eq [TypingProbe]::Sample } 'Win+Tab lost the text position or inserted an unrelated Tab.'

    Start-Input
    Wait-For { $target.Text.Length -ge 3 } 'Manual input check did not start.'
    [TypingProbe]::Key(0x5A) # External Z must be swallowed without pausing.
    Wait-For { $target.Text -eq [TypingProbe]::Sample } 'Keyboard suppression failed or automation paused for unrelated input.'
    [TypingProbe]::Key(0x5A)
    Pump-For 300
    if (-not $target.Text.EndsWith('z', [StringComparison]::OrdinalIgnoreCase)) { throw 'Keyboard was not restored after completion.' }
    Write-Output 'PASS: 1-second hotkey countdown, Unicode including emoji, CRLF paragraphs, spaces, tab, pause/resume, Stop, restart, keyboard suppression and restoration.'
    Write-Output 'Still test other editors, focus changes, elevated windows, shutdown, capture exclusion and your actual Windows 10/11 configuration.'
} finally {
    [TypingProbe]::Hotkey(0x77)
    $targetForm.Close()
    $targetForm.Dispose()
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $directory -ErrorAction SilentlyContinue
    Write-Output 'Remove the imported automation-test.md record through Helper Settings if no longer needed.'
}
