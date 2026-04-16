Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AndroidSdkPath {
  param(
    [string]$AndroidSdkPath
  )

  if (-not [string]::IsNullOrWhiteSpace($AndroidSdkPath)) {
    return $AndroidSdkPath
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
    return $env:ANDROID_SDK_ROOT
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
    return $env:ANDROID_HOME
  }
  return 'D:\Android\Sdk'
}

function Get-AndroidBuildRootPlan {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [string]$MappedDrive = 'X:'
  )

  $shouldMap = $ProjectRoot -match '[^\x00-\x7F]'
  $buildProjectRoot = if ($shouldMap) { "$MappedDrive\" } else { $ProjectRoot }

  return [pscustomobject]@{
    OriginalProjectRoot = $ProjectRoot
    MappedDrive = $MappedDrive
    ShouldMap = $shouldMap
    BuildProjectRoot = $buildProjectRoot
  }
}

function Resolve-AndroidOutputApkPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Release'
  )

  $apkName = if ($Mode -eq 'Debug') { 'app-debug.apk' } else { 'app-release.apk' }
  return Join-Path $ProjectRoot "flutter_app\build\app\outputs\flutter-apk\$apkName"
}

function Ensure-AndroidManifestNetworking {
  param(
    [string]$ProjectRoot,
    [string]$ManifestPath
  )

  $targetManifestPath = $ManifestPath
  if ([string]::IsNullOrWhiteSpace($targetManifestPath)) {
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
      throw 'Either ProjectRoot or ManifestPath must be provided.'
    }
    $targetManifestPath = Join-Path $ProjectRoot 'flutter_app\android\app\src\main\AndroidManifest.xml'
  }

  if (-not (Test-Path $targetManifestPath)) {
    throw "Android manifest not found: $targetManifestPath"
  }

  $content = Get-Content -Path $targetManifestPath -Raw
  $updated = $content

  if ($updated -notmatch 'android\.permission\.INTERNET') {
    $updated = $updated -replace '(<manifest\b[^>]*>)', "`$1`r`n  <uses-permission android:name=`"android.permission.INTERNET`" />"
  }

  if ($updated -notmatch 'android:usesCleartextTraffic=') {
    $updated = $updated -replace '<application\b', '<application android:usesCleartextTraffic="true"'
  }

  if ($updated -ne $content) {
    Set-Content -Path $targetManifestPath -Value $updated -Encoding utf8
  }
}

function Get-AndroidBuildPlan {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Release',
    [object]$HasAndroidProject = $null,
    [string]$AndroidSdkPath
  )

  $resolvedSdkPath = Resolve-AndroidSdkPath -AndroidSdkPath $AndroidSdkPath
  $flutterAppDir = Join-Path $ProjectRoot 'flutter_app'
  $androidDir = Join-Path $flutterAppDir 'android'
  $hasAndroid = if ($null -eq $HasAndroidProject) { Test-Path $androidDir } else { [bool]$HasAndroidProject }
  $target = 'lib/main_windows.dart'
  $buildFlag = if ($Mode -eq 'Debug') { '--debug' } else { '--release' }

  $commands = New-Object 'System.Collections.Generic.List[string[]]'
  $commands.Add(@('puro', 'flutter', 'config', '--android-sdk', $resolvedSdkPath))
  $commands.Add(@('puro', 'flutter', 'pub', 'get'))
  if (-not $hasAndroid) {
    $commands.Add(@('puro', 'flutter', 'create', '--platforms=android', '.'))
  }
  $commands.Add(@('puro', 'flutter', 'build', 'apk', $buildFlag, '--target', $target))

  return [pscustomobject]@{
    ProjectRoot = $ProjectRoot
    Mode = $Mode
    AndroidSdkPath = $resolvedSdkPath
    FlutterAppDir = $flutterAppDir
    HasAndroidProject = $hasAndroid
    Target = $target
    OutputApkPath = Resolve-AndroidOutputApkPath -ProjectRoot $ProjectRoot -Mode $Mode
    Commands = $commands.ToArray()
  }
}

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Command
  )

  if ($Command.Count -eq 0) {
    throw 'Command is empty.'
  }

  $filePath = $Command[0]
  $arguments = if ($Command.Count -gt 1) { $Command[1..($Command.Count - 1)] } else { @() }

  & $filePath @arguments
  if ($LASTEXITCODE -ne 0) {
    $joined = $arguments -join ' '
    throw "Command failed ($LASTEXITCODE): $filePath $joined"
  }
}

function Invoke-AndroidBuild {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [ValidateSet('Debug', 'Release')]
    [string]$Mode = 'Release',
    [string]$AndroidSdkPath,
    [switch]$DryRun
  )

  $rootPlan = Get-AndroidBuildRootPlan -ProjectRoot $ProjectRoot
  $usingMappedDrive = $false

  if ($rootPlan.ShouldMap) {
    $existing = subst | Where-Object { $_ -like "$($rootPlan.MappedDrive)*=>*" }
    if ($existing) {
      $mappedPath = ($existing -split '=>', 2)[1].Trim()
      $normalizedMappedPath = [System.IO.Path]::GetFullPath($mappedPath).TrimEnd('\')
      $normalizedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
      if (-not $normalizedMappedPath.Equals($normalizedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$($rootPlan.MappedDrive) is already mapped to '$mappedPath'. Please release it first."
      }
    } elseif (-not $DryRun) {
      subst $rootPlan.MappedDrive $ProjectRoot
      $usingMappedDrive = $true
    }
  }

  $effectiveProjectRoot = if ($rootPlan.ShouldMap -and -not $DryRun) {
    $rootPlan.BuildProjectRoot
  } else {
    $ProjectRoot
  }

  $plan = Get-AndroidBuildPlan -ProjectRoot $effectiveProjectRoot -Mode $Mode -AndroidSdkPath $AndroidSdkPath
  $finalOutputApkPath = Resolve-AndroidOutputApkPath -ProjectRoot $ProjectRoot -Mode $Mode

  try {
    if ($DryRun) {
      $sourceFlutterAppDir = Join-Path $ProjectRoot 'flutter_app'
      if (-not (Test-Path $sourceFlutterAppDir)) {
        throw "Flutter app directory not found: $sourceFlutterAppDir"
      }
      if (-not (Test-Path $plan.AndroidSdkPath)) {
        throw "Android SDK path not found: $($plan.AndroidSdkPath)"
      }

      Write-Host "Android SDK: $($plan.AndroidSdkPath)"
      if ($rootPlan.ShouldMap) {
        Write-Host "Non-ASCII path detected; runtime build uses $($rootPlan.MappedDrive) mapping."
      }
      Write-Host 'Commands:'
      foreach ($command in $plan.Commands) {
        Write-Host "  $($command -join ' ')"
      }
      Write-Host "Expected output: $finalOutputApkPath"
      return $plan
    }

    if (-not (Test-Path $plan.FlutterAppDir)) {
      throw "Flutter app directory not found: $($plan.FlutterAppDir)"
    }
    if (-not (Test-Path $plan.AndroidSdkPath)) {
      throw "Android SDK path not found: $($plan.AndroidSdkPath)"
    }

    $originalAndroidSdkRoot = $env:ANDROID_SDK_ROOT
    $originalAndroidHome = $env:ANDROID_HOME

    Push-Location $plan.FlutterAppDir
    try {
      $env:ANDROID_SDK_ROOT = $plan.AndroidSdkPath
      $env:ANDROID_HOME = $plan.AndroidSdkPath

      foreach ($command in $plan.Commands) {
        $isBuildCommand = $command.Count -ge 4 -and
          $command[0] -eq 'puro' -and
          $command[1] -eq 'flutter' -and
          $command[2] -eq 'build'
        if ($isBuildCommand) {
          Ensure-AndroidManifestNetworking -ProjectRoot $effectiveProjectRoot
        }
        Invoke-CheckedCommand -Command $command
      }
    } finally {
      Pop-Location
      $env:ANDROID_SDK_ROOT = $originalAndroidSdkRoot
      $env:ANDROID_HOME = $originalAndroidHome
    }
  } finally {
    if ($usingMappedDrive) {
      subst $rootPlan.MappedDrive /d
    }
  }

  if (-not (Test-Path $finalOutputApkPath)) {
    throw "APK output not found: $finalOutputApkPath"
  }

  Write-Host 'Build complete:'
  Write-Host $finalOutputApkPath
  return $plan
}

Export-ModuleMember -Function Resolve-AndroidSdkPath, Get-AndroidBuildRootPlan, Resolve-AndroidOutputApkPath, Ensure-AndroidManifestNetworking, Get-AndroidBuildPlan, Invoke-AndroidBuild
