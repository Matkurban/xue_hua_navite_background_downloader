# Desktop checks for the example app on Windows.
#
# Runs analyze, the Windows build, unit tests, each integration_test file in
# its own process, then flutter_driver. A single `flutter test integration_test/`
# reuses the desktop device and often fails on the second file.
#
# Usage:
#   pwsh example/tool/run_desktop_tests.ps1
#   $env:FLUTTER_BIN = 'C:\flutter\bin\flutter.bat'; pwsh example/tool/run_desktop_tests.ps1
# Override the download folder with XUEHUA_DOWNLOAD_DIR when it is not
# %USERPROFILE%\Downloads\XueHuaDownloads.
#
# MSBuild .tlog files under example/build can exceed MAX_PATH when the repo
# lives in a long path such as C:\Users\...\StudioProjects\... . Clone to a
# short directory, or point one at the repo:
#   New-Item -ItemType Junction -Path C:\bgdl -Target C:\path\to\this\repo
#   cd C:\bgdl\example
# Do not re-enable windows/CMakeLists.txt googletest while that guard is
# if(FALSE). if(FALSE AND ...) breaks CMake configure.
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ExampleDir = Split-Path -Parent $ScriptDir
$RepoDir = Split-Path -Parent $ExampleDir

if ($env:FLUTTER_BIN) {
  $Flutter = $env:FLUTTER_BIN
} else {
  $Flutter = 'flutter'
}

function Invoke-Flutter {
  param(
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string[]]$ArgumentList
  )
  # ArgumentList is a single array so tokens such as -d are not bound to
  # common parameters. -d is an unambiguous prefix of -Debug on an advanced
  # function, which previously dropped the Windows device id.
  Push-Location $WorkingDirectory
  try {
    & $Flutter @ArgumentList
    if ($LASTEXITCODE -ne 0) {
      throw "flutter $($ArgumentList -join ' ') failed with exit $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

Write-Host '== flutter analyze =='
Invoke-Flutter -WorkingDirectory $RepoDir -ArgumentList @('analyze')
Invoke-Flutter -WorkingDirectory $ExampleDir -ArgumentList @('analyze')

Write-Host '== flutter build windows (example) =='
Invoke-Flutter -WorkingDirectory $ExampleDir -ArgumentList @('build', 'windows')

Write-Host '== plugin unit tests =='
Invoke-Flutter -WorkingDirectory $RepoDir -ArgumentList @('test')

Write-Host '== example widget test =='
Invoke-Flutter -WorkingDirectory $ExampleDir -ArgumentList @('test', 'test/widget_test.dart')

Write-Host '== example integration tests (one process per file) =='
$files = Get-ChildItem -Path (Join-Path $ExampleDir 'integration_test') -Filter '*_test.dart'
if (-not $files) {
  throw 'no integration_test/*_test.dart files'
}
foreach ($file in $files) {
  Write-Host "-- $($file.Name)"
  Invoke-Flutter -WorkingDirectory $ExampleDir -ArgumentList @(
    'test', '--device-id=windows', $file.FullName)
}

Write-Host '== flutter_driver example UI =='
# Clear Downloads and TEMP. The plugin uses TEMP when the OS has no Downloads folder.
$DownloadDirs = @()
if ($env:XUEHUA_DOWNLOAD_DIR) {
  $DownloadDirs += $env:XUEHUA_DOWNLOAD_DIR
} else {
  $DownloadDirs += (Join-Path $env:USERPROFILE 'Downloads\XueHuaDownloads')
  if ($env:TEMP) {
    $DownloadDirs += (Join-Path $env:TEMP 'XueHuaDownloads')
  }
}
foreach ($DownloadDir in $DownloadDirs) {
  New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
  Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
}
Invoke-Flutter -WorkingDirectory $ExampleDir -ArgumentList @(
  'drive',
  '--driver=test_driver/app_test.dart',
  '--target=test_driver/app.dart',
  '--device-id=windows')

Write-Host 'windows checks passed.'
