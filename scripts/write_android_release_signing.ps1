param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$requiredEnvVars = @(
    "ANDROID_RELEASE_KEYSTORE_BASE64",
    "ANDROID_RELEASE_STORE_PASSWORD",
    "ANDROID_RELEASE_KEY_ALIAS",
    "ANDROID_RELEASE_KEY_PASSWORD"
)

$missing = $requiredEnvVars | Where-Object {
    [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_))
}
if ($missing.Count -gt 0) {
    throw "Missing Android release signing secrets: $($missing -join ', ')"
}

$androidRoot = Join-Path $RepoRoot "android"
$keystorePath = Join-Path $androidRoot "easytier-pro-release.jks"
$keyPropertiesPath = Join-Path $androidRoot "key.properties"

$base64 = $env:ANDROID_RELEASE_KEYSTORE_BASE64 -replace "\s", ""
try {
    $keystoreBytes = [Convert]::FromBase64String($base64)
} catch {
    throw "ANDROID_RELEASE_KEYSTORE_BASE64 is not valid base64."
}

[System.IO.File]::WriteAllBytes($keystorePath, $keystoreBytes)

$keyProperties = @(
    "storeFile=easytier-pro-release.jks",
    "storePassword=$env:ANDROID_RELEASE_STORE_PASSWORD",
    "keyAlias=$env:ANDROID_RELEASE_KEY_ALIAS",
    "keyPassword=$env:ANDROID_RELEASE_KEY_PASSWORD"
) -join [Environment]::NewLine

[System.IO.File]::WriteAllText(
    $keyPropertiesPath,
    $keyProperties + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Android release signing files written."
