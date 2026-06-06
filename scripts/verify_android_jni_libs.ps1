param(
    [string[]] $ExpectedAbi = @("arm64-v8a", "x86_64"),
    [string] $LibraryName = "libeasytier_android_jni.so"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$jniRoot = Join-Path $repoRoot "android\app\src\main\jniLibs"
$buildGradle = Join-Path $repoRoot "android\app\build.gradle.kts"

if (-not (Test-Path $jniRoot)) {
    throw "Android JNI directory was not found: $jniRoot"
}
if (-not (Test-Path $buildGradle)) {
    throw "Android app Gradle file was not found: $buildGradle"
}

$expected = $ExpectedAbi |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_.Length -gt 0 } |
    Select-Object -Unique
if ($expected.Count -eq 0) {
    throw "ExpectedAbi must contain at least one ABI."
}

$actual = Get-ChildItem -Path $jniRoot -Directory |
    Select-Object -ExpandProperty Name |
    Sort-Object
$expectedSorted = $expected | Sort-Object

$missing = $expectedSorted | Where-Object { $actual -notcontains $_ }
$unexpected = $actual | Where-Object { $expectedSorted -notcontains $_ }
if ($missing.Count -gt 0) {
    throw "Missing Android JNI ABI directories: $($missing -join ', ')"
}
if ($unexpected.Count -gt 0) {
    throw "Unexpected Android JNI ABI directories: $($unexpected -join ', ')"
}

foreach ($abi in $expectedSorted) {
    $library = Join-Path (Join-Path $jniRoot $abi) $LibraryName
    if (-not (Test-Path $library)) {
        throw "Missing Android JNI library for ${abi}: $library"
    }
    $file = Get-Item -LiteralPath $library
    if ($file.Length -le 0) {
        throw "Android JNI library for ${abi} is empty: $library"
    }
    $hash = Get-FileHash -LiteralPath $library -Algorithm SHA256
    Write-Host "$abi $LibraryName $($file.Length) bytes SHA256 $($hash.Hash)"
}

$gradleText = Get-Content -Path $buildGradle -Raw
$match = [regex]::Match(
    $gradleText,
    'val\s+releaseAbiFilters\s*=\s*listOf\((?<abis>[^)]*)\)',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if (-not $match.Success) {
    throw "Could not find releaseAbiFilters in $buildGradle"
}

$gradleAbis = [regex]::Matches($match.Groups["abis"].Value, '"([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Sort-Object
$gradleMissing = $expectedSorted | Where-Object { $gradleAbis -notcontains $_ }
$gradleUnexpected = $gradleAbis | Where-Object { $expectedSorted -notcontains $_ }
if ($gradleMissing.Count -gt 0 -or $gradleUnexpected.Count -gt 0) {
    throw "releaseAbiFilters [$($gradleAbis -join ', ')] do not match JNI ABIs [$($expectedSorted -join ', ')]"
}

Write-Host "Android JNI ABI verification passed: $($expectedSorted -join ', ')"
