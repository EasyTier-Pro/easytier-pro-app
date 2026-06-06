param(
    [string] $AdbPath = "",
    [string] $DeviceSerial = "",
    [string] $PackageName = "net.easytier.pro",
    [string] $OutputDirectory = "",
    [string[]] $ExpectedRoute = @(),
    [string[]] $ExpectedAddress = @(),
    [string[]] $PingTarget = @(),
    [switch] $RequirePingSuccess,
    [switch] $SkipVerify,
    [switch] $AllowMissingAppLogs
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "build\android-e2e-evidence"
}

function Get-LocalAndroidSdkPath {
    $localProperties = Join-Path $repoRoot "android\local.properties"
    if (-not (Test-Path $localProperties)) {
        return $null
    }
    foreach ($line in Get-Content -Path $localProperties) {
        if ($line -match '^sdk\.dir=(.+)$') {
            return $matches[1].Trim().Replace('\\', '\')
        }
    }
    return $null
}

function Resolve-AdbPath {
    if (-not [string]::IsNullOrWhiteSpace($AdbPath)) {
        if (Test-Path $AdbPath) {
            return (Resolve-Path $AdbPath).Path
        }
        throw "adb was not found at: $AdbPath"
    }

    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Get-LocalAndroidSdkPath))) {
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidates.Add((Join-Path $root "platform-tools\adb.exe")) | Out-Null
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe")) | Out-Null
    }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "adb was not found. Set -AdbPath or install Android platform-tools."
}

$script:ResolvedAdbPath = Resolve-AdbPath

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [switch] $AllowFailure
    )

    $fullArgs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($DeviceSerial)) {
        $fullArgs.Add("-s") | Out-Null
        $fullArgs.Add($DeviceSerial) | Out-Null
    }
    foreach ($argument in $Arguments) {
        $fullArgs.Add($argument) | Out-Null
    }

    $output = & $script:ResolvedAdbPath @($fullArgs.ToArray()) 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "adb $($fullArgs -join ' ') failed with exit code ${exitCode}:`n$text"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $text
    }
}

function Resolve-DeviceSerial {
    if (-not [string]::IsNullOrWhiteSpace($DeviceSerial)) {
        return
    }

    $output = & $script:ResolvedAdbPath devices 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "adb devices failed:`n$($output -join "`n")"
    }
    $devices = @(
        $output |
            ForEach-Object { $_.ToString() } |
            Where-Object { $_ -match '^(\S+)\s+device$' } |
            ForEach-Object { $matches[1] }
    )
    if ($devices.Count -eq 0) {
        throw "No online Android devices were found by adb."
    }
    if ($devices.Count -gt 1) {
        throw "Multiple Android devices are online. Pass -DeviceSerial. Devices: $($devices -join ', ')"
    }
    $script:DeviceSerial = $devices[0]
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Text
    )
    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

function Save-AdbCommandOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FileName,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $result = Invoke-Adb -Arguments $Arguments -AllowFailure
    $file = Join-Path $runOutputDirectory $FileName
    $header = @(
        "# adb $($Arguments -join ' ')",
        "# exit_code=$($result.ExitCode)",
        ""
    ) -join "`n"
    Write-TextFile -Path $file -Text "$header$($result.Output)"
    return $result
}

Resolve-DeviceSerial

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runOutputDirectory = Join-Path $OutputDirectory $timestamp
New-Item -ItemType Directory -Path $runOutputDirectory -Force | Out-Null

$metadata = @(
    "# EasyTier Pro Android E2E evidence",
    "# generated_at=$((Get-Date).ToString("o"))",
    "# adb=$script:ResolvedAdbPath",
    "# device=$script:DeviceSerial",
    "# package=$PackageName",
    ""
) -join "`n"
Write-TextFile -Path (Join-Path $runOutputDirectory "metadata.txt") -Text $metadata

$remoteLogDir = "/data/data/$PackageName/cache/easytier-pro-app/logs"
$listResult = Invoke-Adb `
    -Arguments @("shell", "run-as", $PackageName, "sh", "-c", "ls -1 $remoteLogDir/*.log 2>/dev/null") `
    -AllowFailure

$remoteLogs = @(
    $listResult.Output -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_.Length -gt 0 -and $_ -notmatch '^run-as:' }
)

$diagnosticsPath = Join-Path $runOutputDirectory "diagnostics.log"
$diagnostics = New-Object System.Text.StringBuilder
[void] $diagnostics.AppendLine("# EasyTier Pro adb diagnostics export")
[void] $diagnostics.AppendLine("# generated_at=$((Get-Date).ToString("o"))")
[void] $diagnostics.AppendLine("# package=$PackageName")
[void] $diagnostics.AppendLine("# remote_log_dir=$remoteLogDir")
[void] $diagnostics.AppendLine()

if ($remoteLogs.Count -eq 0) {
    [void] $diagnostics.AppendLine("# No app log files were found through adb run-as.")
    [void] $diagnostics.AppendLine("# Install a debug build, open the app, reproduce the issue, then run this script again.")
    Write-TextFile -Path $diagnosticsPath -Text $diagnostics.ToString()
    if (-not $AllowMissingAppLogs) {
        throw "No app log files were found for $PackageName. For release builds, export diagnostics from the app share sheet instead."
    }
} else {
    foreach ($remoteLog in $remoteLogs) {
        $catResult = Invoke-Adb `
            -Arguments @("shell", "run-as", $PackageName, "cat", $remoteLog) `
            -AllowFailure
        [void] $diagnostics.AppendLine("## FILE: run-as:$remoteLog")
        if ($catResult.ExitCode -eq 0) {
            [void] $diagnostics.AppendLine($catResult.Output)
        } else {
            [void] $diagnostics.AppendLine("<failed to read $remoteLog>")
            [void] $diagnostics.AppendLine($catResult.Output)
        }
        [void] $diagnostics.AppendLine()
    }
    Write-TextFile -Path $diagnosticsPath -Text $diagnostics.ToString()
}

Save-AdbCommandOutput -FileName "route_tables.txt" -Arguments @("shell", "ip", "route", "show", "table", "all") | Out-Null
Save-AdbCommandOutput -FileName "ip_rules.txt" -Arguments @("shell", "ip", "rule") | Out-Null
Save-AdbCommandOutput -FileName "connectivity.txt" -Arguments @("shell", "dumpsys", "connectivity") | Out-Null
Save-AdbCommandOutput -FileName "package.txt" -Arguments @("shell", "dumpsys", "package", $PackageName) | Out-Null

$failedPings = New-Object System.Collections.Generic.List[string]
foreach ($target in $PingTarget) {
    $trimmedTarget = $target.Trim()
    if ($trimmedTarget.Length -eq 0) {
        continue
    }
    $safeName = [regex]::Replace($trimmedTarget, '[^A-Za-z0-9_.-]', '_')
    $pingResult = Save-AdbCommandOutput `
        -FileName "ping-$safeName.txt" `
        -Arguments @("shell", "ping", "-c", "3", "-W", "3", $trimmedTarget)
    if ($pingResult.ExitCode -ne 0) {
        $failedPings.Add($trimmedTarget) | Out-Null
    }
}

if (-not $SkipVerify -and $remoteLogs.Count -gt 0) {
    $verifyScript = Join-Path $PSScriptRoot "verify_android_e2e_diagnostics.ps1"
    & $verifyScript `
        -LogPath $diagnosticsPath `
        -ExpectedRoute $ExpectedRoute `
        -ExpectedAddress $ExpectedAddress
}

if ($RequirePingSuccess -and $failedPings.Count -gt 0) {
    throw "Android ping checks failed: $($failedPings -join ', '). Evidence directory: $runOutputDirectory"
}

Write-Host "Android E2E evidence collected."
Write-Host "Directory: $runOutputDirectory"
Write-Host "Diagnostics: $diagnosticsPath"
Write-Host "Routes: $(Join-Path $runOutputDirectory "route_tables.txt")"
Write-Host "Connectivity: $(Join-Path $runOutputDirectory "connectivity.txt")"
if ($PingTarget.Count -gt 0) {
    Write-Host "Ping targets: $($PingTarget -join ', ')"
}
