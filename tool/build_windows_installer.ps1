# Windows PowerShell 5.1+. No administrator privileges are needed.
[CmdletBinding()]
param(
  [string]$Version,
  [ValidateRange(0,65535)][int]$BuildNumber,
  [string]$InnoCompiler,
  [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$staging = $null

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Program failed (exit $LASTEXITCODE)." }
}

function Find-InnoCompiler {
  if ($InnoCompiler) {
    if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) { throw "ISCC.exe not found: $InnoCompiler" }
    return (Resolve-Path -LiteralPath $InnoCompiler).Path
  }
  $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  foreach ($folder in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    if ($folder) {
      $candidate = Join-Path $folder 'Inno Setup 6\ISCC.exe'
      if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
  }
  throw 'Install Inno Setup 6.3 or newer, or pass -InnoCompiler "C:\path\ISCC.exe". https://jrsoftware.org/isdl.php'
}

function Find-VcRuntime {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Install Visual Studio 2022 with Desktop development with C++ (including MSVC, Windows SDK and CMake).'
  }
  $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Visual Studio C++ tools were not found. Run flutter doctor -v.' }
  $redist = Join-Path $installation 'VC\Redist\MSVC'
  if (Test-Path -LiteralPath $redist) {
    $versions = Get-ChildItem -LiteralPath $redist -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending
    foreach ($directory in $versions) {
      foreach ($crt in Get-ChildItem -Path (Join-Path $directory.FullName 'x64\Microsoft.VC*.CRT') -Directory -ErrorAction SilentlyContinue) {
        if ((Test-Path -LiteralPath (Join-Path $crt.FullName 'msvcp140.dll')) -and
            (Test-Path -LiteralPath (Join-Path $crt.FullName 'vcruntime140.dll'))) { return $crt.FullName }
      }
    }
  }
  throw 'MSVC x64 redistributable DLLs were not found. Add/update the MSVC C++ build tools in Visual Studio Installer.'
}

Push-Location $root
try {
  if ($env:OS -ne 'Windows_NT') { throw 'Run this build script on Windows.' }
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') {
    throw 'This release script targets Windows x64. Run it on an x64 Windows machine.'
  }
  $flutter = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $flutter) { throw 'Flutter was not found in PATH. Install Flutter SDK, add its bin directory to PATH and reopen the terminal.' }
  $iscc = Find-InnoCompiler
  $innoVersion = (Get-Item -LiteralPath $iscc).VersionInfo
  if ($innoVersion.FileMajorPart -lt 6 -or ($innoVersion.FileMajorPart -eq 6 -and $innoVersion.FileMinorPart -lt 3)) {
    throw 'Inno Setup 6.3 or newer is required.'
  }
  $runtime = Find-VcRuntime
  $pubspec = Get-Content -LiteralPath (Join-Path $root 'pubspec.yaml') -Raw
  $match = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*(?:#.*)?$')
  if (-not $match.Success) { throw 'Expected version: X.Y.Z+N in pubspec.yaml.' }
  if (-not $Version) { $Version = $match.Groups[1].Value }
  if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be X.Y.Z, for example 1.1.0.' }
  foreach ($part in $Version.Split('.')) {
    if ([long]$part -gt 65535) { throw 'Windows version components must be between 0 and 65535.' }
  }
  if (-not $PSBoundParameters.ContainsKey('BuildNumber')) {
    $number = if ($match.Groups[2].Success) { [long]$match.Groups[2].Value } else { 1 }
    if ($number -gt 65535) { throw 'Windows build number must be between 0 and 65535.' }
    $BuildNumber = [int]$number
  }
  Write-Host "Building Helper $Version+$BuildNumber (Windows x64)" -ForegroundColor Cyan
  Invoke-Checked $flutter.Source @('pub', 'get')
  if (-not $SkipTests) {
    Invoke-Checked $flutter.Source @('analyze', '--no-pub')
    Invoke-Checked $flutter.Source @('test', '--no-pub')
  }
  Invoke-Checked $flutter.Source @('build', 'windows', '--release', "--build-name=$Version", "--build-number=$BuildNumber", '--no-pub')
  $release = Join-Path $root 'build\windows\x64\runner\Release'
  foreach ($required in @('helper.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $required))) { throw "Build output missing: $required" }
  }
  # App-local redistributables let a clean Windows machine run the Flutter app
  # without asking the user to install a separate Visual C++ runtime.
  Get-ChildItem -LiteralPath $runtime -Filter '*.dll' -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $release -Force
  }
  $output = Join-Path $root "installer\output\v$Version"
  $staging = Join-Path $root ('installer\output\.build-' + [guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($staging)
  Write-Host 'Creating the Inno Setup installer and portable update...' -ForegroundColor Cyan
  Invoke-Checked $iscc @("/DAppVersion=$Version", "/O$staging", (Join-Path $root 'installer\helper.iss'))
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($release, (Join-Path $staging 'helper-windows-x64.zip'))
  $checksums = foreach ($name in @('helper-windows-x64-setup.exe', 'helper-windows-x64.zip')) {
    $file = Join-Path $staging $name
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing release artifact: $name" }
    '{0}  {1}' -f (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant(), $name
  }
  $checksums | Set-Content -LiteralPath (Join-Path $staging 'SHA256SUMS.txt') -Encoding ASCII
  # Publish only after every build/package operation succeeded. An unsuccessful
  # build leaves any previously completed output untouched.
  [void][IO.Directory]::CreateDirectory($output)
  foreach ($name in @('helper-windows-x64-setup.exe', 'helper-windows-x64.zip', 'SHA256SUMS.txt')) {
    Move-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $output $name) -Force
  }
  Write-Host "DONE: $output" -ForegroundColor Green
  Write-Host "Create GitHub Release v$Version and upload the EXE and ZIP from this directory."
  Write-Host 'The ZIP is required for the in-app updater. SHA256SUMS.txt is optional for publishing.'
} catch {
  Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
} finally {
  if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force }
  Pop-Location
}
