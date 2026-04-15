param(
  [ValidateSet('Debug', 'Release')]
  [string]$Mode = 'Debug'
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    $joined = $Arguments -join ' '
    throw "Command failed ($LASTEXITCODE): $FilePath $joined"
  }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterAppDir = Join-Path $projectRoot 'flutter_app'
$target = 'lib/main_windows.dart'
$mappedDrive = 'X:'
$usingMappedDrive = $false

if ($Mode -eq 'Release' -and $projectRoot -match '[^\x00-\x7F]') {
  $existing = subst | Where-Object { $_ -like "$mappedDrive*=>*" }
  if ($existing) {
    $mappedPath = ($existing -split '=>', 2)[1].Trim()
    if ($mappedPath -ne $projectRoot) {
      throw "$mappedDrive is already mapped to '$mappedPath'. Please release it first."
    }
  } else {
    subst $mappedDrive $projectRoot
    $usingMappedDrive = $true
  }
  $flutterAppDir = Join-Path "$mappedDrive\" 'flutter_app'
}

Push-Location $flutterAppDir
try {
  Invoke-Checked 'puro' @('flutter', 'pub', 'get')

  if ($Mode -eq 'Release') {
    Invoke-Checked 'puro' @('flutter', 'build', 'windows', '--release', '--target', $target)
    $output = 'build\windows\x64\runner\Release\smart_meeting_app.exe'
    $runnerDir = Join-Path $flutterAppDir 'build\windows\x64\runner\Release'
  } else {
    Invoke-Checked 'puro' @('flutter', 'build', 'windows', '--debug', '--target', $target)
    $output = 'build\windows\x64\runner\Debug\smart_meeting_app.exe'
    $runnerDir = Join-Path $flutterAppDir 'build\windows\x64\runner\Debug'
  }

  $staleFiles = @(
    'webview_windows_plugin.dll',
    'WebView2Loader.dll'
  )
  foreach ($name in $staleFiles) {
    $targetPath = Join-Path $runnerDir $name
    if (Test-Path $targetPath) {
      Remove-Item $targetPath -Force
    }
  }

  Write-Host "Build complete:"
  Write-Host "$flutterAppDir\\$output"
} finally {
  Pop-Location
  if ($usingMappedDrive) {
    subst $mappedDrive /d
  }
}
