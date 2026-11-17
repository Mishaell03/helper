# Runs before Inno Setup removes files. Never select processes by name alone.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstallDirectory
)
$ErrorActionPreference = 'Stop'

try {
  $root = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
  $scriptRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
  if (-not $root.Equals($scriptRoot, [StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath (Join-Path $root 'helper.exe') -PathType Leaf)) {
    throw 'The shutdown script must run from the Helper installation directory.'
  }
  $prefix = $root + '\'

  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class HelperUninstallWindows {
    delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int count);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    public static void RequestExit(int process) {
        EnumWindows((window, data) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (owner == (uint)process && name.ToString() == "FLUTTER_RUNNER_WIN32_WINDOW")
                PostMessage(window, 0x8000 + 43, IntPtr.Zero, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
    }
}
'@

  function Get-InstalledProcesses {
    foreach ($process in @(Get-Process -Name helper, generator -ErrorAction SilentlyContinue)) {
      try {
        $path = $process.Path
        if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
          $process
        }
      } catch {
        # Exited processes or inaccessible processes in other installations.
      }
    }
  }

  $running = @(Get-InstalledProcesses)
  foreach ($process in $running) {
    if ($process.ProcessName -eq 'helper') {
      [HelperUninstallWindows]::RequestExit($process.Id)
    }
  }
  # Allow the native runner to stop automation and close its kill-on-close job.
  $deadline = [DateTime]::UtcNow.AddSeconds(4)
  while ((@(Get-InstalledProcesses)).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 100
  }
  foreach ($process in @(Get-InstalledProcesses)) {
    try {
      if (-not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw 'Process did not stop.' }
      }
    } catch {
      if (-not $process.HasExited) { throw }
    }
  }
  if ((@(Get-InstalledProcesses)).Count -gt 0) {
    throw 'Helper is still running; uninstall was cancelled to avoid a partial removal.'
  }

  # Preserve autostart for another portable installation, if any.
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $value = Get-ItemProperty -LiteralPath $runKey -Name 'Helper.Background' -ErrorAction SilentlyContinue
  $expected = '"' + (Join-Path $root 'helper.exe') + '" --background'
  if ($value -and $value.'Helper.Background' -eq $expected) {
    Remove-ItemProperty -LiteralPath $runKey -Name 'Helper.Background'
  }
  exit 0
} catch {
  Write-Error $_ -ErrorAction Continue
  exit 1
}
