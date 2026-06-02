$ErrorActionPreference = "SilentlyContinue"

function Write-Result {
  param (
    [string]$Message,
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$timestamp] [$Level] $Message"
}

function Test-IsAdmin {
  try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  catch {
    return $false
  }
}

function Get-ChromeVersion {
  param (
    [string]$ChromePath
  )

  if (-not $ChromePath -or -not (Test-Path $ChromePath)) {
    return $null
  }

  try {
    $item = Get-Item $ChromePath

    if ($item.VersionInfo.ProductVersion) {
      return $item.VersionInfo.ProductVersion
    }

    return $item.VersionInfo.FileVersion
  }
  catch {
    return $null
  }
}

function Get-LatestUpdater {
  param (
    [string]$Scope
  )

  $programFilesX86 = ${env:ProgramFiles(x86)}

  if ($Scope -eq "Machine") {
    $root = "$programFilesX86\Google\GoogleUpdater"
  }
  else {
    $root = "$env:LOCALAPPDATA\Google\GoogleUpdater"
  }

  if (-not (Test-Path $root)) {
    return $null
  }

  return Get-ChildItem `
    -Path $root `
    -Filter "updater.exe" `
    -Recurse |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

Write-Result "Starting Chrome update check."

$programFilesX86 = ${env:ProgramFiles(x86)}
$isAdmin = Test-IsAdmin

# Detect Chrome first. If Chrome is not installed, do nothing.
$chromeCandidates = @(
  [PSCustomObject]@{
    Path  = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    Scope = "Machine"
  },
  [PSCustomObject]@{
    Path  = "$programFilesX86\Google\Chrome\Application\chrome.exe"
    Scope = "Machine"
  },
  [PSCustomObject]@{
    Path  = "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    Scope = "User"
  }
)

$chromeInfo = $chromeCandidates |
  Where-Object { Test-Path $_.Path } |
  Select-Object -First 1

if (-not $chromeInfo) {
  Write-Result "Google Chrome is not installed. No action taken." "SKIP"
  exit 0
}

$chrome = $chromeInfo.Path
$chromeScope = $chromeInfo.Scope

Write-Result "Chrome found at: $chrome"
Write-Result "Detected Chrome install scope: $chromeScope"

if ($chromeScope -eq "Machine" -and -not $isAdmin) {
  Write-Result "Machine-wide Chrome detected, but PowerShell is not running as Administrator. The updater may fail unless run elevated." "WARN"
}

$startingVersion = Get-ChromeVersion -ChromePath $chrome

if ($startingVersion) {
  Write-Result "Chrome version before update: $startingVersion"
}
else {
  Write-Result "Could not detect Chrome version before update." "WARN"
}

$chromeWasRunning = @(Get-Process chrome).Count -gt 0

if ($chromeWasRunning) {
  Write-Result "Chrome is already running. The script will not open or close Chrome."
}
else {
  Write-Result "Chrome is not currently running."
}

# Prefer legacy updater if present for the same scope.
$legacyUpdater = $null

if ($chromeScope -eq "Machine") {
  $legacyUpdater = "$programFilesX86\Google\Update\GoogleUpdate.exe"
}
else {
  $legacyUpdater = "$env:LOCALAPPDATA\Google\Update\GoogleUpdate.exe"
}

$updaterExitCode = $null

if ($legacyUpdater -and (Test-Path $legacyUpdater)) {
  Write-Result "Using legacy GoogleUpdate.exe: $legacyUpdater"
  Write-Result "Updater arguments: /ua /installsource scheduler"

  $process = Start-Process `
    -FilePath $legacyUpdater `
    -ArgumentList "/ua /installsource scheduler" `
    -Wait `
    -PassThru

  $updaterExitCode = $process.ExitCode
  Write-Result "Legacy updater finished with exit code: $updaterExitCode"
}
else {
  $newUpdater = Get-LatestUpdater -Scope $chromeScope

  if (-not $newUpdater) {
    Write-Result "Chrome is installed, but no matching Google updater executable was found. No update action taken." "SKIP"
    exit 0
  }

  Write-Result "Using newer Google updater: $($newUpdater.FullName)"

  if ($chromeScope -eq "Machine") {
    $updaterArgs = @("--update-apps", "--system")
  }
  else {
    $updaterArgs = @("--update-apps")
  }

  Write-Result "Updater arguments: $($updaterArgs -join ' ')"

  $process = Start-Process `
    -FilePath $newUpdater.FullName `
    -ArgumentList $updaterArgs `
    -Wait `
    -PassThru

  $updaterExitCode = $process.ExitCode
  Write-Result "Newer updater finished with exit code: $updaterExitCode"

  if ($updaterExitCode -eq 75009) {
    Write-Result "Updater still returned 75009. This is coming from the existing Google updater itself, not winget or the script fallback." "WARN"
    Write-Result "For machine-wide Chrome, confirm the script is running elevated or as SYSTEM." "WARN"
  }
}

# Only open/close Chrome if it was not already running.
if (-not $chromeWasRunning) {
  Write-Result "Opening Chrome to chrome://settings/help so Chrome can process update state."

  $startedAt = Get-Date

  Start-Process $chrome -ArgumentList "chrome://settings/help"

  Write-Result "Waiting 30 seconds."
  Start-Sleep -Seconds 30

  $startedChromeProcesses = Get-Process chrome |
    Where-Object {
      try {
        $_.StartTime -ge $startedAt.AddSeconds(-2)
      }
      catch {
        $false
      }
    }

  if ($startedChromeProcesses) {
    Write-Result "Attempting graceful close of Chrome processes started by this script."

    foreach ($p in $startedChromeProcesses) {
      try {
        if ($p.MainWindowHandle -ne 0) {
          $null = $p.CloseMainWindow()
          Write-Result "Sent close request to Chrome process ID $($p.Id)."
        }
      }
      catch {
        Write-Result "Could not gracefully close Chrome process ID $($p.Id)." "WARN"
      }
    }

    Start-Sleep -Seconds 5

    $remainingChromeProcesses = Get-Process chrome |
      Where-Object {
        try {
          $_.StartTime -ge $startedAt.AddSeconds(-2)
        }
        catch {
          $false
        }
      }

    if ($remainingChromeProcesses) {
      Write-Result "Force-closing remaining Chrome processes started by this script." "WARN"
      $remainingChromeProcesses | Stop-Process -Force
      Write-Result "Remaining Chrome processes closed."
    }
    else {
      Write-Result "Chrome closed gracefully."
    }
  }
  else {
    Write-Result "No Chrome processes started by this script were found to close."
  }
}
else {
  Write-Result "Chrome was already running before this script started, so no Chrome windows were opened or closed."
}

$endingVersion = Get-ChromeVersion -ChromePath $chrome

if ($endingVersion) {
  Write-Result "Chrome version after update check: $endingVersion"
}
else {
  Write-Result "Could not detect Chrome version after update check." "WARN"
}

if ($startingVersion -and $endingVersion) {
  if ($startingVersion -ne $endingVersion) {
    Write-Result "Chrome update completed. Version changed from $startingVersion to $endingVersion." "SUCCESS"
  }
  else {
    Write-Result "Chrome version did not change. It may already be current, no update was available, or the update requires a later browser restart." "INFO"
  }
}

Write-Result "Possible updater logs:"
Write-Result "$programFilesX86\Google\GoogleUpdater\updater.log"
Write-Result "$env:LOCALAPPDATA\Google\GoogleUpdater\updater.log"

Write-Result "Chrome update script completed."
exit 0
