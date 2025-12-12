# ==========================================================
# Silent in-place upgrade to Windows 11 25H2 using ISO
# - Downloads ISO
# - Mounts it
# - Runs setup.exe silently with your args
# - No user interaction, no forced reboot
# - Cleans up ISO
# ==========================================================
 
# ===== CONFIG =====
$isoUrl  = "https://REPLACE.ME/Win11_25H2_English_x64.iso?"
$isoPath = Join-Path $env:TEMP "Win11_25H2_English_x64.iso"
 
# ===== FUNCTIONS =====
function Test-Is25H2 {
    try {
        $cvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $props = Get-ItemProperty -Path $cvKey -ErrorAction Stop
        if ($props.DisplayVersion -eq '25H2') {
            return $true
        } else {
            return $false
        }
    } catch {
        return $false
    }
}
 
# ===== MAIN LOGIC =====
 
Write-Host "Checking current Windows DisplayVersion..."
 
if (Test-Is25H2) {
    Write-Host "This machine is already on Windows 11 25H2. No upgrade needed."
 
    if (Test-Path $isoPath) {
        try {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            Write-Host ("Deleted leftover ISO: {0}" -f $isoPath)
        } catch {
            Write-Host ("Failed to delete leftover ISO {0}: {1}" -f $isoPath, $_.Exception.Message)
        }
    }
 
    return
}
 
Write-Host "Machine is not 25H2. Proceeding with ISO download..."
 
# Download ISO
try {
    Write-Host "Downloading Windows 11 25H2 ISO..."
    Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    Write-Host ("Download complete: {0}" -f $isoPath)
} catch {
    Write-Host ("Failed to download ISO: {0}" -f $_.Exception.Message)
    exit 1
}
 
if (-not (Test-Path $isoPath)) {
    Write-Host ("ISO not found at {0} after download. Aborting." -f $isoPath)
    exit 1
}
 
# Mount ISO
Write-Host "Mounting ISO..."
 
$mounted = $null
$driveLetter = $null
 
try {
    $mounted = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $volumes = $mounted | Get-Volume
    $driveLetter = ($volumes | Select-Object -ExpandProperty DriveLetter -First 1)
 
    if (-not $driveLetter) {
        Write-Host "Failed to get drive letter for mounted ISO."
        throw "No drive letter found."
    }
 
    Write-Host ("ISO mounted as drive {0}:" -f $driveLetter)
} catch {
    Write-Host ("Failed to mount ISO: {0}" -f $_.Exception.Message)
 
    if (Test-Path $isoPath) {
        try {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            Write-Host ("Deleted ISO after mount failure: {0}" -f $isoPath)
        } catch {
            Write-Host ("Failed to delete ISO after mount failure {0}: {1}" -f $isoPath, $_.Exception.Message)
        }
    }
 
    exit 1
}
 
# Run setup.exe silently
$setupPath = ("{0}:\setup.exe" -f $driveLetter)
 
if (-not (Test-Path $setupPath)) {
    Write-Host ("setup.exe not found at {0}. Aborting." -f $setupPath)
 
    try {
        if ($mounted) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        }
    } catch {}
 
    try {
        if (Test-Path $isoPath) {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
        }
    } catch {}
 
    exit 1
}
 
Write-Host "Starting silent in-place upgrade to Windows 11 25H2..."
Write-Host "This will run with no UI and will NOT force a reboot."
 
# Your requested arguments + EULA accept:
# /Auto Upgrade /Quiet /MigrateDrivers All /DynamicUpdate Disable
# /Telemetry Disable /Compat IgnoreWarning /ShowOOBE None /NoReboot /Eula Accept
$setupArgs = "/Auto Upgrade /Quiet /MigrateDrivers All /DynamicUpdate Disable /Telemetry Disable /Compat IgnoreWarning /ShowOOBE None /NoReboot /Eula Accept"
 
try {
    $process = Start-Process -FilePath $setupPath -ArgumentList $setupArgs -Wait -PassThru
    $exitCode = $process.ExitCode
    Write-Host ("setup.exe exit code: {0}" -f $exitCode)
 
    switch ($exitCode) {
        0 {
            Write-Host "Upgrade completed successfully. A reboot will be required to finish the upgrade."
        }
        3010 {
            Write-Host "Upgrade completed successfully and a reboot is required. Please reboot when convenient."
        }
        default {
            Write-Host ("Setup reported a non-standard exit code: {0}. Check Windows setup logs (Panther folder) for details." -f $exitCode)
        }
    }
} catch {
    Write-Host ("Failed to run setup.exe: {0}" -f $_.Exception.Message)
}
 
# Cleanup: dismount ISO and delete file
Write-Host "Cleaning up mounted ISO and file..."
 
try {
    if ($mounted) {
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        Write-Host "ISO dismounted."
    }
} catch {
    Write-Host ("Failed to dismount ISO: {0}" -f $_.Exception.Message)
}
 
try {
    if (Test-Path $isoPath) {
        Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
        Write-Host ("Deleted ISO file: {0}" -f $isoPath)
    } else {
        Write-Host "No ISO file found to delete."
    }
} catch {
    Write-Host ("Failed to delete ISO file {0}: {1}" -f $isoPath, $_.Exception.Message)
}
 
Write-Host "Done. Please reboot the system manually to complete the upgrade if required."
