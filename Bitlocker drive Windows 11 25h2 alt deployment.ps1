# ==========================================================
# Silent in-place upgrade to Windows 11 25H2 using staged ISO
# - ISO is already staged in the root of E:\
# - E: is BitLocker encrypted and used as Windows Setup temp drive
# - Only E: BitLocker state is touched
# - Captures original E: BitLocker state before changes
# - Unlocks E: using a hardcoded password placeholder
# - Temporarily enables E: auto-unlock only if needed
# - Restores E: to original BitLocker state after upgrade reaches 25H2
# - Restores E: immediately if setup fails before reboot
# - Discovers ISO from E:\ root
# - Runs compatibility scan
# - Runs setup.exe silently
# - No user interaction, no forced reboot
# - Preserves Panther logs
# - Does NOT delete the ISO from E:
# ==========================================================

# ===== CONFIG =====

$targetDisplayVersion = "25H2"

# Staged ISO/temp drive
$stagingDriveLetter = "E"
$stagingRoot = "$($stagingDriveLetter):\"

# Hardcoded placeholder. Replace before running.
$bitLockerPasswordPlainText = "REPLACE_WITH_E_DRIVE_BITLOCKER_PASSWORD"

# Used by Windows Setup for temporary installation files
$tempDriveLetter = $stagingDriveLetter

# Working/log locations on E: after unlock
$workRoot = Join-Path $stagingRoot "Win11_Upgrade"
$logRoot  = Join-Path $workRoot "Logs"

# Fallback logging and post-upgrade restore files.
# These must NOT live on E:, because E: may be locked when the restore task runs.
$fallbackLogRoot = Join-Path $env:ProgramData "Win11_Upgrade_E_Drive_Logs"

# E: state restoration
$restoreStagingDriveOriginalState = $true
$postUpgradeTaskName = "Win11Upgrade_Restore_E_BitLocker_State"
$postUpgradeRestoreScriptPath = Join-Path $fallbackLogRoot "Restore-E-BitLocker-State-AfterUpgrade.ps1"
$stagingDriveStatePath = Join-Path $fallbackLogRoot "E-BitLocker-Original-State.json"

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
$script:OriginalEBitLockerState = $null

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

function Save-OriginalEBitLockerState {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Volume
    )

    Write-Phase "Capturing Original E BitLocker State"

    try {
        $state = [PSCustomObject]@{
            CaptureTime               = (Get-Date).ToString("o")
            StagingDriveLetter        = $stagingDriveLetter
            MountPoint                = "$($stagingDriveLetter):"
            OriginalLockStatus        = [string]$Volume.LockStatus
            OriginalAutoUnlockEnabled = [bool]$Volume.AutoUnlockEnabled
            OriginalProtectionStatus  = [string]$Volume.ProtectionStatus
            OriginalVolumeStatus      = [string]$Volume.VolumeStatus
            TargetDisplayVersion      = $targetDisplayVersion
        }

        $script:OriginalEBitLockerState = $state

        if (-not (Test-Path $fallbackLogRoot)) {
            New-Item -Path $fallbackLogRoot -ItemType Directory -Force | Out-Null
        }

        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stagingDriveStatePath -Encoding UTF8 -Force

        Write-Log ("Original E: LockStatus: {0}" -f $state.OriginalLockStatus)
        Write-Log ("Original E: AutoUnlockEnabled: {0}" -f $state.OriginalAutoUnlockEnabled)
        Write-Log ("Original E: ProtectionStatus: {0}" -f $state.OriginalProtectionStatus)
        Write-Log ("Original E: VolumeStatus: {0}" -f $state.OriginalVolumeStatus)
        Write-Log ("Original E: state saved to: {0}" -f $stagingDriveStatePath)
    } catch {
        Write-Log ("Failed to save original E: BitLocker state: {0}" -f $_.Exception.Message)
        exit 1
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

function Ensure-StagingDriveUnlocked {
    $mountPoint = "$($stagingDriveLetter):"

    Write-Phase "Checking E BitLocker Status"

    $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

    if ($null -eq $volume) {
        Write-Log "Unable to determine E: BitLocker status. Aborting."
        exit 1
    }

    Save-OriginalEBitLockerState -Volume $volume

    Write-Log ("E: BitLocker MountPoint: {0}" -f $volume.MountPoint)
    Write-Log ("E: BitLocker VolumeStatus: {0}" -f $volume.VolumeStatus)
    Write-Log ("E: BitLocker ProtectionStatus: {0}" -f $volume.ProtectionStatus)
    Write-Log ("E: BitLocker LockStatus: {0}" -f $volume.LockStatus)
    Write-Log ("E: BitLocker AutoUnlockEnabled: {0}" -f $volume.AutoUnlockEnabled)

    if ($volume.LockStatus -eq "Unlocked") {
        Write-Log "E: is already unlocked."
        return
    }

    if ($volume.LockStatus -ne "Locked") {
        Write-Log ("Unexpected E: BitLocker LockStatus: {0}. Aborting." -f $volume.LockStatus)
        exit 1
    }

    Write-Phase "Unlocking E BitLocker Drive"

    if ([string]::IsNullOrWhiteSpace($bitLockerPasswordPlainText) -or
        $bitLockerPasswordPlainText -eq "REPLACE_WITH_E_DRIVE_BITLOCKER_PASSWORD") {
        Write-Log "BitLocker password placeholder has not been replaced. Aborting."
        exit 1
    }

    try {
        $securePassword = ConvertTo-SecureString $bitLockerPasswordPlainText -AsPlainText -Force

        Write-Log "Attempting to unlock E: using configured password."

        Unlock-BitLocker `
            -MountPoint $mountPoint `
            -Password $securePassword `
            -ErrorAction Stop | Out-Null
    } catch {
        Write-Log ("Unlock-BitLocker failed for E:: {0}" -f $_.Exception.Message)
        exit 1
    }

    Write-Phase "Verifying E Unlock"

    $elapsed = 0

    while ($elapsed -lt $bitLockerUnlockWaitSeconds) {
        Start-Sleep -Seconds $bitLockerUnlockPollSeconds
        $elapsed += $bitLockerUnlockPollSeconds

        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -ne $volume) {
            Write-Log ("E: unlock verification check after {0} seconds. LockStatus: {1}" -f $elapsed, $volume.LockStatus)

            if ($volume.LockStatus -eq "Unlocked") {
                Write-Log "Verified E: is unlocked."
                return
            }
        }
    }

    Write-Log ("Failed to verify E: unlocked within {0} seconds. Aborting." -f $bitLockerUnlockWaitSeconds)
    exit 1
}

function Enable-EAutoUnlockTemporarily {
    $mountPoint = "$($stagingDriveLetter):"

    Write-Phase "Temporarily Configuring E Auto-Unlock"

    try {
        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -eq $volume) {
            Write-Log "Unable to read E: BitLocker volume before enabling auto-unlock. Aborting."
            Restore-OriginalEBitLockerState -Reason "Unable to read E: before auto-unlock"
            exit 1
        }

        if ($volume.LockStatus -ne "Unlocked") {
            Write-Log "E: is not unlocked. Auto-unlock cannot be enabled. Aborting."
            Restore-OriginalEBitLockerState -Reason "E: was not unlocked before auto-unlock"
            exit 1
        }

        Write-Log ("Current E: AutoUnlockEnabled: {0}" -f $volume.AutoUnlockEnabled)

        if ($volume.AutoUnlockEnabled -eq $true) {
            Write-Log "E: auto-unlock is already enabled. No auto-unlock change needed."
            return
        }

        Write-Log "Temporarily enabling E: auto-unlock so Windows Setup can access E: after reboot."

        Enable-BitLockerAutoUnlock `
            -MountPoint $mountPoint `
            -ErrorAction Stop | Out-Null

        Start-Sleep -Seconds 3

        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -eq $volume) {
            Write-Log "Unable to verify E: auto-unlock state after enabling. Aborting."
            Restore-OriginalEBitLockerState -Reason "Unable to verify E: auto-unlock"
            exit 1
        }

        Write-Log ("Post-enable E: AutoUnlockEnabled: {0}" -f $volume.AutoUnlockEnabled)

        if ($volume.AutoUnlockEnabled -ne $true) {
            Write-Log "Failed to verify E: auto-unlock enabled. Aborting."
            Restore-OriginalEBitLockerState -Reason "E: auto-unlock did not verify"
            exit 1
        }

        Write-Log "Verified E: auto-unlock is temporarily enabled."
    } catch {
        Write-Log ("Failed to enable or verify E: auto-unlock: {0}" -f $_.Exception.Message)
        Restore-OriginalEBitLockerState -Reason "E: auto-unlock enable failure"
        exit 1
    }
}

function Restore-OriginalEBitLockerState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    Write-Phase "Restoring Original E BitLocker State"
    Write-Log ("Restore reason: {0}" -f $Reason)

    if (-not $restoreStagingDriveOriginalState) {
        Write-Log "E: original state restoration is disabled by config."
        return
    }

    try {
        $state = $script:OriginalEBitLockerState

        if ($null -eq $state -and (Test-Path $stagingDriveStatePath)) {
            $state = Get-Content -Path $stagingDriveStatePath -Raw | ConvertFrom-Json
        }

        if ($null -eq $state) {
            Write-Log "Original E: BitLocker state is unavailable. Cannot restore."
            return
        }

        $mountPoint = "$($stagingDriveLetter):"
        $originalLockStatus = [string]$state.OriginalLockStatus
        $originalAutoUnlockEnabled = [System.Convert]::ToBoolean($state.OriginalAutoUnlockEnabled)

        Write-Log ("Original E: LockStatus should be: {0}" -f $originalLockStatus)
        Write-Log ("Original E: AutoUnlockEnabled should be: {0}" -f $originalAutoUnlockEnabled)

        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -eq $volume) {
            Write-Log "Unable to read current E: BitLocker status during restore."
            return
        }

        Write-Log ("Current E: LockStatus before restore: {0}" -f $volume.LockStatus)
        Write-Log ("Current E: AutoUnlockEnabled before restore: {0}" -f $volume.AutoUnlockEnabled)

        if ($volume.LockStatus -eq "Unlocked") {
            if ($volume.AutoUnlockEnabled -ne $originalAutoUnlockEnabled) {
                if ($originalAutoUnlockEnabled -eq $true) {
                    Write-Log "Restoring E: auto-unlock to enabled."

                    Enable-BitLockerAutoUnlock `
                        -MountPoint $mountPoint `
                        -ErrorAction Stop | Out-Null
                } else {
                    Write-Log "Restoring E: auto-unlock to disabled."

                    Disable-BitLockerAutoUnlock `
                        -MountPoint $mountPoint `
                        -ErrorAction Stop | Out-Null
                }

                Start-Sleep -Seconds 3
            }
        } else {
            Write-Log "E: is not unlocked, so auto-unlock state may not be adjustable in this session."
        }

        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -ne $volume) {
            Write-Log ("E: AutoUnlockEnabled after auto-unlock restore attempt: {0}" -f $volume.AutoUnlockEnabled)
        }

        if ($originalLockStatus -eq "Locked") {
            $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

            if ($null -ne $volume -and $volume.LockStatus -eq "Unlocked") {
                Write-Log "Original E: state was locked. Locking E: now."

                Lock-BitLocker `
                    -MountPoint $mountPoint `
                    -ForceDismount `
                    -ErrorAction Stop

                Start-Sleep -Seconds 5
            } else {
                Write-Log "E: is already locked or unavailable."
            }
        } else {
            Write-Log "Original E: state was unlocked. Leaving E: unlocked."
        }

        $volume = Get-BitLockerVolumeSafe -MountPoint $mountPoint

        if ($null -ne $volume) {
            Write-Log ("Final E: LockStatus after restore: {0}" -f $volume.LockStatus)
            Write-Log ("Final E: AutoUnlockEnabled after restore: {0}" -f $volume.AutoUnlockEnabled)
        }

        Write-Log "E: BitLocker state restore routine completed."
    } catch {
        Write-Log ("Failed to restore original E: BitLocker state: {0}" -f $_.Exception.Message)
    }
}

function Unregister-PostUpgradeRestoreTask {
    try {
        $existingTask = Get-ScheduledTask -TaskName $postUpgradeTaskName -ErrorAction SilentlyContinue

        if ($null -ne $existingTask) {
            Unregister-ScheduledTask -TaskName $postUpgradeTaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log ("Removed scheduled task: {0}" -f $postUpgradeTaskName)
        }
    } catch {
        Write-Log ("Failed to unregister scheduled task {0}: {1}" -f $postUpgradeTaskName, $_.Exception.Message)
    }
}

function Register-PostUpgradeRestoreTask {
    Write-Phase "Registering Post-Upgrade E Restore Task"

    if (-not $restoreStagingDriveOriginalState) {
        Write-Log "Post-upgrade E: restore task is disabled by config."
        return
    }

    try {
        if (-not (Test-Path $stagingDriveStatePath)) {
            Write-Log ("Original E: BitLocker state file not found: {0}" -f $stagingDriveStatePath)
            Write-Log "Aborting because E: cannot be guaranteed to return to its original state."
            Restore-OriginalEBitLockerState -Reason "Missing state file before setup"
            exit 1
        }

        if (-not (Test-Path $fallbackLogRoot)) {
            New-Item -Path $fallbackLogRoot -ItemType Directory -Force | Out-Null
        }

        $restoreScript = @"
`$statePath = "$stagingDriveStatePath"
`$taskName = "$postUpgradeTaskName"
`$logRoot = "$fallbackLogRoot"
`$logPath = Join-Path `$logRoot "Restore-E-BitLocker-State-AfterUpgrade.log"

function Write-RestoreLog {
    param ([string]`$Message)

    try {
        if (-not (Test-Path `$logRoot)) {
            New-Item -Path `$logRoot -ItemType Directory -Force | Out-Null
        }

        `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        `$line = "[{0}] {1}" -f `$timestamp, `$Message

        Add-Content -Path `$logPath -Value `$line
    } catch {
    }
}

function Get-CurrentDisplayVersion {
    try {
        `$cvKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        `$props = Get-ItemProperty -Path `$cvKey -ErrorAction Stop
        return `$props.DisplayVersion
    } catch {
        Write-RestoreLog ("Failed to read DisplayVersion: {0}" -f `$_.Exception.Message)
        return `$null
    }
}

function Get-BitLockerVolumeForRestore {
    param ([string]`$MountPoint)

    try {
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
            Write-RestoreLog "Get-BitLockerVolume cmdlet is not available."
            return `$null
        }

        return Get-BitLockerVolume -MountPoint `$MountPoint -ErrorAction Stop
    } catch {
        Write-RestoreLog ("Failed to get BitLocker status for {0}: {1}" -f `$MountPoint, `$_.Exception.Message)
        return `$null
    }
}

Write-RestoreLog "Starting post-upgrade E: BitLocker state restore task."

try {
    if (-not (Test-Path `$statePath)) {
        Write-RestoreLog ("State file not found: {0}" -f `$statePath)
        Write-RestoreLog "Leaving task registered."
        exit 1
    }

    `$state = Get-Content -Path `$statePath -Raw | ConvertFrom-Json

    `$targetDisplayVersion = [string]`$state.TargetDisplayVersion
    `$currentDisplayVersion = Get-CurrentDisplayVersion

    Write-RestoreLog ("Current DisplayVersion: {0}" -f `$currentDisplayVersion)
    Write-RestoreLog ("Target DisplayVersion: {0}" -f `$targetDisplayVersion)

    if (`$currentDisplayVersion -ne `$targetDisplayVersion) {
        Write-RestoreLog "Target DisplayVersion has not been reached yet. Leaving E: state as-is and keeping task registered."
        exit 0
    }

    `$stagingDriveLetter = [string]`$state.StagingDriveLetter
    `$mountPoint = "`$stagingDriveLetter`:"
    `$originalLockStatus = [string]`$state.OriginalLockStatus
    `$originalAutoUnlockEnabled = [System.Convert]::ToBoolean(`$state.OriginalAutoUnlockEnabled)

    Write-RestoreLog ("Original E: LockStatus should be: {0}" -f `$originalLockStatus)
    Write-RestoreLog ("Original E: AutoUnlockEnabled should be: {0}" -f `$originalAutoUnlockEnabled)

    `$volume = Get-BitLockerVolumeForRestore -MountPoint `$mountPoint

    if (`$null -eq `$volume) {
        Write-RestoreLog "Unable to read E: BitLocker status. Leaving task registered."
        exit 1
    }

    Write-RestoreLog ("Current E: LockStatus before restore: {0}" -f `$volume.LockStatus)
    Write-RestoreLog ("Current E: AutoUnlockEnabled before restore: {0}" -f `$volume.AutoUnlockEnabled)

    if (`$volume.LockStatus -eq "Unlocked") {
        if (`$volume.AutoUnlockEnabled -ne `$originalAutoUnlockEnabled) {
            if (`$originalAutoUnlockEnabled -eq `$true) {
                Write-RestoreLog "Restoring E: auto-unlock to enabled."

                Enable-BitLockerAutoUnlock `
                    -MountPoint `$mountPoint `
                    -ErrorAction Stop | Out-Null
            } else {
                Write-RestoreLog "Restoring E: auto-unlock to disabled."

                Disable-BitLockerAutoUnlock `
                    -MountPoint `$mountPoint `
                    -ErrorAction Stop | Out-Null
            }

            Start-Sleep -Seconds 3
        } else {
            Write-RestoreLog "E: auto-unlock already matches original state."
        }
    } else {
        Write-RestoreLog "E: is not unlocked. Auto-unlock state may not be adjustable."
    }

    `$volume = Get-BitLockerVolumeForRestore -MountPoint `$mountPoint

    if (`$null -eq `$volume) {
        Write-RestoreLog "Unable to reread E: BitLocker status after auto-unlock restore attempt. Leaving task registered."
        exit 1
    }

    Write-RestoreLog ("E: AutoUnlockEnabled after restore attempt: {0}" -f `$volume.AutoUnlockEnabled)

    if (`$originalLockStatus -eq "Locked") {
        if (`$volume.LockStatus -eq "Unlocked") {
            Write-RestoreLog "Original E: state was locked. Locking E:."

            Lock-BitLocker `
                -MountPoint `$mountPoint `
                -ForceDismount `
                -ErrorAction Stop

            Start-Sleep -Seconds 5
        } else {
            Write-RestoreLog "E: is already locked."
        }
    } else {
        Write-RestoreLog "Original E: state was unlocked. Leaving E: unlocked."
    }

    `$volume = Get-BitLockerVolumeForRestore -MountPoint `$mountPoint

    if (`$null -eq `$volume) {
        Write-RestoreLog "Unable to verify final E: BitLocker status. Leaving task registered."
        exit 1
    }

    Write-RestoreLog ("Final E: LockStatus: {0}" -f `$volume.LockStatus)
    Write-RestoreLog ("Final E: AutoUnlockEnabled: {0}" -f `$volume.AutoUnlockEnabled)

    `$lockMatches = ([string]`$volume.LockStatus -eq `$originalLockStatus)
    `$autoUnlockMatches = ([System.Convert]::ToBoolean(`$volume.AutoUnlockEnabled) -eq `$originalAutoUnlockEnabled)

    if (`$lockMatches -and `$autoUnlockMatches) {
        Write-RestoreLog "Verified E: BitLocker state matches original state."

        try {
            Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction Stop
            Write-RestoreLog ("Removed scheduled task: {0}" -f `$taskName)
        } catch {
            Write-RestoreLog ("Failed to remove scheduled task: {0}" -f `$_.Exception.Message)
        }

        exit 0
    } else {
        Write-RestoreLog "E: restore verification failed. Leaving task registered for next startup."
        exit 1
    }
} catch {
    Write-RestoreLog ("Post-upgrade E: restore task failed: {0}" -f `$_.Exception.Message)
    Write-RestoreLog "Leaving task registered for next startup."
    exit 1
}
"@

        Set-Content -Path $postUpgradeRestoreScriptPath -Value $restoreScript -Encoding UTF8 -Force

        Write-Log ("Wrote post-upgrade E: restore script to: {0}" -f $postUpgradeRestoreScriptPath)

        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$postUpgradeRestoreScriptPath`""

        $trigger = New-ScheduledTaskTrigger -AtStartup

        $principal = New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable

        Register-ScheduledTask `
            -TaskName $postUpgradeTaskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Force | Out-Null

        Write-Log ("Registered scheduled task: {0}" -f $postUpgradeTaskName)
        Write-Log "E: will be restored to its original BitLocker state after the OS reaches the target DisplayVersion."
    } catch {
        Write-Log ("Failed to register post-upgrade E: restore task: {0}" -f $_.Exception.Message)
        Write-Log "Aborting because E: cannot be guaranteed to return to its original state."
        Restore-OriginalEBitLockerState -Reason "Failed to register post-upgrade restore task"
        exit 1
    }
}

function Validate-StagingDriveAccess {
    Write-Phase "Validating E Drive Access"

    if (-not (Test-Path $stagingRoot)) {
        Write-Log ("{0} does not exist or is not accessible. Aborting." -f $stagingRoot)
        Restore-OriginalEBitLockerState -Reason "E: not accessible"
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
        Restore-OriginalEBitLockerState -Reason "Failed to create E: working/log directory"
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
            Restore-OriginalEBitLockerState -Reason "Insufficient E: free space"
            exit 1
        }
    } catch {
        Write-Log ("Failed to check free space on {0}: {1}" -f $tempDriveLetter, $_.Exception.Message)
        Restore-OriginalEBitLockerState -Reason "Failed to check E: free space"
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
            Restore-OriginalEBitLockerState -Reason "Insufficient system drive free space"
            exit 1
        }
    } catch {
        Write-Log ("Failed to check free space on system drive: {0}" -f $_.Exception.Message)
        Restore-OriginalEBitLockerState -Reason "Failed to check system drive free space"
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
            Restore-OriginalEBitLockerState -Reason "No ISO found on E:"
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
            Restore-OriginalEBitLockerState -Reason "Selected ISO appears too small"
            exit 1
        }

        $script:SelectedIsoPath = $selectedIso.FullName

        $selectedIsoSizeGB = [math]::Round(($selectedIso.Length / 1GB), 2)
        Write-Log ("Final selected ISO: {0}" -f $script:SelectedIsoPath)
        Write-Log ("Selected ISO size: {0} GB" -f $selectedIsoSizeGB)
    } catch {
        Write-Log ("Failed to discover staged ISO: {0}" -f $_.Exception.Message)
        Restore-OriginalEBitLockerState -Reason "ISO discovery failure"
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
        if (Test-Path $logRoot) {
            # Primary logs on E:
        } else {
            Write-Log "Primary E: log root is unavailable. Panther logs may only be preserved if E: is accessible."
        }

        $pantherPath = "C:\`$WINDOWS.~BT\Sources\Panther"

        if (Test-Path $pantherPath) {
            if (-not (Test-Path $logRoot)) {
                New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
            }

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
Write-Log "Only E: BitLocker state will be modified. No other drive BitLocker settings will be changed."

Write-Phase "Checking Administrator Rights"

if (-not (Test-IsAdmin)) {
    Write-Log "This script must be run as Administrator."
    exit 1
}

Write-Log "Administrator rights confirmed."

Write-Phase "Checking Current Windows Version Before Touching E"

$currentWindowsInfo = Get-CurrentWindowsInfo

if ($null -ne $currentWindowsInfo) {
    Write-Log ("Current ProductName: {0}" -f $currentWindowsInfo.ProductName)
    Write-Log ("Current DisplayVersion: {0}" -f $currentWindowsInfo.DisplayVersion)
    Write-Log ("Current Build: {0}" -f $currentWindowsInfo.CurrentBuildNumber)
}

if (Test-IsTargetVersion) {
    Write-Log ("This machine is already on Windows 11 {0}. No upgrade needed." -f $targetDisplayVersion)
    Write-Log "E: was not unlocked or modified."
    exit 0
}

if (Test-IsWindows11) {
    Write-Log "Detected Windows 11."
} else {
    Write-Log "Machine does not appear to be on Windows 11. Continuing because Windows 10 to Windows 11 in-place upgrade may be intended."
}

Ensure-StagingDriveUnlocked
Enable-EAutoUnlockTemporarily
Validate-StagingDriveAccess
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
    Restore-OriginalEBitLockerState -Reason "Failed to mount ISO"
    exit 1
}

# Validate setup.exe exists
Write-Phase "Validating Setup Media"

$setupPath = ("{0}:\setup.exe" -f $driveLetter)

if (-not (Test-Path $setupPath)) {
    Write-Log ("setup.exe not found at {0}. Aborting." -f $setupPath)
    Dismount-IsoSafely
    Restore-OriginalEBitLockerState -Reason "setup.exe missing from mounted ISO"
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
            Restore-OriginalEBitLockerState -Reason "Compatibility scan found blocking app or driver"
            exit $compatExitCode
        }

        "0xC1900200" {
            Write-Log "Compatibility scan failed: system does not meet Windows 11 requirements. Aborting upgrade."
            Preserve-SetupLogs
            Dismount-IsoSafely
            Restore-OriginalEBitLockerState -Reason "Compatibility scan failed Windows 11 requirements"
            exit $compatExitCode
        }

        "0xC1900204" {
            Write-Log "Compatibility scan failed: selected migration choice is not available. Check edition, language, or architecture compatibility."
            Preserve-SetupLogs
            Dismount-IsoSafely
            Restore-OriginalEBitLockerState -Reason "Compatibility scan migration choice unavailable"
            exit $compatExitCode
        }

        "0xC190020E" {
            Write-Log "Compatibility scan failed: insufficient disk space for installation."
            Write-Log "E: is being used with /TempDrive, but Windows Setup still requires enough free space on the system drive."
            Preserve-SetupLogs
            Dismount-IsoSafely
            Restore-OriginalEBitLockerState -Reason "Compatibility scan insufficient disk space"
            exit $compatExitCode
        }

        default {
            Write-Log ("Compatibility scan returned unexpected exit code: {0} ({1}). Aborting upgrade." -f $compatExitCode, $compatExitCodeHex)
            Preserve-SetupLogs
            Dismount-IsoSafely
            Restore-OriginalEBitLockerState -Reason "Compatibility scan unexpected exit code"
            exit $compatExitCode
        }
    }
} catch {
    Write-Log ("Failed to run compatibility scan: {0}" -f $_.Exception.Message)
    Preserve-SetupLogs
    Dismount-IsoSafely
    Restore-OriginalEBitLockerState -Reason "Compatibility scan execution failure"
    exit 1
}

# Register post-upgrade restore task only after compatibility has passed.
# This prevents E: from being left modified if setup never starts.
Register-PostUpgradeRestoreTask

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
    Write-Log "E: BitLocker original state has NOT been restored yet because Windows Setup may need E: after reboot."
    Write-Log ("A startup task will restore E: to its original BitLocker state after Windows reaches DisplayVersion {0}." -f $targetDisplayVersion)
    Write-Log ("Restore task name: {0}" -f $postUpgradeTaskName)
    Write-Log ("Original E: state file: {0}" -f $stagingDriveStatePath)
    Write-Log "No ISO cleanup was performed. The staged ISO remains on E:."
    Write-Log "Done. Please reboot the system manually if required."
    exit 0
} else {
    Write-Log "Upgrade did not complete successfully."
    Write-Log "Restoring E: to its original BitLocker state now because setup did not return success."
    Restore-OriginalEBitLockerState -Reason "Setup failed before successful handoff"
    Unregister-PostUpgradeRestoreTask
    Write-Log ("Leaving files in place for troubleshooting: {0}" -f $workRoot)
    Write-Log "Review logs under the Logs folder and Panther logs if available."
    Write-Log "No ISO cleanup was performed. The staged ISO remains on E:."

    exit $exitCode
}
