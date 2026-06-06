param(
    [string] $EasyTierRoot = "",
    [string] $EasyTierCommit = "13f2ebfe12f9a0a0d8294dbe325503da62381a40",
    [string] $AndroidSdk = "",
    [string] $NdkVersion = "28.2.13676358",
    [string[]] $Abi = @("arm64-v8a", "x86_64"),
    [switch] $SkipCopy,
    [switch] $SkipCommitCheck
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$jniOutputRoot = Join-Path $repoRoot "android\app\src\main\jniLibs"

function Resolve-FirstPath([string[]] $Candidates) {
    foreach ($candidate in $Candidates) {
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

function Read-AndroidSdkFromLocalProperties() {
    $localProperties = Join-Path $repoRoot "android\local.properties"
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

if ([string]::IsNullOrWhiteSpace($EasyTierRoot)) {
    $EasyTierRoot = Resolve-FirstPath @(
        (Join-Path $PSScriptRoot "..\..\EasyTier-android-jni-13f2"),
        (Join-Path $PSScriptRoot "..\..\EasyTier")
    )
}

if ([string]::IsNullOrWhiteSpace($EasyTierRoot)) {
    throw "EasyTierRoot was not provided and no sibling EasyTier checkout was found."
}

$EasyTierRoot = (Resolve-Path $EasyTierRoot).Path
$jniCrate = Join-Path $EasyTierRoot "easytier-contrib\easytier-android-jni"
if (-not (Test-Path (Join-Path $jniCrate "Cargo.toml"))) {
    throw "EasyTier Android JNI crate was not found at $jniCrate"
}

if (-not $SkipCommitCheck) {
    $currentCommit = (& git -C $EasyTierRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read EasyTier commit from $EasyTierRoot"
    }
    if ($currentCommit -ne $EasyTierCommit) {
        throw "EasyTier checkout is $currentCommit, expected $EasyTierCommit. Pass -SkipCommitCheck only when intentionally rebuilding another upstream revision."
    }
}

if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    $AndroidSdk = Resolve-FirstPath @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Read-AndroidSdkFromLocalProperties)
    )
}

if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    throw "Android SDK path was not provided. Set ANDROID_SDK_ROOT or pass -AndroidSdk."
}

$AndroidSdk = (Resolve-Path $AndroidSdk).Path
$ndkRoot = Join-Path $AndroidSdk "ndk\$NdkVersion"
if (-not (Test-Path $ndkRoot)) {
    throw "Android NDK $NdkVersion was not found at $ndkRoot"
}

$toolchainBin = Join-Path $ndkRoot "toolchains\llvm\prebuilt\windows-x86_64\bin"
$sysroot = Join-Path $ndkRoot "toolchains\llvm\prebuilt\windows-x86_64\sysroot"
$clang = Join-Path $toolchainBin "clang.exe"
$llvmAr = Join-Path $toolchainBin "llvm-ar.exe"
$readElf = Join-Path $toolchainBin "llvm-readelf.exe"

$targetMap = @{
    "arm64-v8a" = @{
        RustTarget = "aarch64-linux-android"
        ClangPrefix = "aarch64-linux-android21"
        IncludeTarget = "aarch64-linux-android"
    }
    "x86_64" = @{
        RustTarget = "x86_64-linux-android"
        ClangPrefix = "x86_64-linux-android21"
        IncludeTarget = "x86_64-linux-android"
    }
}

$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_SDK_ROOT = $AndroidSdk
$env:ANDROID_NDK_HOME = $ndkRoot
$env:ANDROID_NDK_ROOT = $ndkRoot
$env:CLANG_PATH = $clang

foreach ($abiName in $Abi) {
    if (-not $targetMap.ContainsKey($abiName)) {
        throw "Unsupported ABI '$abiName'. Supported values: $($targetMap.Keys -join ', ')"
    }

    $target = $targetMap[$abiName]
    $rustTarget = $target.RustTarget
    $clangPrefix = $target.ClangPrefix
    $includeTarget = $target.IncludeTarget
    $envSuffix = $rustTarget -replace "-", "_"
    $cargoTargetEnv = "CARGO_TARGET_$($envSuffix.ToUpperInvariant())_LINKER"
    $clangCmd = Join-Path $toolchainBin "$clangPrefix-clang.cmd"
    $sysrootArg = $sysroot -replace "\\", "/"
    $includeBase = "$sysrootArg/usr/include"
    $includeTargetPath = "$includeBase/$includeTarget"
    $bindgenArgs = "--sysroot=$sysrootArg -I$includeBase -I$includeTargetPath"

    Write-Host "Building EasyTier JNI for $abiName ($rustTarget)"
    & rustup target add $rustTarget
    if ($LASTEXITCODE -ne 0) {
        throw "rustup target add failed for $rustTarget"
    }

    Set-Item -Path "Env:CC_$envSuffix" -Value $clangCmd
    Set-Item -Path "Env:AR_$envSuffix" -Value $llvmAr
    Set-Item -Path "Env:$cargoTargetEnv" -Value $clangCmd
    Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS" -Value $bindgenArgs
    Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$rustTarget" -Value $bindgenArgs
    Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$envSuffix" -Value $bindgenArgs

    Push-Location $jniCrate
    try {
        & cargo build --target $rustTarget --release
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed for $rustTarget"
        }
    } finally {
        Pop-Location
    }

    $builtLibrary = Join-Path $EasyTierRoot "target\$rustTarget\release\libeasytier_android_jni.so"
    if (-not (Test-Path $builtLibrary)) {
        throw "Expected JNI library was not produced: $builtLibrary"
    }

    if (Test-Path $readElf) {
        Write-Host "Dynamic dependencies for ${abiName}:"
        & $readElf -d $builtLibrary | Select-String -Pattern "NEEDED|SONAME"
    }

    if (-not $SkipCopy) {
        $abiOutput = Join-Path $jniOutputRoot $abiName
        New-Item -ItemType Directory -Force $abiOutput | Out-Null
        Copy-Item -LiteralPath $builtLibrary -Destination (Join-Path $abiOutput "libeasytier_android_jni.so") -Force
    }

    $hash = Get-FileHash $builtLibrary -Algorithm SHA256
    Write-Host "$abiName SHA256 $($hash.Hash)"
}
