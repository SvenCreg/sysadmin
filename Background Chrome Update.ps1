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

Write-Result "Starting Chrome update check."

$programFilesX86 = ${env:ProgramFiles(x86)}

# Check whether Chrome is actually installed before doing anything else
$chromePaths = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "$programFilesX86\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)

$chrome = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $chrome) {
  Write-Result "Google Chrome is not installed. No action taken." "SKIP"
  exit 0
}

Write-Result "Chrome found at: $chrome"

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

# Try old GoogleUpdate.exe first
$oldUpdaterPaths = @(
  "$programFilesX86\Google\Update\GoogleUpdate.exe",
  "$env:LOCALAPPDATA\Google\Update\GoogleUpdate.exe"
)

$oldUpdater = $oldUpdaterPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

# Try newer GoogleUpdater location
$newUpdaterSearchPaths = @(
  "$programFilesX86\Google\GoogleUpdater",
  "$env:ProgramFiles\Google\GoogleUpdater",
  "$env:LOCALAPPDATA\Google\GoogleUpdater"
) | Where-Object { Test-Path $_ }

$newUpdater = $null

if ($newUpdaterSearchPaths) {
  $newUpdater = Get-ChildItem `
    -Path $newUpdaterSearchPaths `
    -Filter "updater.exe" `
    -Recurse |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

$updaterExitCode = $null
$updaterUsed = $null

if ($oldUpdater) {
  $updaterUsed = $oldUpdater
  Write-Result "Using legacy updater: $oldUpdater"

  $process = Start-Process `
    -FilePath $oldUpdater `
    -ArgumentList "/ua /installsource scheduler" `
    -Wait `
    -PassThru

  $updaterExitCode = $process.ExitCode
  Write-Result "Legacy updater finished with exit code: $updaterExitCode"
}
elseif ($newUpdater) {
  $updaterUsed = $newUpdater.FullName
  Write-Result "Using newer updater: $($newUpdater.FullName)"

  $process = Start-Process `
    -FilePath $newUpdater.FullName `
    -ArgumentList "--wake" `
    -Wait `
    -PassThru

  $updaterExitCode = $process.ExitCode
  Write-Result "Newer updater finished with exit code: $updaterExitCode"
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

# Re-check Chrome version after updater/browser processing
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
    Write-Result "Chrome version did not change. It may already be current, no update was available, or an update may require a future browser restart." "INFO"
  }
}
else {
  Write-Result "Version comparison could not be completed because one or both version checks failed." "WARN"
}

Write-Result "Chrome update script completed."
exit 0
