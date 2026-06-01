$ErrorActionPreference = "SilentlyContinue"

$chromeWasRunning = @(Get-Process chrome).Count -gt 0

$chrome = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $chrome) {
  Write-Error "chrome.exe not found."
  exit 1
}

# Try old GoogleUpdate.exe first, then newer GoogleUpdater\*\updater.exe
$oldUpdater = @(
  "$env:ProgramFiles(x86)\Google\Update\GoogleUpdate.exe",
  "$env:LOCALAPPDATA\Google\Update\GoogleUpdate.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$newUpdater = Get-ChildItem `
  -Path "$env:ProgramFiles(x86)\Google\GoogleUpdater", "$env:LOCALAPPDATA\Google\GoogleUpdater" `
  -Filter "updater.exe" `
  -Recurse |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if ($oldUpdater) {
  Start-Process $oldUpdater -ArgumentList "/ua /installsource scheduler" -Wait
}
elseif ($newUpdater) {
  Start-Process $newUpdater.FullName -ArgumentList "--wake" -Wait
}
else {
  Write-Error "No Google updater executable found."
  exit 1
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
