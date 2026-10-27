param(
    [string] $EasyTierRoot = "",
    [string] $EasyTierCommit = "48ccc56a1aa4a63ec5192f71e85b330b155f0136",
    [string] $AndroidSdk = "",
    [string] $NdkVersion = "28.2.13676358",
    [string[]] $Abi = @("arm64-v8a", "x86_64"),
    [switch] $SkipCopy,
    [switch] $SkipCommitCheck
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$jniOutputRoot = Join-Path $repoRoot "android/app/src/main/jniLibs"

function Resolve-NdkHostTag() {
    if ($PSVersionTable.PSEdition -eq "Desktop" -or $IsWindows) {
        return "windows-x86_64"
    }
    if ($IsLinux) {
        return "linux-x86_64"
    }
    if ($IsMacOS) {
        return "darwin-x86_64"
    }
    throw "Unsupported host OS for Android NDK toolchain."
}

function Resolve-ToolPath([string] $Directory, [string[]] $Names) {
    foreach ($name in $Names) {
        $candidate = Join-Path $Directory $name
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }
    throw "Required Android NDK tool was not found in $Directory. Tried: $($Names -join ', ')"
}

function Resolve-LibclangPath([string[]] $Directories) {
    foreach ($directory in $Directories) {
        if (-not (Test-Path $directory)) {
            continue
        }
        $libclang = Get-ChildItem -Path $directory -Filter "libclang*" -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($libclang) {
            return $libclang.DirectoryName
        }
    }
    return ""
}

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
    $localProperties = Join-Path $repoRoot "android/local.properties"
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
        (Join-Path $PSScriptRoot "../../EasyTier")
    )
}

if ([string]::IsNullOrWhiteSpace($EasyTierRoot)) {
    throw "EasyTierRoot was not provided and no sibling EasyTier checkout was found."
}

$EasyTierRoot = (Resolve-Path $EasyTierRoot).Path
$jniCrate = Join-Path $EasyTierRoot "easytier-contrib/easytier-android-jni"
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

$mobilePatch = Join-Path $PSScriptRoot "mobile_core.patch"
& git -C $EasyTierRoot apply --reverse --check $mobilePatch 2>$null
if ($LASTEXITCODE -ne 0) {
    & git -C $EasyTierRoot apply --check $mobilePatch
    if ($LASTEXITCODE -ne 0) {
        throw "Shared mobile core patch does not match the EasyTier checkout."
    }
    & git -C $EasyTierRoot apply $mobilePatch
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply shared mobile core patch."
    }
}
Write-Host "Mobile core patch SHA256 $((Get-FileHash $mobilePatch -Algorithm SHA256).Hash)"

if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) {
    $gitCommonDir = (& git -C $EasyTierRoot rev-parse --path-format=absolute --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve the main EasyTier checkout."
    }
    $env:CARGO_TARGET_DIR = Join-Path (Split-Path $gitCommonDir -Parent) "target"
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
$ndkRoot = Join-Path $AndroidSdk "ndk/$NdkVersion"
if (-not (Test-Path $ndkRoot)) {
    throw "Android NDK $NdkVersion was not found at $ndkRoot"
}

$ndkHostTag = Resolve-NdkHostTag
$toolchainRoot = Join-Path $ndkRoot "toolchains/llvm/prebuilt/$ndkHostTag"
$toolchainBin = Join-Path $toolchainRoot "bin"
$sysroot = Join-Path $toolchainRoot "sysroot"
$clang = Resolve-ToolPath $toolchainBin @("clang.exe", "clang")
$llvmAr = Resolve-ToolPath $toolchainBin @("llvm-ar.exe", "llvm-ar")
$readElf = Resolve-ToolPath $toolchainBin @("llvm-readelf.exe", "llvm-readelf")
$libclangPath = Resolve-LibclangPath @($toolchainBin, (Join-Path $toolchainRoot "lib64"))

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
if (-not [string]::IsNullOrWhiteSpace($libclangPath)) {
    $env:LIBCLANG_PATH = $libclangPath
}

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
    $clangCmd = Resolve-ToolPath $toolchainBin @("$clangPrefix-clang.cmd", "$clangPrefix-clang")
    $sysrootArg = $sysroot -replace "\\", "/"
    $includeBase = "$sysrootArg/usr/include"
    $includeTargetPath = "$includeBase/$includeTarget"
    $bindgenArgs = "--sysroot=$sysrootArg -I$includeBase -I$includeTargetPath"

    Write-Host "Building EasyTier JNI for $abiName ($rustTarget)"
    Set-Item -Path "Env:CC_$envSuffix" -Value $clangCmd
    Set-Item -Path "Env:AR_$envSuffix" -Value $llvmAr
    Set-Item -Path "Env:$cargoTargetEnv" -Value $clangCmd
    Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS" -Value $bindgenArgs
    Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$rustTarget" -Value $bindgenArgs
    Set-Item -Path "Env:BINDGEN_EXTRA_CLANG_ARGS_$envSuffix" -Value $bindgenArgs

    Push-Location $jniCrate
    try {
        Write-Host "Using Rust toolchain: $((& rustup show active-toolchain).Trim())"
        & rustup target add $rustTarget
        if ($LASTEXITCODE -ne 0) {
            throw "rustup target add failed for $rustTarget"
        }

        & cargo build --locked --target $rustTarget --release
        if ($LASTEXITCODE -ne 0) {
            throw "cargo build failed for $rustTarget"
        }
    } finally {
        Pop-Location
    }

    $builtLibrary = Join-Path $env:CARGO_TARGET_DIR "$rustTarget/release/libeasytier_android_jni.so"
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
