param(
    [Parameter(Mandatory = $true)]
    [string] $LogPath,
    [string[]] $ExpectedRoute = @(),
    [string[]] $ExpectedAddress = @(),
    [string] $PackageName = "net.easytier.pro",
    [bool] $RequireConfigServerStarted = $true,
    [switch] $RequireStop,
    [switch] $RequireConfigServerStop,
    [switch] $AllowMappedRouteText
)

$ErrorActionPreference = "Stop"

function Get-EntryValue([object] $Object, [string] $Name) {
    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Convert-ToStringList([object] $Value) {
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ($trimmed.Length -eq 0) {
            return @()
        }
        return @($trimmed)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Value) {
            if ($null -eq $item) {
                continue
            }
            $text = $item.ToString().Trim()
            if ($text.Length -gt 0) {
                $items.Add($text) | Out-Null
            }
        }
        return $items.ToArray()
    }
    $text = $Value.ToString().Trim()
    if ($text.Length -eq 0) {
        return @()
    }
    return @($text)
}

function Convert-ToBool([object] $Value) {
    if ($Value -is [bool]) {
        return $Value
    }
    $text = if ($null -eq $Value) { "" } else { $Value.ToString().Trim() }
    if ($text.Length -eq 0) {
        return $false
    }
    return @("true", "1", "yes") -contains $text.ToLowerInvariant()
}

function Assert-ContainsAll([string[]] $Actual, [string[]] $Expected, [string] $Description) {
    $missing = $Expected |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_.Length -gt 0 -and $Actual -notcontains $_ }
    if ($missing.Count -gt 0) {
        throw "$Description missing: $($missing -join ', '). Actual: $($Actual -join ', ')"
    }
}

if (-not (Test-Path $LogPath)) {
    throw "Diagnostics log was not found: $LogPath"
}

$resolvedLogPath = (Resolve-Path $LogPath).Path
$entries = New-Object System.Collections.Generic.List[object]
foreach ($line in Get-Content -Path $resolvedLogPath) {
    $trimmed = $line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) {
        continue
    }
    if (-not $trimmed.StartsWith("{")) {
        continue
    }
    try {
        $entry = $trimmed | ConvertFrom-Json
        if ($null -ne (Get-EntryValue $entry "message")) {
            $entries.Add($entry) | Out-Null
        }
    } catch {
        continue
    }
}

if ($entries.Count -eq 0) {
    throw "No JSON log entries were found in $resolvedLogPath"
}

function Find-EntriesByMessage([string] $Message) {
    return @($entries | Where-Object { (Get-EntryValue $_ "message") -eq $Message })
}

if ($RequireConfigServerStarted) {
    $configServerStarted = Find-EntriesByMessage "Android config server client started"
    if ($configServerStarted.Count -eq 0) {
        throw "Missing Android config server client started log entry."
    }
}

$vpnEstablished = Find-EntriesByMessage "Android VPN established"
if ($vpnEstablished.Count -eq 0) {
    throw "Missing Android VPN established log entry."
}
$latestVpn = $vpnEstablished[$vpnEstablished.Count - 1]
$context = Get-EntryValue $latestVpn "context"

$tunFd = Get-EntryValue $context "tun_fd"
if ($null -eq $tunFd -or $tunFd.ToString().Trim().Length -eq 0 -or $tunFd.ToString().Trim() -eq "0") {
    throw "Android VPN established log does not contain a usable tun_fd."
}

$routes = Convert-ToStringList (Get-EntryValue $context "routes")
if ($routes.Count -eq 0) {
    throw "Android VPN established log does not contain routes."
}
Assert-ContainsAll $routes $ExpectedRoute "Android VPN routes"

if (-not $AllowMappedRouteText) {
    $mappedTexts = $routes | Where-Object { $_.Contains("->") }
    if ($mappedTexts.Count -gt 0) {
        throw "Android VPN routes still contain raw mapped route text: $($mappedTexts -join ', ')"
    }
}

$addresses = Convert-ToStringList (Get-EntryValue $context "addresses")
if ($addresses.Count -eq 0) {
    throw "Android VPN established log does not contain addresses."
}
Assert-ContainsAll $addresses $ExpectedAddress "Android VPN addresses"

$disallowedApplications = Convert-ToStringList (Get-EntryValue $context "disallowed_applications")
if ($disallowedApplications -notcontains $PackageName) {
    throw "Android VPN disallowed_applications does not contain $PackageName. Actual: $($disallowedApplications -join ', ')"
}

if (-not (Convert-ToBool (Get-EntryValue $context "self_disallowed"))) {
    throw "Android VPN established log does not confirm self_disallowed=true."
}

if ($RequireStop) {
    $vpnStopped = Find-EntriesByMessage "Android VPN stopped"
    if ($vpnStopped.Count -eq 0) {
        throw "Missing Android VPN stopped log entry."
    }
}

if ($RequireConfigServerStop) {
    $configServerStopped = Find-EntriesByMessage "Android config server client stopped"
    if ($configServerStopped.Count -eq 0) {
        throw "Missing Android config server client stopped log entry."
    }
}

Write-Host "Android E2E diagnostics verification passed."
Write-Host "Log: $resolvedLogPath"
Write-Host "tun_fd: $tunFd"
Write-Host "addresses: $($addresses -join ', ')"
Write-Host "routes: $($routes -join ', ')"
Write-Host "disallowed_applications: $($disallowedApplications -join ', ')"
