param(
    [string[]] $ExpectedAbi = @("arm64-v8a", "x86_64"),
    [string] $LibraryName = "libeasytier_android_jni.so",
    [string[]] $RequiredSymbol = @(
        "Java_com_easytier_jni_EasyTierJNI_callJsonRpc",
        "Java_com_easytier_jni_EasyTierJNI_listInstances"
    )
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$jniRoot = Join-Path $repoRoot "android/app/src/main/jniLibs"
$buildGradle = Join-Path $repoRoot "android/app/build.gradle.kts"
$localProperties = Join-Path $repoRoot "android/local.properties"

function Read-AndroidSdkFromLocalProperties() {
    if (-not (Test-Path $localProperties)) {
        return ""
    }

    foreach ($line in Get-Content $localProperties) {
        if ($line -match "^sdk\.dir=(.+)$") {
            return ($Matches[1] -replace "\\\\", "\").Trim()
        }
    }
    return ""
}

function Resolve-AndroidSdkPath() {
    foreach ($candidate in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, (Read-AndroidSdkFromLocalProperties))) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $resolved = Resolve-Path $candidate -ErrorAction SilentlyContinue
        if ($resolved) {
            return $resolved.Path
        }
    }
    return ""
}

function Resolve-NdkToolPath([string[]] $Names) {
    $androidSdk = Resolve-AndroidSdkPath
    if ([string]::IsNullOrWhiteSpace($androidSdk)) {
        return ""
    }
    $ndkRoot = Join-Path $androidSdk "ndk"
    if (-not (Test-Path $ndkRoot)) {
        return ""
    }
    $candidate = Get-ChildItem -Path $ndkRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $Names -contains $_.Name } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($candidate) {
        return $candidate.FullName
    }
    return ""
}

function Resolve-LlvmNmPath() {
    return Resolve-NdkToolPath @("llvm-nm", "llvm-nm.exe")
}

function Resolve-LlvmReadelfPath() {
    return Resolve-NdkToolPath @("llvm-readelf", "llvm-readelf.exe")
}

function Get-ExpectedElfMachine([string] $Abi) {
    switch ($Abi) {
        "arm64-v8a" { return "AArch64" }
        "x86_64" { return "Advanced Micro Devices X86-64" }
        default { return "" }
    }
}

function Assert-AndroidElfMachine {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Library,
        [Parameter(Mandatory = $true)]
        [string] $Abi,
        [Parameter(Mandatory = $true)]
        [string] $LlvmReadelf
    )

    $expectedMachine = Get-ExpectedElfMachine $Abi
    if ([string]::IsNullOrWhiteSpace($expectedMachine)) {
        Write-Warning "No ELF machine expectation is configured for Android ABI $Abi."
        return
    }

    $header = (& $LlvmReadelf -h $Library 2>$null) -join "`n"
    if (-not [regex]::IsMatch($header, "Machine:\s*$([regex]::Escape($expectedMachine))")) {
        throw "Android JNI library for ${Abi} has unexpected ELF machine. Expected ${expectedMachine}: $Library`n$header"
    }
}

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
$llvmNm = Resolve-LlvmNmPath
$llvmReadelf = Resolve-LlvmReadelfPath

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
    if (-not [string]::IsNullOrWhiteSpace($llvmReadelf)) {
        Assert-AndroidElfMachine -Library $library -Abi $abi -LlvmReadelf $llvmReadelf
    }
    if (-not [string]::IsNullOrWhiteSpace($llvmNm)) {
        $symbols = (& $llvmNm -D $library 2>$null) -join "`n"
        foreach ($symbol in $RequiredSymbol) {
            if (-not $symbols.Contains($symbol)) {
                throw "Android JNI library for ${abi} is missing required symbol ${symbol}: $library"
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($llvmNm)) {
    Write-Warning "llvm-nm was not found; skipped Android JNI required symbol checks."
}
if ([string]::IsNullOrWhiteSpace($llvmReadelf)) {
    Write-Warning "llvm-readelf was not found; skipped Android JNI ELF machine checks."
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
