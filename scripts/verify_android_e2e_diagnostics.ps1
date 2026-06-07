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

function Normalize-RouteCidr([string] $Value) {
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

function Convert-ToComparableList([string[]] $Values, [switch] $NormalizeRoutes) {
    return @(
        $Values |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 } |
            ForEach-Object {
                if ($NormalizeRoutes) {
                    Normalize-RouteCidr $_
                } else {
                    $_
                }
            }
    )
}

function Assert-ContainsAll(
    [string[]] $Actual,
    [string[]] $Expected,
    [string] $Description,
    [switch] $NormalizeRoutes
) {
    $actualValues = Convert-ToComparableList $Actual -NormalizeRoutes:$NormalizeRoutes
    $expectedValues = Convert-ToComparableList $Expected -NormalizeRoutes:$NormalizeRoutes
    $missing = $expectedValues |
        Where-Object { $ActualValues -notcontains $_ }
    if ($missing.Count -gt 0) {
        throw "$Description missing: $($missing -join ', '). Actual: $($actualValues -join ', ')"
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

function Find-EntryIndexesByMessage([string] $Message) {
    $indexes = New-Object System.Collections.Generic.List[int]
    for ($index = 0; $index -lt $entries.Count; $index++) {
        if ((Get-EntryValue $entries[$index] "message") -eq $Message) {
            $indexes.Add($index) | Out-Null
        }
    }
    return $indexes.ToArray()
}

$vpnEstablished = Find-EntriesByMessage "Android VPN established"
if ($vpnEstablished.Count -eq 0) {
    throw "Missing Android VPN established log entry."
}
$vpnEstablishedIndexes = Find-EntryIndexesByMessage "Android VPN established"
$latestVpnIndex = $vpnEstablishedIndexes[$vpnEstablishedIndexes.Count - 1]
$latestVpn = $vpnEstablished[$vpnEstablished.Count - 1]
$context = Get-EntryValue $latestVpn "context"
$vpnStoppedIndexes = Find-EntryIndexesByMessage "Android VPN stopped"
$configServerStartedIndexes = Find-EntryIndexesByMessage "Android config server client started"
$configServerStoppedIndexes = Find-EntryIndexesByMessage "Android config server client stopped"

if ($RequireConfigServerStarted) {
    $configServerStartsBeforeLatestVpn = @(
        $configServerStartedIndexes |
            Where-Object { $_ -lt $latestVpnIndex }
    )
    if ($configServerStartsBeforeLatestVpn.Count -eq 0) {
        throw "Missing Android config server client started log entry before the latest Android VPN established log entry."
    }
    $latestConfigServerStartIndex =
        $configServerStartsBeforeLatestVpn[$configServerStartsBeforeLatestVpn.Count - 1]
    $configServerStoppedAfterStartBeforeVpn = @(
        $configServerStoppedIndexes |
            Where-Object {
                $_ -gt $latestConfigServerStartIndex -and
                $_ -lt $latestVpnIndex
            }
    )
    if ($configServerStoppedAfterStartBeforeVpn.Count -gt 0) {
        throw "Android config server client was stopped after the latest start and before the latest Android VPN established log entry."
    }
    if (-not $RequireConfigServerStop -and $configServerStoppedIndexes.Count -gt 0) {
        $latestConfigServerStartedIndex =
            $configServerStartedIndexes[$configServerStartedIndexes.Count - 1]
        $latestConfigServerStoppedIndex =
            $configServerStoppedIndexes[$configServerStoppedIndexes.Count - 1]
        if ($latestConfigServerStoppedIndex -gt $latestConfigServerStartedIndex) {
            throw "Android config server client stopped after the latest start log entry."
        }
    }
}

$tunFd = Get-EntryValue $context "tun_fd"
if ($null -eq $tunFd -or $tunFd.ToString().Trim().Length -eq 0 -or $tunFd.ToString().Trim() -eq "0") {
    throw "Android VPN established log does not contain a usable tun_fd."
}

$routes = Convert-ToStringList (Get-EntryValue $context "routes")
if ($routes.Count -eq 0) {
    throw "Android VPN established log does not contain routes."
}
Assert-ContainsAll $routes $ExpectedRoute "Android VPN routes" -NormalizeRoutes

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
    $vpnStoppedAfterLatest = @(
        $vpnStoppedIndexes |
            Where-Object { $_ -gt $latestVpnIndex }
    )
    if ($vpnStoppedAfterLatest.Count -eq 0) {
        throw "Missing Android VPN stopped log entry after the latest Android VPN established log entry."
    }
} elseif (-not $RequireConfigServerStop) {
    $vpnStoppedAfterLatest = @(
        $vpnStoppedIndexes |
            Where-Object { $_ -gt $latestVpnIndex }
    )
    if ($vpnStoppedAfterLatest.Count -gt 0) {
        throw "Android VPN stopped after the latest Android VPN established log entry."
    }
}

if ($RequireConfigServerStop) {
    $configServerStoppedAfterLatest = @(
        $configServerStoppedIndexes |
            Where-Object { $_ -gt $latestVpnIndex }
    )
    if ($configServerStoppedAfterLatest.Count -eq 0) {
        throw "Missing Android config server client stopped log entry after the latest Android VPN established log entry."
    }
    $latestConfigServerStoppedAfterLatestIndex =
        $configServerStoppedAfterLatest[$configServerStoppedAfterLatest.Count - 1]
    $configServerStartedAfterStop = @(
        $configServerStartedIndexes |
            Where-Object { $_ -gt $latestConfigServerStoppedAfterLatestIndex }
    )
    if ($configServerStartedAfterStop.Count -gt 0) {
        throw "Android config server client restarted after the required stop log entry."
    }
}

Write-Host "Android E2E diagnostics verification passed."
Write-Host "Log: $resolvedLogPath"
Write-Host "tun_fd: $tunFd"
Write-Host "addresses: $($addresses -join ', ')"
Write-Host "routes: $($routes -join ', ')"
Write-Host "disallowed_applications: $($disallowedApplications -join ', ')"
