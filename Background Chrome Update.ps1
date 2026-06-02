$ErrorActionPreference = "SilentlyContinue"

function Write-Result {
  param (
    [string]$Message,
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$timestamp] [$Level] $Message"
}

function Get-ChromeVersion {
  param (
    [string]$ChromePath
  )

  if (-not $ChromePath) {
    return $null
  }

  if (-not (Test-Path $ChromePath)) {
    return $null
  }

  try {
    $version = (Get-Item $ChromePath).VersionInfo.ProductVersion

    if (-not $version) {
      $version = (Get-Item $ChromePath).VersionInfo.FileVersion
    }

    return $version
  }
  catch {
    return $null
  }
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
  Write-Result "Machine-wide Chrome detected, but PowerShell is not running as Administrator. Updater may fail. Run as admin for best results." "WARN"
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

# Legacy updater locations
$oldUpdaterCandidates = @(
  [PSCustomObject]@{
    Path  = "$programFilesX86\Google\Update\GoogleUpdate.exe"
    Scope = "Machine"
  },
  [PSCustomObject]@{
    Path  = "$env:LOCALAPPDATA\Google\Update\GoogleUpdate.exe"
    Scope = "User"
  }
)

$oldUpdaterInfo = $oldUpdaterCandidates |
  Where-Object { Test-Path $_.Path } |
  Select-Object -First 1

# New updater locations
$newUpdaterCandidates = @()

$systemUpdaterRoot = "$programFilesX86\Google\GoogleUpdater"
$userUpdaterRoot = "$env:LOCALAPPDATA\Google\GoogleUpdater"

if (Test-Path $systemUpdaterRoot) {
  $newUpdaterCandidates += Get-ChildItem `
    -Path $systemUpdaterRoot `
    -Filter "updater.exe" `
    -Recurse |
    ForEach-Object {
      [PSCustomObject]@{
        Path          = $_.FullName
        Scope         = "Machine"
        LastWriteTime = $_.LastWriteTime
      }
    }
}

if (Test-Path $userUpdaterRoot) {
  $newUpdaterCandidates += Get-ChildItem `
    -Path $userUpdaterRoot `
    -Filter "updater.exe" `
    -Recurse |
    ForEach-Object {
      [PSCustomObject]@{
        Path          = $_.FullName
        Scope         = "User"
        LastWriteTime = $_.LastWriteTime
      }
    }
}

$newUpdaterInfo = $newUpdaterCandidates |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

$updaterExitCode = $null
$updaterUsed = $null
$updaterScope = $null

if ($oldUpdaterInfo) {
  $updaterUsed = $oldUpdaterInfo.Path
  $updaterScope = $oldUpdaterInfo.Scope

  Write-Result "Using legacy updater: $updaterUsed"
  Write-Result "Updater scope: $updaterScope"

  $process = Start-Process `
    -FilePath $updaterUsed `
    -ArgumentList "/ua /installsource scheduler" `
    -Wait `
    -PassThru

  $updaterExitCode = $process.ExitCode
  Write-Result "Legacy updater finished with exit code: $updaterExitCode"
}
elseif ($newUpdaterInfo) {
  $updaterUsed = $newUpdaterInfo.Path
  $updaterScope = $newUpdaterInfo.Scope

  Write-Result "Using newer updater: $updaterUsed"
  Write-Result "Updater scope: $updaterScope"

  if ($updaterScope -eq "Machine") {
    $updaterArgs = "--wake --system"
  }
  else {
    $updaterArgs = "--wake"
  }

  Write-Result "Updater arguments: $updaterArgs"

  $process = Start-Process `
    -FilePath $updaterUsed `
    -ArgumentList $updaterArgs `
    -Wait `
    -PassThru

  $updaterExitCode = $process.ExitCode
  Write-Result "Newer updater finished with exit code: $updaterExitCode"

  if ($updaterExitCode -eq 75009) {
    Write-Result "Updater returned 75009. For machine-wide installs, this often means the updater call/scope/permissions need attention. Confirm this script is running as Administrator." "WARN"
  }
}
else {
  Write-Result "Chrome is installed, but no Google updater executable was found. No update action taken." "SKIP"

  $endingVersion = Get-ChromeVersion -ChromePath $chrome

  if ($endingVersion) {
    Write-Result "Chrome version after script: $endingVersion"
  }

  exit 0
}

# Only open/close Chrome if it was not already running
if (-not $chromeWasRunning) {
  Write-Result "Opening Chrome to chrome://settings/help so it can process the update state."

  $startedAt = Get-Date

  Start-Process $chrome -ArgumentList "chrome://settings/help"

  Write-Result "Waiting 30 seconds for Chrome to process the update state."
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
    Write-Result "Chrome version did not change. It may already be current, no update was available, or the update may require a later Chrome restart." "INFO"
  }
}
else {
  Write-Result "Version comparison could not be completed because one or both version checks failed." "WARN"
}

# Show likely updater log locations
Write-Result "Possible updater logs:"
Write-Result "$programFilesX86\Google\GoogleUpdater\updater.log"
Write-Result "$env:LOCALAPPDATA\Google\GoogleUpdater\updater.log"

Write-Result "Chrome update script completed."
exit 0
