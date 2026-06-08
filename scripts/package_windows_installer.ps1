param(
    [string] $ReleaseDir = "build/windows/x64/runner/Release",
    [string] $OutputDir = "dist",
    [string] $AppVersion = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$releasePath = Resolve-Path (Join-Path $repoRoot $ReleaseDir)
$outputPath = Join-Path $repoRoot $OutputDir
$appExe = Join-Path $releasePath "easytier_pro_app.exe"

if (-not (Test-Path $appExe)) {
    throw "Windows release executable was not found: $appExe"
}

if ([string]::IsNullOrWhiteSpace($AppVersion)) {
    $pubspec = Get-Content -Path (Join-Path $repoRoot "pubspec.yaml") -Raw
    if ($pubspec -match "(?m)^version:\s*([^\s#]+)") {
        $AppVersion = $Matches[1]
    } else {
        $AppVersion = "0.0.0"
    }
}

$setupVersion = ($AppVersion -replace "\+", ".")
$safeVersion = ($setupVersion -replace "[^0-9A-Za-z._-]", "-")
$outputBaseName = "easytier-pro-windows-x64-setup-$safeVersion"

New-Item -ItemType Directory -Force $outputPath | Out-Null

$iscc = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
if ($null -eq $iscc) {
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $candidate = if ([string]::IsNullOrWhiteSpace($programFilesX86)) {
        ""
    } else {
        Join-Path $programFilesX86 "Inno Setup 6/ISCC.exe"
    }
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
        $isccPath = (Resolve-Path $candidate).Path
    } else {
        throw "ISCC.exe was not found. Install Inno Setup before packaging the Windows installer."
    }
} else {
    $isccPath = $iscc.Source
}

function Convert-ToInnoPath([string] $Path) {
    return ($Path -replace '"', '""')
}

$releaseInnoPath = Convert-ToInnoPath $releasePath.Path
$outputInnoPath = Convert-ToInnoPath (Resolve-Path $outputPath).Path
$issPath = Join-Path $outputPath "easytier-pro-windows-installer.iss"

$iss = @"
#define AppName "EasyTier Pro"
#define AppVersion "$setupVersion"
#define AppExeName "easytier_pro_app.exe"
#define SourceDir "$releaseInnoPath"
#define OutputDir "$outputInnoPath"
#define OutputBaseName "$outputBaseName"

[Setup]
AppId={{9F21B3F0-9A38-4657-A55F-1B4BB6C4C1AE}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=EasyTier Pro
DefaultDirName={autopf}\EasyTier Pro
DefaultGroupName=EasyTier Pro
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern
UninstallDisplayIcon={app}\{#AppExeName}

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,EasyTier Pro}"; Flags: nowait postinstall skipifsilent
"@

Set-Content -Path $issPath -Value $iss -Encoding UTF8

& $isccPath $issPath
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE"
}

$installer = Join-Path $outputPath "$outputBaseName.exe"
if (-not (Test-Path $installer)) {
    throw "Expected Windows installer was not produced: $installer"
}

Write-Host "Windows installer produced: $installer"
