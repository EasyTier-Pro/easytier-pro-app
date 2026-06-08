param(
    [switch] $RequireSigning,
    [switch] $RequireE2E,
    [switch] $RequireStopEvidence,
    [string] $LocalConnectedSummaryPath = "",
    [string] $OnlineConnectedSummaryPath = "",
    [string] $LocalStoppedSummaryPath = "",
    [string] $OnlineStoppedSummaryPath = ""
)

$ErrorActionPreference = "Stop"

function Assert-FileExists([string] $Path, [string] $Description) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description path was not provided."
    }
    if (-not (Test-Path $Path)) {
        throw "$Description was not found: $Path"
    }
}

function Read-Summary([string] $Path, [string] $Description) {
    Assert-FileExists $Path $Description
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        throw "$Description is not valid JSON: $Path"
    }
}

function Get-PropertyValue([object] $Object, [string] $Name) {
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Convert-ToBool([object] $Value) {
    if ($Value -is [bool]) {
        return $Value
    }
    $text = if ($null -eq $Value) { "" } else { $Value.ToString().Trim() }
    return @("true", "1", "yes") -contains $text.ToLowerInvariant()
}

function Convert-ToArray([object] $Value) {
    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @($Value)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value)
    }
    return @($Value)
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

function Convert-ToComparableList([object] $Value, [switch] $NormalizeRoutes) {
    return @(
        Convert-ToArray $Value |
            Where-Object { $null -ne $_ } |
            ForEach-Object { $_.ToString().Trim() } |
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

function Assert-TrueField([object] $Summary, [string] $Field, [string] $Description) {
    if (-not (Convert-ToBool (Get-PropertyValue $Summary $Field))) {
        throw "$Description must have $Field=true."
    }
}

function Assert-EmptyArrayField([object] $Summary, [string] $Field, [string] $Description) {
    $values = Convert-ToArray (Get-PropertyValue $Summary $Field)
    if ($values.Count -gt 0) {
        throw "$Description must have empty $Field. Actual: $($values -join ', ')"
    }
}

function Assert-NonEmptyArrayField([object] $Summary, [string] $Field, [string] $Description) {
    $values = @(
        Convert-ToArray (Get-PropertyValue $Summary $Field) |
            Where-Object { $null -ne $_ -and $_.ToString().Trim().Length -gt 0 }
    )
    if ($values.Count -eq 0) {
        throw "$Description must have non-empty $Field."
    }
}

function Assert-ArrayFieldContainsAll(
    [object] $Summary,
    [string] $ActualField,
    [string] $ExpectedField,
    [string] $Description,
    [switch] $NormalizeRoutes
) {
    $actualValues = Convert-ToComparableList (Get-PropertyValue $Summary $ActualField) `
        -NormalizeRoutes:$NormalizeRoutes
    $expectedValues = Convert-ToComparableList (Get-PropertyValue $Summary $ExpectedField) `
        -NormalizeRoutes:$NormalizeRoutes
    $missing = @($expectedValues | Where-Object { $actualValues -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "$Description must have $ActualField containing $ExpectedField. Missing: $($missing -join ', '). Actual: $($actualValues -join ', ')"
    }
}

function Assert-ArrayFieldContainsValue(
    [object] $Summary,
    [string] $Field,
    [string] $ExpectedValue,
    [string] $Description
) {
    $values = Convert-ToComparableList (Get-PropertyValue $Summary $Field)
    $expected = $ExpectedValue.Trim()
    if ($expected.Length -eq 0) {
        throw "$Description expected value for $Field is empty."
    }
    if ($values -notcontains $expected) {
        throw "$Description must have $Field containing $expected. Actual: $($values -join ', ')"
    }
}

function Assert-EnvironmentName([object] $Summary, [string] $Expected, [string] $Description) {
    $actual = Get-PropertyValue $Summary "environment_name"
    $actualText = if ($null -eq $actual) { "" } else { $actual.ToString().Trim().ToLowerInvariant() }
    if ($actualText -ne $Expected) {
        throw "$Description must have environment_name=$Expected. Actual: $actualText"
    }
}

function Assert-ReferencedEvidenceFile([object] $Summary, [string] $Field, [string] $Description) {
    $files = Get-PropertyValue $Summary "files"
    if ($null -eq $files) {
        throw "$Description must include files.$Field."
    }
    $path = Get-PropertyValue $files $Field
    $pathText = if ($null -eq $path) { "" } else { $path.ToString().Trim() }
    if ($pathText.Length -eq 0) {
        throw "$Description must include files.$Field."
    }
    if (-not (Test-Path $pathText)) {
        throw "$Description referenced files.$Field was not found: $pathText"
    }
}

function Assert-ReferencedEvidenceFiles([object] $Summary, [string] $Description) {
    foreach ($field in @("diagnostics", "routes", "route_probes", "connectivity", "metadata")) {
        Assert-ReferencedEvidenceFile $Summary $field $Description
    }
}

function Assert-PassingSummary([object] $Summary, [string] $Description) {
    Assert-TrueField $Summary "passed" $Description
    Assert-TrueField $Summary "diagnostics_available" $Description
    Assert-TrueField $Summary "diagnostics_verification_passed" $Description
    Assert-EmptyArrayField $Summary "failures" $Description
    Assert-ReferencedEvidenceFiles $Summary $Description
}

function Assert-ConnectedEvidence([string] $Path, [string] $Label) {
    $summary = Read-Summary $Path "$Label connected Android E2E summary"
    Assert-PassingSummary $summary "$Label connected Android E2E summary"
    Assert-EnvironmentName $summary $Label "$Label connected Android E2E summary"
    Assert-TrueField $summary "require_system_route" "$Label connected Android E2E summary"
    Assert-TrueField $summary "require_ping_success" "$Label connected Android E2E summary"
    Assert-TrueField $summary "require_probe_package_route" "$Label connected Android E2E summary"
    Assert-TrueField $summary "require_self_excluded_route" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "expected_routes" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "expected_route_devices" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "ping_targets" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "probe_package_names" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "diagnostics_routes" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "diagnostics_builder_routes" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "diagnostics_builder_disallowed_applications" "$Label connected Android E2E summary"
    Assert-TrueField $summary "diagnostics_builder_self_disallowed" "$Label connected Android E2E summary"
    Assert-ArrayFieldContainsAll `
        $summary `
        "diagnostics_routes" `
        "expected_routes" `
        "$Label connected Android E2E summary" `
        -NormalizeRoutes
    Assert-ArrayFieldContainsAll `
        $summary `
        "diagnostics_builder_routes" `
        "expected_routes" `
        "$Label connected Android E2E summary" `
        -NormalizeRoutes
    $packageName = Get-PropertyValue $summary "package_name"
    $packageNameText = if ($null -eq $packageName) {
        ""
    } else {
        $packageName.ToString().Trim()
    }
    if ($packageNameText.Length -eq 0) {
        throw "$Label connected Android E2E summary must have package_name."
    }
    Assert-ArrayFieldContainsValue `
        $summary `
        "diagnostics_builder_disallowed_applications" `
        $packageNameText `
        "$Label connected Android E2E summary"
    Assert-ArrayFieldContainsValue `
        $summary `
        "diagnostics_builder_disallowed_applications" `
        "com.android.settings" `
        "$Label connected Android E2E summary"
    Assert-ArrayFieldContainsValue `
        $summary `
        "diagnostics_builder_disallowed_applications" `
        "com.android.shell" `
        "$Label connected Android E2E summary"
    Assert-EmptyArrayField $summary "missing_system_routes" "$Label connected Android E2E summary"
    Assert-EmptyArrayField $summary "failed_pings" "$Label connected Android E2E summary"
    Assert-EmptyArrayField $summary "failed_probe_routes" "$Label connected Android E2E summary"
    Assert-EmptyArrayField $summary "failed_self_excluded_routes" "$Label connected Android E2E summary"
    Write-Host "$Label connected Android E2E evidence verified: $Path"
}

function Assert-StoppedEvidence([string] $Path, [string] $Label) {
    $summary = Read-Summary $Path "$Label stopped Android E2E summary"
    Assert-PassingSummary $summary "$Label stopped Android E2E summary"
    Assert-EnvironmentName $summary $Label "$Label stopped Android E2E summary"
    Assert-TrueField $summary "require_stop" "$Label stopped Android E2E summary"
    Assert-TrueField $summary "require_config_server_stop" "$Label stopped Android E2E summary"
    Write-Host "$Label stopped Android E2E evidence verified: $Path"
}

& (Join-Path $PSScriptRoot "verify_android_release_inputs.ps1") `
    -RequireSigning:$RequireSigning

if ($RequireE2E) {
    Assert-ConnectedEvidence $LocalConnectedSummaryPath "local"
    Assert-ConnectedEvidence $OnlineConnectedSummaryPath "online"
} else {
    if (-not [string]::IsNullOrWhiteSpace($LocalConnectedSummaryPath)) {
        Assert-ConnectedEvidence $LocalConnectedSummaryPath "local"
    }
    if (-not [string]::IsNullOrWhiteSpace($OnlineConnectedSummaryPath)) {
        Assert-ConnectedEvidence $OnlineConnectedSummaryPath "online"
    }
    Write-Host "Android connected E2E evidence check skipped. Pass -RequireE2E with local and online summary.json paths before treating the Android port as complete."
}

if ($RequireStopEvidence) {
    Assert-StoppedEvidence $LocalStoppedSummaryPath "local"
    Assert-StoppedEvidence $OnlineStoppedSummaryPath "online"
} else {
    if (-not [string]::IsNullOrWhiteSpace($LocalStoppedSummaryPath)) {
        Assert-StoppedEvidence $LocalStoppedSummaryPath "local"
    }
    if (-not [string]::IsNullOrWhiteSpace($OnlineStoppedSummaryPath)) {
        Assert-StoppedEvidence $OnlineStoppedSummaryPath "online"
    }
    Write-Host "Android stop E2E evidence check skipped. Pass -RequireStopEvidence with local and online stop summary.json paths before release sign-off."
}

Write-Host "Android porting readiness checks finished."
