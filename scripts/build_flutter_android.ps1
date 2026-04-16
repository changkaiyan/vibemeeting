param(
  [ValidateSet('Debug', 'Release')]
  [string]$Mode = 'Release',
  [string]$AndroidSdkPath,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'build_flutter_android.psm1'
Import-Module $modulePath -Force

$projectRoot = Split-Path -Parent $PSScriptRoot
Invoke-AndroidBuild `
  -ProjectRoot $projectRoot `
  -Mode $Mode `
  -AndroidSdkPath $AndroidSdkPath `
  -DryRun:$DryRun
