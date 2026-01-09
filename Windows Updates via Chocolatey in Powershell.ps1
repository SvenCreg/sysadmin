# ============================================================
# Requires: Windows PowerShell 5.1
# Requires: Run as Administrator
# ============================================================

# Ensure Windows PowerShell 5.1
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host "This script must be run in Windows PowerShell 5.1 (powershell.exe)." -ForegroundColor Red
    exit 1
}

# Ensure Administrator (SAFE one-line check)
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------------------------------------------------
# Windows & Microsoft Updates
# ------------------------------------------------------------
try {
    # Ensure NuGet + PSGallery
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    # Install PSWindowsUpdate for all users
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Install-Module -Name PSWindowsUpdate -Scope AllUsers -Force
    }

    Import-Module PSWindowsUpdate -Force

    # Validate cmdlet availability
    if (-not (Get-Command Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
        throw "PSWindowsUpdate module loaded but Get-WindowsUpdate is unavailable."
    }

    # Install all Windows + Microsoft updates silently
    Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot

    Write-Host "Windows updates applied successfully." -ForegroundColor Green
}
catch {
    Write-Host "Error during Windows Update:" -ForegroundColor Red
    Write-Host $_ -ForegroundColor Red
}

# ------------------------------------------------------------
# Third-party application updates (Chocolatey)
# ------------------------------------------------------------
try {
    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    choco upgrade all -y --ignore-checksums --no-progress
    Write-Host "Third-party apps updated via Chocolatey." -ForegroundColor Green
}
catch {
    Write-Host "Error during third-party updates:" -ForegroundColor Yellow
    Write-Host $_ -ForegroundColor Yellow
}
