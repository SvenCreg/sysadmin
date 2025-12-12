<#
Windows cleanup script for low disk space before feature update.
 
What it does:
  - Shows free space before/after
  - Cleans temp folders (Windows + user)
  - Clears Windows Update cache (SoftwareDistribution)
  - Runs DISM component store cleanup
  - Optional: delete C:\Windows.old (rollback removal)
 
Run as:  PowerShell (Admin)
#>
 
# ================== CONFIG ==================
# Set this to $true if you ALSO want to delete C:\Windows.old
# WARNING: This removes your ability to roll back to the previous Windows version.
$RemoveWindowsOld = $false
# ============================================
 
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
 
# Helper: get free space on C:
function Get-FreeSpaceGB {
    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($drive) {
        return [math]::Round($drive.Free/1GB, 2)
    } else {
        return $null
    }
}
 
Write-Info "Starting aggressive cleanup..."
$before = Get-FreeSpaceGB
if ($before -ne $null) {
    Write-Info ("Free space on C: BEFORE cleanup: {0} GB" -f $before)
} else {
    Write-Warn "Could not read C: drive info."
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
 
# ----------------- 2. Clear Windows Update cache -----------------
Write-Info "Clearing Windows Update cache (SoftwareDistribution)..."
 
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
    Start-Service bits   -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
}
catch {
    Write-Warn "Problem clearing SoftwareDistribution: $_"
}
 
# ----------------- 3. Optional: delete Windows.old -----------------
if ($RemoveWindowsOld) {
    $woPath = "C:\Windows.old"
    if (Test-Path $woPath) {
        Write-Warn "Deleting C:\Windows.old ... this removes rollback to previous Windows build."
        try {
            # Need extra perms
            attrib -r -a -s -h "$woPath" /s /d 2>$null
            Remove-Item $woPath -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Warn "Failed to remove C:\Windows.old : $_"
        }
    } else {
        Write-Info "C:\Windows.old not found; nothing to delete."
    }
} else {
    Write-Info "Skipping C:\Windows.old removal (set \$RemoveWindowsOld = \$true to enable)."
}
 
# ----------------- 4. Run DISM component cleanup -----------------
Write-Info "Running DISM component store cleanup (this can take a while)..."
 
try {
    # /ResetBase makes all superseded components permanent, preventing uninstall of individual updates
& Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
} catch {
    Write-Warn "DISM cleanup encountered an error: $_"
}
 
# ----------------- Final report -----------------
$after = Get-FreeSpaceGB
if ($after -ne $null) {
    Write-Info ("Free space on C: AFTER cleanup: {0} GB" -f $after)
    if ($before -ne $null) {
        $delta = [math]::Round($after - $before, 2)
        Write-Info ("Total space reclaimed: {0} GB" -f $delta)
    }
}
 
Write-Info "Cleanup complete. You can now try the feature update."
