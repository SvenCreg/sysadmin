$ErrorActionPreference = "SilentlyContinue"

# Check whether Chrome is actually installed before doing anything else
$chrome = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# If Chrome is not installed, do nothing and exit successfully
if (-not $chrome) {
  exit 0
}

$chromeWasRunning = @(Get-Process chrome).Count -gt 0

# Try old GoogleUpdate.exe first
$oldUpdater = @(
  "$env:ProgramFiles(x86)\Google\Update\GoogleUpdate.exe",
  "$env:LOCALAPPDATA\Google\Update\GoogleUpdate.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# Try newer GoogleUpdater location
$newUpdater = Get-ChildItem `
  -Path "$env:ProgramFiles(x86)\Google\GoogleUpdater", "$env:LOCALAPPDATA\Google\GoogleUpdater" `
  -Filter "updater.exe" `
  -Recurse |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

# If Chrome exists but no updater is found, do nothing
if ($oldUpdater) {
  Start-Process $oldUpdater -ArgumentList "/ua /installsource scheduler" -Wait
}
elseif ($newUpdater) {
  Start-Process $newUpdater.FullName -ArgumentList "--wake" -Wait
}
else {
  exit 0
}

# Only open/close Chrome if it was not already running
if (-not $chromeWasRunning) {
  $startedAt = Get-Date

  Start-Process $chrome -ArgumentList "chrome://settings/help"

  Start-Sleep -Seconds 30

  Get-Process chrome |
    Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
    ForEach-Object {
      try {
        if ($_.MainWindowHandle -ne 0) {
          $null = $_.CloseMainWindow()
        }
      } catch {}
    }

  Start-Sleep -Seconds 5

  Get-Process chrome |
    Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
    Stop-Process -Force
}

exit 0
