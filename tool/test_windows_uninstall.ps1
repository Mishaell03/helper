# Only starts/kills disposable fake applications in a fresh test directory.
# Does not install/uninstall Helper or touch the user's shortcuts/library.
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA ('Temp\opencode\helper-uninstall-test-' + [guid]::NewGuid().ToString('N'))
$installed = Join-Path $root 'installed'
$outside = Join-Path $root 'outside'
[void][IO.Directory]::CreateDirectory($installed)
[void][IO.Directory]::CreateDirectory($outside)
$processes = @()
try {
  $fake = Join-Path $installed 'helper.exe'
  Add-Type -OutputAssembly $fake -OutputType WindowsApplication -TypeDefinition @'
public static class DisposableHelper {
    public static void Main() { System.Threading.Thread.Sleep(120000); }
}
'@
  $module = Join-Path $installed 'modules\ExcelMigrationEngine'
  [void][IO.Directory]::CreateDirectory($module)
  Copy-Item -LiteralPath $fake -Destination (Join-Path $module 'generator.exe')
  Copy-Item -LiteralPath $fake -Destination (Join-Path $outside 'helper.exe')
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\installer\stop_helper.ps1') -Destination $installed
  $app = Start-Process -FilePath $fake -PassThru
  $generator = Start-Process -FilePath (Join-Path $module 'generator.exe') -PassThru
  $foreign = Start-Process -FilePath (Join-Path $outside 'helper.exe') -PassThru
  $processes = @($app, $generator, $foreign)
  Start-Sleep -Milliseconds 300
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File (Join-Path $installed 'stop_helper.ps1') -InstallDirectory $installed
  if ($LASTEXITCODE -ne 0) { throw 'Shutdown helper failed.' }
  if (-not $app.WaitForExit(2000) -or -not $generator.WaitForExit(2000)) {
    throw 'An installed application was left running.'
  }
  if ($foreign.HasExited) { throw 'A different installation was incorrectly stopped.' }
  if (-not (Test-Path -LiteralPath (Join-Path $outside 'helper.exe'))) {
    throw 'A file outside the installation was modified.'
  }
  Write-Host 'PASS: installed Helper and generator stopped; outside Helper untouched.'
} finally {
  foreach ($process in $processes) {
    try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch {}
  }
  # Narrow deletion: this exact directory was freshly created above.
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
