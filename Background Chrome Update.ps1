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

function Get-ChromeInstall {
  $programFilesX86 = ${env:ProgramFiles(x86)}

  $candidates = @(
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

  return $candidates |
    Where-Object { Test-Path $_.Path } |
    Select-Object -First 1
}

function Get-GoogleUpdateTasks {
  param (
    [string]$ChromeScope
  )

  $allTasks = Get-ScheduledTask |
    Where-Object {
      $_.TaskName -like "GoogleUpdateTask*" -or
      $_.TaskName -like "GoogleUpdaterTask*" -or
      $_.TaskPath -like "\GoogleSystem\*" -or
      $_.TaskPath -like "\GoogleUser\*" -or
      $_.TaskPath -like "\GoogleUpdate\*"
    }

  if (-not $allTasks) {
    return @()
  }

  if ($ChromeScope -eq "Machine") {
    $preferred = $allTasks |
      Where-Object {
        $_.TaskName -like "*Machine*" -or
        $_.TaskName -like "*System*" -or
        $_.TaskPath -like "\GoogleSystem\*"
      }
  }
  else {
    $preferred = $allTasks |
      Where-Object {
        $_.TaskName -like "*User*" -or
        $_.TaskPath -like "\GoogleUser\*"
      }
  }

  if ($preferred) {
    return @($preferred)
  }

  return @($allTasks)
}

function Wait-ForTaskToFinish {
  param (
    [string]$TaskName,
    [string]$TaskPath,
    [int]$TimeoutSeconds = 180
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

  do {
    Start-Sleep -Seconds 5

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath

    if ($task.State -ne "Running") {
      break
    }
  }
  while ((Get-Date) -lt $deadline)

  $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath

  return $info.LastTaskResult
}

function Invoke-GoogleUpdateScheduledTasks {
  param (
    [string]$ChromeScope
  )

  $tasks = Get-GoogleUpdateTasks -ChromeScope $ChromeScope

  if (-not $tasks -or $tasks.Count -eq 0) {
    Write-Result "No Google Update / Google Updater scheduled tasks were found." "WARN"
    return $false
  }

  Write-Result "Found $($tasks.Count) Google updater scheduled task(s)."

  $success = $false

  foreach ($task in $tasks) {
    $taskFullName = "$($task.TaskPath)$($task.TaskName)"

    if ($task.State -eq "Disabled") {
      Write-Result "Skipping disabled task: $taskFullName" "WARN"
      continue
    }

    Write-Result "Starting scheduled task: $taskFullName"

    try {
      Start-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath

      $result = Wait-ForTaskToFinish `
        -TaskName $task.TaskName `
        -TaskPath $task.TaskPath `
        -TimeoutSeconds 180

      Write-Result "Task finished with LastTaskResult: $result"

      if ($result -eq 0) {
        $success = $true
      }
    }
    catch {
      Write-Result "Failed to start scheduled task: $taskFullName" "WARN"
    }
  }

  return $success
}

function Show-UpdaterDiagnostics {
  $programFilesX86 = ${env:ProgramFiles(x86)}

  Write-Result "Checking likely Google updater log locations."

  $logCandidates = @(
    "$programFilesX86\Google\GoogleUpdater\updater.log",
    "$env:ProgramFiles\Google\GoogleUpdater\updater.log",
    "$env:LOCALAPPDATA\Google\GoogleUpdater\updater.log",
    "$programFilesX86\Google\GoogleUpdater\updater_history.jsonl",
    "$env:LOCALAPPDATA\Google\GoogleUpdater\updater_history.jsonl"
  )

  foreach ($log in $logCandidates) {
    if (Test-Path $log) {
      Write-Result "Found log: $log"

      Write-Host ""
      Write-Host "---- Last 40 lines of $log ----"
      Get-Content $log -Tail 40
      Write-Host "---- End log excerpt ----"
      Write-Host ""
    }
  }
}

Write-Result "Starting Chrome update check."

$isAdmin = Test-IsAdmin
$chromeInfo = Get-ChromeInstall

if (-not $chromeInfo) {
  Write-Result "Google Chrome is not installed. No action taken." "SKIP"
  exit 0
}

$chrome = $chromeInfo.Path
$chromeScope = $chromeInfo.Scope

Write-Result "Chrome found at: $chrome"
Write-Result "Detected Chrome install scope: $chromeScope"

if ($chromeScope -eq "Machine" -and -not $isAdmin) {
  Write-Result "Machine-wide Chrome detected, but PowerShell is not elevated. Scheduled task/update actions may fail unless run as Administrator or SYSTEM." "WARN"
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

Write-Result "Running existing Google updater through scheduled task registration, not direct updater.exe command line."

$taskUpdateSucceeded = Invoke-GoogleUpdateScheduledTasks -ChromeScope $chromeScope

if ($taskUpdateSucceeded) {
  Write-Result "At least one Google updater scheduled task completed successfully."
}
else {
  Write-Result "No Google updater scheduled task reported success." "WARN"
}

if (-not $chromeWasRunning) {
  Write-Result "Opening Chrome to chrome://settings/help to trigger Chrome's own update check path."

  $startedAt = Get-Date

  Start-Process $chrome -ArgumentList "chrome://settings/help"

  Write-Result "Waiting 60 seconds for Chrome to process update state."
  Start-Sleep -Seconds 60

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

    Start-Sleep -Seconds 10

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

  Start-Sleep -Seconds 5
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
    Write-Result "Chrome version did not change. It may already be current, the updater failed internally, or the update requires a later restart." "INFO"
  }
}

Show-UpdaterDiagnostics

Write-Result "Chrome update script completed."
exit 0
