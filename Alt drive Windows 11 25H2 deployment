# ==========================================================
# Silent in-place upgrade to Windows 11 25H2 using ISO
# - Downloads ISO to D:\Temp
# - Mounts it
# - Runs setup.exe silently with your args
# - No user interaction, no forced reboot
# - Cleans up ISO and temp folder from D:
# ==========================================================

# ===== CONFIG =====
$isoUrl = "https://REPLACE.ME/Win11_25H2_English_x64.iso?"

$workRoot = "D:\Temp\Win11_Upgrade"
$isoPath  = Join-Path $workRoot "Win11_25H2_English_x64.iso"

# ===== FUNCTIONS =====
function Test-Is25H2 {
    try {
        $cvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $props = Get-ItemProperty -Path $cvKey -ErrorAction Stop
        return ($props.DisplayVersion -eq '25H2')
    } catch {
        return $false
    }
}

function Cleanup-DTemp {
    Write-Host "Cleaning up D: temp files..."

    try {
        if (Test-Path $isoPath) {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            Write-Host "Deleted ISO."
        }

        if (Test-Path $workRoot) {
            Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Deleted temp folder."
        }
    } catch {
        Write-Host ("Cleanup failed: {0}" -f $_.Exception.Message)
    }
}

# ===== MAIN LOGIC =====

Write-Host "Checking current Windows DisplayVersion..."

if (Test-Is25H2) {
    Write-Host "This machine is already on Windows 11 25H2. No upgrade needed."
    Cleanup-DTemp
    return
}

# Ensure D:\Temp working directory exists
try {
    if (-not (Test-Path $workRoot)) {
        New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
        Write-Host ("Created temp directory: {0}" -f $workRoot)
    }
} catch {
    Write-Host ("Failed to create D: temp directory: {0}" -f $_.Exception.Message)
    exit 1
}

# Download ISO
try {
    Write-Host "Downloading Windows 11 25H2 ISO to D: drive..."
    Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    Write-Host ("Download complete: {0}" -f $isoPath)
} catch {
    Write-Host ("Failed to download ISO: {0}" -f $_.Exception.Message)
    Cleanup-DTemp
    exit 1
}

if (-not (Test-Path $isoPath)) {
    Write-Host ("ISO not found at {0}. Aborting." -f $isoPath)
    Cleanup-DTemp
    exit 1
}

# Mount ISO
Write-Host "Mounting ISO..."

$mounted = $null
$driveLetter = $null

try {
    $mounted = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $driveLetter = ($mounted | Get-Volume | Select-Object -ExpandProperty DriveLetter -First 1)

    if (-not $driveLetter) {
        throw "No drive letter assigned."
    }

    Write-Host ("ISO mounted as drive {0}:" -f $driveLetter)
} catch {
    Write-Host ("Failed to mount ISO: {0}" -f $_.Exception.Message)
    Cleanup-DTemp
    exit 1
}

# Run setup.exe
$setupPath = ("{0}:\setup.exe" -f $driveLetter)

if (-not (Test-Path $setupPath)) {
    Write-Host ("setup.exe not found at {0}. Aborting." -f $setupPath)
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    Cleanup-DTemp
    exit 1
}

Write-Host "Starting silent in-place upgrade to Windows 11 25H2..."
Write-Host "No UI. No forced reboot."

$setupArgs = "/Auto Upgrade /Quiet /MigrateDrivers All /DynamicUpdate Disable /Telemetry Disable /Compat IgnoreWarning /ShowOOBE None /NoReboot /Eula Accept"

try {
    $process = Start-Process -FilePath $setupPath -ArgumentList $setupArgs -Wait -PassThru
    $exitCode = $process.ExitCode

    Write-Host ("setup.exe exit code: {0}" -f $exitCode)

    switch ($exitCode) {
        0     { Write-Host "Upgrade completed successfully. Reboot required." }
        3010  { Write-Host "Upgrade completed successfully. Reboot required." }
        default {
            Write-Host ("Non-standard exit code: {0}. Check Panther logs." -f $exitCode)
        }
    }
} catch {
    Write-Host ("Failed to run setup.exe: {0}" -f $_.Exception.Message)
}

# Cleanup
try {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    Write-Host "ISO dismounted."
} catch {}

Cleanup-DTemp

Write-Host "Done. Please reboot the system manually if required."
