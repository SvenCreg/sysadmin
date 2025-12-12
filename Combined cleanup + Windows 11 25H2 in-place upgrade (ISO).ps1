<#
Combined cleanup + Windows 11 25H2 in-place upgrade (ISO)

Updated flow (per your request):
  1) Check if already 25H2
  2) Run the Windows Update cache step FIRST (stop wuauserv/bits -> clear SoftwareDistribution -> start services)
  3) Start ISO download AFTER services are restarted (so cleanup won't disrupt the download)
  4) Continue cleanup (temp, optional Windows.old, DISM)
  5) Wait for ISO download to finish
  6) Mount ISO, run setup.exe silently, then dismount + delete ISO (ALWAYS attempt delete at end)

Run as: PowerShell (Admin)
#>

# ================== CONFIG ==================
$RemoveWindowsOld = $false   # WARNING: removes rollback ability

$isoUrl  = "https://REPLACE.ME/Win11_25H2_English_x64.iso?"

# Save ISO somewhere temp-cleanup won't touch
$isoDir  = "C:\ProgramData\Win11_Upgrade"
$isoPath = Join-Path $isoDir "Win11_25H2_English_x64.iso"

$setupArgs = "/Auto Upgrade /Quiet /MigrateDrivers All /DynamicUpdate Disable /Telemetry Disable /Compat IgnoreWarning /ShowOOBE None /NoReboot /Eula Accept"
# ===========================================

function Write-Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg)  { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err ($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# Check for admin
$curr = [Security.Principal.WindowsIdentity]::GetCurrent()
$princ = New-Object Security.Principal.WindowsPrincipal($curr)
if (-not $princ.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
    exit 1
}

function Get-FreeSpaceGB {
    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($drive) { return [math]::Round($drive.Free/1GB, 2) }
    return $null
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

function Start-IsoDownloadBits {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    $destDir = Split-Path -Parent $DestinationPath
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # Remove any previous ISO so we don't mount the wrong one later
    if (Test-Path $DestinationPath) {
        try { Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue } catch {}
    }

    Write-Info "Starting ISO download in background (BITS) -> $DestinationPath"
    try {
        return Start-BitsTransfer -Source $Url -Destination $DestinationPath -Asynchronous -DisplayName "Win11_25H2_ISO"
    } catch {
        Write-Err "BITS download failed to start: $_"
        return $null
    }
}

function Wait-IsoDownloadBits {
    param(
        [Parameter(Mandatory)] $Job,
        [Parameter(Mandatory)] [string] $DestinationPath
    )

    Write-Info "Waiting for ISO download to finish..."
    while ($true) {
        $j = Get-BitsTransfer -Id $Job.Id -ErrorAction SilentlyContinue
        if (-not $j) { throw "BITS job disappeared unexpectedly." }

        switch ($j.JobState) {
            'Transferred' {
                Complete-BitsTransfer -BitsJob $j
                break
            }
            'Error' {
                $err = $j.Error
                try { Remove-BitsTransfer -BitsJob $j -Confirm:$false } catch {}
                throw ("BITS download error: {0}" -f ($err.Description))
            }
            'Cancelled' { throw "BITS download was cancelled." }
            default { Start-Sleep -Seconds 3 }
        }
    }

    if (-not (Test-Path $DestinationPath)) {
        throw "ISO not found at $DestinationPath after download completion."
    }
    Write-Info "ISO download complete: $DestinationPath"
}

function Cleanup-IsoArtifacts {
    param(
        [string] $IsoPath,
        $MountedObj
    )

    Write-Info "Cleaning up mounted ISO and file..."
    try {
        if ($MountedObj) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
            Write-Info "ISO dismounted."
        }
    } catch {
        Write-Warn ("Failed to dismount ISO: {0}" -f $_.Exception.Message)
    }

    try {
        if (Test-Path $IsoPath) {
            Remove-Item $IsoPath -Force -ErrorAction SilentlyContinue
            Write-Info ("Deleted ISO file: {0}" -f $IsoPath)
        } else {
            Write-Info "No ISO file found to delete."
        }
    } catch {
        Write-Warn ("Failed to delete ISO file {0}: {1}" -f $IsoPath, $_.Exception.Message)
    }
}

# ----------------- MAIN -----------------

Write-Info "Checking current Windows DisplayVersion..."
$needsUpgrade = -not (Test-Is25H2)
if (-not $needsUpgrade) {
    Write-Info "This machine is already on Windows 11 25H2. No upgrade needed."
}

Write-Info "Starting aggressive cleanup..."
$before = Get-FreeSpaceGB
if ($before -ne $null) { Write-Info ("Free space on C: BEFORE cleanup: {0} GB" -f $before) }

# ----------------- 0. Windows Update cache FIRST (service stop/start happens here) -----------------
Write-Info "Clearing Windows Update cache (SoftwareDistribution) FIRST..."
try {
    Write-Info "Stopping Windows Update services (wuauserv, bits)..."
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service bits -Force -ErrorAction SilentlyContinue

    $sdPath = "C:\Windows\SoftwareDistribution"
    if (Test-Path $sdPath) {
        Write-Info "Deleting contents of $sdPath ..."
        Get-ChildItem $sdPath -Recurse -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        Write-Warn "$sdPath does not exist, skipping."
    }

    Write-Info "Starting Windows Update services..."
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
}
catch {
    Write-Warn "Problem clearing SoftwareDistribution: $_"
}

# ----------------- Start ISO download AFTER services are restarted -----------------
$bitsJob = $null
if ($needsUpgrade) {
    $bitsJob = Start-IsoDownloadBits -Url $isoUrl -DestinationPath $isoPath
    if (-not $bitsJob) {
        Write-Err "Could not start ISO download. Aborting."
        exit 1
    }
}

# ----------------- 1. Clean temp folders -----------------
Write-Info "Cleaning temp folders..."
$tempPaths = @(
    "C:\Windows\Temp",
    $env:TEMP,
    $env:TMP
)

foreach ($path in $tempPaths) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path $path)) {
        Write-Info "Cleaning: $path"
        try {
            Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Error cleaning $path : $_"
        }
    } else {
        Write-Warn "Temp path not found or invalid: $path"
    }
}

# ----------------- 2. Optional: delete Windows.old -----------------
if ($RemoveWindowsOld) {
    $woPath = "C:\Windows.old"
    if (Test-Path $woPath) {
        Write-Warn "Deleting C:\Windows.old ... this removes rollback to previous Windows build."
        try {
            attrib -r -a -s -h "$woPath" /s /d 2>$null
            Remove-Item $woPath -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Failed to remove C:\Windows.old : $_"
        }
    } else {
        Write-Info "C:\Windows.old not found; nothing to delete."
    }
} else {
    Write-Info "Skipping C:\Windows.old removal (set `$RemoveWindowsOld = `$true to enable)."
}

# ----------------- 3. Run DISM component cleanup -----------------
Write-Info "Running DISM component store cleanup (this can take a while)..."
try {
    & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
} catch {
    Write-Warn "DISM cleanup encountered an error: $_"
}

# ----------------- Final cleanup report -----------------
$after = Get-FreeSpaceGB
if ($after -ne $null) {
    Write-Info ("Free space on C: AFTER cleanup: {0} GB" -f $after)
    if ($before -ne $null) {
        $delta = [math]::Round($after - $before, 2)
        Write-Info ("Total space reclaimed: {0} GB" -f $delta)
    }
}
Write-Info "Cleanup phase complete."

# If no upgrade needed, ensure ISO is deleted (in case someone left it there) and exit
if (-not $needsUpgrade) {
    if (Test-Path $isoPath) {
        try { Remove-Item $isoPath -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-Info "Done."
    return
}

# ----------------- UPGRADE PHASE -----------------
try {
    Wait-IsoDownloadBits -Job $bitsJob -DestinationPath $isoPath
} catch {
    Write-Err $_
    # Ensure ISO is deleted if partially present
    if (Test-Path $isoPath) { try { Remove-Item $isoPath -Force -ErrorAction SilentlyContinue } catch {} }
    exit 1
}

$mounted = $null
$driveLetter = $null

try {
    Write-Info "Mounting ISO..."
    $mounted = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $volumes = $mounted | Get-Volume
    $driveLetter = ($volumes | Select-Object -ExpandProperty DriveLetter -First 1)
    if (-not $driveLetter) { throw "No drive letter found for mounted ISO." }
    Write-Info ("ISO mounted as drive {0}:" -f $driveLetter)

    $setupPath = ("{0}:\setup.exe" -f $driveLetter)
    if (-not (Test-Path $setupPath)) { throw "setup.exe not found at $setupPath" }

    Write-Info "Starting silent in-place upgrade to Windows 11 25H2..."
    Write-Info "This will run with no UI and will NOT force a reboot."

    $process = Start-Process -FilePath $setupPath -ArgumentList $setupArgs -Wait -PassThru
    $exitCode = $process.ExitCode
    Write-Info ("setup.exe exit code: {0}" -f $exitCode)

    switch ($exitCode) {
        0     { Write-Info "Upgrade completed successfully. A reboot will be required to finish the upgrade." }
        3010  { Write-Info "Upgrade completed successfully and a reboot is required. Please reboot when convenient." }
        default { Write-Warn "Setup returned a non-standard exit code: $exitCode. Check Windows setup logs (Panther folder) for details." }
    }
}
catch {
    Write-Err ("Upgrade phase failed: {0}" -f $_.Exception.Message)
}
finally {
    # ALWAYS attempt to dismount + delete ISO at the very end
    Cleanup-IsoArtifacts -IsoPath $isoPath -MountedObj $mounted
}

Write-Info "Done. Please reboot the system manually to complete the upgrade if required."
