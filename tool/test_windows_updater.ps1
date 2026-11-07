# Uses only a new, isolated temporary installation. No running Helper or
# real user settings are read, changed or removed.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script = (Resolve-Path (Join-Path $PSScriptRoot '..\assets\update_windows.ps1')).Path
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$root = Join-Path ([IO.Path]::GetTempPath()) ('helper-update-test-' + [guid]::NewGuid().ToString('N'))
$install = Join-Path $root 'installation with spaces'
$payload = Join-Path $root 'payload'
$lock = $null
$sleeper = $null

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}
function New-Work([string]$Name) {
  $work = Join-Path $root $Name
  [void][IO.Directory]::CreateDirectory($work)
  [IO.Compression.ZipFile]::CreateFromDirectory($payload, (Join-Path $work 'update.zip'))
  return $work
}
function Invoke-Updater([string]$Mode, [string]$Work, [int]$TargetPid) {
  # Expected rejection cases emit native stderr in Windows PowerShell 5.1.
  $savedPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script `
        -Mode $Mode -WorkDir $Work -InstallDir $install -AppProcessId $TargetPid -NoUi 2>&1 | Out-Null
    return $LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
}
function Start-Sleeper {
  return Start-Process -FilePath $powershell -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 3' -PassThru -WindowStyle Hidden
}

try {
  [void][IO.Directory]::CreateDirectory($install)
  [void][IO.Directory]::CreateDirectory((Join-Path $payload 'data\flutter_assets'))
  # Valid, harmless Windows executable as the mock application.
  Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $payload 'helper.exe')
  [IO.File]::WriteAllText((Join-Path $payload 'flutter_windows.dll'), 'new dll')
  [IO.File]::WriteAllText((Join-Path $payload 'data\icudtl.dat'), 'new data')
  [IO.File]::WriteAllText((Join-Path $payload 'data\flutter_assets\fixture'), 'asset')
  [IO.File]::WriteAllText((Join-Path $install 'helper.exe'), 'old exe')
  [IO.File]::WriteAllText((Join-Path $install 'flutter_windows.dll'), 'old dll')
  [IO.File]::WriteAllText((Join-Path $install 'unrelated.txt'), 'preserve me')

  $work = New-Work 'successful'
  Assert ((Invoke-Updater 'Prepare' $work $PID) -eq 0) 'Valid archive rejected.'
  $sleeper = Start-Sleeper
  Assert ((Invoke-Updater 'Apply' $work $sleeper.Id) -eq 0) 'Apply failed.'
  Assert (([IO.File]::ReadAllText((Join-Path $install 'flutter_windows.dll'))) -eq 'new dll') 'DLL not replaced.'
  Assert (([IO.File]::ReadAllText((Join-Path $install 'unrelated.txt'))) -eq 'preserve me') 'Unrelated file changed.'
  Assert (Test-Path -LiteralPath (Join-Path $install 'data\flutter_assets\fixture')) 'New assets missing.'
  Assert (-not (Test-Path -LiteralPath $work)) 'Successful update was not cleaned up.'

  # Force a failure after at least one replacement; test the backup rollback.
  Start-Sleep -Milliseconds 500
  [IO.File]::WriteAllText((Join-Path $install 'flutter_windows.dll'), 'rollback dll')
  [IO.File]::WriteAllText((Join-Path $install 'zlocked.dll'), 'keep locked')
  [IO.File]::WriteAllText((Join-Path $payload 'zlocked.dll'), 'replace locked')
  $work = New-Work 'rollback'
  Assert ((Invoke-Updater 'Prepare' $work $PID) -eq 0) 'Rollback fixture rejected.'
  $lock = [IO.File]::Open((Join-Path $install 'zlocked.dll'), 'Open', 'ReadWrite', 'None')
  $sleeper = Start-Sleeper
  Assert ((Invoke-Updater 'Apply' $work $sleeper.Id) -ne 0) 'Locked-file update should fail.'
  $lock.Dispose(); $lock = $null
  Assert (([IO.File]::ReadAllText((Join-Path $install 'flutter_windows.dll'))) -eq 'rollback dll') 'Backup rollback failed.'
  Assert (([IO.File]::ReadAllText((Join-Path $install 'zlocked.dll'))) -eq 'keep locked') 'Locked file changed.'
  Assert (Test-Path -LiteralPath (Join-Path $work 'update.log')) 'Error log missing.'

  # A traversal entry must be rejected before any installation file changes.
  $work = Join-Path $root 'unsafe'
  [void][IO.Directory]::CreateDirectory($work)
  $zip = [IO.Compression.ZipFile]::Open((Join-Path $work 'update.zip'), 'Create')
  try {
    $entry = $zip.CreateEntry('../escaped.txt')
    $writer = New-Object IO.StreamWriter($entry.Open())
    $writer.Write('unsafe'); $writer.Dispose()
  } finally { $zip.Dispose() }
  Assert ((Invoke-Updater 'Prepare' $work $PID) -ne 0) 'Traversal ZIP accepted.'
  Assert (-not (Test-Path -LiteralPath (Join-Path $work 'escaped.txt'))) 'ZIP escaped staging.'
  Write-Output 'PASS: prepare, replacement, preservation of unrelated files, rollback, traversal rejection.'
} finally {
  if ($lock) { $lock.Dispose() }
  if ($sleeper -and -not $sleeper.HasExited) { $sleeper.WaitForExit() }
  Start-Sleep -Milliseconds 500
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
