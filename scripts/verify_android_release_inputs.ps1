param(
    [switch] $RequireSigning
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$androidRoot = Join-Path $repoRoot "android"
$buildGradle = Join-Path $androidRoot "app\build.gradle.kts"
$mainManifest = Join-Path $androidRoot "app\src\main\AndroidManifest.xml"
$debugManifest = Join-Path $androidRoot "app\src\debug\AndroidManifest.xml"
$profileManifest = Join-Path $androidRoot "app\src\profile\AndroidManifest.xml"
$fileProviderPaths = Join-Path $androidRoot "app\src\main\res\xml\easytier_file_paths.xml"
$androidGitIgnore = Join-Path $androidRoot ".gitignore"
$keyProperties = Join-Path $androidRoot "key.properties"

function Assert-FileExists([string] $Path, [string] $Description) {
    if (-not (Test-Path $Path)) {
        throw "$Description was not found: $Path"
    }
}

function Assert-Matches([string] $Text, [string] $Pattern, [string] $Description) {
    if (-not [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        throw $Description
    }
}

function Read-KeyProperties([string] $Path) {
    $values = @{}
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
            continue
        }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -eq 2) {
            $values[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $values
}

& (Join-Path $PSScriptRoot "verify_android_jni_libs.ps1")

Assert-FileExists $buildGradle "Android app Gradle file"
Assert-FileExists $mainManifest "Android main manifest"
Assert-FileExists $debugManifest "Android debug manifest"
Assert-FileExists $profileManifest "Android profile manifest"
Assert-FileExists $fileProviderPaths "Android diagnostics FileProvider paths"
Assert-FileExists $androidGitIgnore "Android gitignore"

$gradleText = Get-Content -Path $buildGradle -Raw
Assert-Matches `
    $gradleText `
    'val\s+easyTierProApplicationId\s*=\s*"net\.easytier\.pro"' `
    "Android release applicationId must remain net.easytier.pro."
Assert-Matches `
    $gradleText `
    'applicationId\s*=\s*easyTierProApplicationId' `
    "Android defaultConfig must use easyTierProApplicationId."
Assert-Matches `
    $gradleText `
    'Release signing requires android/key\.properties' `
    "Release builds must fail when android/key.properties is missing."

$mainManifestText = Get-Content -Path $mainManifest -Raw
Assert-Matches `
    $mainManifestText `
    'android\.permission\.BIND_VPN_SERVICE' `
    "Android main manifest must declare the VPN service binding permission."
Assert-Matches `
    $mainManifestText `
    'android\.net\.VpnService' `
    "Android main manifest must declare the VpnService intent action."
Assert-Matches `
    $mainManifestText `
    'android:foregroundServiceType="specialUse"' `
    "Android main manifest must declare the specialUse foreground service type."
Assert-Matches `
    $mainManifestText `
    'androidx\.core\.content\.FileProvider' `
    "Android main manifest must declare a FileProvider for diagnostics export."
Assert-Matches `
    $mainManifestText `
    'android:authorities="\$\{applicationId\}\.fileprovider"' `
    "Android diagnostics FileProvider authority must follow the release applicationId."
Assert-Matches `
    $mainManifestText `
    '@xml/easytier_file_paths' `
    "Android diagnostics FileProvider must reference easytier_file_paths."
if ([regex]::IsMatch($mainManifestText, 'usesCleartextTraffic\s*=\s*"true"')) {
    throw "Android main manifest must not enable cleartext traffic for release builds."
}

$fileProviderPathsText = Get-Content -Path $fileProviderPaths -Raw
Assert-Matches `
    $fileProviderPathsText `
    '<cache-path\b' `
    "Android diagnostics FileProvider paths must expose app cache logs."

$debugManifestText = Get-Content -Path $debugManifest -Raw
$profileManifestText = Get-Content -Path $profileManifest -Raw
Assert-Matches `
    $debugManifestText `
    'usesCleartextTraffic\s*=\s*"true"' `
    "Android debug manifest should keep cleartext traffic enabled for local E2E."
Assert-Matches `
    $profileManifestText `
    'usesCleartextTraffic\s*=\s*"true"' `
    "Android profile manifest should keep cleartext traffic enabled for local E2E."

$gitIgnoreText = Get-Content -Path $androidGitIgnore -Raw
Assert-Matches $gitIgnoreText '(^|\r?\n)key\.properties(\r?\n|$)' `
    "android/.gitignore must ignore key.properties."
Assert-Matches $gitIgnoreText '(^|\r?\n)\*\*/\*\.jks(\r?\n|$)' `
    "android/.gitignore must ignore JKS files."
Assert-Matches $gitIgnoreText '(^|\r?\n)\*\*/\*\.keystore(\r?\n|$)' `
    "android/.gitignore must ignore keystore files."

if ($RequireSigning) {
    Assert-FileExists $keyProperties "Android release signing properties"
    $properties = Read-KeyProperties $keyProperties
    $requiredKeys = @("storeFile", "storePassword", "keyAlias", "keyPassword")
    $missing = $requiredKeys | Where-Object {
        -not $properties.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($properties[$_])
    }
    if ($missing.Count -gt 0) {
        throw "android/key.properties is missing required keys: $($missing -join ', ')"
    }

    $storeFile = $properties["storeFile"]
    if ([System.IO.Path]::IsPathRooted($storeFile)) {
        $storePath = $storeFile
    } else {
        $storePath = Join-Path $androidRoot $storeFile
    }
    if (-not (Test-Path $storePath)) {
        throw "Android release keystore was not found: $storePath"
    }
    Write-Host "Android release signing inputs verified: $storePath"
} else {
    Write-Host "Android release signing input check skipped. Pass -RequireSigning before producing release artifacts."
}

Write-Host "Android release input verification passed."
