<#
================================================================================
Firefox Silent Install / Update Script (UPDATE-ONLY)

This script will:
- ONLY update existing Firefox installations
- NOT install Firefox if it is missing

HOW TO UPDATE FOR A NEW FIREFOX VERSION:
----------------------------------------
Update these two values ONLY:
1) $TargetVersion
2) Version embedded in $DownloadUrl
================================================================================
#>

# Target Firefox version you want installed
$TargetVersion = [Version] "146.0"

# Firefox download URL (must match the TargetVersion above)
$DownloadUrl = "https://download.mozilla.org/?product=firefox-146.0-ssl&os=win64&lang=en-US"

# Local path where the installer will be downloaded
$LocalInstaller = "C:\Temp\Firefox Installer.exe"

# -------------------------------------------------------------------------
# Detect existing Firefox installation via registry
# -------------------------------------------------------------------------
$firefoxExePath = $null
try {
    $reg = Get-ItemProperty `
        -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\firefox.exe" `
        -ErrorAction Stop
    $firefoxExePath = $reg.Path
} catch {
    # Firefox not found
}

# -------------------------------------------------------------------------
# Exit if Firefox is NOT installed
# -------------------------------------------------------------------------
if (-not $firefoxExePath -or -not (Test-Path $firefoxExePath)) {
    Write-Host "Firefox is not installed. No action taken."
    exit 0
}

# -------------------------------------------------------------------------
# Read installed Firefox version
# -------------------------------------------------------------------------
$installedVersionString = (Get-Item $firefoxExePath).VersionInfo.ProductVersion
$installedVersion = [Version] $installedVersionString

Write-Host "Installed version: $installedVersion"
Write-Host "Target version:    $TargetVersion"

# -------------------------------------------------------------------------
# Compare versions
# -------------------------------------------------------------------------
if ($installedVersion -ge $TargetVersion) {
    Write-Host "Installed version is up to date. No action needed."
    exit 0
}

Write-Host "Installed version is older. Updating Firefox..."

# -------------------------------------------------------------------------
# Ensure the destination directory exists
# -------------------------------------------------------------------------
$destDir = Split-Path $LocalInstaller -Parent
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

# -------------------------------------------------------------------------
# Download the Firefox installer
# -------------------------------------------------------------------------
Write-Host "Downloading Firefox $TargetVersion installer..."
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $LocalInstaller -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Error "Download failed: $_"
    exit 1
}

# -------------------------------------------------------------------------
# Silently run the installer (update only)
# -------------------------------------------------------------------------
Write-Host "Running installer..."
Start-Process -FilePath $LocalInstaller -ArgumentList "-ms" -Wait -NoNewWindow

# -------------------------------------------------------------------------
# Clean up installer file
# -------------------------------------------------------------------------
if (Test-Path $LocalInstaller) {
    Write-Host "Cleaning up installer file..."
    Remove-Item -Path $LocalInstaller -Force -ErrorAction SilentlyContinue
}
