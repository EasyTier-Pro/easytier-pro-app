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
    Assert-NonEmptyArrayField $summary "diagnostics_builder_routes" "$Label connected Android E2E summary"
    Assert-NonEmptyArrayField $summary "diagnostics_builder_disallowed_applications" "$Label connected Android E2E summary"
    Assert-TrueField $summary "diagnostics_builder_self_disallowed" "$Label connected Android E2E summary"
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
