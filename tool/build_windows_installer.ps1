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
  $candidates = @()
  foreach ($folder in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($folder) {
      $candidates += @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^Inno Setup \d+$' } |
          ForEach-Object {
            $candidate = Join-Path $_.FullName 'ISCC.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
              [pscustomobject]@{ Path = $candidate; Major = [int]($_.Name -replace '^Inno Setup ', '') }
            }
          })
    }
  }
  if ($candidates.Count -gt 0) { return ($candidates | Sort-Object Major -Descending | Select-Object -First 1).Path }
  throw 'Install Inno Setup 6.3 or newer, or pass -InnoCompiler "C:\path\ISCC.exe". https://jrsoftware.org/isdl.php'
}

function Test-InnoVersion([string]$Compiler) {
  # Some ISCC builds (including Inno Setup 7) have FileVersion 0.0.0.0.
  # Ask the actual compiler instead; /? may return a non-zero help exit code.
  $savedPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $banner = (& $Compiler '/?' 2>&1 | Out-String)
  } finally { $ErrorActionPreference = $savedPreference }
  $versionMatch = [regex]::Match($banner, '(?i)Inno Setup\s+(\d+)\.(\d+)(?:\.\d+)?')
  if ($versionMatch.Success) {
    $major = [int]$versionMatch.Groups[1].Value
    $minor = [int]$versionMatch.Groups[2].Value
  } else {
    $metadata = (Get-Item -LiteralPath $Compiler).VersionInfo
    $major = $metadata.FileMajorPart
    $minor = $metadata.FileMinorPart
    $majorMatch = [regex]::Match($banner, '(?i)Inno Setup\s+(\d+)\b')
    # A major-only banner is sufficient for 7+, but not for distinguishing
    # Inno Setup 6.0 from 6.3. Unknown 6.x falls back to the actual compilation.
    if ($majorMatch.Success -and [int]$majorMatch.Groups[1].Value -ge 7) {
      $major = [int]$majorMatch.Groups[1].Value
      $minor = 0
    }
  }
  if ($major -eq 0) {
    Write-Warning 'ISCC version is not reported. Continuing; the installer compilation will validate support for the required features.'
  } elseif ($major -lt 6 -or ($major -eq 6 -and $minor -lt 3)) {
    throw "Inno Setup 6.3 or newer is required (detected $major.$minor). Compiler: $Compiler"
  }
  Write-Host "Inno Setup compiler: $Compiler"
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
  Test-InnoVersion $iscc
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
