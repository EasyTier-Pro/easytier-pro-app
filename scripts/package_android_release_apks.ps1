param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string] $OutputDir = (Join-Path $RepoRoot "dist")
)

$ErrorActionPreference = "Stop"

$apkDir = Join-Path $RepoRoot "build/app/outputs/flutter-apk"
$artifacts = [ordered]@{
    "app-arm64-v8a-release.apk" = "easytier-pro-android-arm64-v8a.apk"
    "app-x86_64-release.apk" = "easytier-pro-android-x86_64.apk"
}

New-Item -ItemType Directory -Force $OutputDir | Out-Null

foreach ($sourceName in $artifacts.Keys) {
    $source = Join-Path $apkDir $sourceName
    if (-not (Test-Path $source)) {
        throw "Expected Android release APK was not found: $source"
    }

    $destination = Join-Path $OutputDir $artifacts[$sourceName]
    Copy-Item $source $destination -Force
    $file = Get-Item $destination
    Write-Host "Packaged $($file.Name) ($($file.Length) bytes)"
}
