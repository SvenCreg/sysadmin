$chromeWasRunning = @(Get-Process chrome -ErrorAction SilentlyContinue).Count -gt 0

$googleUpdate = @(
  "$env:ProgramFiles(x86)\Google\Update\GoogleUpdate.exe",
  "$env:LOCALAPPDATA\Google\Update\GoogleUpdate.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$chrome = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $googleUpdate) {
  Write-Error "GoogleUpdate.exe not found."
  exit 1
}

if (-not $chrome) {
  Write-Error "chrome.exe not found."
  exit 1
}

# Check for/download/install Chrome updates
Start-Process $googleUpdate -ArgumentList "/ua /installsource scheduler" -Wait

# Only open Chrome if it was not already open
if (-not $chromeWasRunning) {
  $startedAt = Get-Date

  Start-Process $chrome -ArgumentList "chrome://settings/help"

  # Give Chrome time to process/apply the update prompt/state
  Start-Sleep -Seconds 30

  # Since Chrome was not running before, these should be only the Chrome processes we caused
  $chromeProcesses = Get-Process chrome -ErrorAction SilentlyContinue |
    Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) }

  foreach ($p in $chromeProcesses) {
    try {
      if ($p.MainWindowHandle -ne 0) {
        $null = $p.CloseMainWindow()
      }
    } catch {}
  }

  Start-Sleep -Seconds 5

  # Force-close any remaining Chrome processes that were started by this script
  Get-Process chrome -ErrorAction SilentlyContinue |
    Where-Object { $_.StartTime -ge $startedAt.AddSeconds(-2) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
}
