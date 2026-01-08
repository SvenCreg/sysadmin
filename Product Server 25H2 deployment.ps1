# ==========================================================
# Silent in-place upgrade using Windows 11 25H2 ISO
# - Downloads ISO
# - Mounts it
# - Runs sources\setupprep.exe with /product server
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
        return ($props.DisplayVersion -eq '25H2')
    } catch {
        return $false
    }
}

# ===== MAIN LOGIC =====
Write-Host "Checking current Windows DisplayVersion..."

if (Test-Is25H2) {
    Write-Host "This machine is already on Windows 11 25H2. No upgrade needed."
    if (Test-Path $isoPath) {
        Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
    }
    return
}

Write-Host "Machine is not 25H2. Proceeding with ISO download..."

# Download ISO
try {
    Write-Host "Downloading Windows 11 25H2 ISO..."
    Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
    Write-Host "Download complete."
} catch {
    Write-Host "Failed to download ISO: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path $isoPath)) {
    Write-Host "ISO not found after download. Aborting."
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
        throw "No drive letter assigned to mounted ISO."
    }

    Write-Host "ISO mounted as drive $driveLetter`:"
} catch {
    Write-Host "Failed to mount ISO: $($_.Exception.Message)"
    Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
    exit 1
}

# Run setupprep.exe from sources
$setupPrepPath = "$driveLetter`:\sources\setupprep.exe"

if (-not (Test-Path $setupPrepPath)) {
    Write-Host "setupprep.exe not found at $setupPrepPath. Aborting."
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Starting silent in-place upgrade using setupprep.exe..."
Write-Host "Product: Server | No UI | No forced reboot"

# Arguments:
# /product server is the key change
$setupArgs = @(
    "/product server",
    "/Auto Upgrade",
    "/Quiet",
    "/MigrateDrivers All",
    "/DynamicUpdate Disable",
    "/Telemetry Disable",
    "/Compat IgnoreWarning",
    "/ShowOOBE None",
    "/NoReboot",
    "/Eula Accept"
) -join " "

try {
    $process = Start-Process `
        -FilePath $setupPrepPath `
        -ArgumentList $setupArgs `
        -Wait `
        -PassThru

    $exitCode = $process.ExitCode
    Write-Host "setupprep.exe exit code: $exitCode"

    switch ($exitCode) {
        0    { Write-Host "Upgrade completed successfully. Reboot required." }
        3010 { Write-Host "Upgrade completed. Reboot required." }
        default {
            Write-Host "Non-standard exit code $exitCode. Check Panther logs."
        }
    }
} catch {
    Write-Host "Failed to run setupprep.exe: $($_.Exception.Message)"
}

# Cleanup
Write-Host "Cleaning up..."
try {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
} catch {}

Write-Host "Done. Please reboot manually to complete the upgrade."
