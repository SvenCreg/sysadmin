# Requires: Run as Administrator
# Requires: Windows PowerShell 5.1

if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host "This script must be run in Windows PowerShell 5.1, not PowerShell 7+" -ForegroundColor Red
    exit 1
}

if (-not ([Security.Principal.WindowsPrincipal]
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    # Ensure NuGet & PSGallery
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    # Install PSWindowsUpdate for all users
    Install-Module PSWindowsUpdate -Force -Scope AllUsers

    Import-Module PSWindowsUpdate -Force

    if (-not (Get-Command Get-WindowsUpdate -ErrorAction SilentlyContinue)) {
        throw "PSWindowsUpdate module failed to load."
    }

    # Run Windows & Microsoft updates
    Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot

    Write-Host "Windows updates applied successfully." -ForegroundColor Green
}
catch {
    Write-Host "Error during Windows Update:`n$_" -ForegroundColor Red
}

# Chocolatey updates
try {
    if (!(Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    choco upgrade all -y --ignore-checksums --no-progress
    Write-Host "Third-party apps updated via Chocolatey." -ForegroundColor Green
}
catch {
    Write-Host "Error during third-party update:`n$_" -ForegroundColor Yellow
}
