Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot '..\build_flutter_android.psm1'
Import-Module $modulePath -Force

Describe 'Get-AndroidBuildPlan' {
  It 'uses release mode by default and targets main.dart for native apk' {
    $plan = Get-AndroidBuildPlan `
      -ProjectRoot 'D:\repo' `
      -HasAndroidProject $true `
      -AndroidSdkPath 'D:\Android\Sdk'

    $plan.FlutterAppDir | Should Be 'D:\repo\flutter_app'
    $plan.OutputApkPath | Should Be 'D:\repo\flutter_app\build\app\outputs\flutter-apk\app-release.apk'
    $plan.Commands.Count | Should Be 3
    (($plan.Commands[2]) -join ' ') | Should Be 'puro flutter build apk --release --target lib/main_windows.dart'
  }

  It 'uses debug output when mode is Debug' {
    $plan = Get-AndroidBuildPlan `
      -ProjectRoot 'D:\repo' `
      -Mode 'Debug' `
      -HasAndroidProject $true `
      -AndroidSdkPath 'D:\Android\Sdk'

    $plan.OutputApkPath | Should Be 'D:\repo\flutter_app\build\app\outputs\flutter-apk\app-debug.apk'
    (($plan.Commands[2]) -join ' ') | Should Be 'puro flutter build apk --debug --target lib/main_windows.dart'
  }

  It 'falls back to D:\Android\Sdk when sdk path is not passed' {
    $plan = Get-AndroidBuildPlan -ProjectRoot 'D:\repo'
    $plan.AndroidSdkPath | Should Be 'D:\Android\Sdk'
  }

  It 'bootstraps android platform when android project is missing' {
    $plan = Get-AndroidBuildPlan `
      -ProjectRoot 'D:\repo' `
      -HasAndroidProject $false `
      -AndroidSdkPath 'D:\Android\Sdk'

    $plan.Commands.Count | Should Be 4
    (($plan.Commands[2]) -join ' ') | Should Be 'puro flutter create --platforms=android .'
    (($plan.Commands[3]) -join ' ') | Should Be 'puro flutter build apk --release --target lib/main_windows.dart'
  }
}

Describe 'Get-AndroidBuildRootPlan' {
  It 'does not require mapping for ascii paths' {
    $plan = Get-AndroidBuildRootPlan -ProjectRoot 'D:\repo'
    $plan.ShouldMap | Should Be $false
    $plan.BuildProjectRoot | Should Be 'D:\repo'
  }

  It 'requires mapping for non-ascii paths' {
    $plan = Get-AndroidBuildRootPlan -ProjectRoot 'D:\测试\repo'
    $plan.ShouldMap | Should Be $true
    $plan.BuildProjectRoot | Should Be 'X:\'
  }
}

Describe 'Resolve-AndroidOutputApkPath' {
  It 'resolves release apk path under original project root' {
    $path = Resolve-AndroidOutputApkPath -ProjectRoot 'D:\repo' -Mode 'Release'
    $path | Should Be 'D:\repo\flutter_app\build\app\outputs\flutter-apk\app-release.apk'
  }

  It 'resolves debug apk path under original project root' {
    $path = Resolve-AndroidOutputApkPath -ProjectRoot 'D:\repo' -Mode 'Debug'
    $path | Should Be 'D:\repo\flutter_app\build\app\outputs\flutter-apk\app-debug.apk'
  }
}

Describe 'Ensure-AndroidManifestNetworking' {
  It 'adds INTERNET permission and cleartext flag when missing' {
    $tmp = Join-Path $env:TEMP "android_manifest_test_$([guid]::NewGuid().ToString('N')).xml"
    @'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application
      android:label="smart_meeting_app"
      android:name="${applicationName}"
      android:icon="@mipmap/ic_launcher">
    <activity
        android:name=".MainActivity"
        android:exported="true">
    </activity>
  </application>
</manifest>
'@ | Set-Content -Path $tmp -Encoding utf8

    try {
      Ensure-AndroidManifestNetworking -ManifestPath $tmp
      $content = Get-Content -Path $tmp -Raw
      ($content -like '*android.permission.INTERNET*') | Should Be $true
      ($content -like '*android:usesCleartextTraffic="true"*') | Should Be $true
    } finally {
      if (Test-Path $tmp) { Remove-Item -Force $tmp }
    }
  }

  It 'is idempotent and does not duplicate entries' {
    $tmp = Join-Path $env:TEMP "android_manifest_test_$([guid]::NewGuid().ToString('N')).xml"
    @'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET" />
  <application
      android:label="smart_meeting_app"
      android:usesCleartextTraffic="true">
  </application>
</manifest>
'@ | Set-Content -Path $tmp -Encoding utf8

    try {
      Ensure-AndroidManifestNetworking -ManifestPath $tmp
      Ensure-AndroidManifestNetworking -ManifestPath $tmp
      $content = Get-Content -Path $tmp -Raw
      $internetCount = ([regex]::Matches($content, [regex]::Escape('android.permission.INTERNET'))).Count
      $cleartextCount = ([regex]::Matches($content, [regex]::Escape('android:usesCleartextTraffic="true"'))).Count
      $internetCount | Should Be 1
      $cleartextCount | Should Be 1
    } finally {
      if (Test-Path $tmp) { Remove-Item -Force $tmp }
    }
  }
}
