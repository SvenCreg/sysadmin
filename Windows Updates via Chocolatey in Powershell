# Requires: Run as Administrator
 
# Ensure script is running as administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}
 
$ProgressPreference = 'SilentlyContinue'
 
try {
    # Ensure NuGet and PSWindowsUpdate are ready
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction SilentlyContinue | Out-Null
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module -Name PSWindowsUpdate -Force -Scope CurrentUser -Confirm:$false -ErrorAction SilentlyContinue
    Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
 
    # Install Windows + Microsoft updates silently, suppress reboot
    Get-WindowsUpdate -MicrosoftUpdate -Install -AcceptAll -IgnoreReboot -Confirm:$false
 
    Write-Host "Windows updates applied successfully." -ForegroundColor Green
}
catch {
    Write-Host "Error during Windows Update: $_" -ForegroundColor Red
}
 
# Optional: Chocolatey third-party app updates
try {
    if (!(Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    }
 
    choco upgrade all -y --ignore-checksums --no-progress
    Write-Host "Third-party apps updated via Chocolatey." -ForegroundColor Green
}
catch {
    Write-Host "Error during third-party update: $_" -ForegroundColor Yellow
}
