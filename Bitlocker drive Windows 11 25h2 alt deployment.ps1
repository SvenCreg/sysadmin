# ==========================================================
# Silent in-place upgrade to Windows 11 25H2 using staged ISO
# - ISO is already staged in the root of E:\
# - E: is BitLocker encrypted and is used as Windows Setup temp drive
# - Checks BitLocker status, unlocks E: if locked, verifies unlock
# - Discovers ISO from E:\ root
# - Mounts ISO
# - Runs compatibility scan
# - Runs setup.exe silently with specified args
# - No user interaction, no forced reboot
# - Preserves Panther logs for troubleshooting
# - Does NOT delete the ISO from E:
# ==========================================================

# ===== CONFIG =====

$targetDisplayVersion = "25H2"

# Staged ISO/temp drive
$stagingDriveLetter = "E"
$stagingRoot = "$stagingDriveLetter`:\"

# Hardcoded placeholder. Replace before running.
$bitLockerPasswordPlainText = "REPLACE_WITH_E_DRIVE_BITLOCKER_PASSWORD"

# Used by Windows Setup for temporary installation files
$tempDriveLetter = $stagingDriveLetter

# Working/log locations
$workRoot = Join-Path $stagingRoot "Win11_Upgrade"
$logRoot  = Join-Path $workRoot "Logs"

# Fallback logging before E: is unlocked
$fallbackLogRoot = Join-Path $env:ProgramData "Win11_Upgrade_E_Drive_Logs"

$minimumTempDriveFreeSpaceGB = 20
$minimumSystemDriveFreeSpaceGB = 20

$bitLockerUnlockWaitSeconds = 60
$bitLockerUnlockPollSeconds = 5

# ISO discovery behavior
$isoSearchPattern = "*.iso"
$isoPreferenceRegex = "(?i)(win|windows).*11|25h2"

# ===== GLOBALS =====

$script:LogRoots = @()
$script:SelectedIsoPath = $null

# ===== FUNCTIONS =====

function Initialize-LogRoot {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }

        if ($script:LogRoots -notcontains $Path) {
            $script:LogRoots += $Path
        }

        return $true
    } catch {
        Write-Host ("Failed to initialize log root {0}: {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[{0}] {1}" -f $timestamp, $Message

    Write-Host $line

    foreach ($root in $script:LogRoots) {
        try {
            if (Test-Path $root) {
                Add-Content -Path (Join-Path $root "UpgradeScript.log") -Value $line
            }
        } catch {
            # Avoid logging failures stopping the script
        }
    }
}

function Write-Phase {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Write-Log ""
    Write-Log ("========== {0} ==========" -f $Name)
}

function Convert-ExitCodeToHex {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $unsignedExitCode = [System.BitConverter]::ToUInt32(
        [System.BitConverter]::GetBytes($ExitCode),
        0
    )

    return ("0x{0:X8}" -f $unsignedExitCode)
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

function Get-CurrentWindowsInfo {
    try {
        $cvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        return Get-ItemProperty -Path $cvKey -ErrorAction Stop
    } catch {
        Write-Log ("Failed to read Windows version information: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Test-IsWindows11 {
    try {
        $props = Get-CurrentWindowsInfo

        if ($null -eq $props) {
            return $false
        }

        # Windows 11 starts at build 22000
        $buildNumber = [int]$props.CurrentBuildNumber

        return ($buildNumber -ge 22000)
    } catch {
        return $false
    }
}

function Test-IsTargetVersion {
    try {
        $props = Get-CurrentWindowsInfo

        if ($null -eq $props) {
            return $false
        }

        $buildNumber = [int]$props.CurrentBuildNumber
        $displayVersion = $props.DisplayVersion

        return (($buildNumber -ge 22000) -and ($displayVersion -eq $targetDisplayVersion))
    } catch {
        return $false
    }
}

function Sync-FallbackLogToPrimary {
    try {
        $fallbackLog = Join-Path $fallbackLogRoot "UpgradeScript.log"
        $primaryPreUnlockLog = Join-Path $logRoot "UpgradeScript-PreEUnlock.log"

        if ((Test-Path $fallbackLog) -and (Test-Path $logRoot)) {
            Copy-Item -Path $fallbackLog -Destination $primaryPreUnlockLog -Force -ErrorAction SilentlyContinue
            Write-Log ("Copied pre-E-unlock log to: {0}" -f $primaryPreUnlockLog)
        }
    } catch {
        Write-Log ("Failed to copy fallback log to E:: {0}" -f $_.Exception.Message)
    }
}

function Get-BitLockerVolumeSafe {
    param (
        [Parameter(Mandatory = $true)]
        [string]$MountPoint
    )

    try {
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            Write-Log "Get-BitLockerVolume cmdlet is not available on this system."
            return $null
        }

        return Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    } catch {
        Write-Log ("Failed to get BitLocker status for {0}: {1}" -f $MountPoint, $_.Exception.Message)
        return $null
    }
}

function Ensure-StagingDriveUnlocked {
    $mountPoint = "$stagingDriveLetter`:"

    Write-Phase "Checking BitLocker Status"

    $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

    if ($null -eq $volume) {
        Write-Log "Unable to determine BitLocker status. Aborting."
        exit 1
    }

    Write-Log ("BitLocker MountPoint: {0}" -f $volume.MountPoint)
    Write-Log ("BitLocker VolumeStatus: {0}" -f $volume.VolumeStatus)
    Write-Log ("BitLocker ProtectionStatus: {0}" -f $volume.ProtectionStatus)
    Write-Log ("BitLocker LockStatus: {0}" -f $volume.LockStatus)

    if ($volume.LockStatus -eq "Unlocked") {
        Write-Log ("{0}: is already unlocked." -f $mountPoint)
        return
    }

    if ($volume.LockStatus -ne "Locked") {
        Write-Log ("Unexpected BitLocker LockStatus for {0}: {1}. Aborting." -f $mountPoint, $volume.LockStatus)
        exit 1
    }

    Write-Phase "Unlocking BitLocker Drive"

    if ([string]::IsNullOrWhiteSpace($bitLockerPasswordPlainText) -or
        $bitLockerPasswordPlainText -eq "REPLACE_WITH_E_DRIVE_BITLOCKER_PASSWORD") {
        Write-Log "BitLocker password placeholder has not been replaced. Aborting."
        exit 1
    }

    try {
        $securePassword = ConvertTo-SecureString $bitLockerPasswordPlainText -AsPlainText -Force

        Write-Log ("Attempting to unlock {0}: using configured password." -f $stagingDriveLetter)

        Unlock-BitLocker `
            -MountPoint $mountPoint `
            -Password $securePassword `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Log ("Unlock-BitLocker failed for {0}: {1}" -f $mountPoint, $_.Exception.Message)
        exit 1
    }

    Write-Phase "Verifying BitLocker Unlock"

    $elapsed = 0

    while ($elapsed -lt $bitLockerUnlockWaitSeconds) {
        Start-Sleep -Seconds $bitLockerUnlockPollSeconds
        $elapsed += $bitLockerUnlockPollSeconds

        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -ne $volume) {
            Write-Log ("Unlock verification check after {0} seconds. LockStatus: {1}" -f $elapsed, $volume.LockStatus)

            if ($volume.LockStatus -eq "Unlocked") {
                Write-Log ("Verified {0}: is unlocked." -f $mountPoint)
                return
            }
        }
    }

    Write-Log ("Failed to verify {0}: unlocked within {1} seconds. Aborting." -f $mountPoint, $bitLockerUnlockWaitSeconds)
    exit 1
}

function Validate-StagingDriveAccess {
    Write-Phase "Validating E Drive Access"

    if (-not (Test-Path $stagingRoot)) {
        Write-Log ("{0} does not exist or is not accessible. Aborting." -f $stagingRoot)
        exit 1
    }

    try {
        if (-not (Test-Path $workRoot)) {
            New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
        }

        if (-not (Test-Path $logRoot)) {
            New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
        }

        Initialize-LogRoot -Path $logRoot | Out-Null
        Sync-FallbackLogToPrimary

        Write-Log ("E drive is accessible: {0}" -f $stagingRoot)
        Write-Log ("Working folder: {0}" -f $workRoot)
        Write-Log ("Primary log folder: {0}" -f $logRoot)
    } catch {
        Write-Log ("Failed to create working/log directory on E:: {0}" -f $_.Exception.Message)
        exit 1
    }
}

function Validate-FreeSpace {
    Write-Phase "Checking Free Space"

    try {
        $tempDrive = Get-PSDrive -Name $tempDriveLetter -ErrorAction Stop
        $tempDriveFreeSpaceGB = [math]::Round(($tempDrive.Free / 1GB), 2)

        Write-Log ("{0}: free space: {1} GB" -f $tempDriveLetter, $tempDriveFreeSpaceGB)

        if ($tempDrive.Free -lt ($minimumTempDriveFreeSpaceGB * 1GB)) {
            Write-Log ("Not enough free space on {0}:. Required: {1} GB. Available: {2} GB." -f $tempDriveLetter, $minimumTempDriveFreeSpaceGB, $tempDriveFreeSpaceGB)
            exit 1
        }
    } catch {
        Write-Log ("Failed to check free space on {0}: {1}" -f $tempDriveLetter, $_.Exception.Message)
        exit 1
    }

    try {
        $systemDriveLetter = $env:SystemDrive.TrimEnd(":")
        $systemDrive = Get-PSDrive -Name $systemDriveLetter -ErrorAction Stop
        $systemFreeSpaceGB = [math]::Round(($systemDrive.Free / 1GB), 2)

        Write-Log ("{0}: free space: {1} GB" -f $systemDriveLetter, $systemFreeSpaceGB)

        if ($systemDrive.Free -lt ($minimumSystemDriveFreeSpaceGB * 1GB)) {
            Write-Log ("Not enough free space on {0}:. Required: {1} GB. Available: {2} GB." -f $systemDriveLetter, $minimumSystemDriveFreeSpaceGB, $systemFreeSpaceGB)
            Write-Log "Even with /TempDrive, Windows Setup still requires free space on the system drive."
            exit 1
        }
    } catch {
        Write-Log ("Failed to check free space on system drive: {0}" -f $_.Exception.Message)
        exit 1
    }
}

function Find-StagedIso {
    Write-Phase "Discovering Staged ISO"

    try {
        $isoCandidates = Get-ChildItem `
            -Path $stagingRoot `
            -Filter $isoSearchPattern `
            -File `
            -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending

        if (-not $isoCandidates -or $isoCandidates.Count -eq 0) {
            Write-Log ("No ISO files found in {0}. Aborting." -f $stagingRoot)
            exit 1
        }

        Write-Log ("ISO candidates found in {0}: {1}" -f $stagingRoot, $isoCandidates.Count)

        foreach ($candidate in $isoCandidates) {
            $candidateSizeGB = [math]::Round(($candidate.Length / 1GB), 2)
            Write-Log ("Candidate ISO: {0} | Size: {1} GB | LastWriteTime: {2}" -f $candidate.FullName, $candidateSizeGB, $candidate.LastWriteTime)
        }

        $preferredCandidates = $isoCandidates | Where-Object { $_.Name -match $isoPreferenceRegex }

        if ($preferredCandidates -and $preferredCandidates.Count -gt 0) {
            $selectedIso = $preferredCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            Write-Log ("Selected preferred ISO candidate: {0}" -f $selectedIso.FullName)
        } else {
            $selectedIso = $isoCandidates | Select-Object -First 1
            Write-Log ("No ISO matched preference regex. Selected newest ISO: {0}" -f $selectedIso.FullName)
        }

        if ($selectedIso.Length -lt 1GB) {
            Write-Log ("Selected ISO appears too small: {0} bytes. Aborting." -f $selectedIso.Length)
            exit 1
        }

        $script:SelectedIsoPath = $selectedIso.FullName

        $selectedIsoSizeGB = [math]::Round(($selectedIso.Length / 1GB), 2)
        Write-Log ("Final selected ISO: {0}" -f $script:SelectedIsoPath)
        Write-Log ("Selected ISO size: {0} GB" -f $selectedIsoSizeGB)
    } catch {
        Write-Log ("Failed to discover staged ISO: {0}" -f $_.Exception.Message)
        exit 1
    }
}

function Dismount-IsoSafely {
    Write-Phase "Dismounting ISO"

    try {
        if ($script:SelectedIsoPath -and (Test-Path $script:SelectedIsoPath)) {
            Dismount-DiskImage -ImagePath $script:SelectedIsoPath -ErrorAction SilentlyContinue | Out-Null
            Write-Log "ISO dismount command completed."
        } else {
            Write-Log "No selected ISO path was available for dismount."
        }
    } catch {
        Write-Log ("Failed to dismount ISO: {0}" -f $_.Exception.Message)
    }
}

function Preserve-SetupLogs {
    Write-Phase "Preserving Setup Logs"

    try {
        if (-not (Test-Path $logRoot)) {
            New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
        }

        $pantherPath = "C:\`$WINDOWS.~BT\Sources\Panther"

        if (Test-Path $pantherPath) {
            $destination = Join-Path $logRoot "Panther"

            if (Test-Path $destination) {
                Remove-Item $destination -Recurse -Force -ErrorAction SilentlyContinue
            }

            Copy-Item -Path $pantherPath -Destination $destination -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log ("Copied Panther logs to: {0}" -f $destination)
        } else {
            Write-Log "Panther log folder was not found."
        }
    } catch {
        Write-Log ("Failed to preserve setup logs: {0}" -f $_.Exception.Message)
    }
}

# ===== MAIN LOGIC =====

Initialize-LogRoot -Path $fallbackLogRoot | Out-Null

Write-Phase "Starting Script"
Write-Log "Starting Windows 11 25H2 upgrade script."
Write-Log ("Fallback log folder: {0}" -f $fallbackLogRoot)
Write-Log ("Target DisplayVersion: {0}" -f $targetDisplayVersion)
Write-Log ("Staging/temp drive: {0}:" -f $stagingDriveLetter)
Write-Log "BITS/download workflow is disabled. ISO must already exist in E:\ root."

Write-Phase "Checking Administrator Rights"

if (-not (Test-IsAdmin)) {
    Write-Log "This script must be run as Administrator."
    exit 1
}

Write-Log "Administrator rights confirmed."

Ensure-StagingDriveUnlocked
Validate-StagingDriveAccess

Write-Phase "Checking Current Windows Version"

$currentWindowsInfo = Get-CurrentWindowsInfo

if ($null -ne $currentWindowsInfo) {
    Write-Log ("Current ProductName: {0}" -f $currentWindowsInfo.ProductName)
    Write-Log ("Current DisplayVersion: {0}" -f $currentWindowsInfo.DisplayVersion)
    Write-Log ("Current Build: {0}" -f $currentWindowsInfo.CurrentBuildNumber)
}

if (Test-IsTargetVersion) {
    Write-Log ("This machine is already on Windows 11 {0}. No upgrade needed." -f $targetDisplayVersion)
    Write-Log "No ISO cleanup will be performed."
    exit 0
}

if (Test-IsWindows11) {
    Write-Log "Detected Windows 11."
} else {
    Write-Log "Machine does not appear to be on Windows 11. Continuing because Windows 10 to Windows 11 in-place upgrade may be intended."
}

Validate-FreeSpace
Find-StagedIso

# Mount ISO
Write-Phase "Mounting ISO"

$mounted = $null
$driveLetter = $null

try {
    $mounted = Mount-DiskImage -ImagePath $script:SelectedIsoPath -PassThru -ErrorAction Stop
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
Write-Phase "Validating Setup Media"

$setupPath = ("{0}:\setup.exe" -f $driveLetter)

if (-not (Test-Path $setupPath)) {
    Write-Log ("setup.exe not found at {0}. Aborting." -f $setupPath)
    Dismount-IsoSafely
    exit 1
}

Write-Log ("setup.exe found: {0}" -f $setupPath)

# Compatibility scan
# Important:
# For /Compat ScanOnly, 0xC1900210 means the scan completed and no compatibility issues were found.
Write-Phase "Running Compatibility Scan"

$compatArgs = "/Auto Upgrade /Quiet /Compat ScanOnly /DynamicUpdate Disable /Telemetry Disable /Eula Accept /TempDrive $tempDriveLetter"

Write-Log ("Compatibility scan arguments: {0}" -f $compatArgs)

try {
    $compatProcess = Start-Process -FilePath $setupPath -ArgumentList $compatArgs -Wait -PassThru
    $compatExitCode = $compatProcess.ExitCode
    $compatExitCodeHex = Convert-ExitCodeToHex -ExitCode $compatExitCode

    Write-Log ("Compatibility scan exit code: {0} ({1})" -f $compatExitCode, $compatExitCodeHex)

    switch ($compatExitCodeHex) {
        "0xC1900210" {
            Write-Log "Compatibility scan completed successfully. No compatibility issues found. Continuing with upgrade."
        }

        "0x00000000" {
            Write-Log "Compatibility scan completed with exit code 0. Continuing with upgrade."
        }

        "0xC1900208" {
            Write-Log "Compatibility scan found blocking app or driver compatibility issues. Aborting upgrade."
            Preserve-SetupLogs
            Dismount-IsoSafely
            exit $compatExitCode
        }

        "0xC1900200" {
            Write-Log "Compatibility scan failed: system does not meet Windows 11 requirements. Aborting upgrade."
            Preserve-SetupLogs
            Dismount-IsoSafely
            exit $compatExitCode
        }

        "0xC1900204" {
            Write-Log "Compatibility scan failed: selected migration choice is not available. Check edition, language, or architecture compatibility."
            Preserve-SetupLogs
            Dismount-IsoSafely
            exit $compatExitCode
        }

        "0xC190020E" {
            Write-Log "Compatibility scan failed: insufficient disk space for installation."
            Write-Log "E: is being used with /TempDrive, but Windows Setup still requires enough free space on the system drive."
            Preserve-SetupLogs
            Dismount-IsoSafely
            exit $compatExitCode
        }

        default {
            Write-Log ("Compatibility scan returned unexpected exit code: {0} ({1}). Aborting upgrade." -f $compatExitCode, $compatExitCodeHex)
            Preserve-SetupLogs
            Dismount-IsoSafely
            exit $compatExitCode
        }
    }
} catch {
    Write-Log ("Failed to run compatibility scan: {0}" -f $_.Exception.Message)
    Preserve-SetupLogs
    Dismount-IsoSafely
    exit 1
}

# Run setup.exe
Write-Phase "Running Silent In-Place Upgrade"

Write-Log ("Starting silent in-place upgrade to Windows 11 {0}..." -f $targetDisplayVersion)
Write-Log "No UI. No forced reboot."

$setupArgs = "/Auto Upgrade /Quiet /MigrateDrivers All /DynamicUpdate Disable /Telemetry Disable /Compat IgnoreWarning /ShowOOBE None /NoReboot /Eula Accept /TempDrive $tempDriveLetter"

Write-Log ("Setup arguments: {0}" -f $setupArgs)

$success = $false
$exitCode = 1

try {
    $process = Start-Process -FilePath $setupPath -ArgumentList $setupArgs -Wait -PassThru
    $exitCode = $process.ExitCode
    $exitCodeHex = Convert-ExitCodeToHex -ExitCode $exitCode

    Write-Log ("setup.exe exit code: {0} ({1})" -f $exitCode, $exitCodeHex)

    switch ($exitCode) {
        0 {
            Write-Log "Upgrade command completed successfully. Reboot required."
            $success = $true
        }

        3010 {
            Write-Log "Upgrade command completed successfully. Reboot required."
            $success = $true
        }

        default {
            Write-Log ("Upgrade failed or returned unexpected exit code: {0} ({1}). Check Panther logs." -f $exitCode, $exitCodeHex)
            $success = $false
        }
    }
} catch {
    Write-Log ("Failed to run setup.exe: {0}" -f $_.Exception.Message)
    $success = $false
    $exitCode = 1
}

# Always try to preserve setup logs before exit
Preserve-SetupLogs

# Dismount ISO
Dismount-IsoSafely

Write-Phase "Final Status"

if ($success) {
    Write-Log "Upgrade command completed successfully."
    Write-Log "No ISO cleanup was performed. The staged ISO remains on E:."
    Write-Log "Done. Please reboot the system manually if required."
    exit 0
} else {
    Write-Log "Upgrade did not complete successfully."
    Write-Log ("Leaving files in place for troubleshooting: {0}" -f $workRoot)
    Write-Log "Review logs under the Logs folder and Panther logs if available."
    Write-Log "No ISO cleanup was performed. The staged ISO remains on E:."

    exit $exitCode
}
