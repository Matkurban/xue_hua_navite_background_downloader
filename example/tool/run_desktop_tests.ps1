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
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$FlutterArgs
  )
  Push-Location $WorkingDirectory
  try {
    & $Flutter @FlutterArgs
    if ($LASTEXITCODE -ne 0) {
      throw "flutter $($FlutterArgs -join ' ') failed with exit $LASTEXITCODE"
    }
  } finally {
    Pop-Location
  }
}

Write-Host '== flutter analyze =='
Invoke-Flutter -WorkingDirectory $RepoDir analyze
Invoke-Flutter -WorkingDirectory $ExampleDir analyze

Write-Host '== flutter build windows (example) =='
Invoke-Flutter -WorkingDirectory $ExampleDir build windows

Write-Host '== plugin unit tests =='
Invoke-Flutter -WorkingDirectory $RepoDir test

Write-Host '== example widget test =='
Invoke-Flutter -WorkingDirectory $ExampleDir test test/widget_test.dart

Write-Host '== example integration tests (one process per file) =='
$files = Get-ChildItem -Path (Join-Path $ExampleDir 'integration_test') -Filter '*_test.dart'
if (-not $files) {
  throw 'no integration_test/*_test.dart files'
}
foreach ($file in $files) {
  Write-Host "-- $($file.Name)"
  Invoke-Flutter -WorkingDirectory $ExampleDir test -d windows $file.FullName
}

Write-Host '== flutter_driver example UI =='
if ($env:XUEHUA_DOWNLOAD_DIR) {
  $DownloadDir = $env:XUEHUA_DOWNLOAD_DIR
} else {
  $DownloadDir = Join-Path $env:USERPROFILE 'Downloads\XueHuaDownloads'
}
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
Get-ChildItem -Path $DownloadDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
Invoke-Flutter -WorkingDirectory $ExampleDir drive `
  --driver=test_driver/app_test.dart `
  --target=test_driver/app.dart `
  -d windows

Write-Host 'windows checks passed.'
