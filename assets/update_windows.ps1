param(
  [Parameter(Mandatory=$true)][ValidateSet('Prepare','Apply')][string]$Mode,
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][int]$AppProcessId,
  [switch]$NoUi
)
$ErrorActionPreference = 'Stop'
$stage = Join-Path $WorkDir 'stage'
$backup = Join-Path $WorkDir 'backup'
$log = Join-Path $WorkDir 'update.log'
$exe = Join-Path $InstallDir 'helper.exe'

if ($Mode -eq 'Prepare') {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [void][IO.Directory]::CreateDirectory($stage)
  $zip = [IO.Compression.ZipFile]::OpenRead((Join-Path $WorkDir 'update.zip'))
  try {
    $total = 0L
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('/', '\')
      $segments = $name.TrimEnd('\').Split('\')
      # Reject traversal, ADS, reserved names, aliases and symbolic links.
      if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or
          ($segments | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' -or $_ -match '[. ]$' -or $_ -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)' }) -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
          -not $names.Add($name)) { throw 'Unsafe ZIP entry.' }
      $total += $entry.Length
      if ($total -gt 2147483648 -or $zip.Entries.Count -gt 20000) { throw 'Archive is too large.' }
      $target = [IO.Path]::GetFullPath((Join-Path $stage $name))
      if (-not $target.StartsWith($stage + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe ZIP path.' }
      if ($name.EndsWith('\')) { [void][IO.Directory]::CreateDirectory($target); continue }
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target)
    }
  } finally { $zip.Dispose() }
  foreach ($required in @('helper.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Missing $required" }
  }
  # Do not follow junctions/symlinks in the installation tree.
  $directory = Get-Item -LiteralPath $InstallDir
  while ($null -ne $directory) {
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked installation directory is unsupported.' }
    $directory = $directory.Parent
  }
  foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
    $relative = $file.FullName.Substring($stage.Length + 1)
    $target = Join-Path $InstallDir $relative
    $cursor = $target
    while ($cursor.Length -ge $InstallDir.Length) {
      if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked target is unsupported.' }
      $cursor = [IO.Path]::GetDirectoryName($cursor)
      if (-not $cursor) { break }
    }
  }
  $probe = Join-Path $InstallDir ([guid]::NewGuid().ToString() + '.update-test')
  [IO.File]::WriteAllText($probe, 'test')
  Remove-Item -LiteralPath $probe
  exit 0
}

$replaced = New-Object 'System.Collections.Generic.List[string]'
$created = New-Object 'System.Collections.Generic.List[string]'
try {
  # Capture the running process before waiting to avoid acting on a reused PID.
  $app = Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue
  if (-not $app -or -not (Test-Path -LiteralPath $stage) -or
      (Test-Path -LiteralPath (Join-Path $WorkDir 'cancelled'))) { throw 'Update handoff cancelled.' }
  [IO.File]::WriteAllText((Join-Path $WorkDir 'ready'), 'ready')
  if (-not $app.WaitForExit(120000)) { throw 'Helper did not exit. No files were changed.' }
  if (Test-Path -LiteralPath (Join-Path $WorkDir 'cancelled')) { throw 'Update cancelled.' }
  [void][IO.Directory]::CreateDirectory($backup)
  foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
    $relative = $file.FullName.Substring($stage.Length + 1)
    $target = Join-Path $InstallDir $relative
    if (Test-Path -LiteralPath $target) {
      $saved = Join-Path $backup $relative
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
      Copy-Item -LiteralPath $target -Destination $saved
      $replaced.Add($relative)
    } else { $created.Add($relative) }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
  }
  Start-Process -FilePath $exe -WorkingDirectory $InstallDir
} catch {
  $_ | Out-String | Set-Content -LiteralPath $log
  $rollbackFailed = $false
  foreach ($relative in $replaced) {
    try { Copy-Item -LiteralPath (Join-Path $backup $relative) -Destination (Join-Path $InstallDir $relative) -Force }
    catch { $rollbackFailed = $true; $_ | Out-String | Add-Content -LiteralPath $log }
  }
  foreach ($relative in $created) {
    try { if (Test-Path -LiteralPath (Join-Path $InstallDir $relative)) { Remove-Item -LiteralPath (Join-Path $InstallDir $relative) } }
    catch { $rollbackFailed = $true }
  }
  if (-not $NoUi) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show("Update failed. Rollback incomplete: $rollbackFailed. Backup and log: $WorkDir", 'Helper update')
  }
  if (-not $rollbackFailed -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe -WorkingDirectory $InstallDir }
  exit 1 # Keep backup/log for recovery; never touch LocalAppData or registry.
}
Remove-Item -LiteralPath $WorkDir -Recurse -Force
