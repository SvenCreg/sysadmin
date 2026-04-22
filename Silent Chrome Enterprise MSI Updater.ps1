# Chrome Enterprise MSI Updater for ConnectWise RMM
# Silent, no user interaction
# Updates Chrome ONLY if already installed
# Reports: Updated / Already current / Not installed / Failed
#
# ============================================================
# MAINTENANCE NOTE – UPDATING CHROME VERSION / DOWNLOAD LINK
# ============================================================
# If Google releases a new Chrome Enterprise version OR the download
# stops working:
#
# 1) Go to:
#    https://chromeenterprise.google/intl/en_ca/download/
#
# 2) Choose:
#    - Windows 64-bit
#    - Stable channel
#    - Enterprise Bundle (ZIP)
#
# 3) Copy the DIRECT link for:
#    GoogleChromeEnterpriseBundle64.zip
#
# 4) Update $downloadUrl in Section 2 with that direct link.
#
# Once you update $downloadUrl, the rest of the script stays the same.
# ============================================================

$ErrorActionPreference = "Stop"

###############################################
# Force TLS 1.2 (important for older systems)
###############################################
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

###############################################
# Helper: Get local Chrome version
###############################################
function Get-ChromeVersion {
    $paths = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                return (Get-Item $path).VersionInfo.ProductVersion
            } catch {}
        }
    }
    return $null
}

###############################################
# Helper: Get latest Chrome version (Google API)
###############################################
function Get-LatestChromeVersion {
    try {
        $url = "https://versionhistory.googleapis.com/v1/chrome/platforms/win/channels/stable/versions?pageSize=1"
        $response = Invoke-RestMethod -Uri $url -Method Get
        return $response.versions[0].version
    } catch {
        Write-Output "Warning - Failed to query Chrome version API: $($_.Exception.Message)"
        return $null
    }
}

###############################################
# 1. Detect Chrome – EXIT if not installed
###############################################
$oldVersion = Get-ChromeVersion

if (-not $oldVersion) {
    Write-Output "Not installed - Google Chrome is not present. No action taken."
    exit 0
}

Write-Output "Current Chrome version (local): $oldVersion"

###############################################
# 1.5 Check latest available version ONLINE
###############################################
$latestVersion = Get-LatestChromeVersion

if ($latestVersion) {
    Write-Output "Latest Chrome version (online): $latestVersion"

    try {
        if ([version]$oldVersion -ge [version]$latestVersion) {
            Write-Output "Already current MSI version - Installed version is up to date."
            exit 0
        }
    }
    catch {
        Write-Output "Warning - Version comparison failed, continuing with update..."
    }
}
else {
    Write-Output "Warning - Could not determine latest version. Continuing with update..."
}

###############################################
# 2. Download the Enterprise bundle (ZIP)
###############################################
$tempDir = "$env:TEMP\ChromeUpdate"
$zipPath = "$tempDir\ChromeBundle.zip"
$msiPath = Join-Path $tempDir "Installers\GoogleChromeStandaloneEnterprise64.msi"

if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Path $tempDir | Out-Null

$downloadUrl = "https://dl.google.com/chrome/install/GoogleChromeEnterpriseBundle64.zip"

###############################################
# Download (BITS first, fallback to Invoke-WebRequest)
###############################################
$downloaded = $false

try {
    Write-Output "Attempting download via BITS..."
    Start-BitsTransfer -Source $downloadUrl -Destination $zipPath -ErrorAction Stop
    $downloaded = $true
}
catch {
    Write-Output "BITS failed: $($_.Exception.Message)"
    Write-Output "Falling back to Invoke-WebRequest..."

    $maxAttempts = 3
    $attempt = 1

    while (-not $downloaded -and $attempt -le $maxAttempts) {
        try {
            Write-Output "Download attempt $attempt..."
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
            $downloaded = $true
        }
        catch {
            Write-Output "Attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
            $attempt++
        }
    }
}

if (-not $downloaded -or -not (Test-Path $zipPath)) {
    Write-Output "Failed - Unable to download Chrome bundle."
    Remove-Item -Recurse -Force $tempDir
    exit 1
}

###############################################
# 3. Extract the MSI from the bundle
###############################################
Write-Output "Extracting MSI from bundle..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempDir)

if (-not (Test-Path $msiPath)) {
    Write-Output "Failed - MSI not found inside downloaded ZIP (expected under .\Installers)."
    Remove-Item -Recurse -Force $tempDir
    exit 1
}

###############################################
# 4. Install / Upgrade Chrome using MSI (silent)
###############################################
Write-Output "Updating Chrome Enterprise MSI silently..."

$arguments = "/i `"$msiPath`" /qn REBOOT=ReallySuppress DO_NOT_LAUNCH_CHROME=1"

$process  = Start-Process "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
$exitCode = $process.ExitCode

Write-Output "MSI installer exit code: $exitCode"

if ($exitCode -ne 0) {
    Write-Output "Failed - MSI installation returned non-zero exit code."
    Remove-Item -Recurse -Force $tempDir
    exit 1
}

###############################################
# 5. Re-check Chrome version
###############################################
Start-Sleep -Seconds 3
$newVersion = Get-ChromeVersion

if (-not $newVersion) {
    Write-Output "Failed - Chrome missing after update attempt."
    Remove-Item -Recurse -Force $tempDir
    exit 1
}

Write-Output "Chrome version after update: $newVersion"

###############################################
# 6. Cleanup
###############################################
Remove-Item -Recurse -Force $tempDir

###############################################
# 7. Decide: Updated / Already current
###############################################
try {
    $vOld = [version]$oldVersion
    $vNew = [version]$newVersion

    if ($vNew -gt $vOld) {
        Write-Output "Updated - Chrome upgraded from $oldVersion to $newVersion."
        exit 0
    }

    if ($vNew -eq $vOld) {
        Write-Output "Already current - Chrome remains at $newVersion."
        exit 0
    }
}
catch {
    if ($newVersion -ne $oldVersion) {
        Write-Output "Updated - Chrome upgraded."
        exit 0
    } else {
        Write-Output "Already current - Chrome unchanged."
        exit 0
    }
}
