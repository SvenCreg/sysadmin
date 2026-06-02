$ErrorActionPreference = "SilentlyContinue"

function Write-Result {
  param (
    [string]$Message,
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$timestamp] [$Level] $Message"
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

# If Chrome exists but no updater is found, do nothing
if ($oldUpdater) {
  Write-Result "Using legacy updater: $oldUpdater"

  $process = Start-Process `
    -FilePath $oldUpdater `
    -ArgumentList "/ua /installsource scheduler" `
    -Wait `
    -PassThru

  Write-Result "Legacy updater finished with exit code: $($process.ExitCode)"
}
elseif ($newUpdater) {
  Write-Result "Using newer updater: $($newUpdater.FullName)"

  $process = Start-Process `
    -FilePath $newUpdater.FullName `
    -ArgumentList "--wake" `
    -Wait `
    -PassThru

  Write-Result "Newer updater finished with exit code: $($process.ExitCode)"
}
else {
  Write-Result "Chrome is installed, but no Google updater executable was found. No update action taken." "SKIP"
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

Write-Result "Chrome update script completed."
exit 0
