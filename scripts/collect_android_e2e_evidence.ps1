param(
    [string] $AdbPath = "",
    [string] $DeviceSerial = "",
    [string] $PackageName = "net.easytier.pro",
    [string] $OutputDirectory = "",
    [string[]] $ExpectedRoute = @(),
    [string[]] $ExpectedAddress = @(),
    [string[]] $PingTarget = @(),
    [string[]] $ProbePackageName = @(),
    [switch] $RequireSystemRoute,
    [switch] $RequirePingSuccess,
    [switch] $RequireProbePackageRoute,
    [switch] $RequireStop,
    [switch] $RequireConfigServerStop,
    [switch] $SkipVerify,
    [switch] $AllowMissingAppLogs
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "build\android-e2e-evidence"
}

$nonEmptyExpectedRoutes = @(
    $ExpectedRoute |
        ForEach-Object { if ($null -eq $_) { "" } else { $_.Trim() } } |
        Where-Object { $_.Length -gt 0 }
)
$nonEmptyPingTargets = @(
    $PingTarget |
        ForEach-Object { if ($null -eq $_) { "" } else { $_.Trim() } } |
        Where-Object { $_.Length -gt 0 }
)
$nonEmptyProbePackageNames = @(
    $ProbePackageName |
        ForEach-Object { if ($null -eq $_) { "" } else { $_.Trim() } } |
        Where-Object { $_.Length -gt 0 }
)
if ($RequireSystemRoute -and $nonEmptyExpectedRoutes.Count -eq 0) {
    throw "-RequireSystemRoute requires at least one -ExpectedRoute value."
}
if ($RequirePingSuccess -and $nonEmptyPingTargets.Count -eq 0) {
    throw "-RequirePingSuccess requires at least one -PingTarget value."
}
if ($RequireProbePackageRoute -and $nonEmptyExpectedRoutes.Count -eq 0) {
    throw "-RequireProbePackageRoute requires at least one -ExpectedRoute value."
}
if ($RequireProbePackageRoute -and $nonEmptyProbePackageNames.Count -eq 0) {
    throw "-RequireProbePackageRoute requires at least one -ProbePackageName value."
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

function Normalize-RouteCidr {
    param([Parameter(Mandatory = $true)][string] $Value)

    $text = $Value.Trim()
    if ($text.Length -eq 0) {
        return ""
    }

    $mappedIndex = $text.IndexOf("->")
    if ($mappedIndex -ge 0) {
        $mapped = $text.Substring($mappedIndex + 2).Trim()
        if ($mapped.Length -gt 0) {
            $text = $mapped
        } else {
            $text = $text.Substring(0, $mappedIndex).Trim()
        }
    }

    $slashIndex = $text.IndexOf("/")
    if ($slashIndex -lt 0) {
        $addressText = $text
        $prefix = 32
    } elseif ($slashIndex -eq 0 -or $slashIndex -eq $text.Length - 1) {
        return $text
    } else {
        $addressText = $text.Substring(0, $slashIndex)
        $prefixText = $text.Substring($slashIndex + 1)
        $prefix = 0
        if (-not [int]::TryParse($prefixText, [ref] $prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
            return $text
        }
    }

    $octets = $addressText.Split(".")
    if ($octets.Count -ne 4) {
        return $text
    }
    [uint64] $address = 0
    foreach ($octetText in $octets) {
        $octet = 0
        if (-not [int]::TryParse($octetText, [ref] $octet) -or $octet -lt 0 -or $octet -gt 255) {
            return $text
        }
        $address = ($address -shl 8) -bor [uint64] $octet
    }

    [uint64] $mask = if ($prefix -eq 0) {
        0
    } else {
        ([uint64] 4294967295 -shl (32 - $prefix)) -band [uint64] 4294967295
    }
    [uint64] $network = $address -band $mask
    $networkAddress = @(
        ($network -shr 24) -band 0xff
        ($network -shr 16) -band 0xff
        ($network -shr 8) -band 0xff
        $network -band 0xff
    ) -join "."
    return "$networkAddress/$prefix"
}

function Convert-Ipv4ToUInt64 {
    param([Parameter(Mandatory = $true)][string] $Address)

    $octets = $Address.Trim().Split(".")
    if ($octets.Count -ne 4) {
        return $null
    }
    [uint64] $value = 0
    foreach ($octetText in $octets) {
        $octet = 0
        if (-not [int]::TryParse($octetText, [ref] $octet) -or $octet -lt 0 -or $octet -gt 255) {
            return $null
        }
        $value = ($value -shl 8) -bor [uint64] $octet
    }
    return $value
}

function Convert-UInt64ToIpv4 {
    param([Parameter(Mandatory = $true)][uint64] $Value)

    return @(
        ($Value -shr 24) -band 0xff
        ($Value -shr 16) -band 0xff
        ($Value -shr 8) -band 0xff
        $Value -band 0xff
    ) -join "."
}

function Get-RouteProbeAddress {
    param([Parameter(Mandatory = $true)][string] $Value)

    $normalized = Normalize-RouteCidr $Value
    if ($normalized.Length -eq 0) {
        return ""
    }
    $parts = $normalized.Split("/", 2)
    if ($parts.Count -ne 2) {
        return $normalized
    }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref] $prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
        return $parts[0]
    }
    if ($prefix -eq 0) {
        return ""
    }
    if ($prefix -ge 31) {
        return $parts[0]
    }
    $network = Convert-Ipv4ToUInt64 $parts[0]
    if ($null -eq $network) {
        return $parts[0]
    }
    return Convert-UInt64ToIpv4 ($network + 1)
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

function Get-PackageUid {
    param([Parameter(Mandatory = $true)][string] $PackageText)

    foreach ($pattern in @('userId=(\d+)', 'uid=(\d+)')) {
        if ($PackageText -match $pattern) {
            return $matches[1]
        }
    }
    return ""
}

function Save-RouteProbeOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Targets,
        [object[]] $UidProbes = @()
    )

    $uniqueTargets = @(
        $Targets |
            ForEach-Object { if ($null -eq $_) { "" } else { $_.Trim() } } |
            Where-Object { $_.Length -gt 0 } |
            Select-Object -Unique
    )
    $file = Join-Path $runOutputDirectory "route_probes.txt"
    $buffer = New-Object System.Text.StringBuilder
    $probeResults = New-Object System.Collections.Generic.List[object]
    [void] $buffer.AppendLine("# Android route probes")
    foreach ($probe in $UidProbes) {
        [void] $buffer.AppendLine("# uid_probe=$($probe.Label) uid=$($probe.Uid)")
    }
    [void] $buffer.AppendLine()
    if ($uniqueTargets.Count -eq 0) {
        [void] $buffer.AppendLine("# No route probe targets were provided.")
        Write-TextFile -Path $file -Text $buffer.ToString()
        return
    }

    foreach ($target in $uniqueTargets) {
        $commands = New-Object System.Collections.Generic.List[object]
        $commands.Add(
            [pscustomobject] @{
                Label = "shell"
                Args = [string[]] @("shell", "ip", "route", "get", $target)
            }
        ) | Out-Null
        foreach ($probe in $UidProbes) {
            $commands.Add(
                [pscustomobject] @{
                    Label = $probe.Label
                    Args = [string[]] @("shell", "ip", "route", "get", $target, "uid", $probe.Uid)
                }
            ) | Out-Null
        }
        foreach ($command in $commands) {
            $arguments = $command.Args
            $result = Invoke-Adb -Arguments $arguments -AllowFailure
            $probeResults.Add(
                [pscustomobject] @{
                    Probe = $command.Label
                    Target = $target
                    ExitCode = $result.ExitCode
                    Output = $result.Output
                    Arguments = $arguments
                }
            ) | Out-Null
            [void] $buffer.AppendLine("# probe=$($command.Label)")
            [void] $buffer.AppendLine("# adb $($arguments -join ' ')")
            [void] $buffer.AppendLine("# exit_code=$($result.ExitCode)")
            [void] $buffer.AppendLine($result.Output)
            [void] $buffer.AppendLine()
        }
    }
    Write-TextFile -Path $file -Text $buffer.ToString()
    return $probeResults.ToArray()
}

function Test-RouteTextContainsCidr {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RouteText,
        [Parameter(Mandatory = $true)]
        [string] $Cidr
    )

    $trimmed = $Cidr.Trim()
    if ($trimmed.Length -eq 0) {
        return $true
    }
    $normalized = Normalize-RouteCidr $trimmed
    if ($RouteText.Contains($trimmed) -or $RouteText.Contains($normalized)) {
        return $true
    }

    $parts = $normalized.Split("/", 2)
    if ($parts.Count -eq 2 -and $parts[1] -eq "32") {
        return [regex]::IsMatch(
            $RouteText,
            "(^|\s)$([regex]::Escape($parts[0]))(\s|$)"
        )
    }

    return $false
}

function Get-RouteDevicesForCidrs {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RouteText,
        [Parameter(Mandatory = $true)]
        [string[]] $Cidrs
    )

    $devices = New-Object System.Collections.Generic.List[string]
    $lines = @($RouteText -split '\r?\n')
    foreach ($cidr in $Cidrs) {
        $trimmed = if ($null -eq $cidr) { "" } else { $cidr.Trim() }
        if ($trimmed.Length -eq 0) {
            continue
        }
        foreach ($line in $lines) {
            if ((Test-RouteTextContainsCidr $line $trimmed) -and $line -match '(^|\s)dev\s+(\S+)') {
                $devices.Add($matches[2]) | Out-Null
            }
        }
    }
    return @($devices | Select-Object -Unique)
}

function Test-RouteProbeUsesAnyDevice {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProbeText,
        [Parameter(Mandatory = $true)]
        [string[]] $Devices
    )

    foreach ($device in $Devices) {
        $trimmed = if ($null -eq $device) { "" } else { $device.Trim() }
        if ($trimmed.Length -eq 0) {
            continue
        }
        if ([regex]::IsMatch($ProbeText, "(^|\s)dev\s+$([regex]::Escape($trimmed))(\s|$)")) {
            return $true
        }
    }
    return $false
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
    "# probe_packages=$($ProbePackageName -join ',')",
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

$routeTables = Save-AdbCommandOutput -FileName "route_tables.txt" -Arguments @("shell", "ip", "route", "show", "table", "all")
Save-AdbCommandOutput -FileName "ip_rules.txt" -Arguments @("shell", "ip", "rule") | Out-Null
Save-AdbCommandOutput -FileName "ip_addresses.txt" -Arguments @("shell", "ip", "addr", "show") | Out-Null
Save-AdbCommandOutput -FileName "ip_links.txt" -Arguments @("shell", "ip", "link", "show") | Out-Null
Save-AdbCommandOutput -FileName "connectivity.txt" -Arguments @("shell", "dumpsys", "connectivity") | Out-Null
Save-AdbCommandOutput -FileName "network_policy.txt" -Arguments @("shell", "dumpsys", "netpolicy") | Out-Null
Save-AdbCommandOutput -FileName "netd.txt" -Arguments @("shell", "dumpsys", "netd") | Out-Null
$packageResult = Save-AdbCommandOutput -FileName "package.txt" -Arguments @("shell", "dumpsys", "package", $PackageName)
$packageUid = Get-PackageUid $packageResult.Output
$uidProbes = New-Object System.Collections.Generic.List[object]
$missingProbePackageUids = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($packageUid)) {
    $uidProbes.Add(
        [pscustomobject] @{
            Label = "disallowed:$PackageName"
            Uid = $packageUid
        }
    ) | Out-Null
} else {
    Write-Warning "Could not resolve UID for $PackageName; self-disallowed route probe will be skipped."
}
foreach ($probePackage in @($ProbePackageName | Select-Object -Unique)) {
    $trimmedProbePackage = if ($null -eq $probePackage) { "" } else { $probePackage.Trim() }
    if ($trimmedProbePackage.Length -eq 0) {
        continue
    }
    $safeProbePackage = [regex]::Replace($trimmedProbePackage, '[^A-Za-z0-9_.-]', '_')
    $probePackageResult = Save-AdbCommandOutput `
        -FileName "package-probe-$safeProbePackage.txt" `
        -Arguments @("shell", "dumpsys", "package", $trimmedProbePackage)
    $probePackageUid = Get-PackageUid $probePackageResult.Output
    if (-not [string]::IsNullOrWhiteSpace($probePackageUid)) {
        $uidProbes.Add(
            [pscustomobject] @{
                Label = "probe:$trimmedProbePackage"
                Uid = $probePackageUid
            }
        ) | Out-Null
    } else {
        Write-Warning "Could not resolve UID for probe package $trimmedProbePackage; package route probe will be skipped."
        $missingProbePackageUids.Add($trimmedProbePackage) | Out-Null
    }
}
$routeProbeTargets = New-Object System.Collections.Generic.List[string]
foreach ($target in $PingTarget) {
    $trimmedTarget = if ($null -eq $target) { "" } else { $target.Trim() }
    if ($trimmedTarget.Length -gt 0) {
        $routeProbeTargets.Add($trimmedTarget) | Out-Null
    }
}
foreach ($route in $ExpectedRoute) {
    $trimmedRoute = if ($null -eq $route) { "" } else { $route.Trim() }
    if ($trimmedRoute.Length -gt 0) {
        $probeTarget = Get-RouteProbeAddress $trimmedRoute
        if ($probeTarget.Length -gt 0) {
            $routeProbeTargets.Add($probeTarget) | Out-Null
        }
    }
}
$routeProbeResults = @(
    Save-RouteProbeOutput -Targets $routeProbeTargets.ToArray() -UidProbes $uidProbes.ToArray()
)
$expectedRouteDevices = @(
    Get-RouteDevicesForCidrs -RouteText $routeTables.Output -Cidrs $ExpectedRoute
)

$missingSystemRoutes = @(
    $ExpectedRoute |
        ForEach-Object { if ($null -eq $_) { "" } else { $_.Trim() } } |
        Where-Object { $_.Length -gt 0 -and -not (Test-RouteTextContainsCidr $routeTables.Output $_) }
)
$missingSystemRouteMessage = ""
if ($missingSystemRoutes.Count -gt 0) {
    $missingSystemRouteMessage = "Expected routes were not found in Android system route tables: $($missingSystemRoutes -join ', ')"
    Write-Warning $missingSystemRouteMessage
}

$failedPings = New-Object System.Collections.Generic.List[string]
foreach ($target in $PingTarget) {
    $trimmedTarget = if ($null -eq $target) { "" } else { $target.Trim() }
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
        -ExpectedAddress $ExpectedAddress `
        -PackageName $PackageName `
        -RequireStop:$RequireStop `
        -RequireConfigServerStop:$RequireConfigServerStop
}

$requiredFailures = New-Object System.Collections.Generic.List[string]
if ($RequireSystemRoute -and $missingSystemRoutes.Count -gt 0) {
    $requiredFailures.Add($missingSystemRouteMessage) | Out-Null
}
if ($RequirePingSuccess -and $failedPings.Count -gt 0) {
    $requiredFailures.Add("Android ping checks failed: $($failedPings -join ', ')") | Out-Null
}
if ($RequireProbePackageRoute) {
    if ($missingProbePackageUids.Count -gt 0) {
        $requiredFailures.Add(
            "Probe package UID was not resolved: $($missingProbePackageUids -join ', ')"
        ) | Out-Null
    }
    if ($expectedRouteDevices.Count -eq 0) {
        $requiredFailures.Add(
            "No Android route devices were found for ExpectedRoute: $($nonEmptyExpectedRoutes -join ', ')"
        ) | Out-Null
    }
    $probePackageResults = @(
        $routeProbeResults |
            Where-Object { $_.Probe -like 'probe:*' }
    )
    if ($probePackageResults.Count -eq 0) {
        $requiredFailures.Add(
            "No route probe results were collected for ProbePackageName."
        ) | Out-Null
    } else {
        $failedProbeRoutes = @(
            $probePackageResults |
                Where-Object {
                    $_.ExitCode -ne 0 -or
                    -not (Test-RouteProbeUsesAnyDevice $_.Output $expectedRouteDevices)
                } |
                ForEach-Object {
                    "$($_.Probe) target=$($_.Target) exit=$($_.ExitCode)"
                }
        )
        if ($failedProbeRoutes.Count -gt 0) {
            $requiredFailures.Add(
                "Probe package route checks did not use expected VPN route devices ($($expectedRouteDevices -join ', ')): $($failedProbeRoutes -join '; ')"
            ) | Out-Null
        }
    }
}
if ($requiredFailures.Count -gt 0) {
    throw "$($requiredFailures -join ' '). Evidence directory: $runOutputDirectory"
}

Write-Host "Android E2E evidence collected."
Write-Host "Directory: $runOutputDirectory"
Write-Host "Diagnostics: $diagnosticsPath"
Write-Host "Routes: $(Join-Path $runOutputDirectory "route_tables.txt")"
Write-Host "Route probes: $(Join-Path $runOutputDirectory "route_probes.txt")"
Write-Host "Connectivity: $(Join-Path $runOutputDirectory "connectivity.txt")"
if ($missingSystemRoutes.Count -gt 0) {
    Write-Host "Missing system routes: $($missingSystemRoutes -join ', ')"
}
if ($expectedRouteDevices.Count -gt 0) {
    Write-Host "Expected route devices: $($expectedRouteDevices -join ', ')"
}
if ($PingTarget.Count -gt 0) {
    Write-Host "Ping targets: $($PingTarget -join ', ')"
}
if ($ProbePackageName.Count -gt 0) {
    Write-Host "Probe packages: $($ProbePackageName -join ', ')"
}
