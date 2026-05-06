# ==========================================================
# Silent in-place upgrade to Windows 11 25H2 using ISO
# - Downloads ISO to D:\Temp using BITS with retries
# - Mounts it
# - Runs setup.exe silently with specified args
# - No user interaction, no forced reboot
# - Preserves files/logs on failure for troubleshooting
# - Cleans up ISO and temp folder only on success or if already upgraded
# ==========================================================

# ===== CONFIG =====
$isoUrl = "https://REPLACE.ME/Win11_25H2_English_x64.iso?"

$workRoot = "D:\Temp\Win11_Upgrade"
$isoPath  = Join-Path $workRoot "Win11_25H2_English_x64.iso"
$logRoot  = Join-Path $workRoot "Logs"

$minimumFreeSpaceGB = 20
$maxDownloadAttempts = 3
$downloadRetryDelaySeconds = 30

# ===== FUNCTIONS =====

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] {1}" -f $timestamp, $Message

    Write-Host $line

    try {
        if (Test-Path $logRoot) {
            Add-Content -Path (Join-Path $logRoot "UpgradeScript.log") -Value $line
        }
    } catch {
        # Avoid logging failures stopping the script
    }
}

function Test-IsAdmin {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

        return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-Is25H2 {
    try {
        $cvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $props = Get-ItemProperty -Path $cvKey -ErrorAction Stop

        return ($props.DisplayVersion -eq '25H2')
    } catch {
        return $false
    }
}

function Test-IsWindows11 {
    try {
        $cvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $props = Get-ItemProperty -Path $cvKey -ErrorAction Stop

        # Windows 11 starts at build 22000
        $buildNumber = [int]$props.CurrentBuildNumber

        return ($buildNumber -ge 22000)
    } catch {
        return $false
    }
}

function Cleanup-DTemp {
    Write-Log "Cleaning up D: temp files..."

    try {
        if (Test-Path $isoPath) {
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted ISO."
        }

        if (Test-Path $workRoot) {
            Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted temp folder."
        }
    } catch {
        Write-Log ("Cleanup failed: {0}" -f $_.Exception.Message)
    }
}

function Preserve-SetupLogs {
    try {
        if (-not (Test-Path $logRoot)) {
            New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
        }

        $pantherPath = "C:\$WINDOWS.~BT\Sources\Panther"

        if (Test-Path $pantherPath) {
            $destination = Join-Path $logRoot "Panther"
            Copy-Item -Path $pantherPath -Destination $destination -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log ("Copied Panther logs to: {0}" -f $destination)
        } else {
            Write-Log "Panther log folder was not found."
        }
    } catch {
        Write-Log ("Failed to preserve setup logs: {0}" -f $_.Exception.Message)
    }
}

function Dismount-IsoSafely {
    try {
        if (Test-Path $isoPath) {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
            Write-Log "ISO dismounted."
        }
    } catch {
        Write-Log ("Failed to dismount ISO: {0}" -f $_.Exception.Message)
    }
}

function Stop-ExistingBitsJobs {
    try {
        $existingJobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq "Windows 11 25H2 ISO Download" }

        foreach ($job in $existingJobs) {
            Write-Log ("Removing existing BITS job: {0}" -f $job.DisplayName)
            Remove-BitsTransfer -BitsJob $job -Confirm:$false -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log ("Failed to remove existing BITS jobs: {0}" -f $_.Exception.Message)
    }
}

function Download-IsoWithBits {
    $downloadSucceeded = $false

    for ($attempt = 1; $attempt -le $maxDownloadAttempts; $attempt++) {
        try {
            Write-Log ("Downloading Windows 11 25H2 ISO using BITS. Attempt {0} of {1}..." -f $attempt, $maxDownloadAttempts)
            Write-Log ("Download URL: {0}" -f $isoUrl)

            Stop-ExistingBitsJobs

            if (Test-Path $isoPath) {
                Write-Log "Existing partial or previous ISO found. Removing it before download."
                Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            }

            Start-BitsTransfer `
                -Source $isoUrl `
                -Destination $isoPath `
                -DisplayName "Windows 11 25H2 ISO Download" `
                -Description "Downloading Windows 11 25H2 ISO for in-place upgrade" `
                -TransferType Download `
                -ErrorAction Stop

            Write-Log ("Download complete: {0}" -f $isoPath)

            $downloadSucceeded = $true
            break
        } catch {
            Write-Log ("Download attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)

            Stop-ExistingBitsJobs

            if ($attempt -lt $maxDownloadAttempts) {
                Write-Log ("Retrying download in {0} seconds..." -f $downloadRetryDelaySeconds)
                Start-Sleep -Seconds $downloadRetryDelaySeconds
            }
        }
    }

    return $downloadSucceeded
}

# ===== MAIN LOGIC =====

# Ensure working/log directory exists early
try {
    if (-not (Test-Path $workRoot)) {
        New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $logRoot)) {
        New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
    }
} catch {
    Write-Host ("Failed to create working/log directory: {0}" -f $_.Exception.Message)
    exit 1
}

Write-Log "Starting Windows 11 25H2 upgrade script."

# Check admin rights
if (-not (Test-IsAdmin)) {
    Write-Log "This script must be run as Administrator."
    exit 1
}

# Check current version
Write-Log "Checking current Windows DisplayVersion..."

if (Test-Is25H2) {
    Write-Log "This machine is already on Windows 11 25H2. No upgrade needed."
    Cleanup-DTemp
    exit 0
}

# Optional Windows 11 check
# This allows Windows 10 to Windows 11 upgrades, so we do not block if false.
if (Test-IsWindows11) {
    Write-Log "Detected Windows 11."
} else {
    Write-Log "Machine does not appear to be on Windows 11. Continuing because Windows 10 to Windows 11 in-place upgrade may be intended."
}

# Validate D: drive exists
if (-not (Test-Path "D:\")) {
    Write-Log "D: drive does not exist. Aborting."
    exit 1
}

# Validate free space
try {
    $drive = Get-PSDrive -Name D -ErrorAction Stop
    $freeSpaceGB = [math]::Round(($drive.Free / 1GB), 2)

    Write-Log ("D: free space: {0} GB" -f $freeSpaceGB)

    if ($drive.Free -lt ($minimumFreeSpaceGB * 1GB)) {
        Write-Log ("Not enough free space on D:. Required: {0} GB. Available: {1} GB." -f $minimumFreeSpaceGB, $freeSpaceGB)
        exit 1
    }
} catch {
    Write-Log ("Failed to check free space on D:: {0}" -f $_.Exception.Message)
    exit 1
}

# Basic ISO URL validation
if ($isoUrl -like "*REPLACE.ME*") {
    Write-Log "ISO URL is still a placeholder. Replace `$isoUrl before running."
    exit 1
}

# Download ISO using BITS with retries
if (-not (Download-IsoWithBits)) {
    Write-Log "ISO download failed after all retry attempts. Aborting."
    exit 1
}

if (-not (Test-Path $isoPath)) {
    Write-Log ("ISO not found at {0}. Aborting." -f $isoPath)
    exit 1
}

# Validate downloaded ISO size
try {
    $isoItem = Get-Item $isoPath -ErrorAction Stop
    $isoSizeGB = [math]::Round(($isoItem.Length / 1GB), 2)

    Write-Log ("Downloaded ISO size: {0} GB" -f $isoSizeGB)

    if ($isoItem.Length -lt 1GB) {
        Write-Log "Downloaded ISO appears too small. Aborting."
        exit 1
    }
} catch {
    Write-Log ("Failed to validate ISO size: {0}" -f $_.Exception.Message)
    exit 1
}

# Mount ISO
Write-Log "Mounting ISO..."

$mounted = $null
$driveLetter = $null

try {
    $mounted = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 3

    $driveLetter = ($mounted | Get-Volume | Select-Object -ExpandProperty DriveLetter -First 1)

    if (-not $driveLetter) {
        throw "No drive letter assigned."
    }

    Write-Log ("ISO mounted as drive {0}:" -f $driveLetter)
} catch {
    Write-Log ("Failed to mount ISO: {0}" -f $_.Exception.Message)
    exit 1
}

# Validate setup.exe exists
$setupPath = ("{0}:\setup.exe" -f $driveLetter)

if (-not (Test-Path $setupPath)) {
    Write-Log ("setup.exe not found at {0}. Aborting." -f $setupPath)
    Dismount-IsoSafely
    exit 1
}

# Optional compatibility scan
# This helps detect blockers before attempting the real upgrade.
Write-Log "Starting Windows Setup compatibility scan..."

$compatArgs = "/Auto Upgrade /Quiet /Compat ScanOnly /DynamicUpdate Disable /Telemetry Disable /Eula Accept"

try {
    $compatProcess = Start-Process -FilePath $setupPath -ArgumentList $compatArgs -Wait -PassThru
    $compatExitCode = $compatProcess.ExitCode

    Write-Log ("Compatibility scan exit code: {0}" -f $compatExitCode)

    if ($compatExitCode -ne 0) {
        Write-Log "Compatibility scan returned a non-zero exit code. Aborting upgrade attempt."
        Preserve-SetupLogs
        Dismount-IsoSafely
        exit $compatExitCode
    }
} catch {
    Write-Log ("Failed to run compatibility scan: {0}" -f $_.Exception.Message)
    Preserve-SetupLogs
    Dismount-IsoSafely
    exit 1
}

# Run setup.exe
Write-Log "Starting silent in-place upgrade to Windows 11 25H2..."
Write-Log "No UI. No forced reboot."

$setupArgs = "/Auto Upgrade /Quiet /MigrateDrivers All /DynamicUpdate Disable /Telemetry Disable /Compat IgnoreWarning /ShowOOBE None /NoReboot /Eula Accept"

$success = $false
$exitCode = 1

try {
    $process = Start-Process -FilePath $setupPath -ArgumentList $setupArgs -Wait -PassThru
    $exitCode = $process.ExitCode

    Write-Log ("setup.exe exit code: {0}" -f $exitCode)

    switch ($exitCode) {
        0 {
            Write-Log "Upgrade completed successfully. Reboot required."
            $success = $true
        }

        3010 {
            Write-Log "Upgrade completed successfully. Reboot required."
            $success = $true
        }

        default {
            Write-Log ("Upgrade failed or returned unexpected exit code: {0}. Check Panther logs." -f $exitCode)
            $success = $false
        }
    }
} catch {
    Write-Log ("Failed to run setup.exe: {0}" -f $_.Exception.Message)
    $success = $false
    $exitCode = 1
}

# Always try to preserve setup logs before cleanup or exit
Preserve-SetupLogs

# Dismount ISO
Dismount-IsoSafely

# Cleanup only on success
if ($success) {
    Write-Log "Upgrade command completed successfully. Cleaning up temporary files."
    Cleanup-DTemp

    Write-Log "Done. Please reboot the system manually if required."
    exit 0
} else {
    Write-Log "Upgrade did not complete successfully."
    Write-Log ("Leaving files in place for troubleshooting: {0}" -f $workRoot)
    Write-Log "Review logs under the Logs folder and Panther logs if available."

    exit $exitCode
}
